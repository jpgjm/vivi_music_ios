//
//  EventLog.swift
//  ViviMusic
//
//  「いつ・何が・どの曲に対して起きたか」を時系列で記録する診断用ログ。
//
//  目的:
//    「再生されない」「ダウンロードが失敗する」といった不具合は、
//    "検索 → ストリーム解決 → AVPlayer 投入 → 再生開始" のどの段階で
//    崩れたのかが分からないと原因を特定できない。
//    videoId とタイムスタンプを突き合わせられるよう、主要な操作を全て記録する。
//
//  設計 (AlarmClock の EventLog と同方式):
//    - `enum` の static メソッドとして実装し、どこからでも呼べるようにする。
//    - 保存先は UserDefaults。
//    - 件数が増え続けないよう上限を設け、古いものから捨てる。
//    - Documents/Log 配下にテキストとして書き出せるようにし、
//      「ファイル」アプリや共有シートから取り出せるようにする。
//

import Foundation

/// ログ 1 件分。
struct LogEntry: Codable, Identifiable {
    var id: UUID
    var timestamp: Date
    /// 出来事の種類 (EventLog.Category.rawValue)
    var category: String
    /// 関連する videoId (無い場合は nil)
    var videoID: String?
    /// 補足情報
    var message: String

    init(category: String, videoID: String?, message: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.category = category
        self.videoID = videoID
        self.message = message
    }
}

enum EventLog {

    /// 出来事の種類。UI での色分けや絞り込みにも使う。
    enum Category: String, CaseIterable {
        case bootstrap    = "起動"
        case network      = "通信"
        case home         = "ホーム"
        case explore      = "探索"
        case search       = "検索"
        case resolveOK    = "URL解決成功"
        case resolveNG    = "URL解決失敗"
        case playStart    = "再生開始"
        case playStop     = "再生停止"
        case playError    = "再生エラー"
        case queue        = "キュー"
        case downloadStart = "DL開始"
        case downloadOK   = "DL完了"
        case downloadNG   = "DL失敗"
        case lyrics       = "歌詞"
        case storage      = "保存"
        case playlist     = "プレイリスト"
        case timer        = "タイマー"
        case auth         = "ログイン"
        case together     = "Together"

        /// エラー系かどうか (UI で赤く表示する判定に使う)
        var isError: Bool {
            switch self {
            case .resolveNG, .playError, .downloadNG:
                return true
            default:
                return false
            }
        }
    }

    private static let storageKey = "EventLog.entries"
    private static let maxEntries = 800

    /// 同時書き込みでログが壊れないようにするためのロック。
    private static let lock = NSLock()

    // MARK: - 記録

    /// 出来事を 1 件記録する。
    /// - Parameters:
    ///   - category: 出来事の種類
    ///   - videoID: 対象の videoId (あれば)
    ///   - message: 補足情報 (URL の一部・エラー内容など、後から追える情報を入れる)
    static func log(_ category: Category, videoID: String? = nil, message: String = "") {
        let entry = LogEntry(
            category: category.rawValue,
            videoID: videoID,
            message: message
        )

        lock.lock()
        var all = loadRaw()
        all.append(entry)
        if all.count > maxEntries {
            all.removeFirst(all.count - maxEntries)
        }
        saveRaw(all)
        lock.unlock()

        #if DEBUG
        print("[\(category.rawValue)] \(videoID ?? "-") \(message)")
        #endif
    }

    /// 経過時間つきで記録する。処理時間のボトルネック特定に使う。
    static func logDuration(_ category: Category,
                            videoID: String? = nil,
                            start: Date,
                            message: String = "") {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let combined = message.isEmpty ? "\(ms)ms" : "\(message) (\(ms)ms)"
        log(category, videoID: videoID, message: combined)
    }

    /// エラーを記録する。`Error` の中身をできるだけ詳しく残す。
    static func logError(_ category: Category,
                         videoID: String? = nil,
                         error: Error,
                         context: String = "") {
        var parts: [String] = []
        if !context.isEmpty { parts.append(context) }
        parts.append(String(describing: type(of: error)))
        parts.append(error.localizedDescription)

        // URLError は code も残すと原因の切り分けが早い
        if let urlError = error as? URLError {
            parts.append("URLError.code=\(urlError.errorCode)")
        }
        log(category, videoID: videoID, message: parts.joined(separator: " | "))
    }

    // MARK: - 取得

    /// 記録されているログを新しい順で返す。
    static func entries() -> [LogEntry] {
        loadRaw().reversed()
    }

    /// 記録件数。
    static func count() -> Int {
        loadRaw().count
    }

    /// すべて消す。
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // MARK: - 書き出し

    /// ログを人が読めるテキストに整形する (古い順)。
    static func exportText() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        var lines: [String] = []
        lines.append("VIVI Music 診断ログ")
        lines.append("書き出し日時: \(df.string(from: Date()))")
        lines.append("件数: \(count())")
        lines.append("端末: \(DeviceInfo.machineIdentifier)"
                     + " / \(DeviceInfo.model)"
                     + " / \(DeviceInfo.idiom)")
        lines.append("OS: \(DeviceInfo.systemName) / \(DeviceInfo.osVersion)")
        lines.append("メモリ: \(DeviceInfo.physicalMemoryText)"
                     + " (\(DeviceInfo.physicalMemory) バイト)"
                     + " / コア \(DeviceInfo.processorCount)")
        lines.append("状態: 発熱 \(DeviceInfo.thermalState)"
                     + " / 低電力モード \(DeviceInfo.isLowPowerMode ? "オン" : "オフ")")
        lines.append(String(repeating: "-", count: 60))

        for e in loadRaw() {
            let time = df.string(from: e.timestamp)
            let idPart = e.videoID ?? "-"
            lines.append("\(time)  [\(e.category)]  id=\(idPart)")
            if !e.message.isEmpty {
                lines.append("    \(e.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// ログを NDJSON (1 行 1 レコード) に整形する (古い順)。
    ///
    /// テキスト版が人間向けなのに対し、こちらは機械処理向け。
    /// `jq` や表計算に流し込んで絞り込み・集計ができる。
    /// 途中で壊れても行単位で読めるので、テキスト版より扱いやすい。
    static func exportJSONL() -> String {
        let encoder = JSONEncoder()
        // 生成順を安定させたいのでキーのソートはしない (宣言順のまま)。
        // スラッシュのエスケープは可読性を落とすだけなので外す。
        encoder.outputFormatting = [.withoutEscapingSlashes]

        var lines: [String] = []

        // 1 行目に端末情報を入れる。
        // NDJSON は 1 行 1 レコードなので、`type` で見分けられるようにしておけば
        // 構造を壊さずにヘッダ相当の情報を持たせられる。
        let meta = MetaRecord(
            type: "meta",
            ts: iso8601Formatter.string(from: Date()),
            app: "VIVI Music",
            count: count(),
            machine: DeviceInfo.machineIdentifier,
            model: DeviceInfo.model,
            idiom: DeviceInfo.idiom,
            systemName: DeviceInfo.systemName,
            osVersion: DeviceInfo.osVersion,
            physicalMemory: DeviceInfo.physicalMemory,
            processorCount: DeviceInfo.processorCount,
            thermalState: DeviceInfo.thermalState,
            lowPowerMode: DeviceInfo.isLowPowerMode
        )
        if let data = try? encoder.encode(meta),
           let text = String(data: data, encoding: .utf8) {
            lines.append(text)
        }

        for entry in loadRaw() {
            let record = LogRecord(
                ts: iso8601Formatter.string(from: entry.timestamp),
                category: entry.category,
                level: Category(rawValue: entry.category)?.isError == true ? "ERROR" : "INFO",
                videoId: entry.videoID,
                message: entry.message
            )
            guard let data = try? encoder.encode(record),
                  let text = String(data: data, encoding: .utf8) else { continue }
            lines.append(text)
        }
        // NDJSON は末尾も改行で終えるのが慣例。
        return lines.joined(separator: "\n") + "\n"
    }

    /// NDJSON の 1 行目に入れる端末情報。
    private struct MetaRecord: Encodable {
        let type: String
        let ts: String
        let app: String
        let count: Int
        let machine: String
        let model: String
        let idiom: String
        let systemName: String
        let osVersion: String
        let physicalMemory: UInt64
        let processorCount: Int
        let thermalState: String
        let lowPowerMode: Bool
    }

    /// NDJSON の 1 レコード。キーの並びは宣言順になる。
    private struct LogRecord: Encodable {
        let ts: String
        let category: String
        let level: String
        /// 対象の曲が無い行では出力しない。
        let videoId: String?
        let message: String
    }

    /// ログを ZIP にまとめて `Documents/Log/` に置き、その URL を返す。
    ///
    /// 出来上がる構造:
    ///
    ///     2026-08-13T04-49-35+09-00_log.zip
    ///       └─ 2026-08-13T04-49-35+09-00_log/
    ///            ├─ 2026-08-13T04-49-35+09-00_log.txt
    ///            └─ 2026-08-13T04-49-35+09-00_log.jsonl
    ///
    /// テキストと NDJSON を両方入れるのは、目視で追う用途と
    /// 機械処理する用途のどちらにも一度で対応するため。
    ///
    /// ZIP 化には `NSFileCoordinator` の `.forUploading` を使う。
    /// これはディレクトリを読み取るときに一時的な ZIP を作る仕組みで、
    /// 外部ライブラリを足さずに済む。
    ///
    /// Documents に置くのは、Info.plist で UIFileSharingEnabled を
    /// 有効にしているため「ファイル」アプリからも取り出せるようにするため。
    static func writeExportBundle() -> URL? {
        let fm = FileManager.default
        let base = "\(filenameTimestamp(Date()))_log"

        // 1. 一時領域に <base>/ を作り、2 つのファイルを書く
        let work = fm.temporaryDirectory
            .appendingPathComponent("log-export-\(UUID().uuidString)", isDirectory: true)
        let folder = work.appendingPathComponent(base, isDirectory: true)
        defer { try? fm.removeItem(at: work) }

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(exportText().utf8)
                .write(to: folder.appendingPathComponent("\(base).txt"))
            try Data(exportJSONL().utf8)
                .write(to: folder.appendingPathComponent("\(base).jsonl"))

        } catch {
            print("[EventLog] failed to stage log files: \(error)")
            return nil
        }

        // 2. 置き場所を用意する
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let logDir = docs.appendingPathComponent("Log", isDirectory: true)
        if !fm.fileExists(atPath: logDir.path) {
            do {
                try fm.createDirectory(at: logDir, withIntermediateDirectories: true)
            } catch {
                print("[EventLog] failed to create Log directory: \(error)")
                return nil
            }
        }
        let destination = logDir.appendingPathComponent("\(base).zip")

        // 3. ZIP 化して置き場所へコピーする
        //    クロージャに渡される URL は抜けた時点で消えるので、
        //    その中でコピーを済ませる必要がある。
        var coordinatorError: NSError?
        var result: URL?
        NSFileCoordinator().coordinate(readingItemAt: folder,
                                       options: .forUploading,
                                       error: &coordinatorError) { zipURL in
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: zipURL, to: destination)
                result = destination
            } catch {
                print("[EventLog] failed to copy zip: \(error)")
            }
        }
        if let coordinatorError {
            print("[EventLog] zip failed: \(coordinatorError)")
            return nil
        }
        return result
    }

    // MARK: - 日時の整形

    /// NDJSON の `ts` に使う形式 (例: 2026-08-13T04:59:19.694+09:00)。
    private static let iso8601Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"
        return f
    }()

    /// ファイル名に使う形式 (例: 2026-08-13T04-49-35+09-00)。
    ///
    /// `:` はファイル名に使えるものの、環境によって扱いが割れるので
    /// すべて `-` に置き換える。時刻部分は元から `-` 区切りなので、
    /// 実際に置き換わるのはタイムゾーンの `+09:00` の部分だけ。
    private static func filenameTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ssXXX"
        return f.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    // MARK: - 内部

    private static func loadRaw() -> [LogEntry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([LogEntry].self, from: data) else {
            return []
        }
        return list
    }

    private static func saveRaw(_ entries: [LogEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
