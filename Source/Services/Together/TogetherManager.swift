//
//  TogetherManager.swift
//  ViviMusic
//
//  Listen Together の中核。WebSocket でサーバーとつながり、
//  部屋の状態と再生を同期する。
//
//  役割は 2 通り:
//    ホスト  … 自分の再生操作を部屋の全員へ配る
//    参加者  … ホストから届く指示に従って再生を合わせる
//
//  時刻合わせについて:
//    サーバーは操作した時刻 (server_time) を添えてくる。
//    受け取った側は「操作からここまでに経った時間」を足し込んでから
//    シークすることで、通信の遅れぶんのズレを抑えている。
//

import Foundation
import Combine

@MainActor
final class TogetherManager: ObservableObject {
    static let shared = TogetherManager()

    // MARK: - 状態

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        /// つながっているが、まだ部屋には入っていない
        case connected
        case inRoom(code: String)

        var isInRoom: Bool {
            if case .inRoom = self { return true }
            return false
        }

        var label: String {
            switch self {
            case .disconnected:      return "切断中"
            case .connecting:        return "接続しています…"
            case .connected:         return "接続済み"
            case .inRoom(let code):  return "ルーム \(code)"
            }
        }
    }

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var users: [TogetherUser] = []
    @Published private(set) var chatMessages: [TogetherChatMessage] = []
    /// 参加の承認を待っている人 (ホストのみ届く)
    @Published private(set) var pendingRequests: [TogetherUser] = []
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    /// 自分がホストかどうか。
    @Published private(set) var isHost = false
    @Published private(set) var myUserID: String?

    /// 表示名。設定画面から変えられる。
    @Published var username: String {
        didSet { UserDefaults.standard.set(username, forKey: Keys.username) }
    }
    /// 接続先サーバー。
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Keys.server) }
    }

    var roomCode: String? {
        if case .inRoom(let code) = state { return code }
        return nil
    }

    // MARK: - 内部

    private var socket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var pingTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    /// 自分の操作を配信中かどうか。
    /// ホストから届いた指示で再生を変える間は true にして、
    /// その変更を再び配信してしまう堂々巡りを防ぐ。
    private var isApplyingRemote = false

    private var cancellables = Set<AnyCancellable>()

    private enum Keys {
        static let username = "Together.username"
        static let server = "Together.server"
    }

    private init() {
        username = UserDefaults.standard.string(forKey: Keys.username) ?? ""
        serverURL = UserDefaults.standard.string(forKey: Keys.server)
            ?? TogetherServer.default.url
        observePlayer()
    }

    // MARK: - 接続

    func connect() {
        guard socket == nil else { return }
        guard let url = URL(string: serverURL) else {
            errorMessage = "サーバーの URL が正しくありません"
            return
        }

        state = .connecting
        statusMessage = nil
        errorMessage = nil
        EventLog.log(.together, message: "接続開始: \(serverURL)")

        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()

        receiveTask = Task { await receiveLoop() }
        startPing()
        state = .connected
    }

    func disconnect() {
        if state.isInRoom { send(type: TogetherMessage.Client.leaveRoom) }

        pingTask?.cancel(); pingTask = nil
        receiveTask?.cancel(); receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil

        state = .disconnected
        users = []
        chatMessages = []
        pendingRequests = []
        isHost = false
        myUserID = nil
        EventLog.log(.together, message: "切断しました")
    }

    // MARK: - 部屋の操作

    /// 部屋を作ってホストになる。
    func createRoom() {
        guard ensureUsername() else { return }
        connectIfNeeded()
        statusMessage = "ルームを作成しています…"
        send(type: TogetherMessage.Client.createRoom,
             payload: ["username": username])
    }

    /// コードを指定して部屋に入る。
    func joinRoom(code: String) {
        guard ensureUsername() else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else {
            errorMessage = "ルームコードを入力してください"
            return
        }
        connectIfNeeded()
        statusMessage = "ルームに参加しています…"
        send(type: TogetherMessage.Client.joinRoom,
             payload: ["room_code": trimmed, "username": username])
    }

    func leaveRoom() {
        send(type: TogetherMessage.Client.leaveRoom)
        state = .connected
        users = []
        pendingRequests = []
        isHost = false
        EventLog.log(.together, message: "ルームを退出しました")
    }

    /// 参加申請を承認する (ホストのみ)。
    func approve(userID: String) {
        send(type: TogetherMessage.Client.approveJoin, payload: ["user_id": userID])
        pendingRequests.removeAll { $0.id == userID }
    }

    /// 参加申請を断る (ホストのみ)。
    func reject(userID: String) {
        send(type: TogetherMessage.Client.rejectJoin, payload: ["user_id": userID])
        pendingRequests.removeAll { $0.id == userID }
    }

    func kick(userID: String) {
        send(type: TogetherMessage.Client.kickUser, payload: ["user_id": userID])
    }

    func sendChat(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(type: TogetherMessage.Client.chat, payload: ["message": trimmed])
    }

    /// ホストに再同期を頼む。ズレたと感じたときに使う。
    func requestSync() {
        send(type: TogetherMessage.Client.requestSync)
        statusMessage = "同期をやり直しています…"
    }

    private func connectIfNeeded() {
        if socket == nil { connect() }
    }

    private func ensureUsername() -> Bool {
        if username.trimmingCharacters(in: .whitespaces).isEmpty {
            errorMessage = "ユーザー名を入力してください"
            return false
        }
        return true
    }

    // MARK: - 再生の配信 (ホスト)

    /// プレイヤーの動きを見て、ホストなら部屋へ配る。
    private func observePlayer() {
        let player = PlayerManager.shared

        player.$currentSong
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] song in
                guard let self, let song else { return }
                self.broadcastTrackChange(song)
            }
            .store(in: &cancellables)

        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in
                self?.broadcastPlayPause(playing)
            }
            .store(in: &cancellables)
    }

    private var canBroadcast: Bool {
        isHost && state.isInRoom && !isApplyingRemote
    }

    private func broadcastTrackChange(_ song: Song) {
        guard canBroadcast else { return }
        let track = TogetherTrack(song: song)
        send(type: TogetherMessage.Client.playbackAction, payload: [
            "action": TogetherMessage.Action.changeTrack,
            "track_id": song.id,
            "track_info": track.payload,
            "position": 0,
        ])
        EventLog.log(.together, videoID: song.id, message: "曲の変更を配信")
    }

    private func broadcastPlayPause(_ playing: Bool) {
        guard canBroadcast else { return }
        let position = Int(PlayerManager.shared.currentTime * 1000)
        send(type: TogetherMessage.Client.playbackAction, payload: [
            "action": playing ? TogetherMessage.Action.play
                              : TogetherMessage.Action.pause,
            "position": position,
        ])
    }

    /// シークを配信する。呼ぶ側 (PlayerManager) から明示的に叩く。
    func broadcastSeek(to seconds: TimeInterval) {
        guard canBroadcast else { return }
        send(type: TogetherMessage.Client.playbackAction, payload: [
            "action": TogetherMessage.Action.seek,
            "position": Int(seconds * 1000),
        ])
    }

    // MARK: - 送受信

    private func send(type: String, payload: [String: Any]? = nil) {
        guard let socket else { return }

        var message: [String: Any] = ["type": type]
        if let payload { message["payload"] = payload }

        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }

        socket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                EventLog.logError(.together, error: error, context: "送信 \(type)")
                self?.errorMessage = "送信に失敗しました: \(error.localizedDescription)"
            }
        }
    }

    private func receiveLoop() async {
        while let socket, !Task.isCancelled {
            do {
                let message = try await socket.receive()
                switch message {
                case .string(let text):
                    handle(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handle(text: text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if Task.isCancelled { return }
                EventLog.logError(.together, error: error, context: "受信")
                errorMessage = "接続が切れました: \(error.localizedDescription)"
                self.socket = nil
                state = .disconnected
                return
            }
        }
    }

    private func startPing() {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)   // 25 秒
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.send(type: TogetherMessage.Client.ping) }
            }
        }
    }

    // MARK: - 受信メッセージの処理

    private func handle(text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let json = JSON(data: data)
        guard let type = json["type"].string else { return }
        let payload = json["payload"]

        switch type {
        case TogetherMessage.Server.roomCreated:
            let code = payload["room_code"].string ?? ""
            myUserID = payload["user_id"].string
            isHost = true
            state = .inRoom(code: code)
            statusMessage = "ルーム \(code) を作成しました"
            EventLog.log(.together, message: "ルーム作成: \(code)")
            // 既に再生中なら現在の曲を配る
            if let song = PlayerManager.shared.currentSong {
                broadcastTrackChange(song)
            }

        case TogetherMessage.Server.joinRequest:
            if let user = TogetherUser(json: payload) {
                pendingRequests.append(user)
                statusMessage = "\(user.username) さんが参加を希望しています"
            }

        case TogetherMessage.Server.joinApproved:
            let code = payload["room_code"].string ?? ""
            myUserID = payload["user_id"].string
            isHost = false
            state = .inRoom(code: code)
            statusMessage = "ルーム \(code) に参加しました"
            EventLog.log(.together, message: "ルーム参加: \(code)")
            apply(state: TogetherRoomState(json: payload["state"]))

        case TogetherMessage.Server.joinRejected:
            errorMessage = payload["reason"].string ?? "参加を断られました"
            state = .connected

        case TogetherMessage.Server.userJoined:
            if let user = TogetherUser(json: payload) {
                statusMessage = "\(user.username) さんが参加しました"
            }

        case TogetherMessage.Server.userLeft:
            let name = payload["username"].string ?? "誰か"
            statusMessage = "\(name) さんが退出しました"
            let leftID = payload["user_id"].string
            users.removeAll { $0.id == leftID }

        case TogetherMessage.Server.syncState:
            apply(state: TogetherRoomState(json: payload))

        case TogetherMessage.Server.syncPlayback:
            applyPlayback(payload)

        case TogetherMessage.Server.hostChanged:
            let newHost = payload["new_host_id"].string
            isHost = (newHost != nil && newHost == myUserID)
            statusMessage = isHost ? "あなたがホストになりました" : "ホストが交代しました"

        case TogetherMessage.Server.kicked:
            errorMessage = "ルームから退出させられました"
            state = .connected
            users = []
            isHost = false

        case TogetherMessage.Server.chat:
            if let message = TogetherChatMessage(json: payload) {
                chatMessages.append(message)
                if chatMessages.count > 200 { chatMessages.removeFirst() }
            }

        case TogetherMessage.Server.error:
            errorMessage = payload["message"].string ?? "エラーが発生しました"
            EventLog.log(.together, message: "サーバーエラー: \(errorMessage ?? "")")

        case TogetherMessage.Server.pong:
            break

        default:
            EventLog.log(.together, message: "未対応のメッセージ: \(type)")
        }
    }

    // MARK: - 受け取った状態を再生に反映する

    private func apply(state roomState: TogetherRoomState) {
        users = roomState.users
        if let myUserID {
            isHost = (roomState.hostID == myUserID)
        }

        // ホストは自分が基準なので従わない
        guard !isHost else { return }
        guard let track = roomState.currentTrack else { return }

        Task { await applyRemoteTrack(track,
                                      positionMS: roomState.position,
                                      serverTimeMS: roomState.lastUpdate,
                                      playing: roomState.isPlaying) }
    }

    private func applyPlayback(_ payload: JSON) {
        guard !isHost else { return }
        let action = payload["action"].string ?? ""
        let positionMS = payload["position"].int ?? 0
        let serverTimeMS = payload["server_time"].int ?? 0
        let player = PlayerManager.shared

        switch action {
        case TogetherMessage.Action.play:
            withRemoteApply {
                player.seek(to: adjustedSeconds(positionMS, serverTimeMS: serverTimeMS))
                player.resume()
            }

        case TogetherMessage.Action.pause:
            withRemoteApply {
                player.pause()
                player.seek(to: TimeInterval(positionMS) / 1000)
            }

        case TogetherMessage.Action.seek:
            withRemoteApply {
                player.seek(to: adjustedSeconds(positionMS, serverTimeMS: serverTimeMS))
            }

        case TogetherMessage.Action.changeTrack:
            guard let track = TogetherTrack(json: payload["track_info"]) else { return }
            Task { await applyRemoteTrack(track,
                                          positionMS: positionMS,
                                          serverTimeMS: serverTimeMS,
                                          playing: true) }

        case TogetherMessage.Action.skipNext:
            withRemoteApply { Task { await player.next() } }

        case TogetherMessage.Action.skipPrev:
            withRemoteApply { Task { await player.previous() } }

        default:
            break
        }
    }

    private func applyRemoteTrack(_ track: TogetherTrack,
                                  positionMS: Int,
                                  serverTimeMS: Int,
                                  playing: Bool) async {
        let player = PlayerManager.shared
        // 同じ曲なら位置だけ合わせる
        if player.currentSong?.id != track.id {
            isApplyingRemote = true
            await player.play(song: track.song)
            isApplyingRemote = false
            EventLog.log(.together, videoID: track.id, message: "ホストに合わせて再生")
        }

        let target = adjustedSeconds(positionMS, serverTimeMS: serverTimeMS)
        withRemoteApply {
            player.seek(to: target)
            if playing { player.resume() } else { player.pause() }
        }
        // 読み込みに時間がかかることがあるので、少し待ってもう一度合わせる
        try? await Task.sleep(nanoseconds: 700_000_000)
        withRemoteApply {
            player.seek(to: adjustedSeconds(positionMS, serverTimeMS: serverTimeMS))
        }
    }

    /// サーバーが操作した時刻からの経過分を足して、ズレを抑える。
    private func adjustedSeconds(_ positionMS: Int, serverTimeMS: Int) -> TimeInterval {
        var seconds = TimeInterval(positionMS) / 1000
        if serverTimeMS > 0 {
            let nowMS = Int(Date().timeIntervalSince1970 * 1000)
            let elapsed = TimeInterval(nowMS - serverTimeMS) / 1000
            // 極端な値は時計のズレなので採用しない
            if elapsed > 0, elapsed < 30 {
                seconds += elapsed
            }
        }
        return max(seconds, 0)
    }

    /// ホストの指示で再生を変える間は、その変更を配信し返さないようにする。
    private func withRemoteApply(_ body: () -> Void) {
        isApplyingRemote = true
        body()
        // 状態の変化が流れ切ってから解除する
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.isApplyingRemote = false
        }
    }
}
