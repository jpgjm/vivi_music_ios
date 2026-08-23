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
        // ここは Web の UA を使う。
        //
        // rev.40 で「URL を発行したクライアントと UA を揃える」よう変えたが、
        // 元のコードには「クライアント一致は不要」と実測の注記があった。
        // 403 の原因は UA ではなく poToken の欠落だったので、
        // 検証済みの状態へ戻す。
        for (name, value) in YouTubeClient.streamHeaders(forClientName: stream.clientName) {
            request.setValue(value, forHTTPHeaderField: name)
        }

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
    /// **実行順が結果を左右する。**
    /// 診断そのものがデータを消費するので、
    /// 「累積で何バイト取れるか」を測る項目を後ろに置くと、
    /// 前の項目が使い切ったせいで失敗しているのか、
    /// 元から拒否されるのかが区別できなくなる。
    /// そのため累積量と pot の比較を先に済ませてから、
    /// 消費量の読めない項目を回す。
    ///
    /// なお、この URL は **再生側が既に一部を読んだあと** である点に注意。
    /// 「累積で 1 MiB まで」のような制限があるなら、
    /// 診断を始めた時点で残りが少ない可能性がある。
    static func diagnoseRanges(stream: StreamInfo, videoID: String) async {
        guard let url = URL(string: stream.url) else { return }
        let oneMiB = 1_048_576

        EventLog.log(.network, videoID: videoID,
                     message: "範囲診断 開始 (この URL は再生側が既に一部を読んだあと)")

        // ── J: 1 MiB 制限は形式 (itag) ごとか ────────────────
        //
        // 「iOS 非対応の webm/opus を再生できるようにすれば直るのでは」
        // という案が出た。opus の URL でも同じ制限がかかるなら、
        // デコーダを自作しても意味が無い。作る前に測る。
        await diagnoseFormats(videoID: videoID)

        // ── I: 取り直した URL で 1 MiB 以降が取れるか ────────
        //
        // ここが今いちばん知りたい点。
        //   取れる  → URL ごとに配信枠がリセットされる。
        //             1 MiB ごとに URL を取り直せば最後まで再生できる。
        //   取れない → 制限がファイル先頭からの絶対位置。
        //             この経路では曲の後半に到達できず、作りを変える必要がある。
        await probeFreshURL(videoID: videoID)

        // ── G: URL クエリの range= が使えるか ────────────────
        // Range ヘッダでは 1 MiB より先が取れない。
        // yt-dlp は Range ヘッダではなく **URL に &range=start-end** を
        // 付ける方式を使っており (CHUNK_SIZE = 10 MiB)、
        // これは「1 つの URL で取れる量に制限がある」前提の作りに見える。
        // ここが通るなら取得方式を切り替えれば直る。
        await probeRangeQuery(url: url, videoID: videoID)

        // ── H: Range 指定なしだと何バイト返るか ──────────────
        // 1 MiB で切れるなら「この URL は先頭 1 MiB しか配信しない」
        // という見立ての裏付けになる。
        await probeWithoutRange(url: url, videoID: videoID)

        // ── E: 累積で何バイト取れるか ─────────────────────────
        // いちばん知りたいので最初に測る。
        //
        // 2026-08-14 の実測では、曲もファイル長も違うのに
        // **毎回まったく同じ bytes=933888-1196031 (256KiB)** が 403 になった。
        // 開始位置 262144 の 256KiB は通るので大きさの問題ではなく、
        // 「そこまでに読んだ合計が 1 MiB に届くと拒否される」
        // という累積制限を疑っている。
        await measureCumulativeLimit(url: url, videoID: videoID)

        // ── F: pot= が効いているか ───────────────────────────
        await comparePoTokenEffect(url: url, videoID: videoID)

        // ── A: 開始位置が 0 以外の小さい範囲 ──────────────────
        let nonZeroStart = await status(url: url, range: "bytes=\(oneMiB)-\(oneMiB + 1)")

        // ── B: 1 秒待ってから同じ要求 ────────────────────────
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let afterDelay = await status(url: url, range: "bytes=\(oneMiB)-\(oneMiB + 1)")

        // ── C: 0 から始まる小さめの範囲 (256 KiB) ─────────────
        let smallFromZero = await status(url: url, range: "bytes=0-262143")

        EventLog.log(
            .network, videoID: videoID,
            message: "範囲診断: 非ゼロ開始=\(nonZeroStart) / "
                + "1秒後の非ゼロ開始=\(afterDelay) / 0から256KiB=\(smallFromZero)"
        )

        // ── D: どの大きさまで通るか ──────────────────────────
        // ここは合計 1.8 MiB ほど消費するので最後に回す。
        var sizeResults: [String] = []
        var largestOK = 0
        for size in [65_536, 262_144, 524_288, 1_048_576] {
            let start = 262_144   // 0 以外から始めて、実際の使われ方に近づける
            let code = await status(url: url,
                                    range: "bytes=\(start)-\(start + size - 1)")
            sizeResults.append("\(size / 1024)KiB=\(code)")
            if code == 206 { largestOK = max(largestOK, size) }
        }
        EventLog.log(.network, videoID: videoID,
                     message: "範囲診断 (要求サイズ): "
                         + sizeResults.joined(separator: " / "))

        // 結論。ただし D は前の項目の消費を受けるので、
        // 「サイズ上限」と読めても累積制限の影という場合がある。
        if nonZeroStart != 206 && smallFromZero == 206 {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "範囲診断の結論: 開始位置 0 以外の要求が拒否されている")
        } else if nonZeroStart != 206 && afterDelay == 206 {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "範囲診断の結論: 短時間の連続要求が拒否されている (要間隔)")
        } else if largestOK > 0 && largestOK < 1_048_576 {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "範囲診断の参考: 単発で通ったのは "
                             + "\(largestOK / 1024)KiB まで "
                             + "(累積制限がある場合は当てにならない)")
        } else if largestOK == 0 {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "範囲診断の結論: どの大きさでも拒否された。"
                             + "URL か poToken の問題")
        }
    }

    /// 同じ URL から 256 KiB を続けて取り、何回目で拒否されるかを測る。
    ///
    /// 累積制限が本当にあるなら、4 回目 (= 1 MiB 到達) 付近で 403 になるはず。
    /// 最後まで通るなら累積制限は無く、原因は別にある。
    private static func measureCumulativeLimit(url: URL, videoID: String) async {
        let chunk = 262_144
        var results: [String] = []
        var offset = 0
        var firstFailure: Int?

        // 1.5 MiB 分 (6 回) まで試す。1 MiB を跨いだ先も見たいので少し多め。
        for index in 0..<6 {
            let code = await status(url: url,
                                    range: "bytes=\(offset)-\(offset + chunk - 1)")
            results.append("\(index + 1)回目(\(offset / 1024)KiB〜)=\(code)")
            if code != 206 && firstFailure == nil {
                firstFailure = offset
            }
            offset += chunk
        }

        EventLog.log(.network, videoID: videoID,
                     message: "範囲診断 (連続取得): " + results.joined(separator: " / "))

        if let firstFailure {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "範囲診断の結論: 累積 \(firstFailure / 1024)KiB を"
                             + "超えたところで拒否された (累積制限あり)")
        } else {
            EventLog.log(.network, videoID: videoID,
                         message: "範囲診断: 1.5MiB まで連続取得できた (累積制限なし)")
        }
    }

    /// pot= が付いているかどうかで挙動が変わるかを比べる。
    ///
    /// - pot 有りだけ通る → pot は効いている。原因は別
    /// - どちらも同じ     → pot が効いていない可能性がある
    ///   (visitorData との紐づけが違う、など)
    /// - Parameter range: 比べる範囲。
    ///   **1 MiB 未満を指定すること。**
    ///   1 MiB 以降はどのみち拒否される領域なので、
    ///   そこで比べても両方 403 になり何も分からない
    ///   (rev.46〜48 の私の測定はこの誤りを含んでいた)。
    private static func comparePoTokenEffect(url: URL,
                                             videoID: String,
                                             range: String = "bytes=524288-786431",
                                             label: String = "pot") async {
        let full = url.absoluteString
        guard full.contains("pot=") else {
            EventLog.log(.network, videoID: videoID,
                         message: "範囲診断 (\(label)): URL に pot= が付いていない")
            return
        }

        // pot= を取り除いた URL を組み立てる
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return }
        let stripped = (components.queryItems ?? []).filter { $0.name != "pot" }
        components.queryItems = stripped.isEmpty ? nil : stripped
        guard let withoutPot = components.url else { return }

        let withPotCode = await status(url: url, range: range)
        let withoutPotCode = await status(url: withoutPot, range: range)

        EventLog.log(.network, videoID: videoID,
                     message: "範囲診断 (\(label)): あり=\(withPotCode) / なし=\(withoutPotCode)")

        if withPotCode == 206 && withoutPotCode != 206 {
            EventLog.log(.network, videoID: videoID,
                         message: "範囲診断の結論: pot= は効いている")
        } else if withPotCode != 206 && withoutPotCode != 206 {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "範囲診断の結論: pot= の有無で結果が変わらない。"
                             + "pot が効いていない可能性がある")
        }
    }

    /// 形式別の診断を一度だけ回すためのフラグ。
    private static var didProbeFormats = false

    /// **音声形式ごとに** 1 MiB 以降が取れるかを測る。
    ///
    /// ANDROID_VR の応答には AAC (itag 139/140) だけでなく
    /// opus (itag 249/250/251) の直接 URL も入っている。
    /// 1 MiB 制限が URL 単位なのか形式単位なのかで、
    /// 「opus 対応に意味があるか」の答えが変わる。
    ///
    ///   opus が 1 MiB 以降も取れる → opus 対応に進む価値がある
    ///   opus も 403                → コーデックでは解決しない
    private static func diagnoseFormats(videoID: String) async {
        guard !didProbeFormats else { return }
        didProbeFormats = true

        let raw: JSON
        do {
            // 署名復号の要らない ANDROID_VR で取る。
            raw = try await InnerTube.shared.player(videoID: videoID, client: .androidVR165)
        } catch {
            EventLog.log(.network, videoID: videoID,
                         message: "範囲診断 (形式別): player を取得できず")
            return
        }

        let audioFormats = raw["streamingData"]["adaptiveFormats"].array.filter {
            ($0["mimeType"].string ?? "").hasPrefix("audio/")
        }
        guard !audioFormats.isEmpty else {
            EventLog.log(.network, videoID: videoID,
                         message: "範囲診断 (形式別): 音声形式が無い")
            return
        }

        var results: [String] = []
        var opusPassed = false
        var aacPassed = false

        for format in audioFormats {
            guard let urlString = format["url"].string,
                  let url = URL(string: urlString) else {
                let itag = format["itag"].int ?? -1
                results.append("itag\(itag)=URLなし")
                continue
            }

            let itag = format["itag"].int ?? -1
            // "audio/webm; codecs=\"opus\"" → "audio/webm"
            let mime = (format["mimeType"].string ?? "?")
                .split(separator: ";").first.map(String.init) ?? "?"
            let length = Int(format["contentLength"].string ?? "") ?? 0

            // そもそも 1 MiB 未満のファイルなら制限に当たらない
            if length > 0 && length <= 1_048_576 {
                results.append("itag\(itag) \(mime) 全長\(length / 1024)KiB (制限に届かず)")
                continue
            }

            let over = await status(url: url, range: "bytes=1048576-1310719")
            results.append("itag\(itag) \(mime) \(length / 1024)KiB → 1MiB以降=\(over)")

            if over == 206 {
                if mime.contains("webm") { opusPassed = true } else { aacPassed = true }
            }
        }

        EventLog.log(.network, videoID: videoID,
                     message: "範囲診断 (形式別): " + results.joined(separator: " / "))

        if opusPassed && !aacPassed {
            EventLog.log(.network, videoID: videoID,
                         message: "範囲診断の結論: opus (webm) だけが 1 MiB 以降も取れる。"
                             + "opus 再生に対応する価値がある")
        } else if opusPassed && aacPassed {
            EventLog.log(.network, videoID: videoID,
                         message: "範囲診断の結論: どの形式も 1 MiB 以降を取れた。"
                             + "制限は形式ではなく別の条件で決まっている")
        } else {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "範囲診断の結論: opus でも 1 MiB 以降は取れない。"
                             + "コーデックを増やしても解決しない")
        }
    }

    /// この起動で一度だけ回すためのフラグ。
    /// player を叩き直すので、403 のたびに走らせると負荷が高い。
    private static var didProbeFresh = false

    /// **新しく取り直した URL** で 1 MiB 以降が取れるかを測る。
    ///
    /// これまでの診断は「再生側が既に一部を読んだあとの URL」に対するもので、
    /// 「URL ごとに枠があるのか、ファイル先頭からの絶対位置なのか」が
    /// 区別できていなかった。ここで player を叩き直して確かめる。
    private static func probeFreshURL(videoID: String) async {
        guard !didProbeFresh else { return }
        didProbeFresh = true

        let fresh: StreamInfo
        do {
            fresh = try await YouTubeAPI.resolveStream(videoID: videoID)
        } catch {
            EventLog.log(.network, videoID: videoID,
                         message: "範囲診断 (新URL): 取得できず \(error.localizedDescription)")
            return
        }
        guard let url = URL(string: fresh.url) else { return }

        // 新しい URL に対して、まだ何も読んでいない状態で測る。
        // 1 MiB 以降を先に叩く (先に手前を読むと枠を消費しかねないため)
        let over = await status(url: url, range: "bytes=1048576-1572863")
        let under = await status(url: url, range: "bytes=524288-786431")

        EventLog.log(.network, videoID: videoID,
                     message: "範囲診断 (新URL / \(fresh.resolvedBy)): "
                         + "1MiB以降=\(over) / 1MiB未満=\(under)")

        if over == 206 {
            EventLog.log(.network, videoID: videoID,
                         message: "範囲診断の結論: 取り直した URL なら 1 MiB 以降も取れる。"
                             + "1 MiB ごとに URL を取り直す方式で解決できる")
        } else if under == 206 {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "範囲診断の結論: 取り直しても 1 MiB 以降は取れない。"
                             + "制限はファイル先頭からの絶対位置。作りの変更が要る")
        } else {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "範囲診断の結論: 新しい URL でも何も取れない。別の要因")
        }

        // ついでに pot の影響を **1 MiB 未満** で比べる。
        // 手前の位置で比べないと意味が無いことが分かったため。
        await comparePoTokenEffect(url: url, videoID: videoID,
                                   range: "bytes=262144-524287",
                                   label: "pot / 新URL")
    }

    /// URL クエリの `&range=` で取れるかを試す。
    ///
    /// yt-dlp は `Range` ヘッダではなくこちらを使う。
    /// 併用すると解釈が割れる恐れがあるので、**Range ヘッダは付けない**。
    private static func probeRangeQuery(url: URL, videoID: String) async {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return }

        var items = components.queryItems ?? []
        // 既に range= があれば差し替える
        items.removeAll { $0.name == "range" }

        var results: [String] = []
        var anyOK = false

        // 1 MiB より前 / 跨ぐ / 先 の 3 か所で試す
        let ranges = [
            ("先頭", "0-524287"),
            ("1MiB跨ぎ", "786432-1310719"),
            ("1MiB以降", "1048576-1572863"),
        ]
        for (label, value) in ranges {
            components.queryItems = items + [URLQueryItem(name: "range", value: value)]
            guard let target = components.url else { continue }

            var request = URLRequest(url: target)
            // Range ヘッダは **付けない**
            for (name, headerValue) in YouTubeClient.streamHeaders(forClientName: "ANDROID_VR") {
                request.setValue(headerValue, forHTTPHeaderField: name)
            }

            do {
                let (data, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                results.append("\(label)=\(code)(\(data.count / 1024)KiB)")
                if code == 200 || code == 206 { anyOK = true }
            } catch {
                results.append("\(label)=エラー")
            }
        }

        EventLog.log(.network, videoID: videoID,
                     message: "範囲診断 (range= クエリ): " + results.joined(separator: " / "))

        if anyOK {
            EventLog.log(.network, videoID: videoID,
                         message: "範囲診断の結論: range= クエリ方式が使える。"
                             + "Range ヘッダから切り替える価値がある")
        }
    }

    /// Range を一切指定せずに取得し、実際に何バイト返るかを見る。
    ///
    /// 1 MiB 付近で打ち切られるなら、
    /// 「この URL は先頭 1 MiB しか配信しない」という見立ての裏付けになる。
    /// 全長が返るなら、Range の指定の仕方に問題がある。
    private static func probeWithoutRange(url: URL, videoID: String) async {
        var request = URLRequest(url: url)
        for (name, value) in YouTubeClient.streamHeaders(forClientName: "ANDROID_VR") {
            request.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? -1
            let contentLength = http?.value(forHTTPHeaderField: "Content-Length") ?? "なし"
            EventLog.log(.network, videoID: videoID,
                         message: "範囲診断 (Range なし): HTTP \(code) / "
                             + "受信 \(data.count / 1024)KiB / "
                             + "Content-Length=\(contentLength)")
        } catch {
            EventLog.log(.network, videoID: videoID,
                         message: "範囲診断 (Range なし): 失敗 \(error.localizedDescription)")
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
