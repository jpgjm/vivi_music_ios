import Foundation
import Observation

/// ログの重要度。
enum LogLevel: Int, Codable, CaseIterable, Comparable, Identifiable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }

    var symbolName: String {
        switch self {
        case .debug: return "ant"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 1 行分のログ。ファイルには JSON Lines で保存する。
struct LogEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let level: LogLevel
    let category: String
    let message: String

    var line: String {
        "\(LogEntry.formatter.string(from: date)) [\(level.label)] [\(category)] \(message)"
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}

/// アプリ内ログ (汎用版)。
///
/// Mac が無く Xcode のコンソールを見られないため、ログはアプリ内の
/// 「ログ」画面で閲覧し、共有シートで書き出せるようにする。
/// 保存先は Documents/logs/<アプリ名小文字>.log (JSON Lines)。
/// ファイル名は実行時に CFBundleName から導出するため、アプリごとの変更は不要。
/// UIFileSharingEnabled を有効にしていれば「ファイル」App からも取り出せる。
@MainActor
@Observable
final class AppLog {
    static let shared = AppLog()

    /// ログファイル名に使うアプリ名 (実行時に Bundle から解決。ハードコードしない)。
    static var appFileName: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "app"
        let lower = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return lower.isEmpty ? "app" : lower
    }

    /// 共有シートの件名などに使うアプリ表示名 (実行時に Bundle から解決)。
    static var appDisplayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "App"
    }

    private(set) var entries: [LogEntry] = []

    /// メモリ上に保持する上限。超えた分は古いものから落とす (ファイルには残る)。
    private let memoryLimit = 2000
    /// 起動時にファイルから読み戻す行数。
    private let reloadLimit = 500

    let fileURL: URL
    private var handle: FileHandle?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("logs", isDirectory: true)
        fileURL = dir.appendingPathComponent("\(AppLog.appFileName).log")
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            loadTail()
            handle = try FileHandle(forWritingTo: fileURL)
            _ = try handle?.seekToEnd()
        } catch {
            print("AppLog: ファイルを開けません: \(error)")
        }
        log(.info, "log", "ログ開始 (\(fileURL.path))")
    }

    func log(_ level: LogLevel, _ category: String, _ message: String) {
        let entry = LogEntry(id: UUID(), date: Date(), level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > memoryLimit {
            entries.removeFirst(entries.count - memoryLimit)
        }
        print(entry.line)
        if let data = try? encoder.encode(entry) {
            var line = data
            line.append(0x0A)
            try? handle?.write(contentsOf: line)
        }
    }

    /// ファイル末尾の reloadLimit 行を読み戻す。
    private func loadTail() {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(reloadLimit)
        var loaded: [LogEntry] = []
        for line in lines {
            if let d = line.data(using: .utf8), let e = try? decoder.decode(LogEntry.self, from: d) {
                loaded.append(e)
            }
        }
        entries = loaded
    }

    /// 共有用のテキスト (メモリ上の全件)。
    func exportText(minimumLevel: LogLevel = .debug) -> String {
        entries.filter { $0.level >= minimumLevel }.map(\.line).joined(separator: "\n")
    }

    /// メモリとファイルの両方を空にする。
    func clear() {
        entries.removeAll()
        try? handle?.truncate(atOffset: 0)
        log(.info, "log", "ログを消去")
    }
}

/// どこからでも呼べるログ関数。
///
/// メインスレッド以外から呼ばれた場合はメインアクターへ送る。
func qlog(_ level: LogLevel = .info, _ category: String = "app", _ message: String) {
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            AppLog.shared.log(level, category, message)
        }
    } else {
        Task { @MainActor in
            AppLog.shared.log(level, category, message)
        }
    }
}
