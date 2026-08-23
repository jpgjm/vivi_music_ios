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
    @EnvironmentObject private var cookieAuth: CookieAuthService

    @State private var sections: [HomeSection] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showSettings = false
    /// アルバム / プレイリスト / アーティストへの遷移経路。
    @State private var path: [BrowseRoute] = []

    // MARK: - 追加読み込み (continuation)

    /// 次のページのトークン。nil なら終端。
    @State private var continuation: String?
    /// 追加読み込み中かどうか。二重発火の防止に使う。
    @State private var isLoadingMore = false
    /// 追加読み込みで発生したエラー。先頭ページは表示できているので
    /// 画面全体をエラーにせず、末尾に小さく出すだけにする。
    @State private var loadMoreError: String?
    /// 中身が空のページが続いたときに打ち切るためのカウンタ。
    @State private var emptyPageStreak = 0

    /// 1 回の追加読み込みで許容する「中身が空のページ」の連続数。
    /// InnerTube は稀に棚 0 件 + トークンだけのページを返すので数回は追う。
    private let maxEmptyPageStreak = 3

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
                // 曲メニューからさらに別のアルバム / アーティストへ飛べるよう、
                // この画面の path に積む経路を渡しておく。
                BrowseDetailView(route: route) { path.append($0) }
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
        // Cookie ログインの状態が変わったらホームを取り直す。
        // これが無いと、ログインしても画面が匿名フィードのままで
        // 「効いていない」ように見えてしまう。
        .onChange(of: cookieAuth.isSignedIn) { _, _ in
            Task { await load() }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(sections) { section in
                    // 曲だけの棚は縦リストにした方が使いやすいので出し分ける
                    if section.items.allSatisfy({ $0.song != nil }) && section.items.count > 3 {
                        SongShelf(section: section,
                                  onNavigate: { path.append($0) })
                    } else {
                        ShelfSection(section: section) { item in
                            handleTap(item, in: section)
                        }
                    }
                }

                // 一番下まで来たら次のページを読む。
                loadMoreFooter
            }
            .padding(.top, 8)
            .padding(.bottom, Theme.miniPlayerHeight + 24)
        }
        .refreshable { await load() }
    }

    /// リスト末尾に置く追加読み込み用のビュー。
    ///
    /// `LazyVStack` の中に置いているので、実際にスクロールで
    /// 画面に入ったときだけ `onAppear` が呼ばれる = そのとき次を読む。
    @ViewBuilder
    private var loadMoreFooter: some View {
        if isLoadingMore {
            HStack(spacing: 8) {
                ProgressView()
                Text("さらに読み込んでいます…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else if let loadMoreError {
            VStack(spacing: 8) {
                Text(loadMoreError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("再試行") {
                    Task { await loadMore() }
                }
                .font(.footnote)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else if continuation != nil {
            // 自動読み込みのトリガー。
            // 高さ 1pt の透明ビューだと onAppear が飛ぶ端末があるため、
            // 手動でも進められるようボタンとして置いている。
            Button {
                Task { await loadMore() }
            } label: {
                Text("さらに読み込む")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .onAppear {
                Task { await loadMore() }
            }
        } else if !sections.isEmpty {
            Text("これで全部です")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
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

    /// 先頭ページを取得し直す (初回表示 / 引っ張って更新 / ログイン状態の変化)。
    private func load() async {
        isLoading = true
        errorMessage = nil
        loadMoreError = nil
        emptyPageStreak = 0

        EventLog.log(.home,
                     message: "ホーム読み込み開始 (Cookie ログイン "
                         + (cookieAuth.isSignedIn ? "済" : "未") + ")")

        do {
            let feed = try await YouTubeAPI.home()
            sections = feed.sections
            continuation = feed.continuation
            if sections.isEmpty {
                errorMessage = "ホームの内容を取得できませんでした。時間をおいて再試行してください。"
            }
        } catch {
            // 画面が閉じられた等によるキャンセルは異常ではない。
            // ここで状態を壊すと、以後ページングが動かなくなる。
            if Self.isCancellation(error) {
                EventLog.log(.home, message: "ホーム読み込みがキャンセルされました (無視)")
            } else {
                errorMessage = error.localizedDescription
                EventLog.logError(.home, error: error, context: "ホーム読み込み")
            }
        }
        isLoading = false
    }

    /// タスクの取り消しによるエラーかどうか。
    /// `URLError.cancelled` (-999) と `CancellationError` の両方を拾う。
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        return false
    }

    /// 次のページを取得して末尾に足す。
    ///
    /// 打ち切り条件:
    ///   - トークンが無い (終端)
    ///   - 返ってきたトークンが直前と同じ (同じページの取り直し = 無限ループ)
    ///   - 中身が空のページが `maxEmptyPageStreak` 回続いた
    private func loadMore() async {
        guard let firstToken = continuation, !isLoadingMore, !isLoading else { return }

        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }

        // 中身が空のページが返ったら、そこで止まるとフッタの onAppear が
        // 再発火せず手詰まりになる。棚が 1 つでも増えるまでここで追い続ける。
        var token = firstToken
        emptyPageStreak = 0

        while true {
            do {
                let feed = try await YouTubeAPI.home(continuation: token)

                if !feed.sections.isEmpty {
                    sections.append(contentsOf: feed.sections)
                    emptyPageStreak = 0
                } else {
                    emptyPageStreak += 1
                }

                // 同じトークンが返るのは終端の合図。追い続けると無限ループになる。
                guard let next = feed.continuation, next != token else {
                    if feed.continuation != nil {
                        EventLog.log(.home, message: "同一の continuation が返ったため打ち切り")
                    }
                    continuation = nil
                    break
                }

                continuation = next
                token = next

                // 棚が取れたら一旦止めて、次はスクロールに応じて読む。
                if emptyPageStreak == 0 { break }

                if emptyPageStreak >= maxEmptyPageStreak {
                    EventLog.log(.home,
                                 message: "空ページが \(emptyPageStreak) 回続いたため打ち切り")
                    continuation = nil
                    break
                }
            } catch {
                if Self.isCancellation(error) {
                    // トークンは残しておく。次にフッタが見えたら再挑戦できる。
                    EventLog.log(.home, message: "追加読み込みがキャンセルされました (無視)")
                } else {
                    loadMoreError = "続きを読み込めませんでした: \(error.localizedDescription)"
                    EventLog.logError(.home, error: error, context: "ホーム追加読み込み")
                }
                break
            }
        }

        EventLog.log(.home, message: "追加読み込み後の合計 \(sections.count) セクション")
    }
}

// MARK: - 曲だけの棚

/// 曲だけで構成された棚を、3 行 x 横スクロールのグリッドで表示する。
/// YouTube Music の "Quick picks" と同じレイアウト。
struct SongShelf: View {
    let section: HomeSection
    var onNavigate: ((BrowseRoute) -> Void)? = nil
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
                                SongRow(song: song, onNavigate: onNavigate)
                                    .frame(width: 300)
                                    .onTapGesture {
                                        Task { await player.play(song: song, queue: songs) }
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}
