//
//  LibraryStore.swift
//  ViviMusic
//
//  お気に入り・再生履歴の保存。
//  規模が小さいうちは UserDefaults + JSON で十分なのでそうしている。
//  曲数が数千規模になったら SwiftData への移行を検討する。
//

import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var favorites: [Song] = []
    @Published private(set) var history: [Song] = []

    private static let favoritesKey = "LibraryStore.favorites"
    private static let historyKey = "LibraryStore.history"
    private static let historyLimit = 200

    private init() {
        favorites = Self.load(key: Self.favoritesKey)
        history = Self.load(key: Self.historyKey)
        EventLog.log(.bootstrap,
                     message: "ライブラリ読み込み: お気に入り \(favorites.count) / 履歴 \(history.count)")
    }

    // MARK: - お気に入り

    func isFavorite(_ videoID: String) -> Bool {
        favorites.contains { $0.id == videoID }
    }

    func toggleFavorite(_ song: Song) {
        if let index = favorites.firstIndex(where: { $0.id == song.id }) {
            favorites.remove(at: index)
            EventLog.log(.storage, videoID: song.id, message: "お気に入り解除")
        } else {
            favorites.insert(song, at: 0)
            EventLog.log(.storage, videoID: song.id, message: "お気に入り追加: \(song.title)")
        }
        Self.save(favorites, key: Self.favoritesKey)
    }

    // MARK: - 履歴

    func pushHistory(_ song: Song) {
        history.removeAll { $0.id == song.id }
        history.insert(song, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        Self.save(history, key: Self.historyKey)
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: Self.historyKey)
        EventLog.log(.storage, message: "履歴を全消去")
    }

    // MARK: - 永続化

    private static func load(key: String) -> [Song] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let songs = try? JSONDecoder().decode([Song].self, from: data) else {
            return []
        }
        return songs
    }

    private static func save(_ songs: [Song], key: String) {
        if let data = try? JSONEncoder().encode(songs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
