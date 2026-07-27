//
//  PoTokenWebView.swift
//  ViviMusic
//
//  WKWebView の中で BotGuard を走らせて poToken を作る。
//  本家 VIVI Music の `PoTokenWebView.kt` の移植。
//
//  流れ:
//    1. ローカル HTML を読み込む (外部リソース参照なし)
//    2. ネイティブが /api/jnn/v1/Create を叩いてチャレンジを取得
//    3. WebView 内で BotGuard を実行 → botguardResponse
//    4. ネイティブが /api/jnn/v1/GenerateIT を叩いて integrityToken を取得
//    5. WebView 内でミンターを作成 (初期化はここまで)
//    6. 以後 obtainPoToken(識別子) で必要なだけトークンを発行
//

import Foundation
import WebKit

enum PoTokenError: LocalizedError {
    case webViewFailed(String)
    case httpFailed(Int)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .webViewFailed(let detail):
            return "BotGuard の実行に失敗しました (\(detail))"
        case .httpFailed(let code):
            return "BotGuard サービスが HTTP \(code) を返しました"
        case .timedOut(let stage):
            return "BotGuard の処理がタイムアウトしました (\(stage))"
        }
    }
}

@MainActor
final class PoTokenWebView: NSObject {

    // MARK: - 定数 (本家の PoTokenWebView.kt と同じ値)

    private static let googleAPIKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"
    private static let createURL = "https://www.youtube.com/api/jnn/v1/Create"
    private static let generateITURL = "https://www.youtube.com/api/jnn/v1/GenerateIT"
    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.3"

    private static let messageHandlerName = "vivi"

    // MARK: - 状態

    private var webView: WKWebView!
    /// トークンの有効期限。切れたら作り直す。
    private(set) var expiresAt: Date = .distantPast
    var isExpired: Bool { Date() >= expiresAt }

    /// JS からの通知を待っている処理。
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var botguardContinuation: CheckedContinuation<String, Error>?
    private var minterContinuation: CheckedContinuation<Void, Error>?
    private var tokenContinuations: [String: CheckedContinuation<String, Error>] = [:]

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    // MARK: - 生成

    override init() {
        super.init()

        let controller = WKUserContentController()
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        // 画面には出さないので描画は最小限で良い
        config.suppressesIncrementalRendering = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.userAgent

        controller.add(self, name: Self.messageHandlerName)
    }

    /// 後始末。WKUserContentController はハンドラを強参照するので、
    /// 明示的に外さないと解放されない。
    func close() {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.messageHandlerName)
        webView.stopLoading()
    }

    // MARK: - 初期化 (BotGuard の実行と integrityToken の取得)

    /// 使える状態にする。成功したら `obtainPoToken` が呼べる。
    func prepare() async throws {
        let started = Date()
        EventLog.log(.auth, message: "PoToken: BotGuard の初期化を開始")

        // 1) HTML を読み込む
        try await withTimeout(seconds: 15, stage: "HTML 読み込み") {
            try await withCheckedThrowingContinuation { continuation in
                self.readyContinuation = continuation
                self.webView.loadHTMLString(
                    PoTokenHTML.page,
                    baseURL: URL(string: "https://www.youtube.com")
                )
            }
        }

        // 2) チャレンジを取得
        let rawChallenge = try await botguardRequest(
            urlString: Self.createURL,
            body: "[ \"\(Self.requestKey)\" ]"
        )
        let challengeJSON = try PoTokenParsing.challengeData(from: rawChallenge)

        // 3) WebView 内で BotGuard を実行
        let botguardResponse = try await withTimeout(seconds: 30, stage: "BotGuard 実行") {
            try await withCheckedThrowingContinuation { continuation in
                self.botguardContinuation = continuation
                let escaped = Self.jsStringLiteral(challengeJSON)
                self.webView.evaluateJavaScript("viviRunBotGuard(\(escaped))") { _, error in
                    if let error {
                        self.finishBotguard(.failure(PoTokenError.webViewFailed(
                            error.localizedDescription)))
                    }
                }
            }
        }
        EventLog.log(.auth, message: "PoToken: BotGuard 実行完了")

        // 4) integrityToken を取得
        let rawIntegrity = try await botguardRequest(
            urlString: Self.generateITURL,
            body: "[ \"\(Self.requestKey)\", \"\(botguardResponse)\" ]"
        )
        let (tokenJS, expiresIn) = try PoTokenParsing.integrityToken(from: rawIntegrity)
        // 余裕を持って 10 分前に期限切れ扱いにする
        expiresAt = Date().addingTimeInterval(max(expiresIn - 600, 60))

        // 5) ミンターを作る
        try await withTimeout(seconds: 20, stage: "ミンター生成") {
            try await withCheckedThrowingContinuation { continuation in
                self.minterContinuation = continuation
                self.webView.evaluateJavaScript("viviCreateMinter(\(tokenJS))") { _, error in
                    if let error {
                        self.finishMinter(.failure(PoTokenError.webViewFailed(
                            error.localizedDescription)))
                    }
                }
            }
        }

        EventLog.logDuration(.auth, start: started,
                             message: "PoToken: 初期化完了 (有効期限 \(Int(expiresIn))秒)")
    }

    // MARK: - トークンの発行

    /// 指定の識別子 (visitorData や videoId) に紐づく poToken を作る。
    func obtainPoToken(identifier: String) async throws -> String {
        let byteList = try await withTimeout(seconds: 20, stage: "トークン生成") {
            try await withCheckedThrowingContinuation { continuation in
                self.tokenContinuations[identifier] = continuation
                let idLiteral = Self.jsStringLiteral(identifier)
                let u8 = PoTokenParsing.uint8ArrayLiteral(identifier)
                self.webView.evaluateJavaScript(
                    "viviObtainPoToken(\(idLiteral), \(u8))"
                ) { _, error in
                    if let error {
                        self.finishToken(identifier,
                                         .failure(PoTokenError.webViewFailed(
                                            error.localizedDescription)))
                    }
                }
            }
        }
        return PoTokenParsing.base64FromByteList(byteList)
    }

    // MARK: - BotGuard サービスへの HTTP

    private func botguardRequest(urlString: String, body: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.googleAPIKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "x-user-agent")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw PoTokenError.httpFailed(status)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw PoTokenError.webViewFailed("応答が UTF-8 でない")
        }
        return text
    }

    // MARK: - 待ち合わせの後始末

    private func finishReady(_ result: Result<Void, Error>) {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        continuation.resume(with: result)
    }

    private func finishBotguard(_ result: Result<String, Error>) {
        guard let continuation = botguardContinuation else { return }
        botguardContinuation = nil
        continuation.resume(with: result)
    }

    private func finishMinter(_ result: Result<Void, Error>) {
        guard let continuation = minterContinuation else { return }
        minterContinuation = nil
        continuation.resume(with: result)
    }

    private func finishToken(_ identifier: String, _ result: Result<String, Error>) {
        guard let continuation = tokenContinuations.removeValue(forKey: identifier) else { return }
        continuation.resume(with: result)
    }

    // MARK: - ヘルパ

    /// 文字列を JS のリテラルとして安全に埋め込む。
    private static func jsStringLiteral(_ value: String) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: [value], options: [])) ?? Data()
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        // ["..."] の中身だけ取り出す
        return String(array.dropFirst().dropLast())
    }

    /// 一定時間で諦める。WebView が固まったまま待ち続けないようにする。
    private func withTimeout<T>(seconds: TimeInterval,
                                stage: String,
                                operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PoTokenError.timedOut(stage)
            }
            guard let result = try await group.next() else {
                throw PoTokenError.timedOut(stage)
            }
            group.cancelAll()
            return result
        }
    }
}

// MARK: - JS からの通知

extension PoTokenWebView: WKScriptMessageHandler {

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let type = payload["type"] as? String else { return }

        let value = payload["value"] as? String
        let stage = payload["stage"] as? String
        let identifier = payload["identifier"] as? String

        Task { @MainActor in
            switch type {
            case "ready":
                self.finishReady(.success(()))

            case "botguard":
                self.finishBotguard(.success(value ?? ""))

            case "minter":
                self.finishMinter(.success(()))

            case "token":
                if let identifier {
                    self.finishToken(identifier, .success(value ?? ""))
                }

            case "error":
                let detail = "\(stage ?? "?"): \(value ?? "?")"
                EventLog.log(.auth, message: "PoToken: JS エラー \(detail)")
                let error = PoTokenError.webViewFailed(detail)
                switch stage {
                case "botguard": self.finishBotguard(.failure(error))
                case "minter":   self.finishMinter(.failure(error))
                case "token":
                    if let identifier { self.finishToken(identifier, .failure(error)) }
                default:
                    self.finishReady(.failure(error))
                }

            default:
                break
            }
        }
    }
}
