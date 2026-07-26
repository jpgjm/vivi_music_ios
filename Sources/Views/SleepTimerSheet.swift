//
//  SleepTimerSheet.swift
//  ViviMusic
//
//  スリープタイマーの設定シート。
//  「◯分後」と「この曲の終わり」の 2 通りを選べる。
//

import SwiftUI
import Combine

struct SleepTimerSheet: View {
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    /// 選べる長さ (分)。よく使う刻みだけ用意する。
    private let presets = [5, 10, 15, 30, 45, 60, 90]

    /// 残り時間の表示を 1 秒ごとに更新するためのタイマー。
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                if player.isSleepTimerActive {
                    Section {
                        HStack {
                            Image(systemName: "moon.fill")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("タイマー作動中")
                                    .font(.subheadline.weight(.semibold))
                                Text(statusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Spacer()
                        }

                        Button(role: .destructive) {
                            player.cancelSleepTimer()
                            dismiss()
                        } label: {
                            Label("タイマーを解除", systemImage: "xmark.circle")
                        }
                    }
                }

                Section("時間で止める") {
                    ForEach(presets, id: \.self) { minutes in
                        Button {
                            player.setSleepTimer(minutes: minutes)
                            dismiss()
                        } label: {
                            HStack {
                                Text("\(minutes) 分後")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .tint(.primary)
                    }
                }

                Section {
                    Button {
                        player.setSleepAtEndOfTrack()
                        dismiss()
                    } label: {
                        Label("この曲の終わりで止める", systemImage: "music.note")
                    }
                    .tint(.primary)
                } footer: {
                    Text("設定した時間になると再生を一時停止します。アプリは終了しません。")
                }
            }
            .navigationTitle("スリープタイマー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .onReceive(ticker) { now = $0 }
    }

    /// 残り時間 or 「曲の終わりまで」。
    private var statusText: String {
        if player.sleepAtEndOfTrack {
            return "この曲の終わりで停止します"
        }
        guard let end = player.sleepTimerEndDate else { return "" }
        let remaining = max(0, end.timeIntervalSince(now))
        return "残り \(Song.formatDuration(remaining))"
    }
}
