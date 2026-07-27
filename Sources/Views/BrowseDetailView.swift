//
//  BrowseDetailView.swift
//  ViviMusic
//
//  アルバム / プレイリスト / アーティストの詳細画面。
//  3 種類とも「ヘッダ + 曲リスト or 棚」という同じ骨格なので 1 画面で兼ねる。
//

import SwiftUI

struct BrowseDetailView: View {
    let route: BrowseRoute

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager

    @State private var page: BrowsePage?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && page == nil {
                StateMessage(kind: .loading("\(route.kind.displayName)を読み込んでいます…"))
            } else if let errorMessage, page == nil {
                StateMessage(kind: .error(errorMessage, retry: {
                    Task { await load() }
                }))
            } else if let page {
                content(page)
            }
        }
        .navigationTitle(page?.title ?? route.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if page == nil { await load() }
        }
    }

    // MARK: - 本体

    private func content(_ page: BrowsePage) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                header(page)

                if !page.songs.isEmpty {
                    songList(page.songs)
                }

                ForEach(page.sections) { section in
                    ShelfSection(section: section) { item in
                        if case .song(let song) = item {
                            let queue = section.items.compactMap(\.song)
                            Task { await player.play(song: song, queue: queue) }
                        }
                    }
                }
            }
            .padding(.bottom, Theme.miniPlayerHeight + 24)
        }
        .refreshable { await load() }
    }

    // MARK: - ヘッダ

    private func header(_ page: BrowsePage) -> some View {
        VStack(spacing: 14) {
            Artwork(url: page.thumbnailURL,
                    size: 200,
                    radius: Theme.largeArtworkRadius,
                    circular: page.kind == .artist)
                .shadow(color: .black.opacity(0.2), radius: 16, y: 8)

            VStack(spacing: 4) {
                Text(page.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                if let subtitle = page.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }

                if !page.songs.isEmpty {
                    Text("\(page.songs.count) 曲")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 24)

            if !page.songs.isEmpty {
                actionButtons(page.songs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func actionButtons(_ songs: [Song]) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await player.setQueue(songs, startAt: 0) }
            } label: {
                Label("再生", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)

            Button {
                Task { await player.shufflePlay(songs) }
            } label: {
                Label("シャッフル", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)

            Menu {
                Button {
                    for song in songs { player.addToQueue(song) }
                } label: {
                    Label("すべてキューに追加", systemImage: "text.badge.plus")
                }
                Button {
                    Task {
                        for song in songs { await downloads.download(song) }
                    }
                } label: {
                    Label("すべてダウンロード", systemImage: "arrow.down.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - 曲リスト

    private func songList(_ songs: [Song]) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)

                    SongRow(song: song)
                }
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await player.play(song: song, queue: songs) }
                }
            }
        }
    }

    // MARK: - 読み込み

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await YouTubeAPI.browsePage(route: route)
            if result.isEmpty {
                errorMessage = "この\(route.kind.displayName)の内容を取得できませんでした。"
            } else {
                page = result
            }
        } catch {
            errorMessage = error.localizedDescription
            EventLog.logError(.home, error: error,
                              context: "\(route.kind.displayName) \(route.browseID)")
        }
        isLoading = false
    }
}
