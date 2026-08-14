//
//  PlaylistDetailView.swift
//  ViviMusic
//
//  ローカルプレイリストの中身を表示・編集する画面。
//  並べ替えと削除は編集モードで行う (iOS 標準の EditButton を使う)。
//

import SwiftUI

struct PlaylistDetailView: View {
    let playlistID: UUID

    /// 曲メニューからアルバム / アーティストへ飛びたいときに呼ぶ。
    /// この画面は親の NavigationStack に push されているので遷移は親に任せる。
    var onNavigate: ((BrowseRoute) -> Void)?

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var showRenameDialog = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false

    /// Store から常に最新を引く (編集後に画面が古くならないように)。
    private var playlist: LocalPlaylist? {
        playlists.playlist(with: playlistID)
    }

    var body: some View {
        Group {
            if let playlist {
                content(playlist)
            } else {
                // 削除された直後など
                StateMessage(kind: .empty(
                    icon: "music.note.list",
                    title: "プレイリストが見つかりません",
                    message: "削除された可能性があります。"
                ))
            }
        }
        .navigationTitle(playlist?.name ?? "プレイリスト")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = playlist?.name ?? ""
                        showRenameDialog = true
                    } label: {
                        Label("名前を変更", systemImage: "pencil")
                    }

                    if let playlist, !playlist.songs.isEmpty {
                        Button {
                            Task {
                                for song in playlist.songs {
                                    await downloads.download(song)
                                }
                            }
                        } label: {
                            Label("すべてダウンロード", systemImage: "arrow.down.circle")
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("プレイリストを削除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .alert("名前を変更", isPresented: $showRenameDialog) {
            TextField("名前", text: $renameText)
            Button("キャンセル", role: .cancel) {}
            Button("変更") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                playlists.rename(playlistID, to: name)
            }
        }
        .confirmationDialog("このプレイリストを削除しますか?",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                playlists.delete(playlistID)
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    // MARK: - 本体

    private func content(_ playlist: LocalPlaylist) -> some View {
        List {
            Section {
                header(playlist)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if playlist.songs.isEmpty {
                Section {
                    StateMessage(kind: .empty(
                        icon: "plus.circle",
                        title: "曲がありません",
                        message: "検索やホームで曲を長押しして、このプレイリストに追加してください。"
                    ))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(playlist.songs) { song in
                        SongRow(song: song, onNavigate: onNavigate)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task {
                                    await player.play(song: song, queue: playlist.songs)
                                }
                            }
                            }
                    .onDelete { offsets in
                        let ids = offsets.map { playlist.songs[$0].id }
                        for id in ids {
                            playlists.removeSong(id, from: playlistID)
                        }
                    }
                    .onMove { source, destination in
                        playlists.moveSongs(in: playlistID,
                                            from: source, to: destination)
                    }
                }

                Section {
                    Color.clear
                        .frame(height: Theme.miniPlayerHeight)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - ヘッダ

    private func header(_ playlist: LocalPlaylist) -> some View {
        VStack(spacing: 14) {
            PlaylistCover(urls: playlist.coverURLs, size: 180)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)

            VStack(spacing: 3) {
                Text(playlist.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(playlist.subtitleText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !playlist.songs.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        Task { await player.setQueue(playlist.songs, startAt: 0) }
                    } label: {
                        Label("再生", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)

                    Button {
                        Task { await player.shufflePlay(playlist.songs) }
                    } label: {
                        Label("シャッフル", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
                }
                .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
