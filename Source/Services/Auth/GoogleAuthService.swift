//
//  GoogleAuthService.swift
//  ViviMusic
//
//  Google (YouTube) へのログイン。OAuth の **デバイスフロー** を使う。
//
//  なぜログインが要るのか:
//    YouTube の bot 検出が強化され、未ログインだと
//      「ログインして bot ではないことを確認してください」
//    で再生 URL が発行されない、あるいは発行されても途中で 403 になる。
//    本家 VIVI Music (Android) がログイン機能を持っているのも同じ理由。
//
//  なぜデバイスフローなのか:
//    WebView に Google のログイン画面を出す方式は **使えない**。
//    実機で試したところ Google が埋め込みブラウザを検出し
//      「このブラウザまたはアプリは安全でない可能性があります」
//    と表示してログインを拒否した (2021 年以降の Google のポリシー)。
//
//    デバイスフローは Google がテレビなど入力の限られた機器向けに
//    公式提供している方式なので拒否されない。
//    利用者は普段使っているブラウザで google.com/device に
//    コードを入れるだけで済む。
//
//  手順:
//    1. youtube.com/tv から base-js の URL を取り出す
//    2. その JS からクライアント ID / シークレットを取り出す
//       (TV 向けアプリの公開資格情報。YouTube 側が JS に埋め込んでいるもの)
//    3. デバイスコードを要求し、利用者にコードと URL を提示
//    4. 利用者が承認するまでトークンエンドポイントを一定間隔で叩く
//    5. 得たトークンを Keychain に保存し、以後の InnerTube 要求に Bearer で付ける
//

import Foundation

@MainActor
final class GoogleAuthService: ObservableObject {
    static let shared = GoogleAuthService()

    // MARK: - 状態

    enum State: Equatable {
        case signedOut
        /// 利用者が google.com/device でコードを入力するのを待っている
        case awaitingApproval(userCode: String, verificationURL: String)
        case signedIn
    }

    @Published private(set) var state: State = .signedOut
    /// 画面に出す進捗・エラーメッセージ
    @Published private(set) var statusMessage: String?

    private var tokens: OAuthTokens? {
        didSet { state = tokens == nil ? .signedOut : .signedIn }
    }

    private var pollTask: Task<Void, Never>?

    var isSignedIn: Bool { tokens != nil }

    // MARK: - 定数

    private let deviceCodeURL = "https://www.youtube.com/o/oauth2/device/code"
    private let tokenURL = "https://www.youtube.com/o/oauth2/token"
    private let tvPageURL = "https://www.youtube.com/tv"

    /// TV 向けの UA。デバイスフローはこの UA でないと資格情報が取れない。
    private let cobaltUserAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"

    private let scope = "http://gdata.youtube.com "
        + "https://www.googleapis.com/auth/youtube-paid-content"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 45
        return URLSession(configuration: cfg)
    }()

    private init() {
        tokens = TokenStore.load()
        // Swift では初期化中の代入で didSet が呼ばれないため、state を明示的に合わせる
        state = tokens == nil ? .signedOut : .signedIn
        EventLog.log(.bootstrap,
                     message: isSignedIn ? "ログイン済みトークンを読み込み" : "未ログイン")
    }

    // MARK: - ログイン開始

    /// デバイスフローを開始する。
    /// 成功すると `state` が `.awaitingApproval` になり、コードが表示される。
    func startSignIn() async {
        cancelPolling()
        statusMessage = "認証情報を取得しています…"

        do {
            let credentials = try await fetchClientCredentials()
            statusMessage = "コードを発行しています…"

            let device = try await requestDeviceCode(credentials: credentials)
            state = .awaitingApproval(userCode: device.userCode,
                                      verificationURL: device.verificationURL)
            statusMessage = "表示されたコードを入力してください"
            EventLog.log(.auth, message: "デバイスコード発行: \(device.userCode)")

            // 承認されるまで裏で待つ
            pollTask = Task { await self.poll(device: device, credentials: credentials) }

        } catch {
            statusMessage = "認証の開始に失敗しました: \(error.localizedDescription)"
            EventLog.logError(.auth, error: error, context: "startSignIn")
        }
    }

    func cancelSignIn() {
        cancelPolling()
        state = tokens == nil ? .signedOut : .signedIn
        statusMessage = nil
        EventLog.log(.auth, message: "ログイン操作をキャンセル")
    }

    func signOut() {
        cancelPolling()
        tokens = nil
        TokenStore.delete()
        statusMessage = nil
        EventLog.log(.auth, message: "ログアウトしました")
    }

    private func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - トークンの取得 (InnerTube から呼ばれる)

    /// 有効なアクセストークンを返す。期限が近ければ自動で更新する。
    /// 未ログインなら nil。
    func validAccessToken() async -> String? {
        guard let current = tokens else { return nil }
        guard current.needsRefresh else { return current.accessToken }

        do {
            let refreshed = try await refresh(current)
            tokens = refreshed
            TokenStore.save(refreshed)
            EventLog.log(.auth, message: "アクセストークンを更新しました")
            return refreshed.accessToken
        } catch {
            EventLog.logError(.auth, error: error, context: "トークン更新")
            // 更新できない = 認証が切れた
            tokens = nil
            TokenStore.delete()
            return nil
        }
    }

    // MARK: - 手順 1〜2: クライアント資格情報の取得

    private struct Credentials {
        let clientID: String
        let clientSecret: String
    }

    private func fetchClientCredentials() async throws -> Credentials {
        // youtube.com/tv の HTML から base-js の場所を取る
        let html = try await getText(urlString: tvPageURL, userAgent: cobaltUserAgent)
        guard let scriptPath = Self.firstMatch(
            pattern: "<script\\s+id=\"base-js\"\\s+src=\"([^\"]+)\"",
            in: html
        ) else {
            throw AuthError.credentialsNotFound("base-js が見つかりません")
        }

        let scriptURL = scriptPath.hasPrefix("http")
            ? scriptPath
            : "https://www.youtube.com" + scriptPath

        // その JS から clientId とシークレットを取る
        let js = try await getText(urlString: scriptURL, userAgent: cobaltUserAgent)
        guard let clientID = Self.firstMatch(pattern: "clientId:\"([^\"]+)\"", in: js),
              let clientSecret = Self.firstMatch(
                pattern: "clientId:\"[^\"]+\",\\s*\\w+:\"([^\"]+)\"",
                in: js
              ) else {
            throw AuthError.credentialsNotFound("clientId/secret が見つかりません")
        }

        EventLog.log(.auth, message: "クライアント資格情報を取得 (id=\(clientID.prefix(16))…)")
        return Credentials(clientID: clientID, clientSecret: clientSecret)
    }

    // MARK: - 手順 3: デバイスコードの要求

    private struct DeviceCode {
        let deviceCode: String
        let userCode: String
        let verificationURL: String
        let interval: Int
    }

    private func requestDeviceCode(credentials: Credentials) async throws -> DeviceCode {
        let json = try await postForm(urlString: deviceCodeURL, fields: [
            "client_id": credentials.clientID,
            "scope": scope,
            "device_id": UUID().uuidString,
            "device_model": "ytlr::",
        ])

        guard let deviceCode = json["device_code"].string,
              let userCode = json["user_code"].string else {
            throw AuthError.deviceCodeFailed(json["error"].string ?? "不明")
        }
        let verification = json["verification_url"].string ?? "https://www.google.com/device"
        let interval = json["interval"].int ?? 5

        return DeviceCode(deviceCode: deviceCode,
                          userCode: userCode,
                          verificationURL: verification,
                          interval: interval)
    }

    // MARK: - 手順 4: 承認されるまで待つ

    private func poll(device: DeviceCode, credentials: Credentials) async {
        var interval = device.interval
        // だいたい 10 分で諦める
        let deadline = Date().addingTimeInterval(10 * 60)

        while Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            } catch {
                return   // キャンセルされた
            }
            if Task.isCancelled { return }

            do {
                let json = try await postForm(urlString: tokenURL, fields: [
                    "client_id": credentials.clientID,
                    "client_secret": credentials.clientSecret,
                    "code": device.deviceCode,
                    "grant_type": "http://oauth.net/grant_type/device/1.0",
                ])

                if let access = json["access_token"].string,
                   let refresh = json["refresh_token"].string {
                    let expiresIn = json["expires_in"].int ?? 3600
                    let newTokens = OAuthTokens(
                        accessToken: access,
                        refreshToken: refresh,
                        expiryDate: Date().addingTimeInterval(TimeInterval(expiresIn)),
                        clientID: credentials.clientID,
                        clientSecret: credentials.clientSecret
                    )
                    tokens = newTokens
                    TokenStore.save(newTokens)
                    statusMessage = "ログインしました"
                    EventLog.log(.auth, message: "ログイン成功")
                    return
                }

                switch json["error"].string {
                case "authorization_pending":
                    continue                    // まだ承認されていない。待ち続ける
                case "slow_down":
                    interval += 5               // 間隔を空けるよう言われた
                case "expired_token":
                    statusMessage = "コードの有効期限が切れました。やり直してください。"
                    EventLog.log(.auth, message: "デバイスコード期限切れ")
                    state = .signedOut
                    return
                case "access_denied":
                    statusMessage = "承認が拒否されました。"
                    EventLog.log(.auth, message: "ユーザーが承認を拒否")
                    state = .signedOut
                    return
                default:
                    continue
                }
            } catch {
                EventLog.logError(.auth, error: error, context: "トークン待機")
                continue
            }
        }

        statusMessage = "時間切れです。もう一度お試しください。"
        state = .signedOut
        EventLog.log(.auth, message: "ログイン待機がタイムアウト")
    }

    // MARK: - 手順 5: トークンの更新

    private func refresh(_ current: OAuthTokens) async throws -> OAuthTokens {
        let json = try await postForm(urlString: tokenURL, fields: [
            "client_id": current.clientID,
            "client_secret": current.clientSecret,
            "refresh_token": current.refreshToken,
            "grant_type": "refresh_token",
        ])

        guard let access = json["access_token"].string else {
            throw AuthError.refreshFailed(json["error"].string ?? "不明")
        }
        let expiresIn = json["expires_in"].int ?? 3600

        var updated = current
        updated.accessToken = access
        updated.expiryDate = Date().addingTimeInterval(TimeInterval(expiresIn))
        // リフレッシュトークンが更新されることもある
        if let newRefresh = json["refresh_token"].string {
            updated.refreshToken = newRefresh
        }
        return updated
    }

    // MARK: - HTTP ヘルパ

    private func getText(urlString: String, userAgent: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(tvPageURL, forHTTPHeaderField: "Referer")
        // ここは en-US 固定。地域で HTML 構造が変わると正規表現が外れるため。
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")

        let (data, _) = try await session.data(for: request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AuthError.credentialsNotFound("応答を文字列にできません")
        }
        return text
    }

    private func postForm(urlString: String, fields: [String: String]) async throws -> JSON {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        let body = components.percentEncodedQuery ?? ""

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
        request.setValue(cobaltUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)
        return JSON(data: data)
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let group = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[group])
    }
}

enum AuthError: LocalizedError {
    case credentialsNotFound(String)
    case deviceCodeFailed(String)
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound(let detail):
            return "認証情報を取得できませんでした (\(detail))"
        case .deviceCodeFailed(let detail):
            return "コードを発行できませんでした (\(detail))"
        case .refreshFailed(let detail):
            return "トークンを更新できませんでした (\(detail))"
        }
    }
}
