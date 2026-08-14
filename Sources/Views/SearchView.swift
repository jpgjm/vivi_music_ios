//
//  SearchView.swift
//  ViviMusic
//
//  YouTube Music と同じ構成の検索画面。
//    - 入力中は候補 (オートコンプリート) を出す
//    - 確定すると「すべて / 曲 / 動画 / アルバム / アーティスト / プレイリスト」
//      のタブで絞り込める
//    - 「すべて」では 上位の結果 / 曲 / アルバム … が見出しつきで並ぶ
//

import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var player: PlayerManager

    @State private var query = ""
    @State private var filter: SearchFilter = .all
    /// 絞り込みごとに結果を覚えておき、タブを往復しても再取得しない。
    @State private var cache: [SearchFilter: [SearchSection]] = [:]
    @State private var suggestions: [SearchSuggestion] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    @State private var suggestionTask: Task<Void, Never>?
    /// 検索を実行した語。これが入力と一致する間は候補を出さない。
    @State private var searchedQuery = ""
    @State private var recentQueries: [String] = SearchView.loadRecent()
    /// アルバム / アーティスト / プレイリストへの遷移経路。
    @State private var path: [BrowseRoute] = []

    private var sections: [SearchSection] { cache[filter] ?? [] }
    private var hasSearched: Bool { !searchedQuery.isEmpty }

    private var showSuggestions: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
            && query != searchedQuery
            && !suggestions.isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if hasSearched && !showSuggestions {
                    filterBar
                }

                Group {
                    if showSuggestions {
                        suggestionList
                    } else if isSearching && sections.isEmpty {
                        StateMessage(kind: .loading("検索中…"))
                    } else if let errorMessage, sections.isEmpty {
                        StateMessage(kind: .error(errorMessage, retry: {
                            Task { await performSearch(query, filter: filter) }
                        }))
                    } else if sections.isEmpty {
                        emptyState
                    } else {
                        resultList
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .navigationTitle("検索")
            .navigationDestination(for: BrowseRoute.self) { route in
                // 曲メニューからさらに別のアルバム / アーティストへ飛べるよう、
                // この画面の path に積む経路を渡しておく。
                BrowseDetailView(route: route) { path.append($0) }
            }
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "曲名・アーティスト名")
            .onChange(of: query) { _, newValue in
                scheduleSuggestions(newValue)
            }
            .onSubmit(of: .search) {
                suggestionTask?.cancel()
                Task { await performSearch(query, filter: filter) }
            }
        }
    }

    // MARK: - 絞り込みタブ

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.allCases) { candidate in
                    FilterChip(
                        title: candidate.title,
                        selected: filter == candidate
                    ) {
                        guard filter != candidate else { return }
                        filter = candidate
                        // 未取得の絞り込みならここで取りにいく
                        if cache[candidate] == nil {
                            Task { await performSearch(searchedQuery, filter: candidate) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - 結果

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        // 区画が 1 つだけなら見出しは冗長なので出さない
                        if sections.count > 1 {
                            Text(section.title)
                                .font(.title3.weight(.bold))
                                .padding(.horizontal, 16)
                                .padding(.bottom, 2)
                        }

                        ForEach(section.items) { item in
                            SearchResultRow(item: item, onNavigate: { path.append($0) })
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                                .onTapGesture { handleTap(item, in: section) }
                        }
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, Theme.miniPlayerHeight + 24)
        }
    }

    private func handleTap(_ item: HomeItem, in section: SearchSection) {
        if case .song(let song) = item {
            // 同じ区画の曲をまとめてキューにする
            let queue = section.items.compactMap(\.song)
            Task { await player.play(song: song, queue: queue) }
        } else if let route = item.route {
            EventLog.log(.search, message: "\(route.kind.displayName)へ遷移: \(route.title)")
            path.append(route)
        }
    }

    // MARK: - 候補

    private var suggestionList: some View {
        List {
            ForEach(suggestions) { suggestion in
                switch suggestion {
                case .query(let text):
                    Button {
                        query = text
                        suggestionTask?.cancel()
                        Task { await performSearch(text, filter: filter) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            Text(text).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                case .song(let song):
                    SongRow(song: song, onNavigate: { path.append($0) })
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let queue = suggestions.compactMap { s -> Song? in
                                if case .song(let x) = s { return x }
                                return nil
                            }
                            Task { await player.play(song: song, queue: queue) }
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                }
            }

            Color.clear
                .frame(height: Theme.miniPlayerHeight)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
    }

    // MARK: - 未検索 / 0 件

    private var emptyState: some View {
        ScrollView {
            if hasSearched {
                StateMessage(kind: .empty(
                    icon: "magnifyingglass",
                    title: "見つかりませんでした",
                    message: "「\(searchedQuery)」に一致する\(filter.title)はありません。"
                ))
                .padding(.top, 40)
            } else if recentQueries.isEmpty {
                StateMessage(kind: .empty(
                    icon: "magnifyingglass",
                    title: "YouTube を検索",
                    message: "曲名やアーティスト名を入力してください。"
                ))
                .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("最近の検索").font(.headline)
                        Spacer()
                        Button("消去") {
                            recentQueries = []
                            SearchView.saveRecent([])
                        }
                        .font(.footnote)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    ForEach(recentQueries, id: \.self) { q in
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text(q)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            query = q
                            suggestionTask?.cancel()
                            Task { await performSearch(q, filter: filter) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 候補の取得

    /// 入力から 250ms 待ってから候補を取りにいく。
    private func scheduleSuggestions(_ text: String) {
        suggestionTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            suggestions = []
            cache = [:]
            errorMessage = nil
            searchedQuery = ""
            return
        }
        guard trimmed != searchedQuery else { return }

        suggestionTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let found = await YouTubeAPI.searchSuggestions(trimmed)
            guard !Task.isCancelled else { return }
            suggestions = found
        }
    }

    // MARK: - 検索

    private func performSearch(_ text: String, filter targetFilter: SearchFilter) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 語が変わったら全ての絞り込みの結果を捨てる
        if trimmed != searchedQuery {
            cache = [:]
        }

        isSearching = true
        errorMessage = nil
        suggestions = []
        searchedQuery = trimmed
        filter = targetFilter

        do {
            let found = try await YouTubeAPI.search(trimmed, filter: targetFilter)
            cache[targetFilter] = found
            if found.isEmpty {
                errorMessage = nil   // 0 件は emptyState で扱う
            } else {
                addRecent(trimmed)
            }
        } catch {
            errorMessage = error.localizedDescription
            EventLog.logError(.search, error: error,
                              context: "検索 \"\(trimmed)\" [\(targetFilter.title)]")
        }
        isSearching = false
    }

    // MARK: - 検索履歴

    private func addRecent(_ q: String) {
        var list = recentQueries.filter { $0 != q }
        list.insert(q, at: 0)
        if list.count > 15 { list.removeLast(list.count - 15) }
        recentQueries = list
        SearchView.saveRecent(list)
    }

    private static let recentKey = "SearchView.recentQueries"

    private static func loadRecent() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }

    private static func saveRecent(_ list: [String]) {
        UserDefaults.standard.set(list, forKey: recentKey)
    }
}

// MARK: - 結果 1 行

/// 検索結果の行。曲以外 (アルバム / アーティスト / プレイリスト) も扱う。
struct SearchResultRow: View {
    let item: HomeItem
    var onNavigate: ((BrowseRoute) -> Void)? = nil

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        if case .song(let song) = item {
            SongRow(song: song, onNavigate: onNavigate)
        } else {
            HStack(spacing: 12) {
                Artwork(url: item.thumbnailURL,
                        size: 48,
                        radius: 8,
                        circular: item.isCircular)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(kindLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text("・\(subtitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }

    /// 種別を短いラベルで示す。一覧の中で何なのかすぐ分かるようにする。
    private var kindLabel: String {
        switch item {
        case .song:     return "曲"
        case .album:    return "アルバム"
        case .artist:   return "アーティスト"
        case .playlist: return "プレイリスト"
        }
    }
}

// MARK: - 絞り込みチップ

struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(selected ? Theme.accent : Color(.secondarySystemBackground))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
