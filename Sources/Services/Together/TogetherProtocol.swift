//
//  TogetherProtocol.swift
//  ViviMusic
//
//  Listen Together (複数人で同じ曲を同時に聴く機能) の通信仕様。
//  本家 VIVI Music の `listentogether/Protocol.kt` を移植したもので、
//  同じサーバーに対して Android 版と相互に接続できる。
//
//  やり取りは WebSocket 上の JSON で、
//      { "type": "join_room", "payload": { ... } }
//  という形をとる。
//  (本家は protobuf にも対応しているが、JSON も受け付けるのでこちらを使う)
//

import Foundation

// MARK: - メッセージ種別

enum TogetherMessage {

    /// こちらからサーバーへ送るもの
    enum Client {
        static let createRoom = "create_room"
        static let joinRoom = "join_room"
        static let leaveRoom = "leave_room"
        static let approveJoin = "approve_join"
        static let rejectJoin = "reject_join"
        static let playbackAction = "playback_action"
        static let bufferReady = "buffer_ready"
        static let kickUser = "kick_user"
        static let transferHost = "transfer_host"
        static let ping = "ping"
        static let chat = "chat"
        static let requestSync = "request_sync"
        static let suggestTrack = "suggest_track"
    }

    /// サーバーから届くもの
    enum Server {
        static let roomCreated = "room_created"
        static let joinRequest = "join_request"
        static let joinApproved = "join_approved"
        static let joinRejected = "join_rejected"
        static let userJoined = "user_joined"
        static let userLeft = "user_left"
        static let syncPlayback = "sync_playback"
        static let syncState = "sync_state"
        static let bufferWait = "buffer_wait"
        static let bufferComplete = "buffer_complete"
        static let error = "error"
        static let pong = "pong"
        static let hostChanged = "host_changed"
        static let kicked = "kicked"
        static let chat = "chat"
        static let userDisconnected = "user_disconnected"
        static let userReconnected = "user_reconnected"
    }

    /// 再生操作の種類
    enum Action {
        static let play = "play"
        static let pause = "pause"
        static let seek = "seek"
        static let skipNext = "skip_next"
        static let skipPrev = "skip_prev"
        static let changeTrack = "change_track"
        static let syncQueue = "sync_queue"
    }
}

// MARK: - データ構造

/// 部屋にいる人。
struct TogetherUser: Identifiable, Hashable {
    let id: String
    var username: String
    var isHost: Bool
    var isConnected: Bool

    init?(json: JSON) {
        guard let id = json["user_id"].string else { return nil }
        self.id = id
        self.username = json["username"].string ?? "名無し"
        self.isHost = json["is_host"].bool ?? false
        self.isConnected = json["is_connected"].bool ?? true
    }
}

/// 部屋で共有される曲。アプリ内の Song と相互に変換する。
struct TogetherTrack {
    let id: String
    let title: String
    let artist: String
    let album: String?
    /// ミリ秒
    let duration: Int
    let thumbnail: String?

    init(song: Song) {
        self.id = song.id
        self.title = song.title
        self.artist = song.artist
        self.album = song.album
        self.duration = (song.durationSeconds ?? 0) * 1000
        self.thumbnail = song.thumbnailURL
    }

    init?(json: JSON) {
        guard let id = json["id"].string else { return nil }
        self.id = id
        self.title = json["title"].string ?? "Unknown"
        self.artist = json["artist"].string ?? "Unknown"
        self.album = json["album"].string
        self.duration = json["duration"].int ?? 0
        self.thumbnail = json["thumbnail"].string
    }

    var song: Song {
        Song(id: id,
             title: title,
             artist: artist,
             album: album,
             albumID: nil,
             durationSeconds: duration > 0 ? duration / 1000 : nil,
             thumbnailURL: thumbnail,
             artistID: nil)
    }

    var payload: [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "title": title,
            "artist": artist,
            "duration": duration,
        ]
        if let album { dict["album"] = album }
        if let thumbnail { dict["thumbnail"] = thumbnail }
        return dict
    }
}

/// 部屋の現在の状態。参加直後や再同期のときに丸ごと届く。
struct TogetherRoomState {
    var roomCode: String
    var hostID: String
    var users: [TogetherUser]
    var currentTrack: TogetherTrack?
    var isPlaying: Bool
    /// ミリ秒
    var position: Int
    /// サーバー側の時刻 (unix ミリ秒)。遅延の補正に使う。
    var lastUpdate: Int
    var queue: [TogetherTrack]

    init(json: JSON) {
        roomCode = json["room_code"].string ?? ""
        hostID = json["host_id"].string ?? ""
        users = json["users"].array.compactMap { TogetherUser(json: $0) }
        currentTrack = TogetherTrack(json: json["current_track"])
        isPlaying = json["is_playing"].bool ?? false
        position = json["position"].int ?? 0
        lastUpdate = json["last_update"].int ?? 0
        queue = json["queue"].array.compactMap { TogetherTrack(json: $0) }
    }
}

/// 部屋のチャット 1 件。
struct TogetherChatMessage: Identifiable {
    let id = UUID()
    let userID: String
    let username: String
    let text: String
    let date: Date

    init?(json: JSON) {
        guard let text = json["message"].string else { return nil }
        self.userID = json["user_id"].string ?? ""
        self.username = json["username"].string ?? "名無し"
        self.text = text
        if let ms = json["timestamp"].int {
            self.date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        } else {
            self.date = Date()
        }
    }
}

// MARK: - サーバー一覧

/// 接続先サーバー。値は本家の `ListenTogetherServers.kt` から移植。
struct TogetherServer: Identifiable, Hashable {
    var id: String { url }
    let name: String
    let url: String
    let location: String
    let operatorName: String

    static let all: [TogetherServer] = [
        TogetherServer(name: "Hugging Face Sync",
                       url: "wss://devilmi-vivi-music-listen-together.hf.space",
                       location: "Global",
                       operatorName: "VIVIDH"),
        TogetherServer(name: "ViviMusic Sync Server",
                       url: "wss://vivimusic-listen-together.onrender.com",
                       location: "USA",
                       operatorName: "Vividh"),
    ]

    static var `default`: TogetherServer { all[0] }
}
