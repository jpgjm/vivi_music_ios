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

    /// 事前生成トグルの状態。
    ///
    /// アプリを閉じると生成器ごと消えるので、この値は永続化しない。
    /// 起動時は常にオフ = 「作っていない」で実態と一致する。
    @Published private(set) var isPrewarming = false

    /// 生成処理が走っている最中か。トグルの二度押し防止と表示に使う。
    @Published private(set) var isWorking = false

    /// 再生 URL の解決が実際に poToken を要求したか。
    ///
    /// ANDROID_VR / IOS が両方失敗して WEB_REMIX まで降りたときだけ true になる。
    /// 「予備経路が実際に働いている」ことを設定画面に出すために持つ。
    /// この起動中の履歴として扱うので、`invalidate()` では消さない。
    @Published private(set) var isRequiredForPlayback = false

    private var generator: PoTokenWebView?
    /// 生成器を作ったときのセッション識別子。これが変わったら作り直す。
    private var sessionID: String?

    /// GVS 用トークンの控え。
    ///
    /// 紐づけ先が visitorData 固定ではなくなったので、辞書で持つ。
    /// videoId 紐づけの実験が有効な動画では **曲ごとに別のトークン** が要る。
    /// 鍵は `PoTokenBinding.cacheKey` ("videoId:xxxx" など)。
    private var streamingTokens: [String: String] = [:]

    /// 直近に使った紐づけ (設定画面とログ用)。
    @Published private(set) var lastBindingKind: String?

    /// 同時に初期化が走らないようにする。
    private var preparingTask: Task<PoTokenWebView, Error>?

    private init() {}

    /// 指定の動画に使う poToken を用意する。
    ///
    /// - Parameter sessionID: セッション識別子 (visitorData)。
    ///   これが変わったら作り直す必要がある。
    /// - Returns: 生成できなければ nil (呼び出し側は poToken 無しで続行する)
    /// - Parameters:
    ///   - videoID: 対象の動画
    ///   - sessionID: セッション識別子 (visitorData)。生成器の作り直し判定に使う。
    ///   - binding: GVS トークンを何に紐づけるか。
    ///     省略すると従来どおり visitorData 紐づけになる。
    func tokens(videoID: String,
                sessionID: String,
                binding: PoTokenBinding? = nil) async -> PoTokenPair? {
        isRequiredForPlayback = true

        // 紐づけ先が指定されなければ、これまでどおりセッションに紐づける。
        let effectiveBinding = binding ?? .visitorData(sessionID)

        do {
            let generator = try await ensureGenerator(sessionID: sessionID)

            // GVS 用トークン。紐づけ先ごとに控えておく。
            let streaming: String
            if let cached = streamingTokens[effectiveBinding.cacheKey] {
                streaming = cached
            } else {
                streaming = try await generator.obtainPoToken(
                    identifier: effectiveBinding.identifier)
                streamingTokens[effectiveBinding.cacheKey] = streaming
                EventLog.log(.auth, videoID: videoID,
                             message: "poToken を発行 (紐づけ: \(effectiveBinding.kind))")
            }
            lastBindingKind = effectiveBinding.kind

            // player 要求の body に入れるほうは常に videoId 紐づけ。
            let player = try await generator.obtainPoToken(identifier: videoID)
            lastError = nil
            isReady = true
            return PoTokenPair(player: player, streaming: streaming)
        } catch {
            // 中断は失敗ではない。
            //
            // 403 で URL を取り直すとき、AVFoundation 側が古い要求を
            // キャンセルすることがある。ここで invalidate してしまうと、
            // 600ms かけて用意した BotGuard の生成器まで一緒に捨てられ、
            // 次の試行でまた最初から作り直しになる。
            // (2026-08-13 実測: 「poToken 準備完了」の 3ms 後に
            //  CancellationError で破棄されていた)
            if Self.isCancellation(error) {
                EventLog.log(.auth, videoID: videoID,
                             message: "poToken 生成が中断されました (生成器は保持)")
                return nil
            }
            lastError = error.localizedDescription
            isReady = false
            EventLog.logError(.auth, videoID: videoID, error: error, context: "poToken 生成")
            // 次回は作り直す
            invalidate()
            return nil
        }
    }

    /// タスクの取り消しによるエラーかどうか。
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        return false
    }

    // MARK: - 事前生成 (設定画面のトグル)

    /// 再生を待たずに生成しておく。
    ///
    /// 目的は動作確認と先払い。予備経路は普段まったく通らないため、
    /// いざ必要になったときに壊れていても気づけない。
    /// 手動で一度通しておけば、生成できることをログで確認できる。
    ///
    /// 生成しても再生には影響しない。`pot=` を付けるかどうかは
    /// `YouTubeAPI` 側のローカル変数で判断していて、
    /// ここで作ったトークンが ANDROID_VR の URL に混ざることはない。
    ///
    /// - Returns: 生成できたら true
    @discardableResult
    func warmUp() async -> Bool {
        guard !isWorking else { return isReady }

        // 生成には visitorData (セッション識別子) が要る。
        // 起動直後でホームをまだ開いていないと nil になる。
        guard let sessionID = await InnerTube.shared.visitorData else {
            lastError = "セッション (visitorData) がまだありません。"
                + "ホームを一度開いてから試してください。"
            EventLog.log(.auth, message: "poToken 事前生成: visitorData が無いため中止")
            return false
        }

        isWorking = true
        defer { isWorking = false }

        let started = Date()
        do {
            _ = try await ensureGenerator(sessionID: sessionID)
            isPrewarming = true
            // 事前生成では visitorData 紐づけのぶんだけ作っておく。
            let binding = PoTokenBinding.visitorData(sessionID)
            if streamingTokens[binding.cacheKey] == nil,
               let generator = self.generator {
                streamingTokens[binding.cacheKey] =
                    try await generator.obtainPoToken(identifier: binding.identifier)
            }
            isReady = (streamingTokens[binding.cacheKey] != nil)
            lastError = nil
            EventLog.logDuration(.auth, start: started,
                                 message: "poToken を事前生成 "
                                     + (isReady ? "成功" : "失敗 (トークンが空)"))
            return isReady
        } catch {
            if Self.isCancellation(error) {
                EventLog.log(.auth, message: "poToken 事前生成が中断されました (生成器は保持)")
                return false
            }
            isPrewarming = false
            isReady = false
            lastError = error.localizedDescription
            EventLog.logError(.auth, error: error, context: "poToken 事前生成")
            invalidate()
            return false
        }
    }

    /// 生成器を用意する。期限切れやセッション変更があれば作り直す。
    private func ensureGenerator(sessionID newSessionID: String) async throws -> PoTokenWebView {
        // 使い回せるならそのまま返す
        // 生成器そのものは紐づけ先に依存しないので、
        // セッションが同じで期限内なら使い回す。
        if let generator, !generator.isExpired, sessionID == newSessionID {
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

            // 以前はここで streaming 用トークンも発行していたが、
            // 紐づけ先が videoId / dataSyncId / visitorData と可変になったので
            // 発行は tokens() 側に任せる。
            self.generator = created
            self.sessionID = newSessionID
            self.streamingTokens.removeAll()
            EventLog.log(.auth,
                         message: "poToken 準備完了 (session=\(newSessionID.prefix(12))…)")
            return created
        }
        preparingTask = task

        defer { preparingTask = nil }
        return try await task.value
    }

    /// 生成器を捨てる。次回アクセス時に作り直される。
    ///
    /// 再生中に呼んでも問題ない。再生中の URL には `pot=` が既に
    /// 焼き込まれているため、その曲は最後まで再生できる。
    func invalidate() {
        generator?.close()
        generator = nil
        sessionID = nil
        streamingTokens.removeAll()
        preparingTask?.cancel()
        preparingTask = nil
        isReady = false
        isPrewarming = false
        // isRequiredForPlayback はこの起動中の履歴なので消さない。
    }

    // MARK: - 表示

    /// 設定画面に出す状態テキスト。
    ///
    /// 「未生成」だけだと不具合に見えるので、
    /// 予備経路であること・実際に使われているかが分かる文言にする。
    var statusText: String {
        if isWorking { return "生成中…" }
        if isRequiredForPlayback && isReady {
            // どこに紐づけて発行したかを出す。
            // videoId 紐づけなら YouTube の実験が有効ということ。
            if let lastBindingKind { return "使用中（紐づけ: \(lastBindingKind)）" }
            return "使用中"
        }
        if isReady { return "生成済み（待機）" }
        return "未使用（予備経路）"
    }
}
