//
//  DownloadManager.swift
//  ViviMusic
//
//  曲をローカルに保存してオフライン再生を可能にする。
//  保存先: <Documents>/Downloads/<videoId>.m4a
//
//  取得は StreamFetcher に任せる。
//  googlevideo は「Range ヘッダ付きの小分けリクエスト」しか受け付けず、
//  一括取得や `&range=` クエリは 403 で拒否されるため、
//  URLSessionDownloadTask で丸ごと取りにいく方式は使えない。
//

import Foundation

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// videoId → 進捗 (0.0 ... 1.0)。キーが無い = ダウンロード中でない。
    @Published private(set) var progress: [String: Double] = [:]
    /// ダウンロード完了済みの videoId 集合。
    @Published private(set) var downloadedIDs: Set<String> = []
    /// ダウンロード済みの曲 (メタ情報つき、新しい順)。
    @Published private(set) var downloadedSongs: [Song] = []

    /// 進行中のダウンロード。キャンセルに使う。
    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {
        loadPersisted()
    }

    // MARK: - パス

    private var downloadsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func fileURL(for videoID: String) -> URL {
        downloadsDirectory.appendingPathComponent("\(videoID).m4a")
    }

    /// ダウンロード済みならローカル URL を返す。無ければ nil。
    /// PlayerManager がこれを見てローカル優先再生を決める。
    nonisolated func localFileURL(for videoID: String) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("\(videoID).m4a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func isDownloaded(_ videoID: String) -> Bool {
        downloadedIDs.contains(videoID)
    }

    func isDownloading(_ videoID: String) -> Bool {
        progress[videoID] != nil
    }

    // MARK: - ダウンロード

    /// 曲をダウンロードする。既に完了 / 進行中なら何もしない。
    ///
    /// 複数曲をまとめて落とすときは呼び出し側で順に await すれば
    /// 直列に処理される (同時に何十本も走らせない)。
    func download(_ song: Song) async {
        guard !isDownloaded(song.id), !isDownloading(song.id) else { return }

        let task = Task { await performDownload(song) }
        tasks[song.id] = task
        await task.value
        tasks[song.id] = nil
    }

    private func performDownload(_ song: Song) async {
        progress[song.id] = 0
        EventLog.log(.downloadStart, videoID: song.id, message: song.title)

        let dest = fileURL(for: song.id)
        let tmp = dest.appendingPathExtension("part")
        let started = Date()

        do {
            let stream = try await YouTubeAPI.resolveStream(videoID: song.id)

            let videoID = song.id
            let written = try await StreamFetcher.downloadToFile(
                stream: stream,
                videoID: videoID,
                destination: tmp,
                // 403 を受けたら URL を取り直して同じ範囲から再開する
                refresh: { try await YouTubeAPI.resolveStream(videoID: videoID) }
            ) { [weak self] ratio in
                Task { @MainActor in
                    self?.progress[videoID] = ratio
                }
            }

            // 期待値より明らかに小さい = 転送が途中で切れている
            if stream.contentLength > 0 && written < stream.contentLength - 1024 {
                EventLog.log(.downloadNG, videoID: song.id,
                             message: "転送が途中で切れた可能性: \(written) / \(stream.contentLength) バイト")
            }

            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)

            downloadedIDs.insert(song.id)
            downloadedSongs.removeAll { $0.id == song.id }
            downloadedSongs.insert(song, at: 0)
            persist()

            EventLog.logDuration(
                .downloadOK, videoID: song.id, start: started,
                message: "保存完了 "
                    + ByteCountFormatter.string(fromByteCount: Int64(written), countStyle: .file)
            )

            // 完了表示を 1 秒だけ残してから進捗を消す
            progress[song.id] = 1.0
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            progress[song.id] = nil

        } catch is CancellationError {
            try? FileManager.default.removeItem(at: tmp)
            progress[song.id] = nil
            EventLog.log(.downloadNG, videoID: song.id, message: "キャンセルされました")

        } catch {
            try? FileManager.default.removeItem(at: tmp)
            progress[song.id] = nil
            EventLog.logError(.downloadNG, videoID: song.id, error: error, context: "ダウンロード")
        }
    }

    /// 進行中のダウンロードを中止する。
    func cancel(_ videoID: String) {
        tasks[videoID]?.cancel()
        tasks[videoID] = nil
        progress[videoID] = nil
        EventLog.log(.downloadNG, videoID: videoID, message: "ユーザー操作でキャンセル")
    }

    /// ダウンロード済みファイルを削除する。
    func delete(_ videoID: String) {
        let url = fileURL(for: videoID)
        try? FileManager.default.removeItem(at: url)
        downloadedIDs.remove(videoID)
        downloadedSongs.removeAll { $0.id == videoID }
        persist()
        EventLog.log(.storage, videoID: videoID, message: "ダウンロード削除")
    }

    /// ダウンロード済みファイルの合計サイズ (バイト)。
    func totalBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(Int64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }

    /// 人が読めるサイズ表記。
    func totalSizeText() -> String {
        ByteCountFormatter.string(fromByteCount: totalBytes(), countStyle: .file)
    }

    // MARK: - 永続化

    private static let storageKey = "DownloadManager.songs"

    private func loadPersisted() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let songs = try? JSONDecoder().decode([Song].self, from: data) else { return }

        // ファイルが実在するものだけ有効にする (アプリ再インストール後の食い違い対策)
        let valid = songs.filter { localFileURL(for: $0.id) != nil }
        downloadedSongs = valid
        downloadedIDs = Set(valid.map(\.id))

        if valid.count != songs.count {
            EventLog.log(.storage,
                         message: "ダウンロード記録 \(songs.count) 件中 \(valid.count) 件のみ実ファイルあり")
            persist()
        }
        EventLog.log(.bootstrap, message: "ダウンロード済み \(valid.count) 件を読み込み")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(downloadedSongs) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
