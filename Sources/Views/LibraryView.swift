//
//  LibraryView.swift
//  ViviMusic
//

import SwiftUI

struct LibraryView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case playlists = "プレイリスト"
        case favorites = "お気に入り"
        case downloads = "ダウンロード"
        case history = "履歴"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .playlists: return "music.note.list"
            case .favorites: return "heart.fill"
            case .downloads: return "arrow.down.circle.fill"
            case .history:   return "clock.fill"
            }
        }
    }

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var playlists: PlaylistStore

    @State private var tab: Tab = .playlists
    @State private var path: [UUID] = []
    @State private var showCreateDialog = false
    @State private var newPlaylistName = ""

    private var songs: [Song] {
        switch tab {
        case .playlists: return []
        case .favorites: return library.favorites
        case .downloads: return downloads.downloadedSongs
        case .history:   return library.history
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { t in
                        Label(t.rawValue, systemImage: t.icon).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                if tab == .downloads && !downloads.downloadedSongs.isEmpty {
                    HStack {
                        Text("\(downloads.downloadedSongs.count) 曲 ・ \(downloads.totalSizeText())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                }

                if tab == .playlists {
                    playlistList
                } else if songs.isEmpty {
                    emptyState.frame(maxHeight: .infinity)
                } else {
                    songList
                }
            }
            .navigationTitle("ライブラリ")
            .navigationDestination(for: UUID.self) { id in
                PlaylistDetailView(playlistID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if tab == .playlists {
                        Button {
                            newPlaylistName = ""
                            showCreateDialog = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    } else if tab == .history && !library.history.isEmpty {
                        Button("消去") { library.clearHistory() }
                    }
                }
            }
            .alert("新しいプレイリスト", isPresented: $showCreateDialog) {
                TextField("名前", text: $newPlaylistName)
                Button("キャンセル", role: .cancel) {}
                Button("作成") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                    playlists.create(name: name.isEmpty ? "新しいプレイリスト" : name)
                }
            }
        }
    }

    // MARK: - プレイリスト一覧

    @ViewBuilder
    private var playlistList: some View {
        if playlists.playlists.isEmpty {
            StateMessage(kind: .empty(
                icon: "music.note.list",
                title: "プレイリストがありません",
                message: "右上の + から作成できます。曲を長押しして追加してください。"
            ))
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(playlists.playlists) { playlist in
                    PlaylistRow(playlist: playlist)
                        .contentShape(Rectangle())
                        .onTapGesture { path.append(playlist.id) }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16,
                                                  bottom: 4, trailing: 16))
                }
                .onDelete { offsets in
                    let ids = offsets.map { playlists.playlists[$0].id }
                    for id in ids { playlists.delete(id) }
                }
                .onMove { source, destination in
                    playlists.movePlaylists(from: source, to: destination)
                }

                Color.clear
                    .frame(height: Theme.miniPlayerHeight)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
        }
    }

    // MARK: - 曲リスト

    private var songList: some View {
        List {
            ForEach(songs) { song in
                SongRow(song: song, showDownloadBadge: tab != .downloads)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task { await player.play(song: song, queue: songs) }
                    }
                    .swipeActions(edge: .trailing) {
                        if tab == .favorites {
                            Button(role: .destructive) {
                                library.toggleFavorite(song)
                            } label: {
                                Label("削除", systemImage: "heart.slash")
                            }
                        } else if tab == .downloads {
                            Button(role: .destructive) {
                                downloads.delete(song.id)
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        } else if tab == .history {
                            Button {
                                library.toggleFavorite(song)
                            } label: {
                                Label("お気に入り", systemImage: "heart")
                            }
                            .tint(Theme.accent)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
            }

            Color.clear
                .frame(height: Theme.miniPlayerHeight)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var emptyState: some View {
        if tab == .favorites {
            StateMessage(kind: .empty(
                icon: "heart",
                title: "お気に入りはまだありません",
                message: "曲を長押しして「お気に入りに追加」を選ぶとここに並びます。"
            ))
        } else if tab == .downloads {
            StateMessage(kind: .empty(
                icon: "arrow.down.circle",
                title: "ダウンロードはまだありません",
                message: "プレイヤー画面のダウンロードボタンを押すと、オフラインでも再生できます。"
            ))
        } else {
            StateMessage(kind: .empty(
                icon: "clock",
                title: "再生履歴はまだありません",
                message: "再生した曲がここに記録されます。"
            ))
        }
    }
}

// MARK: - プレイリスト 1 行

/// 4 枚のサムネイルをタイル状に並べたカバーを持つ行。
struct PlaylistRow: View {
    let playlist: LocalPlaylist

    var body: some View {
        HStack(spacing: 12) {
            PlaylistCover(urls: playlist.coverURLs, size: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(playlist.subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

/// プレイリストのカバー。曲が 4 曲以上なら 2x2 のタイルにする。
struct PlaylistCover: View {
    let urls: [String]
    let size: CGFloat

    var body: some View {
        Group {
            if urls.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Artwork(url: urls[0], size: size / 2, radius: 0)
                        Artwork(url: urls[1], size: size / 2, radius: 0)
                    }
                    HStack(spacing: 0) {
                        Artwork(url: urls[2], size: size / 2, radius: 0)
                        Artwork(url: urls[3], size: size / 2, radius: 0)
                    }
                }
            } else if let first = urls.first {
                Artwork(url: first, size: size, radius: 0)
            } else {
                ZStack {
                    Color(.tertiarySystemFill)
                    Image(systemName: "music.note.list")
                        .font(.system(size: size * 0.34))
                        .foregroundStyle(.secondary)
                }
                .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
