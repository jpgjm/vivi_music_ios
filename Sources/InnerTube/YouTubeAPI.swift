//
//  YouTubeAPI.swift
//  ViviMusic
//
//  UI から使う高レベル API。InnerTube + Parsers を束ねる。
//  「どのクライアントで叩くか」「失敗したらどこにフォールバックするか」は
//  ここに集約する。
//

import Foundation

enum YouTubeAPI {

    /// browseId 定数。
    enum BrowseID {
        static let home = "FEmusic_home"
        static let explore = "FEmusic_explore"
        static let charts = "FEmusic_charts"
        static let newReleases = "FEmusic_new_releases_albums"
    }

    // MARK: - ホーム

    /// ホームフィード (Quick picks / おすすめ / 最近のトレンド など) を取得する。
    static func home() async throws -> [HomeSection] {
        let started = Date()
        let json = try await InnerTube.shared.browse(browseID: BrowseID.home)
        let sections = Parsers.sections(json)
        EventLog.logDuration(.home, start: started,
                             message: "\(sections.count) セクション取得")
        if sections.isEmpty {
            EventLog.log(.home, message: "セクションが 0 件。レスポンス構造が変わった可能性")
        }
        return sections
    }

    // MARK: - 探索 / トレンド

    /// 探索タブ (新着リリース / ムード / チャート入口)。
    static func explore() async throws -> [HomeSection] {
        let started = Date()
        let json = try await InnerTube.shared.browse(browseID: BrowseID.explore)
        let sections = Parsers.sections(json)
        EventLog.logDuration(.explore, start: started,
                             message: "explore \(sections.count) セクション")
        return sections
    }

    /// チャート (トレンド)。国別の人気曲・人気アーティストが返る。
    static func charts() async throws -> [HomeSection] {
        let started = Date()
        let json = try await InnerTube.shared.browse(browseID: BrowseID.charts)
        let sections = Parsers.sections(json)
        EventLog.logDuration(.explore, start: started,
                             message: "charts \(sections.count) セクション")
        return sections
    }

    /// 新着アルバム。
    static func newReleases() async throws -> [HomeSection] {
        let started = Date()
        let json = try await InnerTube.shared.browse(browseID: BrowseID.newReleases)
        let sections = Parsers.sections(json)
        EventLog.logDuration(.explore, start: started,
                             message: "newReleases \(sections.count) セクション")
        return sections
    }

    /// 任意の browseId を辿る (アルバム / プレイリスト / アーティストページ)。
    static func browse(_ browseID: String) async throws -> [HomeSection] {
        let json = try await InnerTube.shared.browse(browseID: browseID)
        return Parsers.sections(json)
    }

    /// アルバム / プレイリスト / アーティストの詳細ページを取得する。
    ///
    /// プレイリストの browseId は "VL" 接頭辞が要る場合がある。
    /// "PL..." のまま渡されたら補ってから叩く。
    static func browsePage(route: BrowseRoute) async throws -> BrowsePage {
        let started = Date()

        var browseID = route.browseID
        if route.kind == .playlist, browseID.hasPrefix("PL") {
            browseID = "VL" + browseID
        }

        let json = try await InnerTube.shared.browse(browseID: browseID)
        let page = Parsers.browsePage(json,
                                      kind: route.kind,
                                      fallbackTitle: route.title,
                                      fallbackThumbnail: route.thumbnailURL)

        EventLog.logDuration(
            .home, start: started,
            message: "\(route.kind.displayName) \(browseID) → 曲 \(page.songs.count) / 棚 \(page.sections.count)"
        )
        if page.isEmpty {
            EventLog.log(.home, message: "\(browseID) の中身が空。レスポンス構造が想定と違う可能性")
        }
        return page
    }

    // MARK: - 検索

    /// 絞り込みを指定して検索し、区画ごとに分類して返す。
    ///
    /// 「すべて」では YouTube Music と同じく
    /// 上位の結果 / 曲 / 動画 / アルバム / アーティスト / プレイリスト
    /// が見出しつきで返る。
    static func search(_ query: String,
                       filter: SearchFilter) async throws -> [SearchSection] {
        let started = Date()
        let json = try await InnerTube.shared.search(query: query, params: filter.params)
        var sections = Parsers.searchSections(json)

        // 曲で 0 件なら動画でも探す。
        // YouTube Music に登録が無くても YouTube 側にはあることが多い。
        if sections.isEmpty, filter == .song {
            EventLog.log(.search, message: "曲で 0 件 → 動画で再検索")
            let videoJSON = try await InnerTube.shared.search(query: query,
                                                             params: SearchFilter.video.params)
            sections = Parsers.searchSections(videoJSON)
        }

        let total = sections.reduce(0) { $0 + $1.items.count }
        EventLog.logDuration(.search, start: started,
                             message: "\"\(query)\" [\(filter.title)] → "
                                 + "\(sections.count) 区画 / \(total) 件")
        return sections
    }

    /// 曲だけを平坦なリストで得る (キューを組む用途)。
    static func searchSongs(_ query: String) async throws -> [Song] {
        let sections = try await search(query, filter: .song)
        return sections.flatMap { $0.items.compactMap(\.song) }
    }

    /// 検索候補 (オートコンプリート) を取得する。
    /// 失敗しても検索自体は続けられるので、エラーは投げずに空配列を返す。
    static func searchSuggestions(_ input: String) async -> [SearchSuggestion] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else { return [] }
        do {
            let json = try await InnerTube.shared.searchSuggestions(input: trimmed)
            let suggestions = Parsers.searchSuggestions(json)
            EventLog.log(.search, message: "候補 \"\(trimmed)\" → \(suggestions.count) 件")
            return suggestions
        } catch {
            if (error as? URLError)?.code != .cancelled {
                EventLog.logError(.search, error: error, context: "検索候補 \"\(trimmed)\"")
            }
            return []
        }
    }

    // MARK: - 再生ストリーム解決

    /// 再生用の音声ストリームを解決する。
    ///
    /// クライアントの優先順位は本家 VIVI Music の `YTPlayerUtils` に合わせている。
    ///   ANDROID_VR 1.43.32  ← MAIN_CLIENT。発行される URL の制限が最も緩い
    ///   ANDROID_VR 1.61.48  ← フォールバック 1
    ///   WEB_REMIX           ← フォールバック 2
    ///   IOS                 ← 最後の手段
    ///
    /// IOS を最優先にしていた頃は、URL が Range ヘッダを小分けにしないと
    /// 403 を返す挙動のため再生できなかった。ANDROID_VR の URL にはその制限がない。
    ///
    /// 各候補について、URL が実際に使えるかを HEAD で確認してから採用する
    /// (本家の `validateStatus` と同じ考え方)。
    static func resolveStream(videoID: String) async throws -> StreamInfo {
        let started = Date()

        // ログイン済みなら TVHTML5 を先頭に置く。
        // OAuth トークンを受け付けるのはこのクライアントだけで、
        // 認証済みの要求なら bot 判定を通過できる。
        //
        // なお ホーム / 検索 / 探索 は未認証の WEB_REMIX のままで問題なく動く。
        // 認証が要るのは再生 URL の取得だけ。
        let signedIn = await GoogleAuthService.shared.isSignedIn

        // WEB_REMIX を先頭に置く。BotGuard で作る poToken が使えるのは
        // WEB 系のクライアントだけで、これがあると YouTube 側のスロットリング
        // (1MiB で 403 になる状態) を回避できる。
        let clients: [YouTubeClient] = signedIn
            ? [.webRemix, .tvhtml5, .androidVR143, .androidVR161, .ios]
            : [.webRemix, .androidVR143, .androidVR161, .ios]

        var lastError: Error?
        // 再生 URL に付ける poToken。WEB_REMIX で解決できたときだけ入る。
        var streamingPoToken: String?

        for client in clients {
            do {
                // WEB 系なら poToken を用意する (作れなければ無しで続行)
                var playerPoToken: String?
                if client.usesWebPoToken,
                   let sessionID = await InnerTube.shared.visitorData {
                    if let pair = await PoTokenService.shared.tokens(videoID: videoID,
                                                                    sessionID: sessionID) {
                        playerPoToken = pair.player
                        streamingPoToken = pair.streaming
                    }
                }

                let json = try await InnerTube.shared.player(videoID: videoID,
                                                             client: client,
                                                             poToken: playerPoToken)
                var stream = try Parsers.bestAudioStream(json, videoID: videoID)

                // WEB 系で解決したなら再生 URL に pot= を付ける。
                // これが無いと 1MiB ほどでスロットリングされ 403 になる。
                if client.usesWebPoToken, let pot = streamingPoToken {
                    let separator = stream.url.contains("?") ? "&" : "?"
                    stream.url = "\(stream.url)\(separator)pot=\(pot)"
                    EventLog.log(.resolveOK, videoID: videoID, message: "pot= を付与")
                }

                // URL が本当に使えるか確認する。駄目なら次のクライアントへ。
                let status = await StreamProbe.validate(stream: stream)
                guard status.isUsable else {
                    EventLog.log(.resolveNG, videoID: videoID,
                                 message: "\(client.clientName) の URL は使用不可 "
                                     + "(HTTP \(status.statusCode))。次の候補へ")
                    lastError = InnerTubeError.badResponse(status: status.statusCode, body: "")
                    continue
                }

                EventLog.logDuration(
                    .resolveOK, videoID: videoID, start: started,
                    message: "\(client.clientName) / \(stream.mimeType) "
                        + "\(stream.bitrate / 1000)kbps \(stream.contentLength)B "
                        + "検証 HTTP \(status.statusCode)"
                )
                return stream
            } catch {
                lastError = error
                EventLog.logError(.resolveNG, videoID: videoID, error: error,
                                  context: "client=\(client.clientName)")
            }
        }

        throw lastError ?? InnerTubeError.noStream(videoID: videoID)
    }

    /// 曲のメタ情報を player レスポンスから取得する (検索を経由せず再生する場合用)。
    static func songInfo(videoID: String) async throws -> Song {
        let json = try await InnerTube.shared.player(videoID: videoID, client: .ios)
        return Parsers.song(fromPlayerResponse: json, fallbackID: videoID)
    }

    /// 関連曲。キューの自動継続に使う。
    static func related(videoID: String) async -> [Song] {
        do {
            let json = try await InnerTube.shared.next(videoID: videoID)
            let songs = Parsers.relatedSongs(json)
            EventLog.log(.queue, videoID: videoID, message: "関連曲 \(songs.count) 件")
            return songs
        } catch {
            EventLog.logError(.queue, videoID: videoID, error: error, context: "related")
            return []
        }
    }
}
