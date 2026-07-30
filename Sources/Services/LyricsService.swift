//
//  LyricsService.swift
//  ViviMusic
//
//  LRCLib (https://lrclib.net) から歌詞を取得する。
//  認証不要・CC0 で、同期歌詞 (LRC) と通常テキストの両方が返る。
//

import Foundation

enum LyricsService {

    private static let base = "https://lrclib.net/api"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    /// 曲に対応する歌詞を探す。
    /// まず厳密一致 (/get) を試し、無ければ部分一致 (/search) に落とす。
    static func fetch(for song: Song) async -> LyricResult {
        let started = Date()

        // 1) 厳密一致。アルバム名と長さが揃っている場合のみ使える。
        if let album = song.album, let duration = song.durationSeconds {
            if let result = await get(track: song.title,
                                      artist: song.artist,
                                      album: album,
                                      duration: duration) {
                EventLog.logDuration(.lyrics, videoID: song.id, start: started,
                                     message: "厳密一致で取得 (synced=\(result.synced))")
                return result
            }
        }

        // 2) 部分一致
        if let result = await search(track: song.title, artist: song.artist) {
            EventLog.logDuration(.lyrics, videoID: song.id, start: started,
                                 message: "検索一致で取得 (synced=\(result.synced))")
            return result
        }

        EventLog.logDuration(.lyrics, videoID: song.id, start: started,
                             message: "歌詞が見つかりませんでした")
        return .empty
    }

    // MARK: - API 呼び出し

    private static func get(track: String, artist: String,
                            album: String, duration: Int) async -> LyricResult? {
        var comps = URLComponents(string: "\(base)/get")
        comps?.queryItems = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(duration)),
        ]
        guard let url = comps?.url else { return nil }
        return await request(url: url, takeFirstOfArray: false)
    }

    private static func search(track: String, artist: String) async -> LyricResult? {
        var comps = URLComponents(string: "\(base)/search")
        comps?.queryItems = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        guard let url = comps?.url else { return nil }
        return await request(url: url, takeFirstOfArray: true)
    }

    private static func request(url: URL, takeFirstOfArray: Bool) async -> LyricResult? {
        do {
            var req = URLRequest(url: url)
            req.setValue("ViviMusic/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                EventLog.log(.lyrics, message: "LRCLib HTTP \(status)")
                return nil
            }

            let json = JSON(data: data)
            let target = takeFirstOfArray ? json[0] : json
            guard target.exists else { return nil }
            return parse(target)

        } catch {
            EventLog.logError(.lyrics, error: error, context: "LRCLib 取得")
            return nil
        }
    }

    private static func parse(_ json: JSON) -> LyricResult? {
        let plain = json["plainLyrics"].string ?? ""
        if let synced = json["syncedLyrics"].string, !synced.isEmpty {
            return LyricResult(synced: true, lines: parseLRC(synced), plainText: plain)
        }
        if plain.isEmpty { return nil }
        return LyricResult(synced: false, lines: [], plainText: plain)
    }

    // MARK: - LRC パース

    /// `[mm:ss.xx] 歌詞` 形式を時刻つきの行に分解する。
    /// ここで解釈しているのはタイムスタンプの構造だけで、
    /// 歌詞テキストはソースコードには一切含まれない。
    static func parseLRC(_ lrc: String) -> [LyricLine] {
        let pattern = #"\[(\d+):(\d+)(?:\.(\d+))?\](.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var lines: [LyricLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let range = NSRange(raw.startIndex..., in: raw)
            guard let m = regex.firstMatch(in: raw, range: range) else { continue }

            func group(_ i: Int) -> String? {
                guard let r = Range(m.range(at: i), in: raw) else { return nil }
                return String(raw[r])
            }

            let minutes = Int(group(1) ?? "0") ?? 0
            let seconds = Int(group(2) ?? "0") ?? 0
            // 小数部は桁数がまちまちなので 3 桁に正規化する
            var millis = 0
            if let frac = group(3) {
                let padded = frac.padding(toLength: 3, withPad: "0", startingAt: 0)
                millis = Int(padded) ?? 0
            }
            let text = (group(4) ?? "").trimmingCharacters(in: .whitespaces)

            let time = TimeInterval(minutes * 60 + seconds) + TimeInterval(millis) / 1000
            lines.append(LyricLine(time: time, text: text))
        }
        return lines.sorted { $0.time < $1.time }
    }
}
