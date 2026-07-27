//
//  StreamFetcher.swift
//  ViviMusic
//
//  googlevideo からストリームを取得してファイルに落とす。
//
//  診断ログから判明した googlevideo の挙動:
//    - `Range: bytes=0-1` のような小さい範囲要求 → 206 で成功
//    - Range ヘッダなしの全体取得               → 403
//    - `&range=0-N` をクエリに付けた URL (IOS)  → 403
//    - `Range: bytes=0-<全長>` の一括要求       → 403
//    - 1 MiB ずつの分割要求 → **1 個目は成功するが 2 個目で 403**
//
//  最後の挙動が厄介で、1 つの URL で取れる量に上限があるように見える。
//  そのため 403 を受けたら URL を取り直して同じ範囲から再開する。
//  URL の再取得は 100ms 程度で済むので、実用上の問題にはならない。
//

import Foundation

enum StreamFetchError: LocalizedError {
    case badStatus(Int, offset: Int)
    case emptyResponse(offset: Int)
    case exhausted(offset: Int)

    var errorDescription: String? {
        switch self {
        case .badStatus(let status, let offset):
            return "取得に失敗しました (HTTP \(status), offset=\(offset))"
        case .emptyResponse(let offset):
            return "応答が空でした (offset=\(offset))"
        case .exhausted(let offset):
            return "URL を取り直しても取得できませんでした (offset=\(offset))"
        }
    }
}

enum StreamFetcher {

    /// 1 回の要求で取りに行くバイト数。
    static let chunkSize = 1_048_576   // 1 MiB

    /// 1 つのチャンクにつき URL を取り直す最大回数。
    private static let maxRefreshPerChunk = 2

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// ストリームを分割取得して `destination` に書き出す。
    ///
    /// - Parameters:
    ///   - refresh: 403 を受けたときに URL を取り直すための処理。
    ///              省略すると再取得せずそのまま失敗する。
    ///   - onProgress: 0.0〜1.0 の進捗。全長不明の場合は呼ばれない。
    /// - Returns: 書き込んだバイト数
    @discardableResult
    static func downloadToFile(
        stream initialStream: StreamInfo,
        videoID: String,
        destination: URL,
        refresh: (@Sendable () async throws -> StreamInfo)? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Int {

        var stream = initialStream
        let total = stream.contentLength

        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        fm.createFile(atPath: destination.path, contents: nil)

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var offset = 0
        var chunkIndex = 0
        var refreshCount = 0

        while true {
            try Task.checkCancellation()

            // 取得する範囲を決める。全長が分かっていれば末尾を超えないようにする。
            let end: Int
            if total > 0 {
                if offset >= total { break }
                end = min(offset + chunkSize - 1, total - 1)
            } else {
                end = offset + chunkSize - 1
            }

            let (data, status) = try await fetchChunk(urlString: stream.url,
                                                      from: offset, to: end)

            // 最初のチャンクだけ結果を記録しておく (失敗時の切り分け用)
            if chunkIndex == 0 {
                EventLog.log(.network, videoID: videoID,
                             message: "分割取得 開始: HTTP \(status) "
                                 + "bytes=\(offset)-\(end) 受信 \(data.count)B")
            }

            // ---- 403 などで拒否されたら URL を取り直して同じ範囲を再試行 ----
            if status != 206 && status != 200 {
                guard let refresh, refreshCount < maxRefreshPerChunk else {
                    throw StreamFetchError.badStatus(status, offset: offset)
                }
                // 最初の拒否のときだけ原因を切り分ける診断を回す
                if refreshCount == 0 {
                    await StreamProbe.diagnoseRanges(stream: stream, videoID: videoID)
                }
                refreshCount += 1
                EventLog.log(.network, videoID: videoID,
                             message: "HTTP \(status) を受信 (offset=\(offset))。"
                                 + "URL を取り直して再試行 \(refreshCount)/\(maxRefreshPerChunk)")
                stream = try await refresh()
                continue
            }

            guard !data.isEmpty else {
                if total > 0 && offset < total {
                    throw StreamFetchError.emptyResponse(offset: offset)
                }
                break   // 全長不明で空 = 終端
            }

            try handle.write(contentsOf: data)
            offset += data.count
            chunkIndex += 1
            refreshCount = 0   // このチャンクは成功したのでカウンタを戻す

            if total > 0 {
                onProgress?(min(Double(offset) / Double(total), 1.0))
            }

            // 全長不明のときは、要求より少なく返ってきたら終端とみなす
            if total == 0 && data.count < chunkSize { break }
            // 200 が返った場合は全体が来ているので終了
            if status == 200 { break }
        }

        EventLog.log(.network, videoID: videoID,
                     message: "分割取得 完了: \(chunkIndex) チャンク / \(offset) バイト")
        return offset
    }

    /// 指定範囲を 1 回取得する。
    private static func fetchChunk(urlString: String,
                                   from: Int,
                                   to: Int) async throws -> (Data, Int) {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        // 本家に合わせて Web の UA を使う (クライアント一致は不要)
        request.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, status)
    }
}
