import Foundation

//
//  LogHelpers.swift
//  ViviMusic
//
//  汎用ログ部品 (AppLog / qlog) への ViviMusic 専用の整形ヘルパー。
//  旧 EventLog の logDuration / logError / videoID 付き記録と同じ情報量を
//  保ったまま、保存と表示は汎用 AppLog (HIGCatalog と同一 UI) に一本化する。
//

/// videoID 付きで記録する。videoID は "id=..." としてメッセージ先頭に付ける。
func qlogV(_ level: LogLevel, _ category: String, videoID: String? = nil, message: String = "") {
    var parts: [String] = []
    if let videoID { parts.append("id=\(videoID)") }
    if !message.isEmpty { parts.append(message) }
    qlog(level, category, parts.isEmpty ? "-" : parts.joined(separator: " | "))
}

/// 経過時間つきで記録する。処理時間のボトルネック特定に使う。
func qlogDuration(_ category: String, videoID: String? = nil, start: Date, message: String = "") {
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    let combined = message.isEmpty ? "\(ms)ms" : "\(message) (\(ms)ms)"
    qlogV(.info, category, videoID: videoID, message: combined)
}

/// エラーを記録する。`Error` の中身をできるだけ詳しく残す。
func qlogError(_ category: String, videoID: String? = nil, error: Error, context: String = "") {
    var parts: [String] = []
    if !context.isEmpty { parts.append(context) }
    parts.append(String(describing: type(of: error)))
    parts.append(error.localizedDescription)
    // URLError は code も残すと原因の切り分けが早い
    if let urlError = error as? URLError {
        parts.append("URLError.code=\(urlError.errorCode)")
    }
    qlogV(.error, category, videoID: videoID, message: parts.joined(separator: " | "))
}
