//
//  PlaylistStore.swift
//  ViviMusic
//
//  端末内プレイリストの作成・編集・保存。
//  YouTube アカウントにログインしなくても使えるよう、完全にローカルで完結させる。
//

import Foundation
import SwiftUI

@MainActor
final class PlaylistStore: ObservableObject {
    static let shared = PlaylistStore()

    @Published private(set) var playlists: [LocalPlaylist] = []

    private static let storageKey = "PlaylistStore.playlists"

    private init() {
        load()
        EventLog.log(.bootstrap, message: "プレイリスト \(playlists.count) 件を読み込み")
    }

    // MARK: - プレイリストの操作

    /// 新規作成して、作成したものを返す。
    @discardableResult
    func create(name: String, songs: [Song] = []) -> LocalPlaylist {
        let playlist = LocalPlaylist(name: name, songs: songs)
        playlists.insert(playlist, at: 0)
        save()
        EventLog.log(.playlist, message: "作成: \(name) (\(songs.count) 曲)")
        return playlist
    }

    func rename(_ id: UUID, to newName: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let old = playlists[index].name
        playlists[index].name = newName
        save()
        EventLog.log(.playlist, message: "名称変更: \(old) → \(newName)")
    }

    func delete(_ id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let name = playlists[index].name
        playlists.remove(at: index)
        save()
        EventLog.log(.playlist, message: "削除: \(name)")
    }

    /// 一覧の並べ替え。
    func movePlaylists(from source: IndexSet, to destination: Int) {
        playlists.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - 曲の操作

    /// 曲を追加する。既に入っていれば何もしない (重複防止)。
    /// - Returns: 実際に追加されたかどうか
    @discardableResult
    func add(_ song: Song, to id: UUID) -> Bool {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return false }
        guard !playlists[index].songs.contains(where: { $0.id == song.id }) else {
            EventLog.log(.playlist, videoID: song.id,
                         message: "既に「\(playlists[index].name)」に存在するため追加しない")
            return false
        }
        playlists[index].songs.append(song)
        save()
        EventLog.log(.playlist, videoID: song.id,
                     message: "「\(playlists[index].name)」に追加")
        return true
    }

    /// 複数曲をまとめて追加する。
    /// - Returns: 実際に追加された件数
    @discardableResult
    func add(_ songs: [Song], to id: UUID) -> Int {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return 0 }
        let existing = Set(playlists[index].songs.map(\.id))
        let fresh = songs.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return 0 }
        playlists[index].songs.append(contentsOf: fresh)
        save()
        EventLog.log(.playlist,
                     message: "「\(playlists[index].name)」に \(fresh.count) 曲追加")
        return fresh.count
    }

    func removeSong(_ videoID: String, from id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].songs.removeAll { $0.id == videoID }
        save()
        EventLog.log(.playlist, videoID: videoID,
                     message: "「\(playlists[index].name)」から削除")
    }

    /// プレイリスト内の曲を並べ替える。
    func moveSongs(in id: UUID, from source: IndexSet, to destination: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].songs.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// 指定 ID のプレイリストを取り出す (画面側で最新状態を引くのに使う)。
    func playlist(with id: UUID) -> LocalPlaylist? {
        playlists.first { $0.id == id }
    }

    /// この曲を含んでいるプレイリストの名前一覧。
    func playlistNames(containing videoID: String) -> [String] {
        playlists
            .filter { $0.songs.contains(where: { $0.id == videoID }) }
            .map(\.name)
    }

    // MARK: - 永続化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([LocalPlaylist].self, from: data) else {
            return
        }
        playlists = decoded
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(playlists)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } catch {
            EventLog.logError(.storage, error: error, context: "プレイリスト保存")
        }
    }
}
