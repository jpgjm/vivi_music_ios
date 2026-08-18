//
//  ItemMenuSheet.swift
//  ViviMusic
//
//  アルバム / アーティスト / プレイリストの三点リーダーを押したときに出すメニュー。
//  本家 VIVI Music の `ui/menu/YouTubeAlbumMenu.kt` / `YouTubeArtistMenu.kt` /
//  `YouTubePlaylistMenu.kt` にあたる。
//
//  本家は「再生」「シャッフル」「ラジオ」などを、検索結果に付いてくる
//  endpoint (watchPlaylistEndpoint) を使って即座に始められる。
//  こちらはその endpoint を持っていないので、開いた時点で browse を 1 回叩き、
//  中身の曲を取ってから各操作を行う。曲が取れるまでは操作を無効にしておく。
//
//  曲の三点リーダー (SongMenuSheet) と同じ骨格にして、
//  操作の位置が種類ごとに変わらないようにしている。
//

import SwiftUI

struct ItemMenuSheet: View {
    /// 曲以外の項目 (曲を渡した場合は何もできないので、閉じるだけの表示になる)。
    let item: HomeItem
    /// 詳細ページへ遷移したいときに呼ぶ。呼び出し元の NavigationStack に任せる。
    var onNavigate: ((BrowseRoute) -> Void)?

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    /// browse で取れた曲。アーティストなら「人気の曲」が入る。
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var showShareSheet = false
    @State private var toast: String?

    private var route: BrowseRoute? { item.route }
    private var hasSongs: Bool { !songs.isEmpty }

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
            .task {
                if isLoading { await load() }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = shareURL {
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
            Artwork(url: item.thumbnailURL,
                    size: 56,
                    radius: 8,
                    circular: item.isCircular)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 20)
    }

    /// 曲の取得状況。何ができる状態なのかを一言で示す。
    private var statusText: String {
        if isLoading { return "曲を確認しています…" }
        if loadFailed { return "曲を取得できませんでした" }
        if songs.isEmpty { return "再生できる曲は見つかりませんでした" }
        return "\(songs.count) 曲"
    }

    // MARK: - 主要な操作

    private var quickActions: some View {
        HStack(spacing: 10) {
            quickAction(title: "再生", icon: "play.fill", enabled: hasSongs) {
                dismiss()
                Task { await player.setQueue(songs, startAt: 0) }
            }
            quickAction(title: "シャッフル", icon: "shuffle", enabled: hasSongs) {
                dismiss()
                Task { await player.shufflePlay(songs) }
            }
            quickAction(title: "共有", icon: "square.and.arrow.up",
                        enabled: shareURL != nil) {
                showShareSheet = true
            }
        }
        .padding(.horizontal, 20)
    }

    private func quickAction(title: String,
                             icon: String,
                             enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading && !enabled {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon)
                }
                Text(title).font(.footnote.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    // MARK: - 機能一覧

    private var actionList: some View {
        VStack(spacing: 8) {
            if let route {
                menuRow(icon: openIcon,
                        title: "\(route.kind.displayName)を開く",
                        subtitle: item.title) {
                    dismiss()
                    onNavigate?(route)
                }
            }

            menuRow(icon: "text.badge.plus",
                    title: "すべてキューに追加",
                    subtitle: hasSongs ? "\(songs.count) 曲を追加します" : "曲を取得できていません",
                    enabled: hasSongs) {
                for song in songs { player.addToQueue(song) }
                showToast("キューに \(songs.count) 曲を追加しました")
            }

            menuRow(icon: "arrow.down.circle",
                    title: "すべてダウンロード",
                    subtitle: hasSongs
                        ? "オフライン再生用に保存します"
                        : "曲を取得できていません",
                    enabled: hasSongs) {
                let targets = songs
                Task {
                    for song in targets { await downloads.download(song) }
                }
                showToast("\(targets.count) 曲のダウンロードを開始しました")
            }

            if loadFailed {
                menuRow(icon: "arrow.clockwise",
                        title: "もう一度読み込む",
                        subtitle: "曲の取得に失敗しました") {
                    Task { await load() }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    /// 種類ごとの記号。詳細画面のヘッダと印象を揃える。
    private var openIcon: String {
        switch item {
        case .album:    return "smallcircle.filled.circle"
        case .artist:   return "person.crop.square"
        case .playlist: return "music.note.list"
        case .song:     return "music.note"
        }
    }

    private func menuRow(icon: String,
                         title: String,
                         subtitle: String,
                         enabled: Bool = true,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 24)
                    .foregroundStyle(Theme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
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
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    // MARK: - 共有

    /// 共有用の URL。種類ごとに形が違う。
    private var shareURL: URL? {
        guard let route else { return nil }
        switch route.kind {
        case .artist:
            return URL(string: "https://music.youtube.com/channel/\(route.browseID)")
        case .album:
            return URL(string: "https://music.youtube.com/browse/\(route.browseID)")
        case .playlist:
            // playlist?list= には VL を外した id を渡す決まり。
            let id = route.browseID.hasPrefix("VL")
                ? String(route.browseID.dropFirst(2))
                : route.browseID
            return URL(string: "https://music.youtube.com/playlist?list=\(id)")
        }
    }

    // MARK: - 読み込み

    /// 中身の曲を取りにいく。
    ///
    /// アルバム / プレイリストは収録曲、アーティストは人気の曲が入る。
    /// 失敗しても画面は開いたままにして、「もう一度読み込む」を出す。
    private func load() async {
        guard let route else {
            isLoading = false
            return
        }
        isLoading = true
        loadFailed = false
        do {
            let page = try await YouTubeAPI.browsePage(route: route)
            songs = page.songs
        } catch {
            loadFailed = true
            EventLog.logError(.home, error: error,
                              context: "\(route.kind.displayName)メニュー \(route.browseID)")
        }
        isLoading = false
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { toast = nil }
        }
    }
}
