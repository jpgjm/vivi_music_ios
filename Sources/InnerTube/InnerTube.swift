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
    func post(endpoint: String,
              client: YouTubeClient,
              body extra: [String: Any]) async throws -> JSON {

        let started = Date()
        guard let url = URL(string: client.apiBaseURL + endpoint) else {
            throw URLError(.badURL)
        }

        var payload: [String: Any] = ["context": client.context(locale: locale)]
        for (k, v) in extra { payload[k] = v }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if client.usesMusicHeaders {
            // YouTube Music 向けのヘッダ構成 (本家 InnerTube.kt と同じ)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")
            req.setValue(client.clientID, forHTTPHeaderField: "X-YouTube-Client-Name")
            req.setValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
            req.setValue(YouTubeClient.originYouTubeMusic, forHTTPHeaderField: "X-Origin")
            req.setValue(YouTubeClient.originYouTubeMusic, forHTTPHeaderField: "Origin")
            req.setValue(YouTubeClient.refererYouTubeMusic, forHTTPHeaderField: "Referer")
            if let visitorData {
                req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
            }
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
                             message: "POST \(endpoint) [\(client.clientName)] OK \(data.count)B")

        let json = JSON(data: data)
        // セッション識別子を覚えておく (poToken の紐づけに使う)
        if visitorData == nil,
           let value = json["responseContext"]["visitorData"].string, !value.isEmpty {
            visitorData = value
            EventLog.log(.network, message: "visitorData を取得 (\(value.prefix(12))…)")
        }
        return json
    }

    // MARK: - 各エンドポイント

    /// 検索。`params` は SearchFilter の値 (曲だけ / アルバムだけ など)。
    func search(query: String, params: String?) async throws -> JSON {
        var body: [String: Any] = ["query": query]
        if let params { body["params"] = params }
        return try await post(endpoint: "search", client: .webRemix, body: body)
    }

    /// ブラウズ。ホーム (`FEmusic_home`) や 探索 (`FEmusic_explore`) など。
    func browse(browseID: String?,
                params: String? = nil,
                continuation: String? = nil) async throws -> JSON {
        var body: [String: Any] = [:]
        if let browseID { body["browseId"] = browseID }
        if let params { body["params"] = params }
        if let continuation { body["continuation"] = continuation }
        return try await post(endpoint: "browse", client: .webRemix, body: body)
    }

    /// 検索候補 (オートコンプリート)。
    /// エンドポイントは `youtubei/v1/music/get_search_suggestions`。
    func searchSuggestions(input: String) async throws -> JSON {
        let body: [String: Any] = ["input": input]
        return try await post(endpoint: "music/get_search_suggestions",
                              client: .webRemix,
                              body: body)
    }

    /// 再生情報。指定クライアントで叩く。
    /// - Parameter poToken: BotGuard で作った player 用トークン (あれば)
    func player(videoID: String,
                client: YouTubeClient,
                poToken: String? = nil) async throws -> JSON {
        var body: [String: Any] = [
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        if let poToken {
            body["serviceIntegrityDimensions"] = ["poToken": poToken]
        }
        return try await post(endpoint: "player", client: client, body: body)
    }

    /// 関連曲 (自動再生キューの継続に使う)。
    func next(videoID: String) async throws -> JSON {
        let body: [String: Any] = [
            "videoId": videoID,
            "isAudioOnly": true,
        ]
        return try await post(endpoint: "next", client: .webRemix, body: body)
    }
}
