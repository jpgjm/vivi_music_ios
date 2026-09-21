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
    ///
    /// vivi-music (Android) と Metrolist はどちらも 512 KiB。
    /// 範囲診断でも 512KiB=206 が出ているので、この値で問題ない。
    /// rev.45 で 256 KiB まで下げたが、そこまで小さくする必要はなかった。
    private let chunkSize = 524_288   // 512 KiB

    private var stream: StreamInfo
    private let videoID: String
    /// URL が期限切れ / 拒否されたときに取り直すための処理。
    /// 403 を受けたときに URL を取り直す処理。
    /// 引数には「今 403 になった URL を出したクライアント名」を渡すので、
    /// 呼ばれた側はそれを除外して別のクライアントで解決できる。
    private let refresh: (@Sendable (String) async throws -> StreamInfo)?

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

    /// 資産情報の通知を 1 度だけログに出すためのフラグ。
    private var didLogContentInfo = false

    /// 範囲診断を 1 度だけ回すためのフラグ。
    private var didDiagnose = false

    /// visitorData の引き直しを 1 度だけ行うためのフラグ。
    private var didRenewIdentity = false

    /// 先読みを打ち切ったことを 1 度だけログに出すためのフラグ。
    private var didLogReadAheadCap = false

    /// 範囲要求の間隔を空けるための仕切り。
    /// 曲をまたいでも効かせたいので型で 1 つだけ持つ。
    // 連続要求そのものは診断で問題ないと分かったので短くしてよい。
    /// ただし同時に何本も投げるのは行儀が悪いので、少しだけ間隔を置く。
    private static let gate = RangeGate(minimumInterval: 0.05)

    /// duration を 0 に書き換えた先頭領域のコピー。
    /// この範囲の要求はネットワークに行かずここから返す。
    private var headerCache: Data?
    /// ヘッダ取得が同時に走らないようにするための進行中タスク。
    private var headerTask: Task<Data?, Never>?
    /// ヘッダとして先読みする長さ。
    /// itag 140 の ftyp + moov は 1KB 未満だが、余裕を持たせる。
    private let headerLength = 65_536

    init(stream: StreamInfo,
         videoID: String,
         refresh: (@Sendable (String) async throws -> StreamInfo)? = nil) {
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
    ///
    /// ── 2 倍問題の実験 (rev.27) ───────────────────────────────
    /// `audio/mp4` を UTType に引かせると `public.mpeg-4-audio` が返る。
    /// これは「素の AAC / M4A 音声」を指す種別で、コンテナ形式ではない。
    ///
    /// ところが YouTube の itag 140 は **フラグメント化 MP4** で、
    /// 実データを読むと moov に `mvex` があり、その後ろに
    /// `sidx` + `moof`/`mdat` が続く構造になっている
    /// (mvhd/mdhd の duration は正しく 213.09s と入っている)。
    ///
    /// AVFoundation に音声種別として渡すとフラグメント構造の解釈が変わり、
    /// 「mvhd の長さ」と「フラグメントの合計長」を二重に数えて
    /// ちょうど 2 倍になっている疑いがある。
    /// そこで mp4 系はコンテナの種別 (`public.mpeg-4`) として渡してみる。
    ///
    /// これで直らなければ原因は別にあるので、この分岐は戻してよい。
    /// 戻す場合は `containerUTI` を返している行を消して
    /// `UTType(mimeType: mime)?.identifier ?? containerUTI` に戻すだけ。
    private var contentTypeIdentifier: String {
        // "audio/mp4; codecs=..." の ";" より前だけを見る
        let mime = stream.mimeType
            .split(separator: ";")
            .first
            .map(String.init) ?? "audio/mp4"

        let containerUTI = "public.mpeg-4"

        // audio/mp4 も video/mp4 も中身は MP4 コンテナなので同じ種別で渡す。
        if mime.hasSuffix("/mp4") {
            return containerUTI
        }
        return UTType(mimeType: mime)?.identifier ?? containerUTI
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
            let uti = contentTypeIdentifier
            info.contentType = uti
            info.contentLength = Int64(stream.contentLength)
            info.isByteRangeAccessSupported = true

            // 2 倍問題の切り分け用。何を AVFoundation に伝えたかを残す。
            if !didLogContentInfo {
                didLogContentInfo = true
                EventLog.log(.network, videoID: videoID,
                             message: "資産情報を通知: UTI=\(uti)"
                                 + " length=\(stream.contentLength)"
                                 + " mime=\(stream.mimeType)")
            }
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

        // ── 先読みの上限 ─────────────────────────────────────
        //
        // AVFoundation は `requestsAllDataToEndOfResource` で
        // 「末尾まで全部くれ」と言ってくることがある。
        // これをそのまま受けると 5 MB のファイルを全速力で吸い上げてしまう。
        //
        // 曲のビットレートは 130kbps ≒ 16 KB/s。
        // 512 KiB を 50ms 間隔で連射すると 10 MB/s 出るので、
        // **必要量の数百倍**の速さで取りに行っていたことになる。
        // googlevideo 側のレート制限に当たるのは当然だった。
        //
        // (2026-08-14 の診断: 短時間に 1 MiB ほど流すと 403 になり、
        //  少し間を置くと再び通る = バイト量のレート制限)
        //
        // ExoPlayer を使う Android 版が平気なのは、
        // 「バッファが減ったら次を取る」方式で必要なぶんしか読まないため。
        // ここで同じことをする。1 回の応答で渡すのは最大 2 MiB までとし、
        // 続きは AVFoundation が改めて要求してきたときに渡す。
        let maxReadAhead = 2 * 1_048_576   // 2 MiB

        let requestedLength = dataRequest.requestsAllDataToEndOfResource
            ? min(max(total - offset, 0), maxReadAhead)
            : dataRequest.requestedLength

        // 打ち切ったことが分かるようにしておく。
        //
        // ここで区切ると、AVFoundation は残りが必要になった時点で
        // 改めて要求を出してくる想定。もし出してこないと
        // 2 MiB で再生が止まるので、そのときはこのログが手がかりになる。
        if dataRequest.requestsAllDataToEndOfResource,
           total - offset > maxReadAhead, !didLogReadAheadCap {
            didLogReadAheadCap = true
            EventLog.log(.network, videoID: videoID,
                         message: "先読みを \(maxReadAhead / 1024)KiB で区切った "
                             + "(要求は末尾まで / 残り \((total - offset) / 1024)KiB)")
        }

        var remaining = requestedLength

        // 先頭領域は duration を 0 に書き換えたコピーから返す。
        // ここを素通しすると AVFoundation が moov の長さと
        // フラグメントの長さを二重に数え、再生時間が 2 倍になる。
        let header = await patchedHeader(total: total)

        while remaining > 0 && offset < total {
            if Task.isCancelled { return }

            let end = min(offset + min(remaining, chunkSize) - 1, total - 1)

            if let header, offset < header.count {
                let sliceEnd = min(end + 1, header.count)
                let data = header.subdata(in: offset..<sliceEnd)
                guard !data.isEmpty else { break }
                dataRequest.respond(with: data)
                offset += data.count
                remaining -= data.count
                continue
            }

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

    // MARK: - 先頭領域の補正

    /// duration を 0 に書き換えた先頭領域を返す。
    /// 取得できなければ nil (その場合は従来どおり素のデータを流す)。
    private func patchedHeader(total: Int) async -> Data? {
        lock.lock()
        if let headerCache {
            lock.unlock()
            return headerCache
        }
        if let headerTask {
            lock.unlock()
            return await headerTask.value
        }

        let end = min(headerLength, total) - 1
        guard end >= 0 else {
            lock.unlock()
            return nil
        }

        let task = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.loadAndPatchHeader(to: end)
        }
        headerTask = task
        lock.unlock()

        let result = await task.value

        lock.lock()
        headerCache = result
        lock.unlock()
        return result
    }

    private func loadAndPatchHeader(to end: Int) async -> Data? {
        do {
            let data = try await fetch(from: 0, to: end)
            guard !data.isEmpty else { return nil }

            let result = MP4HeaderPatcher.zeroingDurations(in: data)
            if result.patched.isEmpty {
                EventLog.log(.playError, videoID: videoID,
                             message: "先頭 \(data.count)B に書き換え対象の"
                                 + " duration が見つかりませんでした")
            } else {
                EventLog.log(.network, videoID: videoID,
                             message: "duration を 0 に書き換え: "
                                 + result.patched.joined(separator: ", ")
                                 + " (先頭 \(data.count)B)")
            }
            return result.data
        } catch {
            EventLog.logError(.playError, videoID: videoID, error: error,
                              context: "先頭領域の取得")
            return nil
        }
    }

    /// 指定範囲を取得する。拒否されたら URL を取り直して再試行する。
    ///
    /// ── 取り直しの順番 (2026-08-14 に見直し) ─────────────────
    ///
    /// 1 回目: **同じクライアントのまま URL だけ取り直す。**
    ///   403 の多くは URL の期限切れや一時的な拒否で、
    ///   クライアント自体が使えなくなったわけではない。
    ///   ここでいきなり除外すると、唯一動いているクライアントを
    ///   自分から捨てることになる。
    ///   (実測: ANDROID_VR だけが通る状況で、403 のたびに
    ///    ANDROID_VR を除外し、SABR 化した IOS / WEB に落ちて詰んでいた)
    ///
    /// 2 回目: 同じクライアントで 2 度失敗したので、今度は除外して
    ///   別のクライアントへ移る。
    private func fetch(from: Int, to: Int) async throws -> Data {
        // 除外していくクライアント。2 回目の取り直しから使う。
        var blocked = Set<String>()

        for attempt in 0...2 {
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
            guard attempt < 2, let refresh else {
                throw StreamFetchError.badStatus(status, offset: from)
            }

            // 最初の 403 のときだけ、原因を切り分ける診断を回す。
            // これまで StreamFetcher (ダウンロード) 側にしか無く、
            // 再生時の 403 は理由が分からないままだった。
            if !didDiagnose {
                didDiagnose = true
                await StreamProbe.diagnoseRanges(stream: stream, videoID: videoID)
            }

            // ── 1 MiB 制限なら visitorData を引き直す ─────────────
            //
            // 2026-08 以降、先頭 1 MiB より先が返らなくなることがある。
            // 制限は **訪問者アイデンティティ単位**でかかっているらしく、
            // visitorData を作り直すと、制限のかかっていないものが
            // 当たることがある。
            //
            // 恒久策ではない (Google 側が割合を絞れば効かなくなる) が、
            // アプリ内で完結し費用も小さいので、詰まったとき一度だけ試す。
            //
            // ログイン中は visitorData がアカウントに紐づくので
            // InnerTube 側で引き直しを見送る。
            if !didRenewIdentity, from >= 1_000_000 || to >= 1_048_576 {
                didRenewIdentity = true
                await InnerTube.shared.renewVisitorData()
                EventLog.log(.network, videoID: videoID,
                             message: "1 MiB 付近で拒否された。"
                                 + "visitorData を引き直して解決し直す")
            }

            // 2 回目からクライアントを除外する。
            if attempt >= 1, !stream.resolvedBy.isEmpty {
                blocked.insert(stream.resolvedBy)
            }

            EventLog.log(.network, videoID: videoID,
                         message: "HTTP \(status) "
                             + "(bytes=\(from)-\(to) / \(to - from + 1)B)。"
                             + "URL を取り直して再試行 \(attempt + 1)/2"
                             + (blocked.isEmpty ? " (同じクライアントで再取得)"
                                : " (除外: \(blocked.sorted().joined(separator: ", ")))"))
            stream = try await refresh(blocked.sorted().joined(separator: ","))
        }
        throw StreamFetchError.badStatus(-1, offset: from)
    }

    private func requestRange(urlString: String,
                              from: Int,
                              to: Int) async throws -> (Data, Int) {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        // 要求を間引く。
        //
        // AVFoundation は複数の範囲を **同時に** 要求してくる。
        // 実測では先頭の 1 本が通った 19ms 後に投げた 2 本目が
        // 毎回きっかり 403 になっていた (offset=147456 で 4 曲とも同じ)。
        // 時間経過による失効なら位置がばらつくはずで、そうなっていない。
        // googlevideo 側が短時間の連続要求を拒んでいると考えられる。
        await Self.gate.acquire()

        var request = URLRequest(url: url)
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        // Metrolist / vivi-music (Android) と同じヘッダ構成にする。
        // Range と User-Agent だけでは足りず、Origin / Referer / Accept まで
        // 揃えないと googlevideo 側の扱いが変わるようだった。
        for (name, value) in YouTubeClient.streamHeaders(forClientName: stream.clientName) {
            request.setValue(value, forHTTPHeaderField: name)
        }

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
