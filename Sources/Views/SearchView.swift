//
//  SearchView.swift
//  ViviMusic
//
//  入力中は候補 (オートコンプリート) を出し、確定してから検索する。
//  打鍵のたびに検索を投げる方式はレスポンスが重くなるうえ
//  YouTube 側への負荷も大きいので、YouTube Music と同じ「候補 → 確定」方式にしている。
//

import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var player: PlayerManager

    @State private var query = ""
    @State private var results: [Song] = []
    @State private var suggestions: [SearchSuggestion] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    /// 直前の候補取得タスク。入力のたびに古いものを捨てる。
    @State private var suggestionTask: Task<Void, Never>?
    /// 検索を実行した語。これが入力と一致する間は候補を出さない。
    @State private var searchedQuery = ""

    @State private var recentQueries: [String] = SearchView.loadRecent()

    /// 候補を出すべきか。入力があって、まだその語で検索していないとき。
    private var showSuggestions: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
            && query != searchedQuery
            && !suggestions.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if showSuggestions {
                    suggestionList
                } else if isSearching && results.isEmpty {
                    StateMessage(kind: .loading("検索中…"))
                } else if let errorMessage, results.isEmpty {
                    StateMessage(kind: .error(errorMessage, retry: {
                        Task { await performSearch(query) }
                    }))
                } else if results.isEmpty {
                    emptyState
                } else {
                    resultList
                }
            }
            .navigationTitle("検索")
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "曲名・アーティスト名")
            .onChange(of: query) { _, newValue in
                scheduleSuggestions(newValue)
            }
            .onSubmit(of: .search) {
                suggestionTask?.cancel()
                Task { await performSearch(query) }
            }
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
                        Task { await performSearch(text) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            Text(text)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16,
                                              bottom: 8, trailing: 16))

                case .song(let song):
                    // 曲そのものの候補はタップで直接再生する
                    SongRow(song: song)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let queue = suggestions.compactMap { s -> Song? in
                                if case .song(let x) = s { return x }
                                return nil
                            }
                            Task { await player.play(song: song, queue: queue) }
                        }
                        .contextMenu { SongContextMenu(song: song) }
                        .listRowInsets(EdgeInsets(top: 2, leading: 16,
                                                  bottom: 2, trailing: 16))
                }
            }

            Color.clear
                .frame(height: Theme.miniPlayerHeight)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
    }

    // MARK: - 各状態

    private var emptyState: some View {
        ScrollView {
            if recentQueries.isEmpty {
                StateMessage(kind: .empty(
                    icon: "magnifyingglass",
                    title: "YouTube を検索",
                    message: "曲名やアーティスト名を入力してください。"
                ))
                .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("最近の検索")
                            .font(.headline)
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
                            Task { await performSearch(q) }
                        }
                    }
                }
            }
        }
    }

    private var resultList: some View {
        List {
            ForEach(results) { song in
                SongRow(song: song)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task { await player.play(song: song, queue: results) }
                    }
                    .contextMenu { SongContextMenu(song: song) }
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
            }
            Color.clear
                .frame(height: Theme.miniPlayerHeight)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
    }

    // MARK: - 候補の取得

    /// 入力から 250ms 待ってから候補を取りにいく。
    private func scheduleSuggestions(_ text: String) {
        suggestionTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            suggestions = []
            results = []
            errorMessage = nil
            searchedQuery = ""
            return
        }
        // 検索済みの語に戻ってきただけなら候補は出さない
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

    private func performSearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSearching = true
        errorMessage = nil
        suggestions = []
        searchedQuery = trimmed

        do {
            let found = try await YouTubeAPI.searchSongs(trimmed)
            results = found
            if found.isEmpty {
                errorMessage = "「\(trimmed)」に一致する曲が見つかりませんでした。"
            } else {
                addRecent(trimmed)
            }
        } catch {
            errorMessage = error.localizedDescription
            EventLog.logError(.search, error: error, context: "検索 \"\(trimmed)\"")
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
