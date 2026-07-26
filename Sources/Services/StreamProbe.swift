//
//  StreamProbe.swift
//  ViviMusic
//
//  ストリーム URL が実際に使えるかを事前に確認する。
//
//  本家 VIVI Music の `YTPlayerUtils.validateStatus` に相当する。
//  向こうも「HEAD を投げて成功したら採用、駄目なら次のクライアント」
//  という方式で、クライアントを 11 個も並べて総当たりしている。
//
//  本家のコメントより:
//    「googlevideo.com の CDN はアカウントの Cookie を付けると 403 を返す。
//      ストリーム URL は署名済みパラメータで認証されているため Cookie は不要」
//  そのため余計なヘッダは付けない。
//

import Foundation

enum StreamProbe {

    /// 検証結果。
    struct Result {
        let statusCode: Int
        /// このURLを採用してよいか。
        var isUsable: Bool { (200..<400).contains(statusCode) }
    }

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// ストリーム URL が使えるかを確認する。
    ///
    /// HEAD ではなく先頭 2 バイトの GET を使う。
    /// googlevideo は HEAD に対して素っ気ない応答を返すことがあり、
    /// 実際の取得と同じ形 (Range 付き GET) で試すほうが確実なため。
    static func validate(stream: StreamInfo) async -> Result {
        guard let url = URL(string: stream.url) else {
            return Result(statusCode: -1)
        }

        var request = URLRequest(url: url)
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        // 本家に合わせて Web の User-Agent を使う。
        // クライアント別の UA に揃える必要は無いことを実測で確認済み。
        request.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return Result(statusCode: status)
        } catch {
            EventLog.logError(.network, error: error, context: "URL 検証")
            return Result(statusCode: -1)
        }
    }
}

// MARK: - 範囲リクエストの挙動診断

extension StreamProbe {

    /// 分割取得が 403 で止まる原因を切り分けるための診断。
    ///
    /// これまでに分かっていること:
    ///   `bytes=0-1` と `bytes=0-1048575` は成功するが、
    ///   その直後の `bytes=1048576-2097151` は 403 になる。
    ///
    /// 原因の候補が 3 つあるので、それぞれを試して結果を残す。
    ///   A. 開始位置が 0 以外だと拒否される
    ///   B. 連続した要求が短時間だと拒否される (レート制限)
    ///   C. 1 回の URL で取れる量に上限がある
    static func diagnoseRanges(stream: StreamInfo, videoID: String) async {
        guard let url = URL(string: stream.url) else { return }
        let oneMiB = 1_048_576

        // A: 開始位置が 0 以外の小さい範囲
        let nonZeroStart = await status(url: url, range: "bytes=\(oneMiB)-\(oneMiB + 1)")

        // B: 1 秒待ってから同じ要求
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let afterDelay = await status(url: url, range: "bytes=\(oneMiB)-\(oneMiB + 1)")

        // C: 0 から始まる小さめの範囲 (256 KiB)
        let smallFromZero = await status(url: url, range: "bytes=0-262143")

        EventLog.log(
            .network, videoID: videoID,
            message: "範囲診断: 非ゼロ開始=\(nonZeroStart) / "
                + "1秒後の非ゼロ開始=\(afterDelay) / 0から256KiB=\(smallFromZero)"
        )

        // 結論をそのまま書いておくと、次に何を直すべきかがすぐ分かる
        if nonZeroStart != 206 && smallFromZero == 206 {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "範囲診断の結論: 開始位置 0 以外の要求が拒否されている")
        } else if nonZeroStart != 206 && afterDelay == 206 {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "範囲診断の結論: 短時間の連続要求が拒否されている (要間隔)")
        }
    }

    /// 指定範囲でのステータスコードだけを取る。
    private static func status(url: URL, range: String) async -> Int {
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch {
            return -1
        }
    }
}
