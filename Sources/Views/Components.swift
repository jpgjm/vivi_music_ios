//
//  Components.swift
//  ViviMusic
//
//  画面をまたいで使う小さな部品。
//

import SwiftUI

// MARK: - アートワーク

/// URL からアートワークを読み込んで表示する。読み込み中・失敗時はプレースホルダ。
struct Artwork: View {
    let url: String?
    var size: CGFloat?
    var radius: CGFloat = Theme.artworkRadius
    var circular: Bool = false

    var body: some View {
        Group {
            if let url, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        placeholder.overlay(ProgressView().controlSize(.small))
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }

    /// 角丸か円かを実行時に選ぶため AnyShape で型を消す。
    private var shape: AnyShape {
        circular
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Color(.tertiarySystemFill)
            Image(systemName: "music.note")
                .font(.system(size: (size ?? 48) * 0.32))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 曲の行

/// 検索結果・ライブラリなどで使う曲 1 行。
struct SongRow: View {
    let song: Song
    var showDownloadBadge: Bool = true
    var trailing: AnyView? = nil

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager

    private var isCurrent: Bool { player.currentSong?.id == song.id }

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: song.thumbnailURL, size: 48, radius: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)

                HStack(spacing: 4) {
                    if showDownloadBadge, downloads.isDownloaded(song.id) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                    }
                    Text(song.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isCurrent && player.isPlaying {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.variableColor.iterative)
            } else if song.durationSeconds != nil {
                Text(song.durationText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let trailing { trailing }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 横スクロールの棚

/// ホーム / 探索に並ぶ 1 セクション (横スクロール)。
struct ShelfSection: View {
    let section: HomeSection
    let onTapItem: (HomeItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let label = section.label, !label.isEmpty {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                Text(section.title)
                    .font(.title3.weight(.bold))
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(section.items) { item in
                        ShelfCard(item: item)
                            .onTapGesture { onTapItem(item) }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

/// 棚の中のカード 1 枚。
struct ShelfCard: View {
    let item: HomeItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: item.thumbnailURL,
                    size: Theme.shelfItemWidth,
                    circular: item.isCircular)

            Text(item.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: Theme.shelfItemWidth, alignment: .leading)
        .multilineTextAlignment(item.isCircular ? .center : .leading)
    }
}

// MARK: - 状態表示

/// 読み込み中 / 空 / エラーの共通表示。
struct StateMessage: View {
    enum Kind {
        case loading(String)
        case empty(icon: String, title: String, message: String)
        case error(String, retry: () -> Void)
    }

    let kind: Kind

    var body: some View {
        VStack(spacing: 12) {
            switch kind {
            case .loading(let text):
                ProgressView()
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            case .empty(let icon, let title, let message):
                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary)
                Text(title).font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

            case .error(let message, let retry):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text("読み込みに失敗しました").font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                Button("再試行", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

// MARK: - 曲のコンテキストメニュー

/// 曲を長押ししたときのメニュー。VIVI Music の SongMenu 相当。
struct SongContextMenu: View {
    let song: Song

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var playlists: PlaylistStore

    var body: some View {
        Button {
            player.playNext(song)
        } label: {
            Label("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            player.addToQueue(song)
        } label: {
            Label("キューに追加", systemImage: "text.badge.plus")
        }

        // プレイリストへの追加。
        // ここでダイアログを出すとコンテキストメニューの外に状態を持つ必要が
        // 出て複雑になるため、既存プレイリストへの追加はサブメニューで直接行い、
        // 新規作成は自動命名にしている (名前はライブラリ画面で変更できる)。
        Menu {
            ForEach(playlists.playlists) { playlist in
                Button {
                    playlists.add(song, to: playlist.id)
                } label: {
                    Label(playlist.name, systemImage: "music.note.list")
                }
            }
            if !playlists.playlists.isEmpty {
                Divider()
            }
            Button {
                let name = "プレイリスト \(playlists.playlists.count + 1)"
                playlists.create(name: name, songs: [song])
            } label: {
                Label("新規作成して追加", systemImage: "plus")
            }
        } label: {
            Label("プレイリストに追加", systemImage: "music.note.list")
        }

        Button {
            library.toggleFavorite(song)
        } label: {
            Label(library.isFavorite(song.id) ? "お気に入りから削除" : "お気に入りに追加",
                  systemImage: library.isFavorite(song.id) ? "heart.slash" : "heart")
        }

        if downloads.isDownloaded(song.id) {
            Button(role: .destructive) {
                downloads.delete(song.id)
            } label: {
                Label("ダウンロードを削除", systemImage: "trash")
            }
        } else if !downloads.isDownloading(song.id) {
            Button {
                Task { await downloads.download(song) }
            } label: {
                Label("ダウンロード", systemImage: "arrow.down.circle")
            }
        }
    }
}
