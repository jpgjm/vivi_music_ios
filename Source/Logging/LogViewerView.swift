import SwiftUI

/// アプリ内ログの閲覧・共有画面 (汎用版)。
/// 共有シートの件名は実行時に Bundle のアプリ表示名から導出するため、アプリごとの変更は不要。
struct LogViewerView: View {
    @State private var minimumLevel: LogLevel = .debug
    @State private var showClearConfirm = false

    private var log: AppLog { AppLog.shared }

    private var filtered: [LogEntry] {
        log.entries.filter { $0.level >= minimumLevel }.reversed()
    }

    var body: some View {
        List {
            Section {
                Picker("最低レベル", selection: $minimumLevel) {
                    ForEach(LogLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("件数", value: "\(filtered.count) / \(log.entries.count)")
                LabeledContent("保存先") {
                    Text(log.fileURL.path)
                        .font(.caption2)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            }
            Section("ログ (新しい順)") {
                ForEach(filtered) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: entry.level.symbolName)
                                .foregroundStyle(color(for: entry.level))
                            Text(entry.level.label)
                                .font(.caption.bold())
                                .foregroundStyle(color(for: entry.level))
                            Text(entry.category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(LogEntry.formatter.string(from: entry.date))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.message)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("ログ")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(
                    item: log.exportText(minimumLevel: minimumLevel),
                    subject: Text("\(AppLog.appDisplayName) ログ"),
                    preview: SharePreview("\(AppLog.appDisplayName) ログ", image: Image(systemName: "doc.text"))
                ) {
                    Label("共有", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("消去", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("ログを消去しますか？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("消去", role: .destructive) { log.clear() }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// ログ画面をシートとして表示するためのラッパー。
///
/// 表示方法までアプリ間で揃えるため、ログ画面は必ずこのラッパーを
/// `.sheet` で表示する (NavigationLink でのプッシュ表示はしない)。
/// 使い方:
///     @State private var showLogs = false
///     Button("ログ") { showLogs = true }
///         .sheet(isPresented: $showLogs) { LogViewerSheet() }
struct LogViewerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LogViewerView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    }
                }
        }
    }
}
