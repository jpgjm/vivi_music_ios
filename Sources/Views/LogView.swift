//
//  LogView.swift
//  ViviMusic
//
//  EventLog に溜まった診断ログを閲覧・絞り込み・書き出しする画面。
//  AlarmClock の LogView と同じ役割で、
//  「再生されない」「ダウンロードが失敗する」を追跡するための主要な道具。
//

import SwiftUI
import UIKit

struct LogView: View {
    @State private var entries: [LogEntry] = []
    @State private var filter: String? = nil       // nil = すべて
    @State private var showErrorsOnly = false
    @State private var exportURL: URL?
    @State private var showShare = false

    /// 実際に一覧に出す行。
    private var visible: [LogEntry] {
        entries.filter { entry in
            if showErrorsOnly {
                let category = EventLog.Category(rawValue: entry.category)
                guard category?.isError == true else { return false }
            }
            if let filter, entry.category != filter { return false }
            return true
        }
    }

    /// 実際に記録が存在する種類だけをフィルタ候補に出す。
    private var availableCategories: [String] {
        Array(Set(entries.map(\.category))).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar

            if visible.isEmpty {
                StateMessage(kind: .empty(
                    icon: "doc.text.magnifyingglass",
                    title: "ログがありません",
                    message: "アプリを操作すると記録が溜まります。"
                ))
                .frame(maxHeight: .infinity)
            } else {
                List(visible) { entry in
                    LogRow(entry: entry)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("診断ログ (\(entries.count))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        reload()
                    } label: {
                        Label("再読み込み", systemImage: "arrow.clockwise")
                    }
                    Button {
                        UIPasteboard.general.string = EventLog.exportText()
                    } label: {
                        Label("すべてコピー", systemImage: "doc.on.doc")
                    }
                    Button {
                        exportURL = EventLog.writeExportFile()
                        showShare = exportURL != nil
                    } label: {
                        Label("ファイルに書き出す", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button(role: .destructive) {
                        EventLog.clear()
                        reload()
                    } label: {
                        Label("ログを消去", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showShare) {
            if let exportURL {
                ShareSheet(items: [exportURL])
            }
        }
        .onAppear { reload() }
    }

    // MARK: - フィルタ

    private var filterBar: some View {
        VStack(spacing: 8) {
            Toggle("エラーのみ表示", isOn: $showErrorsOnly)
                .font(.footnote)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    LogFilterChip(title: "すべて", selected: filter == nil) {
                        filter = nil
                    }
                    ForEach(availableCategories, id: \.self) { category in
                        LogFilterChip(title: category, selected: filter == category) {
                            filter = (filter == category) ? nil : category
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private func reload() {
        entries = EventLog.entries()
    }
}

// MARK: - 行

private struct LogRow: View {
    let entry: LogEntry

    private var isError: Bool {
        EventLog.Category(rawValue: entry.category)?.isError == true
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "MM/dd HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.category)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isError ? Color.red.opacity(0.18) : Theme.accent.opacity(0.16))
                    .foregroundStyle(isError ? Color.red : Theme.accent)
                    .clipShape(Capsule())

                Text(Self.formatter.string(from: entry.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if let videoID = entry.videoID {
                    Text(videoID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }

            if !entry.message.isEmpty {
                Text(entry.message)
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : .primary)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - フィルタチップ

private struct LogFilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Theme.accent : Color(.tertiarySystemFill))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 共有シート

/// UIActivityViewController を SwiftUI から使うためのラッパ。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
