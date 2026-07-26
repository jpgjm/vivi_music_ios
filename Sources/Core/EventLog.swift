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
        lines.append("iOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
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

    /// ログを `Documents/Log/` 配下にテキストファイルとして書き出し、その URL を返す。
    ///
    /// Documents に置くのは、Info.plist で UIFileSharingEnabled を有効にしているため
    /// 「ファイル」アプリからも直接開けるようにするため。
    static func writeExportFile() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }

        let logDir = docs.appendingPathComponent("Log", isDirectory: true)
        if !fm.fileExists(atPath: logDir.path) {
            do {
                try fm.createDirectory(at: logDir, withIntermediateDirectories: true)
            } catch {
                print("[EventLog] failed to create Log directory: \(error)")
                return nil
            }
        }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        let name = "ViviMusic-log-\(df.string(from: Date())).txt"
        let url = logDir.appendingPathComponent(name)

        do {
            try exportText().data(using: .utf8)?.write(to: url)
            return url
        } catch {
            print("[EventLog] export failed: \(error)")
            return nil
        }
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
