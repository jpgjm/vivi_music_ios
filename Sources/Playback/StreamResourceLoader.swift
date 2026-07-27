//
//  StreamResourceLoader.swift
//  ViviMusic
//
//  AVPlayer の代わりに、こちらが HTTP 通信を行ってデータを渡す仕組み。
//
//  なぜ必要か:
//    AVPlayer に googlevideo の URL をそのまま渡すと、再生時間が実際の
//    ちょうど 2 倍になり、後半が無音になる問題が起きた。
//    (例: 実際 4:22 の曲が 8:45 と表示され、4:22 以降は無音)
//
//    調べたところ、データ量自体は正しかった:
//      4253080 バイト × 8 ÷ 131000 bps ≒ 260 秒 = 4:20
//    にもかかわらず AVPlayer は倍の長さと判断していた。
//    googlevideo が AVPlayer の範囲リクエストに対して、指定位置からではなく
//    毎回ファイル先頭から返すため、AVFoundation が同じデータを二重に
//    受け取っていたことが原因。
//
//  対策:
//    独自スキームの URL を AVURLAsset に渡すと、AVFoundation は通信を
//    自分で行わず、この delegate に「この範囲のデータをくれ」と要求してくる。
//    要求された範囲だけを確実に返すことで、二重取得が起きなくなる。
//    範囲の取り方は StreamFetcher と同じ (1MiB ずつ、Range ヘッダ付き)。
//

import Foundation
import AVFoundation
import UniformTypeIdentifiers

final class StreamResourceLoader: NSObject {

    /// この scheme の URL を渡すと AVFoundation が通信を委ねてくる。
    /// 実在しない scheme であれば何でもよい。
    static let scheme = "viviaudio"

    /// 1 回の要求で取りに行くバイト数。
    /// 大きすぎると googlevideo に 403 で拒否されるため控えめにする。
    private let chunkSize = 1_048_576   // 1 MiB

    private var stream: StreamInfo
    private let videoID: String
    /// URL が期限切れ / 拒否されたときに取り直すための処理。
    private let refresh: (@Sendable () async throws -> StreamInfo)?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// 進行中の要求。AVFoundation がキャンセルしてきたら止める。
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let lock = NSLock()

    /// 最初の要求のときだけログを出すためのフラグ。
    private var didLogFirstChunk = false

    init(stream: StreamInfo,
         videoID: String,
         refresh: (@Sendable () async throws -> StreamInfo)? = nil) {
        self.stream = stream
        self.videoID = videoID
        self.refresh = refresh
    }

    /// 元の URL を独自 scheme に付け替える。
    static func makeURL(from original: String) -> URL? {
        guard var components = URLComponents(string: original) else { return nil }
        components.scheme = scheme
        return components.url
    }

    /// AVFoundation に伝えるコンテンツ種別 (UTI)。
    private var contentTypeIdentifier: String {
        // "audio/mp4; codecs=..." の ";" より前だけを見る
        let mime = stream.mimeType
            .split(separator: ";")
            .first
            .map(String.init) ?? "audio/mp4"
        return UTType(mimeType: mime)?.identifier ?? "public.mpeg-4"
    }
}

// MARK: - AVAssetResourceLoaderDelegate

extension StreamResourceLoader: AVAssetResourceLoaderDelegate {

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource
                        loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let key = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            await self?.handle(loadingRequest)
            self?.forget(key)
        }
        lock.lock()
        tasks[key] = task
        lock.unlock()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)
        lock.lock()
        tasks[key]?.cancel()
        tasks[key] = nil
        lock.unlock()
    }

    private func forget(_ key: ObjectIdentifier) {
        lock.lock()
        tasks[key] = nil
        lock.unlock()
    }

    // MARK: - 要求の処理

    private func handle(_ request: AVAssetResourceLoadingRequest) async {
        // 1) まず「この資源は何か」を答える。
        //    ここで長さを正しく伝えることが、再生時間が狂わない鍵になる。
        if let info = request.contentInformationRequest {
            info.contentType = contentTypeIdentifier
            info.contentLength = Int64(stream.contentLength)
            info.isByteRangeAccessSupported = true
        }

        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }

        let total = stream.contentLength
        guard total > 0 else {
            request.finishLoading(with: StreamFetchError.emptyResponse(offset: 0))
            return
        }

        // 既に一部を渡している場合は currentOffset から続ける
        var offset = Int(dataRequest.currentOffset)
        if offset == 0 { offset = Int(dataRequest.requestedOffset) }

        let requestedLength = dataRequest.requestsAllDataToEndOfResource
            ? max(total - offset, 0)
            : dataRequest.requestedLength

        var remaining = requestedLength

        while remaining > 0 && offset < total {
            if Task.isCancelled { return }

            let end = min(offset + min(remaining, chunkSize) - 1, total - 1)
            do {
                let data = try await fetch(from: offset, to: end)
                guard !data.isEmpty else { break }
                if Task.isCancelled { return }

                dataRequest.respond(with: data)
                offset += data.count
                remaining -= data.count
            } catch {
                if Task.isCancelled { return }
                EventLog.logError(.playError, videoID: videoID, error: error,
                                  context: "ストリーム読み出し (offset=\(offset))")
                request.finishLoading(with: error)
                return
            }
        }

        request.finishLoading()
    }

    /// 指定範囲を取得する。拒否されたら URL を取り直して 1 度だけ再試行する。
    private func fetch(from: Int, to: Int) async throws -> Data {
        for attempt in 0...1 {
            let (data, status) = try await requestRange(urlString: stream.url,
                                                        from: from, to: to)

            if !didLogFirstChunk {
                didLogFirstChunk = true
                EventLog.log(.network, videoID: videoID,
                             message: "ストリーム読み出し 開始: HTTP \(status) "
                                 + "bytes=\(from)-\(to) 受信 \(data.count)B")
            }

            if status == 206 || status == 200 {
                return data
            }

            // 期限切れなどで拒否された。URL を取り直す。
            guard attempt == 0, let refresh else {
                throw StreamFetchError.badStatus(status, offset: from)
            }
            EventLog.log(.network, videoID: videoID,
                         message: "HTTP \(status) (offset=\(from))。URL を取り直して再試行")
            stream = try await refresh()
        }
        throw StreamFetchError.badStatus(-1, offset: from)
    }

    private func requestRange(urlString: String,
                              from: Int,
                              to: Int) async throws -> (Data, Int) {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        request.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1

        // 要求より多く返ってきた場合は切り詰める。
        // これを怠ると AVFoundation に余計なデータが渡り、
        // 再生時間が伸びてしまう (今回の不具合の直接の原因)。
        let expected = to - from + 1
        if data.count > expected {
            EventLog.log(.network, videoID: videoID,
                         message: "要求 \(expected)B に対し \(data.count)B 返却。切り詰めます")
            return (Data(data.prefix(expected)), status)
        }
        return (data, status)
    }
}
