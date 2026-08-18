//
//  LyricsPane.swift
//  ViviMusic
//
//  同期歌詞を表示し、現在行を自動でスクロールして中央に保つ。
//  行をタップするとその時刻へシークする (VIVI Music と同じ挙動)。
//

import SwiftUI

struct LyricsPane: View {
    let lyric: LyricResult
    let currentTime: TimeInterval
    let onSeek: (TimeInterval) -> Void

    /// 現在再生中の行の index。無ければ -1。
    private var activeIndex: Int {
        guard lyric.synced else { return -1 }
        var index = -1
        for (i, line) in lyric.lines.enumerated() {
            if line.time <= currentTime { index = i } else { break }
        }
        return index
    }

    var body: some View {
        Group {
            if lyric.isEmpty {
                StateMessage(kind: .empty(
                    icon: "quote.bubble",
                    title: "歌詞が見つかりません",
                    message: "LRCLib にこの曲の歌詞が登録されていないようです。"
                ))
            } else if lyric.synced {
                syncedView
            } else {
                plainView
            }
        }
    }

    // MARK: - 同期歌詞

    private var syncedView: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 18) {
                    // 上下に余白を入れて、最初と最後の行も中央に来られるようにする
                    Color.clear.frame(height: 120)

                    ForEach(Array(lyric.lines.enumerated()), id: \.element.id) { index, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(index == activeIndex
                                  ? .title3.weight(.bold)
                                  : .body)
                            .foregroundStyle(index == activeIndex
                                             ? Theme.accent
                                             : Color.primary.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { onSeek(line.time) }
                            .animation(.easeOut(duration: 0.25), value: activeIndex)
                    }

                    Color.clear.frame(height: 200)
                }
                .padding(.horizontal, 28)
            }
            .onChange(of: activeIndex) { _, newIndex in
                guard newIndex >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    // MARK: - 通常歌詞

    private var plainView: some View {
        ScrollView {
            Text(lyric.plainText)
                .font(.body)
                .lineSpacing(8)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
        }
    }
}
