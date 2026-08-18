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
    /// 1 回の要求で取りに行くバイト数。
    ///
    /// 2026-08-14 の範囲診断でこう出た:
    ///   非ゼロ開始 (2 バイト)     = 206
    ///   1 秒後の非ゼロ開始         = 206
    ///   0 から 256 KiB            = 206
    ///   実際の要求 (1 MiB)        = 403   ← これだけ落ちる
    ///
    /// URL も poToken も有効で、開始位置も連続要求も問題ない。
    /// **要求サイズだけが拒否の理由** だった。
    /// 以前は ANDROID_VR なら 1 MiB でも通っていたが、
    /// IOS で起きていた制限が同じように及んだものと思われる。
    ///
    /// 256 KiB は診断で 206 を確認できている大きさなので、
    /// 当て推量ではなく実測にもとづく値。
    static let chunkSize = 524_288   // 512 KiB

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
    ///              引数には「今 403 になった URL を出したクライアント名」を
    ///              カンマ区切りで渡すので、除外して解決し直せる。
    ///              省略すると再取得せずそのまま失敗する。
    ///   - onProgress: 0.0〜1.0 の進捗。全長不明の場合は呼ばれない。
    /// - Returns: 書き込んだバイト数
    @discardableResult
    static func downloadToFile(
        stream initialStream: StreamInfo,
        videoID: String,
        destination: URL,
        refresh: (@Sendable (String) async throws -> StreamInfo)? = nil,
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
        // visitorData の引き直しは 1 曲につき 1 回だけ
        var didRenewIdentity = false
        // 403 を出したクライアントを覚えておき、取り直しのときに除外する。
        var blocked = Set<String>()

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
                                                      clientName: stream.clientName,
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

                // 1 MiB 付近で拒否されたなら visitorData を引き直す。
                //
                // rev.85 以降、この引き直しは既定で無効化されている
                // (`InnerTube.allowVisitorDataRenewal`)。公式 iOS アプリは
                // visitorData を引き直さずに 1 MiB を超えて取得できており、
                // 引き直しが有効な対策だという前提が実測で否定されたため。
                //
                // 引き直しが行われなかったのに「引き直して解決し直す」と
                // 出るとログが実態とずれるので、戻り値で文言を分ける。
                if !didRenewIdentity, offset >= 1_000_000 || end >= 1_048_576 {
                    didRenewIdentity = true
                    let renewed = await InnerTube.shared.renewVisitorData()
                    EventLog.log(.network, videoID: videoID,
                                 message: renewed
                                     ? "1 MiB 付近で拒否された。"
                                         + "visitorData を引き直して解決し直す"
                                     : "1 MiB 付近で拒否された。"
                                         + "visitorData は引き直さず URL のみ取り直す")
                }
                refreshCount += 1
                // 1 回目は同じクライアントのまま URL だけ取り直す。
                // 403 の多くは URL の失効や一時的な拒否で、
                // クライアントが使えなくなったわけではないため。
                if refreshCount >= 2, !stream.resolvedBy.isEmpty {
                    blocked.insert(stream.resolvedBy)
                }
                EventLog.log(.network, videoID: videoID,
                             message: "HTTP \(status) を受信 "
                                 + "(bytes=\(offset)-\(end) / \(end - offset + 1)B)。"
                                 + "URL を取り直して再試行 \(refreshCount)/\(maxRefreshPerChunk)"
                                 + (blocked.isEmpty ? " (同じクライアントで再取得)"
                                    : " (除外: \(blocked.sorted().joined(separator: ", ")))"))
                stream = try await refresh(blocked.sorted().joined(separator: ","))
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
                                   clientName: String,
                                   from: Int,
                                   to: Int) async throws -> (Data, Int) {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        // Metrolist / vivi-music (Android) と同じヘッダ構成にする。
        // Range と User-Agent だけでは足りず、Origin / Referer / Accept まで
        // 揃えないと googlevideo 側の扱いが変わるようだった。
        for (name, value) in YouTubeClient.streamHeaders(forClientName: clientName) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1

        // 要求した範囲より多く返ってくることがある。
        // そのまま書き込むとファイルに重複が入り、再生時間が伸びてしまう。
        let expected = to - from + 1
        if data.count > expected {
            return (Data(data.prefix(expected)), status)
        }
        return (data, status)
    }
}
