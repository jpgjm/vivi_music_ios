//
//  HomeView.swift
//  ViviMusic
//
//  YouTube Music のホームフィードをそのまま表示する。
//  「Quick picks」「もう一度聴く」「おすすめのアルバム」などが
//  横スクロールの棚として縦に積まれる構成 (VIVI Music と同じ)。
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var player: PlayerManager

    @State private var sections: [HomeSection] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showSettings = false
    /// アルバム / プレイリスト / アーティストへの遷移経路。
    @State private var path: [BrowseRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if isLoading && sections.isEmpty {
                    StateMessage(kind: .loading("ホームを読み込んでいます…"))
                } else if let errorMessage, sections.isEmpty {
                    StateMessage(kind: .error(errorMessage, retry: {
                        Task { await load() }
                    }))
                } else {
                    content
                }
            }
            .navigationTitle("ホーム")
            .navigationDestination(for: BrowseRoute.self) { route in
                BrowseDetailView(route: route)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
        .task {
            if sections.isEmpty { await load() }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(sections) { section in
                    // 曲だけの棚は縦リストにした方が使いやすいので出し分ける
                    if section.items.allSatisfy({ $0.song != nil }) && section.items.count > 3 {
                        SongShelf(section: section)
                    } else {
                        ShelfSection(section: section) { item in
                            handleTap(item, in: section)
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, Theme.miniPlayerHeight + 24)
        }
        .refreshable { await load() }
    }

    // MARK: - 操作

    private func handleTap(_ item: HomeItem, in section: HomeSection) {
        if case .song(let song) = item {
            // 同じ棚の曲をまとめてキューにする
            let queue = section.items.compactMap(\.song)
            Task { await player.play(song: song, queue: queue) }
        } else if let route = item.route {
            EventLog.log(.home, message: "\(route.kind.displayName)へ遷移: \(route.title)")
            path.append(route)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            sections = try await YouTubeAPI.home()
            if sections.isEmpty {
                errorMessage = "ホームの内容を取得できませんでした。時間をおいて再試行してください。"
            }
        } catch {
            errorMessage = error.localizedDescription
            EventLog.logError(.home, error: error, context: "ホーム読み込み")
        }
        isLoading = false
    }
}

// MARK: - 曲だけの棚

/// 曲だけで構成された棚を、3 行 x 横スクロールのグリッドで表示する。
/// YouTube Music の "Quick picks" と同じレイアウト。
struct SongShelf: View {
    let section: HomeSection
    @EnvironmentObject private var player: PlayerManager

    private var songs: [Song] { section.items.compactMap(\.song) }

    /// 3 行に分割した列の配列を作る。
    private var columns: [[Song]] {
        stride(from: 0, to: songs.count, by: 3).map { start in
            Array(songs[start..<min(start + 3, songs.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        VStack(spacing: 4) {
                            ForEach(column) { song in
                                SongRow(song: song)
                                    .frame(width: 300)
                                    .onTapGesture {
                                        Task { await player.play(song: song, queue: songs) }
                                    }
                                    .contextMenu { SongContextMenu(song: song) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}
