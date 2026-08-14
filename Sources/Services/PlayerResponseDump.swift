//
//  PlayerResponseDump.swift
//  ViviMusic
//
//  `player` エンドポイントの応答をそのままファイルに残す。
//
//  なぜ必要か:
//    2026-08 の「1 MiB で 403」を追う過程で、
//    yt-dlp が見ている実験フラグ `html5_generate_content_po_token` を
//    ViviMusic 側でも探すことにした。ただし yt-dlp が読んでいるのは
//    ウェブページの `ytcfg` であり、InnerTube の player 応答に
//    同じものが入っている保証がない。
//
//    「フラグが見つからない」ときに、
//      - そもそも応答に無いのか
//      - 場所が違って拾えていないのか
//    を区別するには、応答そのものを見るしかない。
//
//  扱いに注意:
//    応答には再生 URL (署名・pot 付き) が含まれる。
//    どれも短時間で失効するものだが、共有するときは中身を意識すること。
//    そのため既定では **オフ** にしてある。
//

import Foundation

enum PlayerResponseDump {

    /// 設定画面のトグルと対応する鍵。
    static let defaultsKey = "diagnostics.dumpPlayerResponse"

    /// 残しておく個数。増えすぎないよう古いものから消す。
    private static let keepCount = 10

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// 書き出し先。ログの ZIP に同梱できるよう Log の下に置く。
    static var directory: URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        return docs
            .appendingPathComponent("Log", isDirectory: true)
            .appendingPathComponent("player-response", isDirectory: true)
    }

    /// 応答を書き出す。トグルがオフなら何もしない。
    ///
    /// - Parameters:
    ///   - data: `player` の応答そのまま
    ///   - videoID: 対象の動画
    ///   - clientName: どのクライアントの応答か
    static func write(data: Data, videoID: String, clientName: String) {
        guard isEnabled, let directory else { return }

        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyyMMdd-HHmmss.SSS"
            let name = "\(df.string(from: Date()))_\(clientName)_\(videoID).json"

            // 読みやすさのため整形して書く。
            // 失敗したら生のまま残す (中身が見られることの方が大事)。
            let output: Data
            if let object = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .withoutEscapingSlashes]) {
                output = pretty
            } else {
                output = data
            }

            try output.write(to: directory.appendingPathComponent(name))
            EventLog.log(.network, videoID: videoID,
                         message: "player 応答を保存: \(name) (\(output.count / 1024)KiB)")

            prune(in: directory)
        } catch {
            EventLog.log(.network, videoID: videoID,
                         message: "player 応答の保存に失敗: \(error.localizedDescription)")
        }
    }

    /// 古いものから消して `keepCount` 個に保つ。
    private static func prune(in directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return da > db   // 新しい順
        }
        for file in sorted.dropFirst(keepCount) {
            try? fm.removeItem(at: file)
        }
    }

    /// 保存済みの件数と合計サイズ。設定画面に出す。
    static func summary() -> (count: Int, bytes: Int) {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey])
        else { return (0, 0) }

        let bytes = files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return (files.count, bytes)
    }

    /// すべて削除する。
    static func removeAll() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
