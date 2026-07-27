//
//  SongMenuSheet.swift
//  ViviMusic
//
//  曲の三点リーダーを押したときに出るメニュー。
//  本家 VIVI Music の `ui/menu/SongMenu.kt` に相当する。
//
//  上部に曲の情報と主要な操作 (次に再生 / キューに追加 / 共有) を横並びで置き、
//  その下に一覧形式で各機能を並べる構成にしている。
//

import SwiftUI
import UIKit

struct SongMenuSheet: View {
    let song: Song
    /// アルバム / アーティストへ遷移したいときに呼ぶ。
    /// 呼び出し元が NavigationStack を持っているのでそちらに任せる。
    var onNavigate: ((BrowseRoute) -> Void)?

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var playlists: PlaylistStore
    @Environment(\.dismiss) private var dismiss

    @State private var showPlaylistPicker = false
    @State private var showShareSheet = false
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    quickActions
                    actionList
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(isPresented: $showPlaylistPicker) {
                PlaylistPickerSheet(song: song)
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = song.shareURL {
                    ShareSheet(items: [url])
                }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - ヘッダ

    private var header: some View {
        HStack(spacing: 12) {
            Artwork(url: song.thumbnailURL, size: 56, radius: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                library.toggleFavorite(song)
                showToast(library.isFavorite(song.id)
                          ? "お気に入りに追加しました"
                          : "お気に入りから削除しました")
            } label: {
                Image(systemName: library.isFavorite(song.id) ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(library.isFavorite(song.id) ? Theme.accent : .primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
    }

    private var subtitleText: String {
        var parts = [song.artist]
        if song.durationSeconds != nil { parts.append(song.durationText) }
        return parts.joined(separator: " • ")
    }

    // MARK: - 主要な操作

    private var quickActions: some View {
        HStack(spacing: 10) {
            quickAction(title: "次に再生",
                        icon: "text.line.first.and.arrowtriangle.forward") {
                player.playNext(song)
                showToast("次に再生します")
            }
            quickAction(title: "追加", icon: "text.badge.plus") {
                player.addToQueue(song)
                showToast("キューに追加しました")
            }
            quickAction(title: "共有", icon: "square.and.arrow.up") {
                showShareSheet = true
            }
        }
        .padding(.horizontal, 20)
    }

    private func quickAction(title: String,
                             icon: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).font(.footnote.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 機能一覧

    private var actionList: some View {
        VStack(spacing: 8) {
            // ラジオ: この曲に似た曲でキューを作る
            menuRow(icon: "dot.radiowaves.left.and.right",
                    title: "ラジオを再生",
                    subtitle: "この曲をもとに似た曲を再生します") {
                dismiss()
                Task { await playRadio() }
            }

            menuRow(icon: "music.note.list",
                    title: "プレイリストに追加",
                    subtitle: playlistSubtitle) {
                showPlaylistPicker = true
            }

            // ダウンロード (状態に応じて表示を切り替える)
            downloadRow

            // アーティストを表示
            if let route = song.artistRoute {
                menuRow(icon: "person.crop.square",
                        title: "アーティストを表示",
                        subtitle: song.artist) {
                    dismiss()
                    onNavigate?(route)
                }
            }

            // アルバムを表示
            if let route = song.albumRoute {
                menuRow(icon: "smallcircle.filled.circle",
                        title: "アルバムを表示",
                        subtitle: song.album ?? "") {
                    dismiss()
                    onNavigate?(route)
                }
            }

            menuRow(icon: "info.circle",
                    title: "詳細",
                    subtitle: "この曲の情報をコピーします") {
                UIPasteboard.general.string = detailText
                showToast("詳細をコピーしました")
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var downloadRow: some View {
        if downloads.isDownloaded(song.id) {
            menuRow(icon: "trash",
                    title: "ダウンロードを削除",
                    subtitle: "端末から削除します",
                    tint: .red) {
                downloads.delete(song.id)
                showToast("ダウンロードを削除しました")
            }
        } else if let progress = downloads.progress[song.id] {
            HStack(spacing: 14) {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ダウンロード中")
                        .font(.subheadline.weight(.medium))
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("中止") {
                    downloads.cancel(song.id)
                    showToast("ダウンロードを中止しました")
                }
                .font(.footnote)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            menuRow(icon: "arrow.down.circle",
                    title: "ダウンロード",
                    subtitle: "オフライン再生用に保存します") {
                Task {
                    await downloads.download(song)
                }
                showToast("ダウンロードを開始しました")
            }
        }
    }

    private func menuRow(icon: String,
                         title: String,
                         subtitle: String,
                         tint: Color = .primary,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 24)
                    .foregroundStyle(tint == .primary ? Theme.accent : tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(tint)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var playlistSubtitle: String {
        let names = playlists.playlistNames(containing: song.id)
        if names.isEmpty { return "保存先を選びます" }
        return "追加済み: \(names.joined(separator: "、"))"
    }

    private var detailText: String {
        var lines = ["タイトル: \(song.title)", "アーティスト: \(song.artist)"]
        if let album = song.album { lines.append("アルバム: \(album)") }
        if song.durationSeconds != nil { lines.append("再生時間: \(song.durationText)") }
        lines.append("videoId: \(song.id)")
        if let url = song.shareURL { lines.append("URL: \(url.absoluteString)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - 動作

    /// この曲を起点に、関連曲でキューを作って再生する。
    private func playRadio() async {
        EventLog.log(.queue, videoID: song.id, message: "ラジオ再生を開始")
        let related = await YouTubeAPI.related(videoID: song.id)
        var queue = [song]
        queue.append(contentsOf: related.filter { $0.id != song.id })
        await player.setQueue(queue, startAt: 0)
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { toast = nil }
        }
    }
}

// MARK: - プレイリスト選択

/// 「プレイリストに追加」で出す選択シート。
struct PlaylistPickerSheet: View {
    let song: Song

    @EnvironmentObject private var playlists: PlaylistStore
    @Environment(\.dismiss) private var dismiss

    @State private var showCreateDialog = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newName = ""
                        showCreateDialog = true
                    } label: {
                        Label("新しいプレイリストを作成", systemImage: "plus.circle")
                    }
                }

                if playlists.playlists.isEmpty {
                    Section {
                        Text("プレイリストがまだありません。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("保存先") {
                        ForEach(playlists.playlists) { playlist in
                            let contains = playlist.songs.contains { $0.id == song.id }
                            Button {
                                if contains {
                                    playlists.removeSong(song.id, from: playlist.id)
                                } else {
                                    playlists.add(song, to: playlist.id)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    PlaylistCover(urls: playlist.coverURLs, size: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .foregroundStyle(.primary)
                                        Text(playlist.subtitleText)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: contains
                                          ? "checkmark.circle.fill"
                                          : "circle")
                                        .foregroundStyle(contains ? Theme.accent : .secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("プレイリストに追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { dismiss() }
                }
            }
            .alert("新しいプレイリスト", isPresented: $showCreateDialog) {
                TextField("名前", text: $newName)
                Button("キャンセル", role: .cancel) {}
                Button("作成") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    playlists.create(name: name.isEmpty ? "新しいプレイリスト" : name,
                                     songs: [song])
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
