//
//  SABRStream.swift
//  ViviMusic
//
//  SABR (Server Adaptive BitRate) で音声を取得する。
//
//  ── なぜ必要か ──────────────────────────────────────────
//  2026-08 以降、googlevideo の再生 URL が
//  「ファイル先頭 1 MiB より先を返さない」状態になることがある。
//  Range ヘッダでも range= クエリでも Range 無しでも同じで、
//  取り直した URL でも同じ位置で拒否される。
//
//  SABR はサーバー主導でメディアを送る仕組みで、
//  この制限を受けない。実測で確認済み:
//
//    直接 URL 1MiB以降 = 403 の同時刻に
//    SABR は 1105KiB (69秒ぶん) を取得できた
//
//  ── 位置づけ ────────────────────────────────────────────
//  **最後の逃げ道**として使う。
//  ANDROID_VR などが通るならそちらが速いので、順番は変えない。
//
//  ── 割り切り (第1版) ────────────────────────────────────
//  曲全体を取り切ってから再生する。
//  進行に合わせて流し込む形にすると AVFoundation との
//  やり取りが複雑になるため、まず「確実に鳴る」ことを優先した。
//  4 MB 程度なので数秒で終わる。
//

import Foundation

enum SABRError: LocalizedError {
    case missingConfig
    case noAudioFormat
    case rejected(status: Int)
    case noMedia

    var errorDescription: String? {
        switch self {
        case .missingConfig:      return "SABR の設定を取得できません"
        case .noAudioFormat:      return "SABR で使える音声形式がありません"
        case .rejected(let code): return "SABR が拒否されました (HTTP \(code))"
        case .noMedia:            return "SABR からメディアが返りません"
        }
    }
}

/// SABR で 1 曲分の音声を取得する。
actor SABRStream {

    private let videoID: String
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    // サーバーとのやり取りに要る状態
    private var abrURL = ""
    private var ustreamerConfig = ""
    private var itag = 140
    private var lastModified: UInt64 = 0
    private var totalLength = 0
    private var mimeType = "audio/mp4"
    private var bitrate = 130_000
    private var poToken: String?

    private var contexts: [Int: SABRProbe.SabrContext] = [:]
    private var activeTypes: Set<Int> = []
    private var playbackCookie: Data?
    private var requestNumber = 0

    /// 組み上がったファイル本体。
    /// MEDIA_HEADER の start_range をもとに正しい位置へ書く。
    private var fileData = Data()
    /// header_id ごとの書き込み位置。
    private var writeOffsets: [Int: Int] = [:]

    init(videoID: String) {
        self.videoID = videoID
    }

    // MARK: - 取得

    /// player を叩いて SABR の入口を用意し、曲全体を取り切る。
    /// - Returns: 音声ファイルの中身と、その形式
    func fetchAll() async throws -> (data: Data, mimeType: String, bitrate: Int) {
        try await prepare()

        // 1 往復目。ここでサーバーからコンテキストの指示が来る。
        let first = try await roundTrip(playerTimeMs: 0, buffered: nil)
        var buffered = first.buffered

        // 指示に従い、コンテキストを載せて取り直す
        if first.mediaBytes == 0 {
            if first.backoffMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(first.backoffMs) * 1_000_000)
            }
            let second = try await roundTrip(playerTimeMs: 0, buffered: nil)
            buffered = second.buffered
            guard second.mediaBytes > 0 else { throw SABRError.noMedia }
        }

        // 残りを順に取る
        for _ in 0..<200 {
            guard fileData.count < totalLength || totalLength == 0 else { break }
            guard let range = buffered else { break }

            let next = try await roundTrip(playerTimeMs: range.startTimeMs + range.durationMs,
                                           buffered: range)
            guard next.mediaBytes > 0 else { break }

            if let more = next.buffered {
                buffered = SABRProbe.BufferedRange(
                    startTimeMs: range.startTimeMs,
                    durationMs: range.durationMs + more.durationMs,
                    startSegmentIndex: range.startSegmentIndex,
                    endSegmentIndex: more.endSegmentIndex,
                    timescale: more.timescale ?? range.timescale
                )
            }
        }

        guard !fileData.isEmpty else { throw SABRError.noMedia }

        EventLog.log(.resolveOK, videoID: videoID,
                     message: "SABR で取得完了 \(fileData.count / 1024)KiB "
                         + "/ 想定 \(totalLength / 1024)KiB")
        return (fileData, mimeType, bitrate)
    }

    // MARK: - 準備

    private func prepare() async throws {
        // WEB は SABR 専用応答を返すので、この用途に向いている。
        let raw = try await InnerTube.shared.player(videoID: videoID, client: .web)

        guard let rawURL = raw["streamingData"]["serverAbrStreamingUrl"].string,
              let config = raw.path("playerConfig", "mediaCommonConfig",
                                    "mediaUstreamerRequestConfig",
                                    "videoPlaybackUstreamerConfig").string else {
            throw SABRError.missingConfig
        }

        // `n=` が変換前で降ってくるので必ず復号を通す。
        // ここを飛ばすと入口で 403 になる。
        abrURL = await PlayerJSService.shared.decipher(rawURL)
        ustreamerConfig = config

        let audio = raw["streamingData"]["adaptiveFormats"].array.filter {
            ($0["mimeType"].string ?? "").hasPrefix("audio/")
        }
        // iOS で鳴らせる AAC を選ぶ。webm/opus は AVFoundation が扱えない。
        guard let format = audio.first(where: {
            ($0["mimeType"].string ?? "").hasPrefix("audio/mp4")
        }) else {
            throw SABRError.noAudioFormat
        }

        itag = format["itag"].int ?? 140
        lastModified = UInt64(format["lastModified"].string ?? "") ?? 0
        totalLength = Int(format["contentLength"].string ?? "") ?? 0
        mimeType = format["mimeType"].string ?? "audio/mp4"
        bitrate = format["bitrate"].int ?? 130_000

        if let sessionID = await InnerTube.shared.visitorData {
            let dataSyncID = await CookieAuthService.shared.credentials?.dataSyncID
            let binding = PoTokenBindingResolver.binding(dataSyncID: dataSyncID,
                                                         visitorData: sessionID)
            poToken = await PoTokenService.shared.tokens(videoID: videoID,
                                                        sessionID: sessionID,
                                                        binding: binding)?.streaming
        }

        EventLog.log(.resolveOK, videoID: videoID,
                     message: "SABR 準備完了 itag=\(itag) "
                         + "全長 \(totalLength / 1024)KiB")
    }

    // MARK: - 1 往復

    private struct RoundTrip {
        var mediaBytes = 0
        var buffered: SABRProbe.BufferedRange?
        var backoffMs = 0
    }

    private func roundTrip(playerTimeMs: Int,
                           buffered: SABRProbe.BufferedRange?) async throws -> RoundTrip {
        guard var components = URLComponents(string: abrURL) else {
            throw SABRError.missingConfig
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "rn" }
        items.append(URLQueryItem(name: "rn", value: String(requestNumber)))
        components.queryItems = items
        requestNumber += 1

        guard let url = components.url else { throw SABRError.missingConfig }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = SABRProbe.buildBody(ustreamerConfig: ustreamerConfig,
                                               itag: itag,
                                               lastModified: lastModified,
                                               playerTimeMs: playerTimeMs,
                                               poToken: poToken,
                                               playbackCookie: playbackCookie,
                                               sabrContexts: contexts,
                                               activeTypes: activeTypes,
                                               buffered: buffered)
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.yt-ump", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw SABRError.rejected(status: status) }

        return consume(UMPReader.parseDetailed(data))
    }

    /// 応答を取り込み、メディアをファイル本体へ書き込む。
    private func consume(_ parsed: UMPReader.ParseResult) -> RoundTrip {
        var result = RoundTrip()
        var headers: [UMPMediaHeader] = []

        for part in parsed.parts {
            switch UMPPartType(rawValue: part.type) {
            case .mediaHeader:
                let header = UMPMediaHeader(part.payload)
                headers.append(header)
                if let id = header.headerID {
                    // このヘッダに属するデータをどこへ書くか
                    writeOffsets[id] = header.startRange ?? fileData.count
                }

            case .media:
                // 先頭 1 バイトは header_id。残りが本体。
                guard part.payload.count > 1, let id = part.payload.first else { break }
                let payload = part.payload.dropFirst()
                let offset = writeOffsets[Int(id)] ?? fileData.count
                write(payload, at: offset)
                writeOffsets[Int(id)] = offset + payload.count
                result.mediaBytes += payload.count

            case .sabrContextUpdate:
                if let ctx = SABRProbe.parseContextUpdate(part.payload) {
                    contexts[ctx.type] = ctx
                    if ctx.sendByDefault { activeTypes.insert(ctx.type) }
                }

            case .sabrContextSendingPolicy:
                var reader = ProtobufReader(part.payload)
                while let (field, value) = reader.next() {
                    guard let type = value.int else { continue }
                    switch field {
                    case 1: activeTypes.insert(type)
                    case 2: activeTypes.remove(type)
                    case 3: contexts.removeValue(forKey: type); activeTypes.remove(type)
                    default: break
                    }
                }

            case .nextRequestPolicy:
                var reader = ProtobufReader(part.payload)
                while let (field, value) = reader.next() {
                    if field == 4 { result.backoffMs = value.int ?? 0 }
                    if field == 7, let cookie = value.data, !cookie.isEmpty {
                        playbackCookie = cookie
                    }
                }

            default:
                break
            }
        }

        if let first = headers.first, let last = headers.last {
            result.buffered = SABRProbe.BufferedRange(
                startTimeMs: first.startMs ?? 0,
                durationMs: headers.reduce(0) { $0 + ($1.durationMs ?? 0) },
                startSegmentIndex: first.sequenceNumber ?? 1,
                endSegmentIndex: last.sequenceNumber ?? 1,
                timescale: first.timescale
            )
        }
        return result
    }

    /// 指定位置へ書き込む。足りなければ 0 で埋めて伸ばす。
    private func write(_ payload: Data, at offset: Int) {
        if offset > fileData.count {
            fileData.append(Data(repeating: 0, count: offset - fileData.count))
        }
        if offset == fileData.count {
            fileData.append(payload)
        } else {
            let end = min(offset + payload.count, fileData.count)
            fileData.replaceSubrange(offset..<end, with: payload)
            if offset + payload.count > end {
                fileData.append(payload.suffix(offset + payload.count - end))
            }
        }
    }
}
