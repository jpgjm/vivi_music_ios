//
//  PoTokenService.swift
//  ViviMusic
//
//  poToken の生成と使い回しを取り仕切る。
//  本家 VIVI Music の `PoTokenGenerator.kt` に相当する。
//
//  poToken には 2 種類ある:
//    - streaming 用 : セッション識別子 (visitorData) に紐づく。
//                     再生 URL に `&pot=` として付ける。
//                     **必ず最初に 1 回だけ** 発行する必要がある。
//    - player 用    : videoId に紐づく。
//                     player 要求の body に入れる。
//
//  WebView の初期化は重いので、期限が切れるまで作り直さない。
//

import Foundation

struct PoTokenPair {
    /// player 要求の body に入れるトークン
    let player: String
    /// 再生 URL の `&pot=` に付けるトークン
    let streaming: String
}

@MainActor
final class PoTokenService: ObservableObject {
    static let shared = PoTokenService()

    /// 直近の失敗理由。設定画面に出して状況が分かるようにする。
    @Published private(set) var lastError: String?
    /// 生成できているかどうか。
    @Published private(set) var isReady = false

    private var generator: PoTokenWebView?
    /// streaming 用トークンとその紐づけ先セッション。
    private var sessionID: String?
    private var streamingToken: String?

    /// 同時に初期化が走らないようにする。
    private var preparingTask: Task<PoTokenWebView, Error>?

    private init() {}

    /// 指定の動画に使う poToken を用意する。
    ///
    /// - Parameter sessionID: セッション識別子 (visitorData)。
    ///   これが変わったら作り直す必要がある。
    /// - Returns: 生成できなければ nil (呼び出し側は poToken 無しで続行する)
    func tokens(videoID: String, sessionID: String) async -> PoTokenPair? {
        do {
            let generator = try await ensureGenerator(sessionID: sessionID)
            guard let streaming = streamingToken else { return nil }
            let player = try await generator.obtainPoToken(identifier: videoID)
            lastError = nil
            isReady = true
            return PoTokenPair(player: player, streaming: streaming)
        } catch {
            lastError = error.localizedDescription
            isReady = false
            EventLog.logError(.auth, videoID: videoID, error: error, context: "poToken 生成")
            // 次回は作り直す
            invalidate()
            return nil
        }
    }

    /// 生成器を用意する。期限切れやセッション変更があれば作り直す。
    private func ensureGenerator(sessionID newSessionID: String) async throws -> PoTokenWebView {
        // 使い回せるならそのまま返す
        if let generator, !generator.isExpired,
           sessionID == newSessionID, streamingToken != nil {
            return generator
        }

        // 既に初期化中ならそれを待つ
        if let preparingTask {
            return try await preparingTask.value
        }

        // 古い生成器があれば先に閉じる
        generator?.close()
        generator = nil

        let task = Task { () throws -> PoTokenWebView in
            let created = PoTokenWebView()
            try await created.prepare()

            // streaming 用トークンは他より先に 1 回だけ発行する決まり
            let streaming = try await created.obtainPoToken(identifier: newSessionID)

            self.generator = created
            self.sessionID = newSessionID
            self.streamingToken = streaming
            EventLog.log(.auth,
                         message: "poToken 準備完了 (session=\(newSessionID.prefix(12))…)")
            return created
        }
        preparingTask = task

        defer { preparingTask = nil }
        return try await task.value
    }

    /// 生成器を捨てる。次回アクセス時に作り直される。
    func invalidate() {
        generator?.close()
        generator = nil
        sessionID = nil
        streamingToken = nil
        preparingTask?.cancel()
        preparingTask = nil
        isReady = false
    }
}
