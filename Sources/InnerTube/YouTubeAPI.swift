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

    /// ホームフィード (Quick picks / おすすめ / 最近のトレンド など) を 1 ページ取得する。
    ///
    /// InnerTube の `FEmusic_home` は初回応答で先頭の数棚しか返さない。
    /// 「新作」「おすすめのアルバム」などの下の方の棚は、返ってきた
    /// continuation トークンで追加リクエストを投げないと取得できない。
    /// 本家 VIVI Music の `HomeViewModel.loadMoreYouTubeItems()` と同じ挙動。
    ///
    /// - Parameter continuation: 2 ページ目以降のトークン。nil なら先頭ページ。
    static func home(continuation: String? = nil) async throws -> HomeFeed {
        let started = Date()

        // continuation を送るときは browseId を付けない (本家と同じ)。
        // 両方付けると InnerTube 側が browseId を優先し、
        // 毎回 1 ページ目が返ってきて先に進めなくなる。
        let json: JSON
        if let continuation {
            json = try await InnerTube.shared.browse(browseID: nil, continuation: continuation)
        } else {
            json = try await InnerTube.shared.browse(browseID: BrowseID.home)
        }

        let sections = Parsers.sections(json)
        let next = Parsers.continuationToken(json)

        EventLog.logDuration(
            .home, start: started,
            message: (continuation == nil ? "先頭ページ" : "追加ページ")
                + " \(sections.count) セクション取得 / "
                + (next == nil ? "続きなし" : "続きあり")
        )
        if sections.isEmpty && continuation == nil {
            EventLog.log(.home, message: "セクションが 0 件。レスポンス構造が変わった可能性")
        }
        return HomeFeed(sections: sections, continuation: next)
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
                       filter: SearchFilter) async throws -> SearchResultPage {
        let started = Date()
        let json = try await InnerTube.shared.search(query: query, params: filter.params)
        var sections = Parsers.searchSections(json)
        var token = Parsers.searchContinuationToken(json)

        // 曲で 0 件なら動画でも探す。
        // YouTube Music に登録が無くても YouTube 側にはあることが多い。
        if sections.isEmpty, filter == .song {
            EventLog.log(.search, message: "曲で 0 件 → 動画で再検索")
            let videoJSON = try await InnerTube.shared.search(query: query,
                                                             params: SearchFilter.video.params)
            sections = Parsers.searchSections(videoJSON)
            token = Parsers.searchContinuationToken(videoJSON)
        }

        // 「すべて」の続きは読まない。
        //
        // ここで返るトークンは「その中の 1 つの棚 (たとえば曲) の続き」であって、
        // 画面全体の続きではない。足すと、曲がプレイリストの区画に
        // 混ざって並ぶことになる。本家 Android 版も、絞り込み中だけ
        // 続きを読む作りになっている (`loadMore` は filter == null で即 return)。
        if filter == .all { token = nil }

        let total = sections.reduce(0) { $0 + $1.items.count }
        EventLog.logDuration(.search, start: started,
                             message: "\"\(query)\" [\(filter.title)] → "
                                 + "\(sections.count) 区画 / \(total) 件"
                                 + (token == nil ? " / 続きなし" : " / 続きあり"))
        return SearchResultPage(sections: sections, continuation: token)
    }

    /// 検索結果の続きを 1 ページ取得する。
    ///
    /// 一覧を下までスクロールしたときに呼ばれる。
    /// 返るのは項目の並びだけで、区画の見出しは付かない。
    /// 呼び出し側が今の区画の末尾に足す。
    static func searchContinuation(_ token: String)
        async throws -> (items: [HomeItem], continuation: String?) {
        let started = Date()
        let json = try await InnerTube.shared.search(continuation: token)
        let result = Parsers.searchContinuation(json)

        EventLog.logDuration(.search, start: started,
                             message: "続きを読み込み → \(result.items.count) 件"
                                 + (result.continuation == nil ? " / 終端" : " / まだ続く"))
        return result
    }

    /// 曲だけを平坦なリストで得る (キューを組む用途)。
    static func searchSongs(_ query: String) async throws -> [Song] {
        let page = try await search(query, filter: .song)
        return page.sections.flatMap { $0.items.compactMap(\.song) }
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
    /// クライアントの優先順位 (2026-08 の実測に基づく):
    ///   ANDROID_VR 1.43.32  ← MAIN_CLIENT。発行される URL の制限が最も緩い
    ///   ANDROID_VR 1.61.48  ← フォールバック 1
    ///   IOS                 ← フォールバック 2
    ///   WEB_REMIX           ← 通常動画では UNPLAYABLE になるので後ろ
    ///   TVHTML5             ← ログイン時のみ。bot 判定下の最後の砦
    ///
    /// IOS を最優先にしていた頃は、URL が Range ヘッダを小分けにしないと
    /// 403 を返す挙動のため再生できなかった。ANDROID_VR の URL にはその制限がない。
    ///
    /// 各候補について、URL が実際に使えるかを HEAD で確認してから採用する
    /// (本家の `validateStatus` と同じ考え方)。
    /// - Parameter excluding: 使わないクライアント名。
    ///   再生の途中で 403 になったときに、同じ URL を出したクライアントを
    ///   もう一度試しても無駄なので除外するために使う。
    ///   全部除外されてしまう場合は、指定を無視して通常の順で試す。
    /// 再生 URL を解決する。
    ///
    /// 解決したあと、そのアイデンティティが googlevideo に絞られて
    /// いないかを検査し、絞られていれば visitorData を引き直して
    /// やり直す。健全なものが出るまで最大 `maxIdentityRedraws` 回。
    ///
    /// ── なぜ要るか ──────────────────────────────────────
    /// 制限は **匿名セッション単位**でかかっており、
    /// 悪い籤を引くとそのセッションを使う限り必ず約 65 秒で 403 になる。
    /// 引き直すと 3 回に 1 回ほど健全なものが当たる (Opaline の観測)。
    ///
    /// 検査は HEAD 1 回で済み、枠も消費しない。
    /// 403 になってから対処するより、始める前に確かめるほうが速い。
    static func resolveStream(videoID: String,
                              excluding: Set<String> = []) async throws -> StreamInfo {
        for attempt in 0...maxIdentityRedraws {
            let stream = try await resolveStreamOnce(videoID: videoID, excluding: excluding)

            // SABR 専用など、そもそも直接 URL を持たないものは検査できない。
            guard !stream.url.isEmpty else { return stream }

            if await VisitorIdentityProbe.isHealthy(stream: stream, videoID: videoID) {
                if attempt > 0 {
                    EventLog.log(.resolveOK, videoID: videoID,
                                 message: "\(attempt) 回目の引き直しで健全なセッションを得た")
                }
                return stream
            }

            guard attempt < maxIdentityRedraws else {
                EventLog.log(.resolveNG, videoID: videoID,
                             message: "\(maxIdentityRedraws) 回引き直しても"
                                 + "健全なセッションが出なかった。そのまま再生を試みる")
                return stream
            }

            // 引き直せたときだけ、もう一度試す意味がある。
            //
            // ログイン中は visitorData がアカウントに紐づいていて
            // 引き直せない。それに気付かず繰り返していたため、
            // 1 曲あたり player 要求が 5 回・セッション検査が 5 回、
            // すべて同じ結果で走っていた (2026-08-14 のログで確認)。
            // 引き直せないなら、ここで打ち切る。
            guard await InnerTube.shared.renewVisitorData() else {
                EventLog.log(.resolveNG, videoID: videoID,
                             message: "セッションが絞られているが、"
                                 + "visitorData を引き直せない "
                                 + "(既定で無効化 / またはログイン中)。"
                                 + "このまま再生を試みる")
                return stream
            }
            EventLog.log(.network, videoID: videoID,
                         message: "セッションが絞られている。visitorData を引き直す "
                             + "(\(attempt + 1)/\(maxIdentityRedraws))")
        }

        throw InnerTubeError.noStream(videoID: videoID)
    }

    /// 健全なセッションが出るまで引き直す回数の上限。
    ///
    /// ── rev.85 時点の実態 ────────────────────────────────────
    /// `InnerTube.allowVisitorDataRenewal` が既定で false なので、
    /// `renewVisitorData()` は初回に false を返し、このループは
    /// 実質 1 周で抜ける。上限値は再検証時のために残してある。
    ///
    /// 公式 iOS アプリは visitorData をまったく引き直さずに
    /// itag 140 を 3.5〜4.1 MiB 取得できていた (コンテナ 3 回比較)。
    /// 引き直しは根本解ではないと判断している。
    private static let maxIdentityRedraws = 4

    private static func resolveStreamOnce(videoID: String,
                                          excluding: Set<String>) async throws -> StreamInfo {
        let started = Date()

        // ログイン済みかどうかで TVHTML5 を末尾に足すかが変わる。
        // OAuth トークンを受け付けるのはこのクライアントだけ。
        //
        // なお ホーム / 検索 / 探索 は未認証の WEB_REMIX のままで問題なく動く。
        // 認証が要るのは再生 URL の取得だけ。
        let signedIn = await GoogleAuthService.shared.isSignedIn

        // ── 並び順の根拠 ────────────────────────────────────────
        //
        // ANDROID_VR を先頭に置く。
        //   復号済みの itag 140 (130kbps, 音声のみ) をそのまま返す唯一の
        //   クライアントで、poToken も署名復号も要らない。実測でも
        //   毎回 HTTP 206 で通っている。
        //
        // WEB_REMIX は後ろに下げる。
        //   music.youtube.com の player は YouTube Music カタログ外の
        //   通常動画を UNPLAYABLE で拒否する (2026-08 実測。別回線から
        //   同じ動画 ID を叩いても再現したので、セッションや poToken の
        //   問題ではない)。検索結果には通常動画が混ざるため、先頭に
        //   置くと毎回 90〜115ms を捨てることになる。
        //   ただし本来の音楽トラックでは成功しうるので、外さずに残す。
        //   ここに来たときだけ BotGuard の初期化 (約 600ms) も走る。
        //
        // TVHTML5 はログイン時のみ、**最後**に足す。
        //   OAuth トークンを載せられる唯一のクライアントで bot 判定を
        //   受けないが、応答は SABR 形式で adaptiveFormats には url も
        //   signatureCipher も入っていない (2026-08 実測)。署名付き URL を
        //   持つのは muxed の itag 18 だけで、AAC 96kbps + 360p 映像という
        //   低音質・高転送量になる。
        //   よって「通るなら他を使い、全滅したときだけ TVHTML5」が正しい。
        // 2026-08-14 追記:
        //   ANDROID_VR (1.43 / 1.61) が bot 判定で全滅し、IOS の URL も
        //   64KiB 先で 403、WEB_REMIX は楽曲・通常動画とも
        //   「動画を再生できません」になった。TVHTML5 も SABR 化が進み
        //   muxed に落ちた末に 403。つまり全経路が同時に塞がった。
        //
        //   そこで素の WEB (www.youtube.com) を候補に足す。
        //   WEB_REMIX と違い音楽カタログの外も扱え、
        //   署名復号・poToken・Cookie 認証はすべて実績のある部品で賄える。
        //   ANDROID_VR の新しい版 (1.68) も候補に入れておく。
        //
        //   並びは「速い順」を保ったまま末尾に足す方針。
        //   ANDROID_VR が復活したときに元の速さで動くようにするため。
        // 2026-08-14 実測にもとづく並び:
        //   ANDROID_VR は 1.68 だけが player を通した。1.65 (yt-dlp 採用版) と
        //   1.43 は復活しうるので後ろに残す。
        //   WEB は SABR 専用応答しか返さず (adaptiveFormats に url も
        //   signatureCipher も無い) 現状まったく使えないため最後尾。
        let allClients: [YouTubeClient] = signedIn
            ? [.androidVR165, .androidVR168, .androidVR143,
               .ios, .webRemix, .tvhtml5, .web]
            : [.androidVR165, .androidVR168, .androidVR143,
               .ios, .webRemix, .web]

        // 途中で 403 になったクライアントを外す。
        // 外した結果 1 つも残らないなら、除外を諦めて全部試す
        // (何も返さないより、もう一度試したほうがまし)。
        var clients = allClients.filter { !excluding.contains($0.clientName) }
        if clients.isEmpty {
            clients = allClients
        } else if !excluding.isEmpty {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "除外して再解決: \(excluding.sorted().joined(separator: ", "))")
        }

        var lastError: Error?
        // 再生 URL に付ける poToken。WEB 系で解決できたときだけ入る。
        var streamingPoToken: String?
        var playerPoToken: String?

        // ── poToken を先に用意しておく ──────────────────────────────
        //
        // 以前は WEB 系の番が回ってきた時点で作り始めていた。
        // ところが、そこへ辿り着くのは「他が全滅したあと」= たいてい
        // 403 からの取り直し中で、AVFoundation 側が要求を取り消すため
        // BotGuard の初期化 (600〜1000ms) が毎回中断されていた。
        // 結果、必要なときに限って poToken が付かない状態になっていた。
        //
        // ── 2026-08-14 追記: poToken は WEB 系だけの話ではなくなった ──
        //
        // yt-dlp の `GVS_PO_TOKEN_POLICY` を見ると、ANDROID_VR も IOS も
        // HTTPS ストリームについて required=True になっている。
        // つまり **再生 URL に `pot=` を付けないと 403 になる**。
        //
        // 実測とも一致する: player の解決は成功するのに、
        // 先頭 64KiB を読んだ直後から 403 が続いていた。
        // 「URL は取れるのに再生できない」の正体はこれ。
        //
        // したがって候補にどのクライアントが居ようが先に用意する。
        // ── 2026-08-14 追記 2: 紐づけ先が可変になった ──────────────
        //
        // yt-dlp のソースにこうある:
        //
        //   experiments['html5_generate_content_po_token'] == 'true'
        //     → GVS の poToken を **videoId に紐づけて** 発行する
        //
        //   # Since 2026.07, intermittent/selective POT enforcement
        //   # has been observed for non-HLS formats
        //
        // この実験が有効な動画では、visitorData に紐づけたトークンを
        // 付けても無効と見なされ、pot 無しと同じ扱い = 1 MiB で 403 になる。
        // 実験は動画・セッション単位で切り替わるため症状が断続的になる。
        //
        // 実験フラグは player の応答にしか入っていないので、
        // ここでは従来どおり visitorData 紐づけで先に用意しておき、
        // player の応答を見た時点で必要なら作り直す。
        let sessionID = await InnerTube.shared.visitorData
        let dataSyncID = await CookieAuthService.shared.credentials?.dataSyncID

        if let sessionID {
            // 紐づけ先はログイン状態で決まる。
            //   ログイン済み → dataSyncId
            //   未ログイン   → visitorData
            // (yt-dlp の get_webpo_content_binding と同じ判断)
            let binding = PoTokenBindingResolver.binding(dataSyncID: dataSyncID,
                                                         visitorData: sessionID)
            if let pair = await PoTokenService.shared.tokens(videoID: videoID,
                                                            sessionID: sessionID,
                                                            binding: binding) {
                playerPoToken = pair.player
                streamingPoToken = pair.streaming
                EventLog.log(.resolveOK, videoID: videoID,
                             message: "poToken を用意した (紐づけ: "
                                 + (binding?.kind ?? "なし") + ")")
            } else {
                EventLog.log(.resolveNG, videoID: videoID,
                             message: "poToken を用意できなかった (無しで続行)")
            }
        }

        for client in clients {
            do {

                // WEB / WEB_REMIX には Cookie 認証を載せる。
                // 未ログインなら CookieAuthService 側で nil が返るだけなので
                // そのまま匿名として動く。
                let raw = try await InnerTube.shared.player(
                    videoID: videoID,
                    client: client,
                    poToken: client.usesWebPoToken ? playerPoToken : nil,
                    useLogin: client.loginSupported
                )

                // TVHTML5 / WEB 系は再生 URL を `url` ではなく
                // `signatureCipher` (撹拌された署名 + 本体) で返す。
                // base.js から取り出した復号関数を通して `url` に直してから解析する。
                // signatureCipher が無ければ何もせず素通りするので、
                // ANDROID_VR / IOS の経路には影響しない。
                let json = await PlayerJSService.shared.resolveStreamingURLs(in: raw,
                                                                            videoID: videoID)

                var stream = try Parsers.bestAudioStream(json, videoID: videoID)

                // 再生 URL に pot= を付けるかどうかは、**URL 自身に訊く**。
                //
                // googlevideo の URL には `sparams` があり、
                // 「署名の対象になっているパラメータ」が列挙されている。
                // ここに `pot` が含まれていれば poToken が前提の URL であり、
                // 含まれていなければ署名の対象外 = 付けても意味が無い。
                //
                // 2026-08-14 の実測 (ANDROID_VR itag 140):
                //   sparams = expire,ei,ip,id,itag,source,requiressl,
                //             xpc,gcr,bui,spc,vprv,svpuc,mime
                //   → pot は入っていない
                //
                // rev.41 で「yt-dlp のポリシーに required とあるから」という
                // 理由で全クライアントに付けるようにしたが、それは誤りだった。
                // Metrolist が ANDROID_VR に付けていないのもこのため。
                //
                // クライアント名で決め打ちにせず URL を見る形にしておけば、
                // 将来 YouTube が pot を要求し始めても自動で追随できる。
                if let pot = streamingPoToken, StreamURL.requiresPoToken(stream.url) {
                    let separator = stream.url.contains("?") ? "&" : "?"
                    stream.url = "\(stream.url)\(separator)pot=\(pot)"
                    EventLog.log(.resolveOK, videoID: videoID,
                                 message: "pot= を付与 (sparams が要求)")
                } else if streamingPoToken != nil {
                    EventLog.log(.resolveOK, videoID: videoID,
                                 message: "pot= は付けない (sparams に pot が無い)")
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

                // どのクライアントで取れた URL かを覚えておく。
                // 途中で 403 になったときに、このクライアントを除外して
                // 取り直すのに使う。
                stream.resolvedBy = client.clientName

                // URL の素性を残しておく。
                // 403 を追うときに「pot を要求する URL だったのか」が
                // 後から分かる。署名や pot の中身は出さない。
                EventLog.log(.resolveOK, videoID: videoID,
                             message: "URL: " + StreamURL.describe(stream.url))

                // ── rev.88: 検証用の全文出力 ────────────────────────
                //
                // 「1 MiB 制限は URL に紐づくのか、取りに行くクライアントに
                // 紐づくのか」を切り分けるため、設定で有効にしたときだけ
                // URL 全体をログへ出す。
                //
                // **既定では出さない。** URL には ip= と sig= が平文で
                // 含まれるので、ログを不用意に共有すると自宅の IP が
                // 漏れる。診断のときだけ設定画面から有効にする。
                if StreamURLDiagnostics.logsFullURL {
                    EventLog.log(.resolveOK, videoID: videoID,
                                 message: "URL全文(検証用): "
                                     + StreamURL.fullURLForDiagnostics(stream.url))
                }
                // 直近の URL は常に控えておく (設定画面のコピー用)。
                // こちらはメモリ上だけで、ログには出ない。
                await StreamURLDiagnostics.shared.record(url: stream.url,
                                                         videoID: videoID,
                                                         clientName: stream.clientName)

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

        throw InnerTubeError.noStream(videoID: videoID)
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
