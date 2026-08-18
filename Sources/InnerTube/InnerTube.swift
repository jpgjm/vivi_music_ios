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

    /// 匿名 (未ログイン) セッションの dataSyncId。
    ///
    /// ── なぜ必要か (rev.85) ──────────────────────────────────
    ///
    /// 公式 iOS アプリのコンテナを解析したところ、identity の分離は
    /// visitorData ではなく **`X-YouTube-DataSync-Id` ヘッダ**で
    /// 行われていた。
    ///
    ///   未ログイン: X-YouTube-DataSync-Id: 416E647D-…-E932CBB1FE9A||
    ///   ログイン中: X-YouTube-DataSync-Id: 101105309871169484516||
    ///
    /// 末尾の `||` は pageId (ブランドチャンネル) の区切りで、
    /// 既定チャンネルでは空になる。ストレージのスコープ
    /// (`Media/CacheV2/<dataSyncId>/`) もこの ID で切られていた。
    ///
    /// 重要なのは **未ログイン時も必ず送っている**点。公式は
    /// 初回起動時に UUID を 1 つ生成し、以後ずっと使い続ける。
    /// ViviMusic はこのヘッダを一度も送っていなかったので、
    /// 公式と同じ形にするため匿名用の UUID を用意する。
    ///
    /// visitorData と同様、**一度決めたら変えない**。
    /// 端末ごとに固定したいので UserDefaults に保存する。
    /// 実体は `GuestIdentity` (このファイル末尾) にある。

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

        // ── rev.85: X-YouTube-DataSync-Id ────────────────────────
        //
        // 公式アプリが identity を分ける唯一のヘッダ。
        // ログイン中はアカウントの dataSyncId、未ログイン時は
        // 端末ごとに固定した UUID を、いずれも末尾 `||` 付きで送る。
        //
        // TVHTML5 には付けない。このクライアントは Music 系ヘッダを
        // 嫌う (付けるとセッション不整合と判定される) ので、
        // 余計なヘッダで既存の動作を壊さないようにする。
        if !client.isTVClient {
            let dataSyncValue: String
            if let id = auth?.dataSyncID, !id.isEmpty {
                // 保存済みの値に既に `||` が付いていることがある。
                dataSyncValue = id.hasSuffix("||") ? id : id + "||"
            } else {
                dataSyncValue = GuestIdentity.dataSyncID + "||"
            }
            req.setValue(dataSyncValue, forHTTPHeaderField: "X-YouTube-DataSync-Id")
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

    /// visitorData の引き直しを許可するか。
    ///
    /// ── なぜ既定で false なのか (rev.85) ──────────────────────
    ///
    /// 公式 iOS アプリのデータコンテナを 3 回取得して比較した結果、
    /// **公式は visitorData をまったく引き直していなかった**。
    ///
    ///   1 回目 (サインアウト) : 4X-uwWeAAZ8 / 発行 1787010491
    ///   2 回目 (サインイン後) : 完全に同一 (f12 の sha1 まで一致)
    ///   3 回目 (再サインアウト): 完全に同一
    ///
    /// この単一の visitorData のまま、公式は itag 140 を
    /// 3.5〜4.1 MiB (約 240 秒ぶん) 連続で取得できていた。
    /// 1 MiB / 65 秒どころか、その 4 倍近くまで問題なく通っている。
    ///
    /// つまり「1 MiB 制限は visitorData の鮮度で決まる」という
    /// 従来の理解は誤りだった可能性が高い。少なくとも公式は
    /// 引き直しをまったく必要としていない。
    ///
    /// さらに、短時間に何度も visitorData を引き直す挙動は
    /// 公式クライアントには存在しないため、それ自体が
    /// アンチアビューズ側の異常シグナルになりうる。
    ///
    /// 効果を再検証したくなったら、ここを true に戻せば
    /// 以前の挙動 (最大 4 回の引き直し) が復活する。
    static var allowVisitorDataRenewal = false

    /// InnerTube 要求に付けている Accept-Language ヘッダの値。
    /// SABR の StreamerContext.ClientInfo と揃えるために公開する。
    func acceptLanguageHeader() -> String {
        "\(locale.hl)-\(locale.gl),\(locale.hl);q=0.9"
    }

    /// visitorData を捨てて、次の要求で新しいものを引き直す。
    ///
    /// **既定では何もせず false を返す。**
    /// 理由は `allowVisitorDataRenewal` のコメントを参照。
    ///
    /// - Note: ログイン中は visitorData がアカウントに紐づくので
    ///         引き直さない。切ると Cookie 認証との整合が壊れる。
    ///
    /// - Returns: 実際に引き直したなら true。
    ///   無効化されている / ログイン中などで引き直せなかったときは false。
    ///   呼び出し側は、false のときに同じことを繰り返さないようにする。
    @discardableResult
    func renewVisitorData() async -> Bool {
        guard Self.allowVisitorDataRenewal else {
            EventLog.log(.network,
                         message: "visitorData の引き直しは無効化されている "
                             + "(公式クライアントは引き直さないため)")
            return false
        }
        guard visitorData != nil else { return false }
        // ログイン中はアカウントに紐づいた visitorData なので触らない。
        if await CookieAuthService.shared.credentials != nil {
            EventLog.log(.network,
                         message: "ログイン中のため visitorData は引き直さない")
            return false
        }
        let old = visitorData?.prefix(12) ?? "-"
        visitorData = nil

        // VISITOR_ 系の Cookie も一緒に消す。
        // これが残っていると、次の要求で同じアイデンティティが
        // 復元されてしまい引き直した意味が無くなる。
        if let base = URL(string: "https://www.youtube.com") {
            HTTPCookieStorage.shared.cookies(for: base)?
                .filter { $0.name.hasPrefix("VISITOR_") }
                .forEach(HTTPCookieStorage.shared.deleteCookie)
        }

        EventLog.log(.network,
                     message: "visitorData を破棄して引き直す (旧 \(old)…)")
        return true
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
    ///
    /// - Parameter continuation: 2 ページ目以降のトークン。
    ///   **検索の続きは本体ではなくクエリ文字列で渡す決まり**で、
    ///   browse (`continuation` を本体に入れる) とは作法が違う。
    ///   本家 Android 版も `parameter("ctoken"/"continuation")` で付けている。
    ///   このとき query / params は送らない。
    func search(query: String? = nil,
                params: String? = nil,
                continuation: String? = nil) async throws -> JSON {
        var body: [String: Any] = [:]
        var endpoint = "search"

        if let continuation, !continuation.isEmpty {
            // トークンには = や + が含まれるので、確実に通るよう
            // 英数字以外はすべて百分率符号化する。
            let encoded = continuation
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
                ?? continuation
            endpoint += "?ctoken=\(encoded)&continuation=\(encoded)&type=next"
        } else {
            if let query { body["query"] = query }
            if let params { body["params"] = params }
        }

        return try await post(endpoint: endpoint, client: .webRemix,
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

/// 匿名 (未ログイン) セッションの識別子。
///
/// 公式 iOS アプリは初回起動時に UUID を 1 つ生成し、
/// `X-YouTube-DataSync-Id: <UUID>||` として **未ログイン時も必ず**
/// 送っている。サインイン・サインアウトを繰り返してもこの UUID は
/// 変わらず、ストレージのスコープ分割にも使われていた。
///
///   Media/CacheV2/416E647D-814F-4EDA-872F-E932CBB1FE9A||/   ← ゲスト
///   Media/CacheV2/101105309871169484516||/                  ← ログイン中
///
/// ViviMusic もこれに倣い、端末ごとに固定の UUID を 1 つ持つ。
/// **引き直してはいけない。** 公式が変えないものを変えると、
/// それ自体が挙動の差になる。
enum GuestIdentity {

    private static let key = "innertube.guestDataSyncID"

    /// 端末に固定された匿名 dataSyncId (末尾の `||` は含まない)。
    static var dataSyncID: String {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: key), !saved.isEmpty {
            return saved
        }
        // 公式と同じ「大文字ハイフン区切り UUID」形式にする。
        let generated = UUID().uuidString
        defaults.set(generated, forKey: key)
        EventLog.log(.network,
                     message: "匿名 dataSyncId を生成 (\(generated.prefix(8))…)")
        return generated
    }

    /// 診断や検証のために作り直す。通常の再生経路からは呼ばない。
    static func regenerate() {
        UserDefaults.standard.removeObject(forKey: key)
        EventLog.log(.network, message: "匿名 dataSyncId を破棄した")
    }
}
