//
//  MiniPlayerView.swift
//  ViviMusic
//

import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerManager

    private var progressRatio: Double {
        guard player.duration > 0 else { return 0 }
        return min(max(player.currentTime / player.duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Artwork(url: player.currentSong?.thumbnailURL, size: 44, radius: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(player.currentSong?.title ?? "")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if player.isPlayingLocal {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.accent)
                        }
                        Text(player.currentSong?.artist ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if player.isLoading {
                    ProgressView().controlSize(.small).frame(width: 34)
                } else {
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    Task { await player.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // 再生位置を細い線で示す
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: geo.size.width * progressRatio)
                }
            }
            .frame(height: 2)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}
