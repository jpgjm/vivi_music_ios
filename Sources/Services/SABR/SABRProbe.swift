//
//  SABRProbe.swift
//  ViviMusic
//
//  SABR が「1 MiB 制限」を回避できるかだけを確かめる実験。
//
//  ── 目的 ────────────────────────────────────────────────
//  2026-08 に、ANDROID_VR の再生 URL がファイル先頭 1 MiB より先を
//  返さなくなる症状が出た (出る時期と出ない時期がある)。
//  Range ヘッダ / range= クエリ / Range なし、どれでも同じ。
//
//  SABR はサーバー主導でメディアを送る仕組みで、
//  Range 要求とは別の土俵にある。**そこなら 1 MiB を超えて
//  取れるのではないか** という見立てを、実装に踏み切る前に測る。
//
//  ここで「2 MiB 目のデータが返る」ことさえ確認できれば、
//  本実装 (1,000〜1,500 行) に進む価値が確定する。
//  返らなければ、その労力を丸ごと避けられる。
//
//  ── やっていること ──────────────────────────────────────
//  1. player を叩いて serverAbrStreamingUrl と
//     videoPlaybackUstreamerConfig を取る
//  2. VideoPlaybackAbrRequest を protobuf で組み立てる
//  3. POST して、返ってきた UMP を解析する
//  4. MEDIA パートの合計バイト数と MEDIA_HEADER の中身を記録する
//
//  ── 割り切っていること ──────────────────────────────────
//  - 受信は 1 往復だけ。継続的なやり取りはしない
//  - buffered_ranges は長さ 0。「まだ何も持っていない」と伝える
//  - player_time_ms をずらして「途中から」も試す
//  - SwiftProtobuf は使わず ProtobufLite で済ませる
//
//  移植元: googlevideo (LuanRT) の SabrStream.buildRequestBody
//

import Foundation

enum SABRProbe {

    /// コンテキストをどう返すか。
    ///
    /// `sabr.malformed_config` の原因を切り分けるために用意した。
    /// 中身の書き方が悪いのか、そもそも返すべきでないのかを分ける。
    enum ContextMode: String {
        /// 何も載せない (待機だけ従う)
        case none = "載せない"
        /// 番号だけ伝える
        case unsentOnly = "番号のみ"
        /// type と value を正しい番号で返す
        case full = "正しい番号で返す"
    }

    /// buffered_ranges の書き方。
    ///
    /// 公式実装は「まだ何も持っていない」ときは **空配列** を送る。
    /// 私は長さ 0 の範囲を 1 つ入れていたので、そこも疑って比べられるようにする。
    enum BufferedMode: String {
        case empty = "空"
        case zeroRange = "長さ0の範囲"
    }

    /// これまでに受け取った範囲。次の要求に「ここまで持っている」と伝える。
    ///
    /// SABR は **バイト位置ではなくセグメント番号**で進む。
    /// 受け取った MEDIA_HEADER から範囲を組み立てて返さないと、
    /// サーバーは次に何を送るべきか判断できない。
    struct BufferedRange {
        var startTimeMs: Int
        var durationMs: Int
        var startSegmentIndex: Int
        var endSegmentIndex: Int
        var timescale: Int?
    }

    /// サーバーから渡される SABR コンテキスト。
    ///
    /// `SABR_CONTEXT_UPDATE` (パート 57) で降ってきて、
    /// **次の要求の StreamerContext.sabr_contexts に返す**決まり。
    /// 返さないとサーバーは同じ指示を繰り返すだけで、メディアを送らない。
    struct SabrContext {
        var type: Int
        var scope: Int?
        var value: Data
        var sendByDefault: Bool
        var writePolicy: Int?

        var scopeLabel: String {
            switch scope {
            case 1: return "PLAYBACK"
            case 2: return "REQUEST"
            case 3: return "WATCH_ENDPOINT"
            case 4: return "CONTENT_ADS"
            default: return "不明(\(scope.map(String.init) ?? "-"))"
            }
        }
    }

    struct Result {
        var partCounts: [String: Int] = [:]
        var mediaBytes = 0
        var mediaHeaders: [UMPMediaHeader] = []
        var httpStatus = -1
        var contentType = ""
        var redirectURL: String?
        var errorText: String?
        var sabrError: String?
        var nextRequestPolicy: String?
        var playbackCookie: Data?
        var unknownDumps: [String] = []
        /// 受け取った SABR コンテキスト (type をキーにする)
        var sabrContexts: [Int: SabrContext] = [:]
        /// 既定で送るべきコンテキストの type
        var activeContextTypes: Set<Int> = []
        /// 破棄すべき type
        var discardContextTypes: Set<Int> = []
        var backoffMs = 0
        var protectionStatus: String?
        var bodyBytes = 0
        /// 読み残したバイト数。0 でなければ UMP の解釈がずれている。
        var unparsedBytes = 0
        /// 走査の記録 (種別:長さ)
        var parseTrace: [String] = []
        /// MEDIA_HEADER が申告した本文の合計
        var declaredBytes = 0
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    // MARK: - 実験の入口

    /// 1 MiB より先が SABR で取れるかを試す。
    ///
    /// - Parameter videoID: 対象の動画
    static func run(videoID: String) async {
        EventLog.log(.network, videoID: videoID, message: "SABR 実験: 開始")

        // ── 1. player から SABR の入口を取る ───────────────────
        let raw: JSON
        do {
            // WEB は SABR 専用応答を返すので、この実験にはむしろ都合が良い。
            raw = try await InnerTube.shared.player(videoID: videoID, client: .web)
        } catch {
            EventLog.log(.network, videoID: videoID,
                         message: "SABR 実験: player 取得に失敗 \(error.localizedDescription)")
            return
        }

        let streaming = raw["streamingData"]
        guard let rawAbrURL = streaming["serverAbrStreamingUrl"].string else {
            EventLog.log(.network, videoID: videoID,
                         message: "SABR 実験: serverAbrStreamingUrl が無い")
            return
        }

        // ── ここが rev.54/55 で 403 になっていた原因 ──────────────
        //
        // serverAbrStreamingUrl は **そのままでは使えない**。
        // `n=` が変換前の状態で降ってくるため、復号を通す必要がある。
        //
        // googlevideo (LuanRT) の公式サンプルでも必ずこうしている:
        //   const serverAbrStreamingUrl =
        //     await innertube.session.player?.decipher(
        //       playerResponse.streaming_data?.server_abr_streaming_url);
        //
        // 未変換のまま POST していたので、入口で 403、本体も空だった。
        let abrURL = await PlayerJSService.shared.decipher(rawAbrURL)
        EventLog.log(.network, videoID: videoID,
                     message: "SABR 実験: URL の n 変換 "
                         + (abrURL == rawAbrURL ? "なし (元のまま)" : "適用済み"))
        guard let ustreamerConfig = raw
            .path("playerConfig", "mediaCommonConfig", "mediaUstreamerRequestConfig",
                  "videoPlaybackUstreamerConfig").string else {
            EventLog.log(.network, videoID: videoID,
                         message: "SABR 実験: videoPlaybackUstreamerConfig が無い")
            return
        }

        // 音声形式を 1 つ選ぶ。AAC (audio/mp4) を優先する。
        let audioFormats = streaming["adaptiveFormats"].array.filter {
            ($0["mimeType"].string ?? "").hasPrefix("audio/")
        }
        guard let format = audioFormats.first(where: {
            ($0["mimeType"].string ?? "").hasPrefix("audio/mp4")
        }) ?? audioFormats.first else {
            EventLog.log(.network, videoID: videoID, message: "SABR 実験: 音声形式が無い")
            return
        }

        let itag = format["itag"].int ?? 140
        let lastModified = UInt64(format["lastModified"].string ?? "") ?? 0
        let totalLength = Int(format["contentLength"].string ?? "") ?? 0

        // SABR の入口は認証を求める可能性が高い。
        // 前回 (rev.54) は poToken 無しで試して 403 だったので今回は載せる。
        var poToken: String?
        if let sessionID = await InnerTube.shared.visitorData {
            let dataSyncID = await CookieAuthService.shared.credentials?.dataSyncID
            let binding = PoTokenBindingResolver.binding(dataSyncID: dataSyncID,
                                                         visitorData: sessionID)
            if let pair = await PoTokenService.shared.tokens(videoID: videoID,
                                                            sessionID: sessionID,
                                                            binding: binding) {
                poToken = pair.streaming
            }
        }

        EventLog.log(.network, videoID: videoID,
                     message: "SABR 実験: itag=\(itag) 全長=\(totalLength / 1024)KiB "
                         + "/ ustreamerConfig \(ustreamerConfig.count) 文字"
                         + "/ poToken \(poToken == nil ? "なし" : "あり")")

        // ── 対照: 直接 URL が今この瞬間に使えるか ──────────────
        //
        // 1 MiB 問題が出ている最中は googlevideo 全体が渋くなる。
        // その状態で SABR が 403 でも「SABR が駄目」とは言えない。
        // 同じ曲の直接 URL を先に叩いて、地の状態を記録しておく。
        // WEB は SABR 専用応答なので直接 URL を持たない。
        // 対照には直接 URL を返す ANDROID_VR を使う。
        await probeDirectURL(videoID: videoID)

        // ── 2. 条件を総当たりで試す ───────────────────────────
        //
        // 何が足りないのか分からないので、4 通りをまとめて測る。
        // 1 回のビルドで済ませたいため。
        var best: (label: String, poToken: String?, sendOrigin: Bool, result: Result)?

        let combinations: [(String, Bool, Bool)] = [
            ("pot有 Origin無", true,  false),
            ("pot無 Origin無", false, false),
            ("pot有 Origin有", true,  true),
            ("pot無 Origin有", false, true),
        ]

        for (label, usePoToken, sendOrigin) in combinations {
            let result = await request(abrURL: abrURL,
                                       ustreamerConfig: ustreamerConfig,
                                       itag: itag,
                                       lastModified: lastModified,
                                       playerTimeMs: 0,
                                       requestNumber: 0,
                                       poToken: usePoToken ? poToken : nil,
                                       sendOrigin: sendOrigin,
                                       playbackCookie: nil,
                                       sabrContexts: [:],
                                       activeTypes: [],
                                       contextMode: .none,
                                       videoID: videoID)
            report(result, label: label, videoID: videoID)

            if result.httpStatus == 200 && best == nil {
                // サーバーが playback_cookie を返してきたら、
                // 次の要求ではそれを添える (SABR の作法)。
                best = (label, usePoToken ? poToken : nil, sendOrigin, result)
            }
        }

        // ── 3. コンテキストの返し方を切り分ける ────────────────
        //
        // rev.60 でコンテキストを返したところ
        //   SABR_ERROR: type=sabr.malformed_config code=2
        // が返ってきた。「設定が不正」と名指しされている。
        //
        // 原因が「返し方が悪い」のか「返すこと自体が違う」のか
        // 分からないので、4 通りを順に試す。
        guard let best else {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "SABR 実験の結論: 4 通りとも 200 にならなかった。"
                             + "要求の中身がまだ足りていない")
            return
        }

        var contexts = best.result.sabrContexts
        var activeTypes = best.result.activeContextTypes
        for type in best.result.discardContextTypes { contexts.removeValue(forKey: type) }
        let backoff = best.result.backoffMs
        let cookie = best.result.playbackCookie

        if !contexts.isEmpty {
            let detail = contexts.values
                .map { "type=\($0.type) scope=\($0.scopeLabel) \($0.value.count)B" }
                .joined(separator: " / ")
            EventLog.log(.network, videoID: videoID,
                         message: "SABR 実験: コンテキストを受領 \(detail)")
        }

        var requestNumber = 1
        var success: Result?

        // 「コンテキストの返し方」と「buffered_ranges の書き方」を組み合わせる。
        // 前回 malformed_config が出たのはフィールド番号の取り違えが原因だったので、
        // それを直したうえで buffered_ranges の影響も見る。
        let attempts: [(ContextMode, BufferedMode)] = [
            (.full, .empty),
            (.full, .zeroRange),
            (.unsentOnly, .empty),
            (.none, .empty),
        ]

        for (mode, buffered) in attempts {
            if backoff > 0 {
                EventLog.log(.network, videoID: videoID,
                             message: "SABR 実験: 指示に従い \(backoff)ms 待機")
                try? await Task.sleep(nanoseconds: UInt64(backoff) * 1_000_000)
            }

            let label = "\(mode.rawValue) / buffered=\(buffered.rawValue)"
            let result = await request(abrURL: abrURL,
                                       ustreamerConfig: ustreamerConfig,
                                       itag: itag,
                                       lastModified: lastModified,
                                       playerTimeMs: 0,
                                       requestNumber: requestNumber,
                                       poToken: best.poToken,
                                       sendOrigin: best.sendOrigin,
                                       playbackCookie: cookie,
                                       sabrContexts: contexts,
                                       activeTypes: activeTypes,
                                       contextMode: mode,
                                       bufferedMode: buffered,
                                       // 送信内容は最初の 1 回だけ出す
                                       dumpRequest: requestNumber == 1,
                                       videoID: videoID)
            report(result, label: label, videoID: videoID)
            requestNumber += 1

            if result.mediaBytes > 0 {
                success = result
                EventLog.log(.network, videoID: videoID,
                             message: "SABR 実験: 「\(label)」でメディアが返った")
                break
            }

            for (type, ctx) in result.sabrContexts { contexts[type] = ctx }
            activeTypes.formUnion(result.activeContextTypes)
        }

        guard success != nil else {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "SABR 実験の結論: 4 通りとも メディアが返らない。"
                             + "送信バイト列を確認して組み立てを見直す")
            return
        }

        // ── 4. セグメントを順に取り、1 MiB を超えられるか見る ────
        //
        // SABR は **バイト位置ではなくセグメント番号**で進む。
        // player_time_ms を飛ばすだけでは駄目で、
        // 受け取った範囲を buffered_ranges に反映しながら往復する。
        //
        // 1 MiB (AAC 128kbps で約 65 秒) を超えたところまで取れれば、
        // SABR が Range の制限を受けないことの証明になる。
        guard let first = success else { return }

        // 集計は 2 系統で持つ。
        //   received : こちらが MEDIA パートから数えた実測
        //   declared : MEDIA_HEADER がサーバー側で申告した本文長
        // 食い違うなら私の UMP 解釈が誤っているので、両方を残す。
        var totalBytes = first.mediaBytes
        var declaredTotal = first.declaredBytes
        var buffered = makeBufferedRange(from: first.mediaHeaders)
        var currentCookie = first.playbackCookie ?? cookie
        var playerTime = 0

        EventLog.log(.network, videoID: videoID,
                     message: "SABR 実験: セグメント取得を開始 "
                         + "(1 セグメント目 実測\(totalBytes / 1024)KiB "
                         + "申告\(declaredTotal / 1024)KiB)")

        // 1 MiB を確実に超えるまで、最大 20 セグメント追う。
        for step in 2...20 {
            guard let range = buffered else {
                EventLog.log(.resolveNG, videoID: videoID,
                             message: "SABR 実験: MEDIA_HEADER が無く範囲を作れない")
                break
            }

            // 持っている範囲の続きを要求する
            playerTime = range.startTimeMs + range.durationMs

            let result = await request(abrURL: abrURL,
                                       ustreamerConfig: ustreamerConfig,
                                       itag: itag,
                                       lastModified: lastModified,
                                       playerTimeMs: playerTime,
                                       requestNumber: requestNumber,
                                       poToken: best.poToken,
                                       sendOrigin: best.sendOrigin,
                                       playbackCookie: currentCookie,
                                       sabrContexts: contexts,
                                       activeTypes: activeTypes,
                                       contextMode: .full,
                                       bufferedMode: .empty,
                                       buffered: range,
                                       videoID: videoID)
            requestNumber += 1

            guard result.mediaBytes > 0 else {
                EventLog.log(.resolveNG, videoID: videoID,
                             message: "SABR 実験: \(step) 個目でメディアが止まった "
                                 + "(累計 申告\(declaredTotal / 1024)KiB "
                                 + "実測\(totalBytes / 1024)KiB / "
                                 + "再生位置 \(playerTime / 1000)秒)")
                report(result, label: "セグメント\(step)", videoID: videoID)
                break
            }

            totalBytes += result.mediaBytes
            declaredTotal += result.declaredBytes

            // 受け取った範囲を足していく
            if let next = makeBufferedRange(from: result.mediaHeaders) {
                buffered = BufferedRange(
                    startTimeMs: range.startTimeMs,
                    durationMs: range.durationMs + next.durationMs,
                    startSegmentIndex: range.startSegmentIndex,
                    endSegmentIndex: next.endSegmentIndex,
                    timescale: next.timescale ?? range.timescale
                )
            }
            if let newCookie = result.playbackCookie, !newCookie.isEmpty {
                currentCookie = newCookie
            }

            EventLog.log(.network, videoID: videoID,
                         message: "SABR 実験: \(step) 個目 "
                             + "実測+\(result.mediaBytes / 1024)KiB "
                             + "申告+\(result.declaredBytes / 1024)KiB / "
                             + "累計 実測\(totalBytes / 1024)KiB "
                             + "申告\(declaredTotal / 1024)KiB "
                             + "(〜\((buffered?.durationMs ?? 0) / 1000)秒)")

            // 1 MiB を超えたら目的達成。
            // 判定にはサーバーの申告値を使う。
            // こちらの集計は UMP の解釈次第で過少になりうるため。
            if declaredTotal > 1_048_576 || totalBytes > 1_048_576 {
                EventLog.log(.network, videoID: videoID,
                             message: "SABR 実験の結論: 累計 申告\(declaredTotal / 1024)KiB "
                                 + "/ 実測\(totalBytes / 1024)KiB を取得できた。"
                                 + "**1 MiB を超えられた**。"
                                 + "SABR は Range の制限を受けない。本実装に進む価値がある")
                return
            }
        }

        EventLog.log(.resolveNG, videoID: videoID,
                     message: "SABR 実験の結論: 累計 申告\(declaredTotal / 1024)KiB "
                         + "/ 実測\(totalBytes / 1024)KiB で止まった。1 MiB に届かなかった")
    }

    /// 受け取った MEDIA_HEADER から buffered_ranges を組み立てる。
    /// 公式実装の `getBufferedRanges` に相当。
    private static func makeBufferedRange(from headers: [UMPMediaHeader]) -> BufferedRange? {
        guard let first = headers.first, let lastHeader = headers.last else { return nil }
        let duration = headers.reduce(0) { $0 + ($1.durationMs ?? 0) }
        return BufferedRange(
            startTimeMs: first.startMs ?? 0,
            durationMs: duration,
            startSegmentIndex: first.sequenceNumber ?? 1,
            endSegmentIndex: lastHeader.sequenceNumber ?? 1,
            timescale: first.timescale
        )
    }

    /// 直接 URL が今この瞬間に使えるかを測る (対照実験)。
    ///
    /// 1 MiB 問題が出ている最中は googlevideo 全体が渋くなる。
    /// その状態で SABR が失敗しても「SABR が駄目」とは言い切れないので、
    /// 地の状態を先に記録しておく。
    private static func probeDirectURL(videoID: String) async {
        guard let raw = try? await InnerTube.shared.player(videoID: videoID,
                                                          client: .androidVR165) else {
            EventLog.log(.network, videoID: videoID,
                         message: "SABR 実験 [対照]: ANDROID_VR を取得できず")
            return
        }
        let formats = raw["streamingData"]["adaptiveFormats"].array.filter {
            ($0["mimeType"].string ?? "").hasPrefix("audio/mp4")
        }
        guard let urlString = formats.compactMap({ $0["url"].string }).first,
              let url = URL(string: urlString) else {
            EventLog.log(.network, videoID: videoID,
                         message: "SABR 実験 [対照]: 直接 URL が無い")
            return
        }

        // 先頭と、1 MiB より先の 2 か所を見る。
        var head = URLRequest(url: url)
        head.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        head.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")
        let headCode = ((try? await session.data(for: head))?.1 as? HTTPURLResponse)?
            .statusCode ?? -1

        var deep = URLRequest(url: url)
        deep.setValue("bytes=1048576-1310719", forHTTPHeaderField: "Range")
        deep.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")
        let deepCode = ((try? await session.data(for: deep))?.1 as? HTTPURLResponse)?
            .statusCode ?? -1

        EventLog.log(.network, videoID: videoID,
                     message: "SABR 実験 [対照]: 直接 URL 先頭=\(headCode) / "
                         + "1MiB以降=\(deepCode)"
                         + (deepCode == 206 ? " (今は 1MiB 制限が出ていない)"
                                            : " (今まさに 1MiB 制限が出ている)"))
    }

    // MARK: - 1 往復

    private static func request(abrURL: String,
                                ustreamerConfig: String,
                                itag: Int,
                                lastModified: UInt64,
                                playerTimeMs: Int,
                                requestNumber: Int,
                                poToken: String?,
                                sendOrigin: Bool,
                                playbackCookie: Data?,
                                sabrContexts: [Int: SabrContext],
                                activeTypes: Set<Int>,
                                contextMode: ContextMode,
                                bufferedMode: BufferedMode = .empty,
                                buffered: BufferedRange? = nil,
                                dumpRequest: Bool = false,
                                videoID: String) async -> Result {
        var result = Result()

        guard var components = URLComponents(string: abrURL) else { return result }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "rn" }
        items.append(URLQueryItem(name: "rn", value: String(requestNumber)))
        components.queryItems = items
        guard let url = components.url else { return result }

        let body = buildRequestBody(ustreamerConfig: ustreamerConfig,
                                    itag: itag,
                                    lastModified: lastModified,
                                    playerTimeMs: playerTimeMs,
                                    poToken: poToken,
                                    playbackCookie: playbackCookie,
                                    contextMode: contextMode,
                                    bufferedMode: bufferedMode,
                                    buffered: buffered,
                                    sabrContexts: sabrContexts,
                                    activeTypes: activeTypes)

        // 自作の ProtobufLite が正しいバイト列を出しているかを目で確かめられるよう、
        // 送信内容を 16 進で残す。
        // (自分が何を送っているか一度も確認しないまま
        //  「サーバーが受け付けない」と悩んでいたため)
        if dumpRequest {
            let hex = body.prefix(160).map { String(format: "%02x", $0) }.joined()
            EventLog.log(.network, videoID: videoID,
                         message: "SABR 送信 (\(body.count)B): \(hex)"
                             + (body.count > 160 ? "…" : ""))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.yt-ump", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")

        // Origin / Referer を送るかどうか。
        //
        // kira のプロキシは host に "youtube" が含まれるときだけ
        // これらを設定しており、**googlevideo.com には付けていない**。
        //   if (url.host.includes('youtube')) { origin / referer をセット }
        // 付けたことで弾かれている可能性があるので、有無を比べられるようにする。
        if sendOrigin {
            request.setValue(YouTubeClient.originYouTube, forHTTPHeaderField: "Origin")
            request.setValue(YouTubeClient.refererYouTube, forHTTPHeaderField: "Referer")
        }
        request.httpShouldHandleCookies = false

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            result.httpStatus = http?.statusCode ?? -1
            result.contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? "なし"

            // 403 でも本体に UMP が入っていることがある。
            // SABR_ERROR や STREAM_PROTECTION_STATUS に理由が書かれているので、
            // ステータスで打ち切らず必ず解析する。
            result.bodyBytes = data.count

            let parsed = UMPReader.parseDetailed(data)
            result.unparsedBytes = parsed.remaining
            result.parseTrace = parsed.trace

            for part in parsed.parts {
                result.partCounts[part.typeLabel, default: 0] += 1

                switch UMPPartType(rawValue: part.type) {
                case .media:
                    // 先頭 1 バイトは header_id なので実データはその後ろ。
                    result.mediaBytes += max(part.payload.count - 1, 0)
                case .mediaHeader:
                    let header = UMPMediaHeader(part.payload)
                    result.mediaHeaders.append(header)
                    result.declaredBytes += header.contentLength ?? 0
                case .sabrRedirect:
                    var reader = ProtobufReader(part.payload)
                    while let (field, value) = reader.next() {
                        if field == 1 { result.redirectURL = value.string }
                    }
                case .sabrContextUpdate:
                    if let ctx = Self.parseContextUpdate(part.payload) {
                        result.sabrContexts[ctx.type] = ctx
                        if ctx.sendByDefault { result.activeContextTypes.insert(ctx.type) }
                    }

                case .sabrContextSendingPolicy:
                    // SabrContextSendingPolicy {
                    //   start_policy = 1, stop_policy = 2, discard_policy = 3 }
                    var reader = ProtobufReader(part.payload)
                    while let (field, v) = reader.next() {
                        guard let type = v.int else { continue }
                        switch field {
                        case 1: result.activeContextTypes.insert(type)
                        case 2: result.activeContextTypes.remove(type)
                        case 3: result.discardContextTypes.insert(type)
                        default: break
                        }
                    }

                case .nextRequestPolicy:
                    // NextRequestPolicy {
                    //   target_audio_readahead_ms = 1, backoff_time_ms = 4,
                    //   playback_cookie = 7, video_id = 8 }
                    var reader = ProtobufReader(part.payload)
                    var notes: [String] = []
                    while let (field, value) = reader.next() {
                        switch field {
                        case 1: notes.append("音声先読み=\(value.int ?? 0)ms")
                        case 3: notes.append("要求間隔上限=\(value.int ?? 0)ms")
                        case 4:
                            result.backoffMs = value.int ?? 0
                            notes.append("待機=\(value.int ?? 0)ms")
                        case 5: notes.append("音声先読み下限=\(value.int ?? 0)ms")
                        case 7:
                            // playback_cookie は次の要求にそのまま返す決まり。
                            result.playbackCookie = value.data
                            notes.append("playbackCookie \(value.data?.count ?? 0)B")
                        case 8: notes.append("videoId=\(value.string ?? "?")")
                        default: notes.append("field\(field)")
                        }
                    }
                    result.nextRequestPolicy = notes.joined(separator: " ")

                case .sabrError:
                    // SabrError { type = 1 (string), code = 2 (int) }
                    var reader = ProtobufReader(part.payload)
                    var type: String?
                    var code: Int?
                    while let (field, value) = reader.next() {
                        if field == 1 { type = value.string }
                        if field == 2 { code = value.int }
                    }
                    result.sabrError = "type=\(type ?? "?") code=\(code.map(String.init) ?? "?")"

                case .streamProtectionStatus:
                    // StreamProtectionStatus { status = 1, max_retries = 2 }
                    //   status 1 = OK / 2 = ATTESTATION_PENDING / 3 = ATTESTATION_REQUIRED
                    var reader = ProtobufReader(part.payload)
                    var status: Int?
                    while let (field, value) = reader.next() {
                        if field == 1 { status = value.int }
                    }
                    let label: String
                    switch status {
                    case 1:  label = "OK"
                    case 2:  label = "認証待ち"
                    case 3:  label = "認証が必要 (poToken 不足)"
                    default: label = "不明(\(status.map(String.init) ?? "-"))"
                    }
                    result.protectionStatus = label
                default:
                    // 未定義のパート。何を言われているか分からないので
                    // 先頭 32 バイトを 16 進で残す。
                    if result.unknownDumps.count < 4 {
                        let hex = part.payload.prefix(32)
                            .map { String(format: "%02x", $0) }
                            .joined()
                        result.unknownDumps.append(
                            "type=\(part.type) size=\(part.payload.count) \(hex)")
                    }
                }
            }
        } catch {
            result.errorText = error.localizedDescription
        }
        return result
    }

    // MARK: - リクエストの組み立て

    /// `VideoPlaybackAbrRequest` を組み立てる。
    ///
    /// フィールド番号の出典:
    ///   protos/video_streaming/video_playback_abr_request.proto
    ///     1  client_abr_state
    ///     2  selected_format_ids
    ///     3  buffered_ranges
    ///     5  video_playback_ustreamer_config
    ///     16 preferred_audio_format_ids
    ///     19 streamer_context
    /// 実験と本番の両方から使う。引数はすべて明示する。
    static func buildBody(ustreamerConfig: String,
                          itag: Int,
                          lastModified: UInt64,
                          playerTimeMs: Int,
                          poToken: String?,
                          playbackCookie: Data?,
                          sabrContexts: [Int: SabrContext],
                          activeTypes: Set<Int>,
                          buffered: BufferedRange?) -> Data {
        buildRequestBody(ustreamerConfig: ustreamerConfig,
                         itag: itag,
                         lastModified: lastModified,
                         playerTimeMs: playerTimeMs,
                         poToken: poToken,
                         playbackCookie: playbackCookie,
                         contextMode: .full,
                         bufferedMode: .empty,
                         buffered: buffered,
                         sabrContexts: sabrContexts,
                         activeTypes: activeTypes)
    }

    /// SABR_CONTEXT_UPDATE を読む。実験と本番で共用する。
    static func parseContextUpdate(_ payload: Data) -> SabrContext? {
        var reader = ProtobufReader(payload)
        var type: Int?
        var scope: Int?
        var value: Data?
        var sendByDefault = false
        var writePolicy: Int?
        while let (field, v) = reader.next() {
            switch field {
            case 1: type = v.int
            case 2: scope = v.int
            case 3: value = v.data
            case 4: sendByDefault = v.bool ?? false
            case 5: writePolicy = v.int
            default: break
            }
        }
        guard let type, let value, !value.isEmpty else { return nil }
        return SabrContext(type: type, scope: scope, value: value,
                           sendByDefault: sendByDefault, writePolicy: writePolicy)
    }

    private static func buildRequestBody(ustreamerConfig: String,
                                         itag: Int,
                                         lastModified: UInt64,
                                         playerTimeMs: Int,
                                         poToken: String?,
                                         playbackCookie: Data?,
                                         contextMode: ContextMode,
                                         bufferedMode: BufferedMode,
                                         buffered: BufferedRange?,
                                         sabrContexts: [Int: SabrContext],
                                         activeTypes: Set<Int>) -> Data {
        var writer = ProtobufWriter()

        // 1: ClientAbrState
        writer.write(field: 1) { state in
            // 28: player_time_ms — ここを動かすと「その時刻から送れ」になる
            state.write(field: 28, int: playerTimeMs)
            // 36: elapsed_wall_time_ms
            state.write(field: 36, int: playerTimeMs)
            // 40: enabled_track_types_bitfield
            //     1 = 音声のみ (googlevideo の EnabledTrackTypes に合わせる)
            state.write(field: 40, int: 1)
        }

        // 2: selected_format_ids
        //
        // rev.57 ではこれを送っておらず、応答が制御パートだけ (105B) だった。
        // 「どの形式を選んだか」が伝わらないと、サーバーは何を送るか決められない。
        writer.write(field: 2) { format in
            format.write(field: 1, int: itag)
            format.write(field: 2, varint: lastModified)
        }

        // 3: buffered_ranges
        //
        // 「ここまで持っている」を伝える。まだ何も持っていないので
        // 長さ 0 の範囲を 1 つだけ入れる。
        // proto 上 start_time_ms / duration_ms / 各 segment_index は
        // required なので、0 でも明示的に書く必要がある。
        if let buffered {
            // 実際に受け取った範囲を伝える。
            // これが無いとサーバーは「まだ何も持っていない」と解釈し、
            // 毎回先頭のセグメントを送り直す (または何も送らない)。
            writer.write(field: 3) { range in
                range.write(field: 1) { format in
                    format.write(field: 1, int: itag)
                    format.write(field: 2, varint: lastModified)
                }
                range.write(field: 2, int: buffered.startTimeMs)
                range.write(field: 3, int: buffered.durationMs)
                range.write(field: 4, int: buffered.startSegmentIndex)
                range.write(field: 5, int: buffered.endSegmentIndex)
                if let timescale = buffered.timescale {
                    range.write(field: 6) { timeRange in
                        timeRange.write(field: 1, int: buffered.startTimeMs)
                        timeRange.write(field: 2, int: buffered.durationMs)
                        timeRange.write(field: 3, int: timescale)
                    }
                }
            }
        } else if bufferedMode == .zeroRange {
            writer.write(field: 3) { range in
                range.write(field: 1) { format in            // format_id
                    format.write(field: 1, int: itag)
                    format.write(field: 2, varint: lastModified)
                }
                range.write(field: 2, int: 0)                // start_time_ms
                range.write(field: 3, int: 0)                // duration_ms
                range.write(field: 4, int: 0)                // start_segment_index
                range.write(field: 5, int: 0)                // end_segment_index
            }
        }
        // .empty のときは field 3 を一切書かない。
        // 公式実装も、まだ何も持っていないときは空配列を渡している。

        // 16: preferred_audio_format_ids — misc.FormatId
        writer.write(field: 16) { format in
            format.write(field: 1, int: itag)                 // itag
            format.write(field: 2, varint: lastModified)      // last_modified
        }

        // 5: video_playback_ustreamer_config (base64 → バイト列)
        if let config = decodeBase64URL(ustreamerConfig) {
            writer.write(field: 5, bytes: config)
        }

        // 19: StreamerContext
        writer.write(field: 19) { context in
            // 1: ClientInfo
            context.write(field: 1) { info in
                info.write(field: 16, int: 1)                 // client_name = WEB
                info.write(field: 17, string: "2.20260813.01.00")  // client_version
                info.write(field: 18, string: "iOS")          // os_name
                info.write(field: 19, string: "26.6")         // os_version
            }
            // 2: po_token
            //
            // SABR の入口が 403 を返したので、認証が要ると見て入れる。
            // googlevideo も streamerContext.poToken に入れている。
            if let poToken, let bytes = decodeBase64URL(poToken) {
                context.write(field: 2, bytes: bytes)
            }
            // 3: playback_cookie
            //    サーバーが NEXT_REQUEST_POLICY で返してきたものを
            //    次の要求にそのまま返す決まり。空なら送らない。
            if let playbackCookie, !playbackCookie.isEmpty {
                context.write(field: 3, bytes: playbackCookie)
            }

            // 5: sabr_contexts / 6: unsent_sabr_contexts
            //
            // ここが rev.58 まで欠けていた部分。
            // サーバーは SABR_CONTEXT_UPDATE (パート 57) で
            // 「このコンテキストを次から付けて送れ」と指示してくる。
            // 返さないと同じ指示を繰り返すだけで、メディアが降りてこない。
            // (2026-08-14 実測: 105B の制御パートだけが毎回返ってきていた)
            // 5: sabr_contexts / 6: unsent_sabr_contexts
            //
            // ── ここを rev.59〜61 で間違えていた ──────────────────
            //
            // 受け取るときの型と返すときの型が **別物** だった。
            //
            //   受信: SabrContextUpdate {
            //           type = 1, scope = 2, value = 3,
            //           send_by_default = 4, write_policy = 5 }
            //
            //   送信: StreamerContext.SabrContext {
            //           type = 1, value = 2 }          ← 2 項目だけ
            //
            // 私は受信側の番号のまま返していたので、
            //   ・scope (int) を value (bytes) の位置に書いた
            //   ・value を存在しないフィールド 3 に書いた
            // となり、サーバーが sabr.malformed_config を返していた。
            //
            // 「載せない」「番号のみ」で正常応答が返り、
            // 中身を書いた 2 通りだけがエラーになった事実とも一致する。
            switch contextMode {
            case .none:
                break   // 何も載せない

            case .unsentOnly:
                for type in sabrContexts.keys.sorted() {
                    context.write(field: 6, int: type)
                }

            case .full:
                for (type, ctx) in sabrContexts.sorted(by: { $0.key < $1.key }) {
                    if activeTypes.contains(type) {
                        context.write(field: 5) { item in
                            item.write(field: 1, int: ctx.type)     // type
                            item.write(field: 2, bytes: ctx.value)  // value
                        }
                    } else {
                        context.write(field: 6, int: type)
                    }
                }
            }
        }

        return writer.data
    }

    /// base64 / base64url のどちらでも読めるようにする。
    private static func decodeBase64URL(_ text: String) -> Data? {
        var s = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    // MARK: - 記録

    private static func report(_ result: Result, label: String, videoID: String) {
        if let error = result.errorText {
            EventLog.log(.network, videoID: videoID,
                         message: "SABR 実験 [\(label)]: 失敗 \(error)")
            return
        }

        let parts = result.partCounts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")

        EventLog.log(.network, videoID: videoID,
                     message: "SABR 実験 [\(label)]: HTTP \(result.httpStatus) "
                         + "/ \(result.contentType) "
                         + "/ 本体 \(result.bodyBytes)B "
                         + "/ MEDIA \(result.mediaBytes)B "
                         + "/ 申告 \(result.declaredBytes)B "
                         + "/ 読み残し \(result.unparsedBytes)B "
                         + "/ パート: \(parts.isEmpty ? "なし" : parts)")

        // 本体と読み取り量が食い違うなら、UMP の解釈を誤っている。
        if result.unparsedBytes > 0 || (result.bodyBytes > 1000
            && result.mediaBytes * 2 < result.bodyBytes) {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "SABR 実験 [\(label)] 走査: "
                             + result.parseTrace.joined(separator: " "))
        }

        if let status = result.protectionStatus {
            EventLog.log(.network, videoID: videoID,
                         message: "SABR 実験 [\(label)] 保護状態: \(status)")
        }
        if let policy = result.nextRequestPolicy {
            EventLog.log(.network, videoID: videoID,
                         message: "SABR 実験 [\(label)] 次回方針: \(policy)")
        }
        if !result.sabrContexts.isEmpty {
            let detail = result.sabrContexts.values
                .map { "type=\($0.type)/\($0.scopeLabel)/\($0.value.count)B"
                        + ($0.sendByDefault ? "/既定送信" : "") }
                .joined(separator: " ")
            EventLog.log(.network, videoID: videoID,
                         message: "SABR 実験 [\(label)] コンテキスト: \(detail)")
        }
        for dump in result.unknownDumps {
            EventLog.log(.network, videoID: videoID,
                         message: "SABR 実験 [\(label)] 未知パート: \(dump)")
        }
        if let sabrError = result.sabrError {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "SABR 実験 [\(label)] SABR_ERROR: \(sabrError)")
        }

        for header in result.mediaHeaders.prefix(3) {
            EventLog.log(.network, videoID: videoID,
                         message: "SABR 実験 [\(label)] MEDIA_HEADER: \(header.summary)")
        }
        if let redirect = result.redirectURL {
            EventLog.log(.network, videoID: videoID,
                         message: "SABR 実験 [\(label)]: SABR_REDIRECT あり "
                             + "(\(redirect.prefix(60))…)")
        }
    }
}
