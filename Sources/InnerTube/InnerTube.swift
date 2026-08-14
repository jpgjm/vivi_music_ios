//
//  InnerTube.swift
//  ViviMusic
//
//  InnerTube への HTTP リクエストを担う層。
//  ヘッダの構成はオリジナル VIVI Music の `InnerTube.kt` に合わせている。
//  ここでは「叩いて JSON を返す」だけを行い、解釈は Parsers.swift に任せる。
//

import Foundation

enum InnerTubeError: LocalizedError {
    case badResponse(status: Int, body: String)
    case noStream(videoID: String)
    case playabilityBlocked(reason: String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let status, let body):
            return "InnerTube HTTP \(status): \(body.prefix(200))"
        case .noStream(let videoID):
            return "再生可能なストリームが見つかりません (\(videoID))"
        case .playabilityBlocked(let reason):
            return "再生できません: \(reason)"
        }
    }
}

/// InnerTube への低レベルアクセス。
actor InnerTube {
    static let shared = InnerTube()

    /// 地域・言語。日本の音楽が出るよう既定は JP/ja。
    private let locale = (hl: "ja", gl: "JP")

    /// InnerTube のセッション識別子。応答から拾って以後の要求に付ける。
    /// poToken を紐づける識別子としても使う。
    private(set) var visitorData: String?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    // MARK: - 汎用 POST

    /// InnerTube の任意エンドポイントに POST して JSON を得る。
    /// - Parameters:
    ///   - endpoint: "search" / "browse" / "player" / "next" など
    ///   - client: 使用するクライアント
    ///   - body: `context` 以外の追加パラメータ
    ///   - useLogin: Cookie 認証 (Cookie + SAPISIDHASH) を付けるか。
    ///     **player では必ず false にする。**
    ///     再生系は ANDROID_VR → IOS → WEB_REMIX → TVHTML5 の経路が
    ///     実績どおり動いているので、認証を混ぜて壊さない。
    func post(endpoint: String,
              client: YouTubeClient,
              body extra: [String: Any],
              useLogin: Bool = false) async throws -> JSON {

        let started = Date()
        guard let url = URL(string: client.apiBaseURL + endpoint) else {
            throw URLError(.badURL)
        }

        // ---------------------------------------------------------------
        // Cookie 認証。対象は loginSupported なクライアント (= WEB_REMIX) だけ。
        // ---------------------------------------------------------------
        let auth: InnerTubeAuthHeaders? =
            (useLogin && client.loginSupported)
                ? await CookieAuthService.shared.headers(origin: client.origin)
                : nil

        // ログイン済みならアカウントに紐づいた visitorData を優先する。
        let effectiveVisitorData = auth?.visitorData ?? visitorData

        // visitorData は **全クライアントに** 入れる。
        //
        // rev.38 で Music 系だけに絞ったが、それは誤りだった。
        // googlevideo に付ける poToken は visitorData に紐づいており、
        // player 要求が同じ visitorData を名乗っていないと
        // 「URL は取れるのに再生だけ 403」という状態になる。
        // yt-dlp も全クライアントの context に visitorData を入れている。
        let contextVisitorData = effectiveVisitorData

        var payload: [String: Any] = [
            "context": client.context(locale: locale,
                                      visitorData: contextVisitorData,
                                      dataSyncID: auth?.dataSyncID)
        ]
        for (k, v) in extra { payload[k] = v }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Cookie は下で自前で組み立てる。URLSession の共有 Cookie ストアに
        // 勝手に足されると二重送信になるので切っておく。
        req.httpShouldHandleCookies = false

        if client.usesMusicHeaders {
            // YouTube Music 向けのヘッダ構成 (本家 InnerTube.kt と同じ)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")
            req.setValue(client.clientID, forHTTPHeaderField: "X-YouTube-Client-Name")
            req.setValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
            // 原点はクライアントごとに違う。
            // WEB は www.youtube.com、WEB_REMIX は music.youtube.com。
            // SAPISIDHASH の計算にも同じ値を使っているので揃える。
            req.setValue(client.origin, forHTTPHeaderField: "X-Origin")
            req.setValue(client.origin, forHTTPHeaderField: "Origin")
            req.setValue(client.origin + "/", forHTTPHeaderField: "Referer")

            // Accept-Language は context の hl と揃える。
            // 以前は "en-US,en;q=0.9" 固定で、context.hl=ja と食い違っていた。
            req.setValue("\(locale.hl)-\(locale.gl),\(locale.hl);q=0.9",
                         forHTTPHeaderField: "Accept-Language")
        }

        // X-Goog-Visitor-Id はクライアントを問わず付ける。
        // context の visitorData と一致させないとセッションが割れる。
        if let effectiveVisitorData {
            req.setValue(effectiveVisitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        if let auth {
            req.setValue(auth.cookie, forHTTPHeaderField: "Cookie")
            req.setValue(auth.authorization, forHTTPHeaderField: "Authorization")
        }
        // TVHTML5 には Music 用のヘッダを付けない。
        // 付けるとセッション不整合と判定され
        // 「ページを再読み込みする必要があります」で拒否される。

        // ---------------------------------------------------------------
        // OAuth のアクセストークンは **TVHTML5 にだけ** 付ける。
        //
        // デバイスフローで得るトークンは TV 向けアプリの資格情報で発行される。
        // WEB_REMIX など他のクライアントに付けると
        //   "Request contains an invalid argument" (HTTP 400)
        // で全リクエストが弾かれる。以前これで検索もホームも壊した。
        // ---------------------------------------------------------------
        if client.acceptsOAuth,
           let token = await GoogleAuthService.shared.validAccessToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // 入力中に古いリクエストを捨てるのは正常動作なのでログに残さない
            if (error as? URLError)?.code != .cancelled {
                EventLog.logError(.network, error: error,
                                  context: "POST \(endpoint) [\(client.clientName)]")
            }
            throw error
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            EventLog.log(.network,
                         message: "POST \(endpoint) [\(client.clientName)] → HTTP \(status)")
            throw InnerTubeError.badResponse(status: status, body: body)
        }

        EventLog.logDuration(.network,
                             start: started,
                             message: "POST \(endpoint) [\(client.clientName)]"
                                 + (auth != nil ? " 認証あり" : "")
                                 + " OK \(data.count)B")

        // 診断用: player の応答をそのまま残す (既定はオフ)。
        // 実験フラグの在り処など、ログの要約だけでは追えないものを見るため。
        if endpoint == "player" {
            let videoID = (extra["videoId"] as? String) ?? "-"
            PlayerResponseDump.write(data: data,
                                     videoID: videoID,
                                     clientName: client.clientName)
        }

        let json = JSON(data: data)
        // セッション識別子を覚えておく (poToken の紐づけに使う)。
        // ログイン済みで保存済みの visitorData がある場合はそちらが優先なので
        // 学習しない (上書きするとアカウントとの紐づけが切れる)。
        if visitorData == nil,
           let value = json["responseContext"]["visitorData"].string, !value.isEmpty {
            visitorData = value
            EventLog.log(.network, message: "visitorData を取得 (\(value.prefix(12))…)")
        }
        return json
    }

    /// 保存済みの visitorData を採用する (ログイン時・起動時に呼ばれる)。
    func adoptVisitorData(_ value: String?) {
        guard let value, !value.isEmpty else { return }
        guard visitorData != value else { return }
        visitorData = value
        EventLog.log(.network, message: "保存済み visitorData を採用 (\(value.prefix(12))…)")
    }

    // MARK: - 各エンドポイント

    /// 検索。`params` は SearchFilter の値 (曲だけ / アルバムだけ など)。
    func search(query: String, params: String?) async throws -> JSON {
        var body: [String: Any] = ["query": query]
        if let params { body["params"] = params }
        return try await post(endpoint: "search", client: .webRemix,
                              body: body, useLogin: true)
    }

    /// ブラウズ。ホーム (`FEmusic_home`) や 探索 (`FEmusic_explore`) など。
    func browse(browseID: String?,
                params: String? = nil,
                continuation: String? = nil) async throws -> JSON {
        var body: [String: Any] = [:]
        if let browseID { body["browseId"] = browseID }
        if let params { body["params"] = params }
        if let continuation { body["continuation"] = continuation }
        return try await post(endpoint: "browse", client: .webRemix,
                              body: body, useLogin: true)
    }

    /// 検索候補 (オートコンプリート)。
    /// エンドポイントは `youtubei/v1/music/get_search_suggestions`。
    func searchSuggestions(input: String) async throws -> JSON {
        let body: [String: Any] = ["input": input]
        return try await post(endpoint: "music/get_search_suggestions",
                              client: .webRemix,
                              body: body,
                              useLogin: true)
    }

    /// アカウントメニュー。ログイン中のアカウント名を得る。
    /// Cookie 認証が本当に効いているかの確認にも使う。
    func accountMenu() async throws -> JSON {
        return try await post(endpoint: "account/account_menu",
                              client: .webRemix,
                              body: [:],
                              useLogin: true)
    }

    /// 再生情報。指定クライアントで叩く。
    /// - Parameter poToken: BotGuard で作った player 用トークン (あれば)
    /// - Parameter useLogin: Cookie 認証を付けるか。
    ///   WEB / WEB_REMIX でのみ意味がある (loginSupported が真のクライアント)。
    ///   ANDROID_VR / IOS / TVHTML5 に渡しても無視される。
    func player(videoID: String,
                client rawClient: YouTubeClient,
                poToken: String? = nil,
                useLogin: Bool = false) async throws -> JSON {
        // WEB は版数が頻繁に変わるので、実際のページから取った値に差し替える。
        var client = rawClient
        if client.clientName == "WEB" {
            client.clientVersion = await WebClientVersion.shared.current()
        }

        var body: [String: Any] = [
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        if let poToken {
            body["serviceIntegrityDimensions"] = ["poToken": poToken]
        }

        // ---------------------------------------------------------------
        // TVHTML5 は signatureTimestamp が無いと再生情報を返さず
        //   「ページを再読み込みする必要があります。」
        // で拒否される。ログイン済みの再生は TVHTML5 でしか通せないため、
        // ここが欠けていると認証済み経路が丸ごと死に、匿名クライアントに
        // 落ちて bot 判定される。
        //
        // 取得できなかった場合は付けずに続行する
        // (どのみち他のクライアントを試すことになる)。
        // ---------------------------------------------------------------
        if client.requiresSignatureTimestamp,
           let sts = await PlayerJSService.shared.signatureTimestamp() {
            body["playbackContext"] = [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS",
                    "signatureTimestamp": sts,
                ]
            ]
        }

        return try await post(endpoint: "player", client: client,
                              body: body, useLogin: useLogin)
    }

    /// 関連曲 (自動再生キューの継続に使う)。
    func next(videoID: String) async throws -> JSON {
        let body: [String: Any] = [
            "videoId": videoID,
            "isAudioOnly": true,
        ]
        return try await post(endpoint: "next", client: .webRemix,
                              body: body, useLogin: true)
    }
}
