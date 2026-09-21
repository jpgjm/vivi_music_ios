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
    /// 絞り込みごとの「次のページ」トークン。
    /// 鍵が無ければ、その絞り込みはもう続きが無い。
    @State private var continuations: [SearchFilter: String] = [:]
    /// 続きを読んでいる最中か。二重に走らせないための札。
    @State private var isLoadingMore = false
    /// 一覧のスクロール量 (先頭の目印の位置。下へスクロールすると負になる)。
    @State private var scrollOffset: CGFloat = 0
    /// 前回続きを読んだときのスクロール量。
    /// nil なら「この検索でまだ一度も読んでいない」。
    @State private var offsetAtLastLoad: CGFloat?
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
                        // 一覧が入れ替わるので、スクロールの判定を初期に戻す
                        offsetAtLastLoad = nil
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
            LazyVStack(alignment: .leading, spacing: 0) {
                // 一覧の先頭に置く目印。スクロール量を測るためだけのもの。
                //
                // ── なぜ要るか ──────────────────────────────────
                // rev.82 では「末尾が画面に入ったら続きを読む」だけで
                // 判断していた。ところが、この画面が全画面プレイヤーに
                // 覆われるなどして描画の条件が変わると、末尾の目印が
                // 何度も「現れた」ことになり、続きを延々と読み続けた。
                // (2026-08-14 実測: 19 ページ 380 件を約 1 秒間隔で取得)
                //
                // そこで「前回読んでからスクロールされたか」を条件に足す。
                // 指が動いていなければ、自動では読まない。
                Color.clear
                    .frame(height: 0)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: SearchScrollOffsetKey.self,
                                value: geo.frame(in: .named(Self.scrollSpace)).minY
                            )
                        }
                    )

                ForEach(sections) { section in
                    // 見出しは「すべて」のときだけ出す。
                    // 絞り込み中は区画が 1 つなので、本家も見出しを出さない。
                    if filter == .all {
                        Text(section.title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }

                    // 区画の中は 1 枚のカードのように見せる。
                    // 上下の端だけ大きく丸め、間は角を落とす (本家の listItemShape)。
                    VStack(spacing: 2) {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                            SearchResultRow(item: item, onNavigate: { path.append($0) })
                                .padding(.horizontal, 12)
                                .frame(height: Theme.searchRowHeight)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(Self.rowShape(index: index,
                                                         count: section.items.count))
                                .contentShape(Rectangle())
                                .onTapGesture { handleTap(item, in: section) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }

                if hasMore {
                    loadMoreFooter
                }
            }
            .padding(.top, 4)
            .padding(.bottom, Theme.miniPlayerHeight + 24)
        }
        .coordinateSpace(name: Self.scrollSpace)
        .onPreferenceChange(SearchScrollOffsetKey.self) { value in
            scrollOffset = value
        }
    }

    /// 一覧の末尾。読み込み中は輪、そうでなければ手で押せるボタンを出す。
    ///
    /// スクロールが止まったまま自動では読まないので、
    /// 「もう少し見たい」ときのためにボタンを残しておく。
    private var loadMoreFooter: some View {
        HStack {
            Spacer()
            if isLoadingMore {
                ProgressView()
            } else {
                Button("さらに読み込む") {
                    Task { await loadMore(force: true) }
                }
                .font(.footnote)
                .tint(Theme.accent)
            }
            Spacer()
        }
        .padding(.vertical, 24)
        .onAppear {
            Task { await loadMore() }
        }
    }

    /// スクロール量を測るための座標空間の名前。
    private static let scrollSpace = "searchResults"

    /// 今の絞り込みに続きがあるか。
    private var hasMore: Bool {
        continuations[filter] != nil
    }

    /// まとまりの何番目かで角の丸め方を変える。
    ///
    /// 先頭は上だけ、末尾は下だけ、間は角無し。1 件だけなら四隅とも丸める。
    /// 本家 Android 版の `listItemShape(index:count:)` と同じ考え方。
    private static func rowShape(index: Int, count: Int) -> UnevenRoundedRectangle {
        let r = Theme.searchGroupRadius
        let isFirst = index == 0
        let isLast = index == count - 1
        return UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? r : 0,
            bottomLeadingRadius: isLast ? r : 0,
            bottomTrailingRadius: isLast ? r : 0,
            topTrailingRadius: isFirst ? r : 0,
            style: .continuous
        )
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
            continuations = [:]
            offsetAtLastLoad = nil
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
            continuations = [:]
        }
        // 一覧を作り直すので、スクロールの判定も初期に戻す
        offsetAtLastLoad = nil

        isSearching = true
        errorMessage = nil
        suggestions = []
        searchedQuery = trimmed
        filter = targetFilter

        do {
            let found = try await YouTubeAPI.search(trimmed, filter: targetFilter)
            cache[targetFilter] = found.sections
            continuations[targetFilter] = found.continuation
            if found.sections.isEmpty {
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

    /// 一覧の続きを 1 ページ読み込んで、今の区画の末尾に足す。
    ///
    /// - Parameter force: ボタンから呼ぶときは true。
    ///   スクロールの条件を無視して 1 ページだけ読む。
    ///
    /// 自動で呼ばれるときは、次のすべてを満たしたときだけ読む。
    ///   1. 走っている最中でない
    ///   2. 続きのトークンがある
    ///   3. **前回読んでからスクロールされている**
    ///
    /// 3 が rev.84 で足した条件。これが無いと、画面が全画面プレイヤーに
    /// 覆われるなどして描画の条件が変わったときに、末尾の目印が何度も
    /// 「現れた」ことになり、続きを延々と読み続ける。
    private func loadMore(force: Bool = false) async {
        guard !isLoadingMore else { return }
        guard let token = continuations[filter] else { return }

        // 指が動いていなければ自動では読まない。
        // 一度も読んでいないとき (offsetAtLastLoad == nil) は 1 回だけ許す。
        if !force, let last = offsetAtLastLoad, abs(scrollOffset - last) < 1 {
            return
        }

        let targetFilter = filter
        let targetQuery = searchedQuery
        isLoadingMore = true
        offsetAtLastLoad = scrollOffset

        do {
            let page = try await YouTubeAPI.searchContinuation(token)

            // 読んでいる間にタブや検索語が変わっていたら捨てる。
            guard targetFilter == filter, targetQuery == searchedQuery else {
                isLoadingMore = false
                return
            }

            var current = cache[targetFilter] ?? []
            if var last = current.last {
                // 既に並んでいるものは足さない (続きは重なることがある)
                let existing = Set(last.items.map(\.id))
                let fresh = page.items.filter { !existing.contains($0.id) }
                last.items.append(contentsOf: fresh)
                current[current.count - 1] = last
                cache[targetFilter] = current
            } else if !page.items.isEmpty {
                cache[targetFilter] = [SearchSection(title: targetFilter.title,
                                                     items: page.items)]
            }

            // トークンが返らなければ終端。鍵を消して目印も消す。
            continuations[targetFilter] = page.continuation
        } catch {
            // 続きが読めなくても、既に出ている分は残す。
            // 目印を消して、無限に再試行しないようにする。
            continuations[targetFilter] = nil
            EventLog.logError(.search, error: error,
                              context: "続きの読み込み [\(targetFilter.title)]")
        }

        isLoadingMore = false
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
///
/// 行の背景・高さ・角の丸めは呼び出し側 (`SearchView.resultList`) が付ける。
/// ここは中身だけを組む。
struct SearchResultRow: View {
    let item: HomeItem
    var onNavigate: ((BrowseRoute) -> Void)? = nil

    /// アルバム / アーティスト / プレイリストのメニューを出しているか。
    @State private var showMenu = false

    var body: some View {
        if case .song(let song) = item {
            SearchSongRow(song: song, onNavigate: onNavigate)
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

                    // 2 行目は API が返す説明をそのまま出す。
                    // 「アーティスト・チャンネル登録者数 8.27万人」のように
                    // 種別から始まるので、こちら側で札を足す必要は無い。
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                RowMenuButton { showMenu = true }
            }
            .contentShape(Rectangle())
            // 長押しでも同じメニューを出す (曲の行と揃える)
            .onLongPressGesture(minimumDuration: 0.4) { showMenu = true }
            .sheet(isPresented: $showMenu) {
                ItemMenuSheet(item: item, onNavigate: onNavigate)
            }
        }
    }
}

/// 検索結果に出す曲の行。
///
/// 通常の `SongRow` と違い、2 行目に「演者 • アルバム • 再生時間」をまとめ、
/// 右端は三点リーダーだけにする。本家 Android 版の `YouTubeListItem` と同じ形。
/// `SongRow` はライブラリ・プレイリスト・ホームでも使うため、
/// そちらには手を入れず、検索専用の行としてここに置く。
struct SearchSongRow: View {
    let song: Song
    var onNavigate: ((BrowseRoute) -> Void)? = nil

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager

    @State private var showMenu = false

    private var isCurrent: Bool { player.currentSong?.id == song.id }

    /// 「演者 • アルバム • 再生時間」。空の要素は飛ばす。
    /// 本家の `joinByBullet` と同じ組み立て。
    private var subtitle: String {
        var parts: [String] = []
        if !song.artist.isEmpty { parts.append(song.artist) }
        if let album = song.album, !album.isEmpty { parts.append(album) }
        if song.durationSeconds != nil { parts.append(song.durationText) }
        return parts.joined(separator: " • ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: song.thumbnailURL, size: 48, radius: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)

                HStack(spacing: 4) {
                    if isCurrent && player.isPlaying {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                    }
                    if downloads.isDownloaded(song.id) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            RowMenuButton { showMenu = true }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.4) { showMenu = true }
        .sheet(isPresented: $showMenu) {
            SongMenuSheet(song: song, onNavigate: onNavigate)
        }
    }
}

/// 行の右端に置く三点リーダー。押しやすいよう当たり判定を広げてある。
struct RowMenuButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

// MARK: - スクロール量の受け渡し

/// 一覧の先頭に置いた目印の位置を、親へ伝えるための鍵。
///
/// 「前回続きを読んでからスクロールされたか」を判断するためだけに使う。
struct SearchScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
