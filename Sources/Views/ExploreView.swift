//
//  ExploreView.swift
//  ViviMusic
//
//  「最近のトレンド」に相当する画面。
//  YouTube Music の 探索 / チャート / 新着リリース を切り替えて表示する。
//
//  - チャート    : 国別の人気曲・人気アーティスト (いわゆるトレンド)
//  - 新着        : 新着アルバム / シングル
//  - 探索        : ムード・ジャンル別のプレイリスト入口
//

import SwiftUI

struct ExploreView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case charts = "チャート"
        case newReleases = "新着"
        case moods = "ムード"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .charts:      return "chart.line.uptrend.xyaxis"
            case .newReleases: return "sparkles"
            case .moods:       return "circle.grid.2x2"
            }
        }
    }

    @EnvironmentObject private var player: PlayerManager

    @State private var tab: Tab = .charts
    /// タブごとに結果をキャッシュして、切り替えのたびに再取得しないようにする。
    @State private var cache: [Tab: [HomeSection]] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// アルバム / プレイリスト / アーティストへの遷移経路。
    @State private var path: [BrowseRoute] = []

    private var sections: [HomeSection] { cache[tab] ?? [] }

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

                Group {
                    if isLoading && sections.isEmpty {
                        StateMessage(kind: .loading("\(tab.rawValue)を読み込んでいます…"))
                    } else if let errorMessage, sections.isEmpty {
                        StateMessage(kind: .error(errorMessage, retry: {
                            Task { await load(force: true) }
                        }))
                    } else if sections.isEmpty {
                        StateMessage(kind: .empty(
                            icon: "tray",
                            title: "内容がありません",
                            message: "地域によっては提供されていない場合があります。"
                        ))
                    } else {
                        list
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .navigationTitle("探索")
            .navigationDestination(for: BrowseRoute.self) { route in
                BrowseDetailView(route: route)
            }
        }
        .task(id: tab) { await load(force: false) }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(sections) { section in
                    if section.items.allSatisfy({ $0.song != nil }) {
                        // チャートは順位つきの縦リストで見せる
                        RankedSongList(section: section)
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
        .refreshable { await load(force: true) }
    }

    private func handleTap(_ item: HomeItem, in section: HomeSection) {
        if case .song(let song) = item {
            let queue = section.items.compactMap(\.song)
            Task { await player.play(song: song, queue: queue) }
        } else if let route = item.route {
            EventLog.log(.explore, message: "\(route.kind.displayName)へ遷移: \(route.title)")
            path.append(route)
        }
    }

    private func load(force: Bool) async {
        if !force, cache[tab] != nil { return }
        isLoading = true
        errorMessage = nil
        do {
            let result: [HomeSection]
            switch tab {
            case .charts:      result = try await YouTubeAPI.charts()
            case .newReleases: result = try await YouTubeAPI.newReleases()
            case .moods:       result = try await YouTubeAPI.explore()
            }
            cache[tab] = result
        } catch {
            errorMessage = error.localizedDescription
            EventLog.logError(.explore, error: error, context: "\(tab.rawValue) 読み込み")
        }
        isLoading = false
    }
}

// MARK: - 順位つきリスト

/// チャート用。左に順位を出した縦リスト。
struct RankedSongList: View {
    let section: HomeSection
    @EnvironmentObject private var player: PlayerManager

    private var songs: [Song] { section.items.compactMap(\.song) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            VStack(spacing: 2) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .trailing)

                        SongRow(song: song)
                    }
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task { await player.play(song: song, queue: songs) }
                    }
                    .contextMenu { SongContextMenu(song: song) }
                }
            }
        }
    }
}
