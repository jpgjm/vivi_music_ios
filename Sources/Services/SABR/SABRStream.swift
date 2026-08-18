//
//  SABRStream.swift
//  ViviMusic
//
//  SABR (Server Adaptive BitRate) で音声を取得する。
//
//  ── なぜ必要か ──────────────────────────────────────────
//  2026-08 以降、googlevideo の再生 URL が
//  「ファイル先頭 1 MiB より先を返さない」状態になることがある。
//  Range ヘッダでも range= クエリでも Range 無しでも同じで、
//  取り直した URL でも同じ位置で拒否される。
//
//  SABR はサーバー主導でメディアを送る仕組みで、
//  この制限を受けない。実測で確認済み:
//
//    直接 URL 1MiB以降 = 403 の同時刻に
//    SABR は 1105KiB (69秒ぶん) を取得できた
//
//  ── 位置づけ ────────────────────────────────────────────
//  **最後の逃げ道**として使う。
//  ANDROID_VR などが通るならそちらが速いので、順番は変えない。
//
//  ── 割り切り (第1版) ────────────────────────────────────
//  曲全体を取り切ってから再生する。
//  進行に合わせて流し込む形にすると AVFoundation との
//  やり取りが複雑になるため、まず「確実に鳴る」ことを優先した。
//  4 MB 程度なので数秒で終わる。
//

import Foundation

enum SABRError: LocalizedError {
    case missingConfig
    case noAudioFormat
    case rejected(status: Int)
    case noMedia
    case brokenContainer

    var errorDescription: String? {
        switch self {
        case .missingConfig:      return "SABR の設定を取得できません"
        case .noAudioFormat:      return "SABR で使える音声形式がありません"
        case .rejected(let code): return "SABR が拒否されました (HTTP \(code))"
        case .noMedia:            return "SABR からメディアが返りません"
        case .brokenContainer:    return "SABR で組み上げた音声が壊れています"
        }
    }
}

/// SABR で 1 曲分の音声を取得する。
actor SABRStream {

    private let videoID: String
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        // 1 曲を取り切るまで何十往復もするので、全体の上限も延ばす
        cfg.timeoutIntervalForResource = 180
        return URLSession(configuration: cfg)
    }()

    // サーバーとのやり取りに要る状態
    private var abrURL = ""
    private var ustreamerConfig = ""
    private var itag = 140
    private var lastModified: UInt64 = 0
    private var totalLength = 0
    private var mimeType = "audio/mp4"
    private var bitrate = 130_000
    private var poToken: String?
    /// videoId に紐づく poToken。認証が通らないときに切り替えて試す。
    private var videoBoundToken: String?
    /// いま使っているトークンの種類 (ログ用)。
    private var tokenKind = "visitorData"
    /// 要求と違う形式が届いたか (ログを一度だけ出すため)。
    private var hasUnexpectedFormat = false
    /// 取り込まない header_id。要求と違う形式のものが入る。
    private var rejectedHeaderIDs: Set<Int> = []

    /// メディア要求に載せる clientVersion。
    /// **player 要求で使ったものと同じ値**にする。
    private var clientVersion = WebClientVersion.fallback

    /// メディア要求で名乗る visitorData。
    ///
    /// **その player 応答を返したセッションの visitorData** を使う。
    /// `InnerTube.shared.visitorData` は WEB_REMIX (music.youtube.com)
    /// 由来のことがあり、SABR の player を叩く WEB (www.youtube.com) とは
    /// 別セッションになりうる。応答の responseContext を優先する。
    private var sessionVisitorData: String?

    /// メディア要求で名乗る Accept-Language。InnerTube 要求と揃える。
    private var acceptLanguage: String?

    /// SABR セッションを開始した時刻。
    /// `ClientAbrState.elapsed_wall_time_ms` の基準にする。
    private var sessionStart = Date()

    /// これまでに受け取った範囲の **累積**。
    ///
    /// 公式のキャッシュ metadata を見ると、セグメントは 1 から末尾まで
    /// 連番で隙間なく並んでいる。公式は「先頭からここまで持っている」を
    /// 伝え続けているので、こちらも累積で申告する。
    private var cumulativeBuffered: SABRProbe.BufferedRange?

    private var contexts: [Int: SABRProbe.SabrContext] = [:]
    private var activeTypes: Set<Int> = []
    private var playbackCookie: Data?
    private var requestNumber = 0

    /// 組み上がったファイル本体。
    /// MEDIA_HEADER の start_range をもとに正しい位置へ書く。
    private var fileData = Data()
    /// header_id ごとの書き込み位置。
    private var writeOffsets: [Int: Int] = [:]
    /// 受け取ったヘッダの記録 (診断用)。
    private var headerLog: [String] = []
    /// 書き込み済みの区間。穴が空いていないかを確かめる。
    private var writtenRanges: [(Int, Int)] = []

    /// 形式の初期化が済んだか。
    ///
    /// 済むまでは `selected_format_ids` を送らない。
    /// 送ってしまうと「その形式は分かっている」と見なされ、
    /// 初期化セグメント (連番 0 / ftyp + moov) が降りてこない。
    private var formatsInitialized = false
    /// 受け取った初期化セグメントの範囲 (診断用)。
    private var initRange: String?
    /// 連番 0 (初期化セグメント) を受け取ったか。
    private var sawInitSegment = false

    /// これまでに落とした合計時間 (ms)。
    ///
    /// `player_time_ms` はここを使う。
    /// buffered_ranges が「直近ぶん」なのに対し、こちらが累積を担う。
    private var downloadedDurationMs = 0
    /// 落とした連番 (重複を数えないため)。
    private var downloadedSegments: Set<Int> = []

    init(videoID: String) {
        self.videoID = videoID
    }

    // MARK: - 取得

    /// player を叩いて SABR の入口を用意し、曲全体を取り切る。
    /// - Returns: 音声ファイルの中身と、その形式
    func fetchAll() async throws -> (data: Data, mimeType: String, bitrate: Int) {
        try await prepare()

        // 1 往復目。ここでサーバーからコンテキストの指示が来る。
        let first = try await roundTrip(playerTimeMs: 0, buffered: nil)
        EventLog.log(.network, videoID: videoID,
                     message: "SABR 1往復目: 保護=\(first.protectionStatus.map(String.init) ?? "-") "
                         + "方針[\(first.policyNotes.joined(separator: " "))] "
                         + "パート[\(first.partSummary)]")
        var buffered = first.buffered

        // 指示に従い、コンテキストを載せて取り直す
        if first.mediaBytes == 0 {
            if first.backoffMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(first.backoffMs) * 1_000_000)
            }
            let second = try await roundTrip(playerTimeMs: 0, buffered: nil)
            EventLog.log(.network, videoID: videoID,
                         message: "SABR 2往復目: 初期化メタ="
                             + (formatsInitialized ? "受領" : "未")
                             + " 保護=\(second.protectionStatus.map(String.init) ?? "-") "
                             + "パート[\(second.partSummary)]")
            buffered = second.buffered

            guard second.mediaBytes > 0 else { throw SABRError.noMedia }
        }

        // 残りを順に取る。
        //
        // ── buffered_ranges の扱い (rev.85 で再修正) ─────────────
        //
        // 経緯:
        //   rev.72 以前 : 累積を送っていた → 69 秒で停止
        //   2026-08-14  : 直近ぶんのみに変更 → 症状変わらず
        //   rev.85      : 累積に戻す (ただし player_time_ms とは分離)
        //
        // 公式 iOS アプリのキャッシュ metadata を解析したところ、
        // セグメントは 1 から末尾まで連番で隙間なく並んでおり、
        // 公式は「先頭からここまで持っている」を伝え続けていた。
        //
        // rev.72 で累積が効かなかったのは、`player_time_ms` にも
        // 同じ累積値を入れて **二重に申告していた** ためと考えられる。
        // 今回は役割をはっきり分けている:
        //
        //   playerTimeMs      … これまでに落とした合計時間 (累積)
        //   elapsedWallTimeMs … セッション開始からの実経過時間
        //   bufferedRanges    … 保持している範囲 (累積・セグメント番号)
        //
        // 69 秒で止まる症状が再発するようなら、
        // cumulativeBuffered の更新を止めて直近ぶんに戻せば
        // 以前の挙動に戻せる (SABRStream.consume を参照)。
        var round = 1
        var lastFileSize = fileData.count
        var lastDurationMs = downloadedDurationMs
        var stalledRounds = 0

        for _ in 0..<200 {
            guard totalLength == 0 || fileData.count < totalLength else { break }
            guard let range = buffered else { break }

            let next = try await roundTrip(playerTimeMs: downloadedDurationMs,
                                           buffered: range)
            round += 1
            // 止まる直前と直後で何が変わるかを追いたいので、
            // 最初の 10 往復は毎回、それ以降は 10 回ごとに残す。
            if round <= 10 || round % 10 == 0 {
                EventLog.log(.network, videoID: videoID,
                             message: "SABR \(round)往復目: "
                                 + "+\(next.mediaBytes / 1024)KiB "
                                 + "累計 \(fileData.count / 1024)/\(totalLength / 1024)KiB "
                                 + "(\(downloadedDurationMs / 1000)秒) "
                                 + "保護=\(next.protectionStatus.map(String.init) ?? "-") "
                                 + "方針[\(next.policyNotes.joined(separator: " "))] "
                                 + "パート[\(next.partSummary)]")
            }
            // ── 進んでいないなら打ち切る ─────────────────────────
            //
            // rev.73 では MEDIA パートは届くのに同じセグメントの
            // 繰り返しで、9 往復ぶん無駄にしていた。
            // 「バイトが来たか」ではなく「実際に前進したか」で判断する。
            let advanced = fileData.count > lastFileSize
                || downloadedDurationMs > lastDurationMs
            lastFileSize = fileData.count
            lastDurationMs = downloadedDurationMs

            if !advanced {
                stalledRounds += 1
            } else {
                stalledRounds = 0
            }

            if stalledRounds >= 2 {
                // ── rev.87: 判定に必要な値をまとめて残す ────────────
                //
                // rev.85 で入れた修正 (StreamerContext.visitorData /
                // poToken 紐づけ統一 / elapsed_wall_time_ms /
                // buffered_ranges 累積) が効いたかどうかを、
                // ここに出る値だけで判断できるようにしておく。
                //
                //   保護=1 → 認証が通った。rev.85 の修正が効いた
                //   保護=2 → 認証待ちのまま。attestation 側が原因
                //   取得量 → 1.08 MiB 前後で止まるなら従来どおり
                let mib = String(format: "%.3f", Double(fileData.count) / 1_048_576)
                EventLog.log(.resolveNG, videoID: videoID,
                             message: "SABR: \(stalledRounds) 往復続けて前進せず打ち切り "
                                 + "(取得済み \(fileData.count / 1024)KiB = \(mib)MiB "
                                 + "/ \(downloadedDurationMs / 1000)秒 "
                                 + "/ 全長 \(totalLength / 1024)KiB "
                                 + "/ 保護=\(next.protectionStatus.map(String.init) ?? "-") "
                                 + "/ トークン種別=\(tokenKind) "
                                 + "/ セッション=\(sessionVisitorData?.prefix(12) ?? "-") "
                                 + "/ 方針[\(next.policyNotes.joined(separator: " "))])")

                // 保護状態 2 は「認証待ち」で、約 1 分ぶんのプレビューを
                // 配ったところで打ち切られる。
                //
                // rev.85 以降、ここでの visitorData 引き直しは既定で
                // 無効化されている (公式 iOS アプリは引き直さずに
                // 3.5〜4.1 MiB 取得できていたため)。呼び出しは残して
                // あるが、通常はスキップされる。
                if (next.protectionStatus ?? 0) >= 2 {
                    let renewed = await InnerTube.shared.renewVisitorData()
                    EventLog.log(.network, videoID: videoID,
                                 message: renewed
                                     ? "SABR: 認証待ちの上限に達した。"
                                         + "次に備えて visitorData を引き直す"
                                     : "SABR: 認証待ち (保護=2) の上限に達した。"
                                         + "visitorData は引き直さない")
                }
                break
            }

            if next.mediaBytes == 0 {
                // ── 認証が原因なら、トークンを替えて 1 度だけやり直す ──
                //
                // StreamProtectionStatus = 2 は「認証待ち」。
                // サーバーは認証が済んでいない相手に約 1.08 MiB だけ
                // 猶予として渡し、そこで打ち切る。
                // visitorData 紐づけが受け付けられていないなら、
                // videoId 紐づけのトークンで通るかもしれない。
                var recovered = false
                if (next.protectionStatus ?? 0) >= 2,
                   tokenKind == "visitorData",
                   videoBoundToken != nil {
                    tokenKind = "videoId"
                    EventLog.log(.network, videoID: videoID,
                                 message: "SABR: 認証待ちのまま停止。"
                                     + "poToken を videoId 紐づけに切り替えて再試行")
                    let retry = try await roundTrip(playerTimeMs: downloadedDurationMs,
                                                    buffered: range)
                    if retry.mediaBytes > 0 {
                        EventLog.log(.network, videoID: videoID,
                                     message: "SABR: videoId 紐づけで再開できた "
                                         + "(+\(retry.mediaBytes / 1024)KiB "
                                         + "保護=\(retry.protectionStatus.map(String.init) ?? "-"))")
                        buffered = retry.buffered
                        recovered = true
                    } else {
                        EventLog.log(.resolveNG, videoID: videoID,
                                     message: "SABR: videoId 紐づけでも変わらず "
                                         + "(保護=\(retry.protectionStatus.map(String.init) ?? "-"))")
                    }
                }

                if !recovered {
                    EventLog.log(.resolveNG, videoID: videoID,
                                 message: "SABR: メディアが返らず終了 "
                                     + "(取得済み \(fileData.count / 1024)KiB "
                                     + "/ 送った再生位置 \(downloadedDurationMs / 1000)秒 "
                                     + "/ 保護=\(next.protectionStatus.map(String.init) ?? "-") "
                                     + "/ 方針[\(next.policyNotes.joined(separator: " "))] "
                                     + "/ パート \(next.partSummary))")
                    if (next.protectionStatus ?? 0) >= 2 {
                        EventLog.log(.resolveNG, videoID: videoID,
                                     message: "SABR: 認証 (StreamProtectionStatus=2) が"
                                         + "完了していないため打ち切られた。"
                                         + "約 1.08MiB が未認証時の猶予枠と思われる")
                    }
                    for dump in next.rawDumps {
                        EventLog.log(.resolveNG, videoID: videoID,
                                     message: "SABR 停止時のパート: \(dump)")
                    }
                    break
                }
                continue
            }

            // **直近の受信ぶんだけ**を次に渡す。累積はしない。
            buffered = next.buffered
        }

        guard !fileData.isEmpty else { throw SABRError.noMedia }

        // 初期化セグメント (ftyp + moov) が来ていなければ、
        // 通常の再生 URL から先頭領域だけ取って補う。
        if !sawInitSegment {
            await fillInitSegment()
        }

        verify()

        // 組み上がりが壊れているなら再生させない。
        //
        // rev.68 では初期化セグメント (連番 0) が来ず、
        // ファイル先頭が空のまま moov が無い状態で再生を試み、
        // AVPlayerItem が Cannot Open で失敗して赤帯が出ていた。
        // 壊れたものを渡すくらいなら、ここで止めたほうがよい。
        guard isPlayableContainer() else {
            throw SABRError.brokenContainer
        }

        // 断片化 MP4 の duration をゼロにする。
        //
        // YouTube の itag 140 は mvhd/tkhd/mdhd に長さが入っているのに
        // 実体は moof/mdat の連なりで、AVFoundation が二重に数えて
        // 再生時間が倍になる。既存の再生経路 (StreamResourceLoader) でも
        // 同じ補正をしている。
        let patched = MP4HeaderPatcher.zeroingDurations(in: fileData)
        if !patched.patched.isEmpty {
            EventLog.log(.resolveOK, videoID: videoID,
                         message: "SABR: duration を 0 に書き換え "
                             + patched.patched.joined(separator: ", "))
        }
        return (patched.data, mimeType, bitrate)
    }

    /// 組み上がったファイルが成立しているかを確かめる。
    ///
    /// バイト数が合っていても中身が壊れていれば鳴らない。
    /// 実際 rev.67 では「1105KiB 取得完了」と出したのに
    /// AVPlayerItem が Cannot Open で失敗していた。
    private func verify() {
        EventLog.log(.resolveOK, videoID: videoID,
                     message: "SABR で取得完了 \(fileData.count / 1024)KiB "
                         + "/ 想定 \(totalLength / 1024)KiB")

        // 1) 先頭に mp4 の箱があるか
        //    正常なら 4〜8 バイト目が "ftyp"
        let head = fileData.prefix(16).map { String(format: "%02x", $0) }.joined()
        var boxes: [String] = []
        if fileData.count >= 8 {
            let type = String(data: fileData.subdata(in: 4..<8), encoding: .ascii) ?? "?"
            boxes.append("先頭box=\(type)")
        }
        // 2) moov があるか (無いと AVFoundation は開けない)
        let hasMoov = contains(ascii: "moov")
        let hasMoof = contains(ascii: "moof")
        boxes.append("moov=\(hasMoov ? "あり" : "なし")")
        boxes.append("moof=\(hasMoof ? "あり" : "なし")")

        EventLog.log(.resolveOK, videoID: videoID,
                     message: "SABR 構造: \(boxes.joined(separator: " / ")) "
                         + "/ 初期化メタ=\(formatsInitialized ? "受領" : "未") "
                         + "/ 連番0=\(sawInitSegment ? "受領" : "未受領") "
                         + "/ init範囲=\(initRange ?? "不明") "
                         + "先頭16B=\(head)")

        // 3) 書き込みに穴が無いか
        let sorted = writtenRanges.sorted { $0.0 < $1.0 }
        var gaps: [String] = []
        var cursor = 0
        for (start, end) in sorted {
            if start > cursor { gaps.append("\(cursor)〜\(start)") }
            cursor = max(cursor, end)
        }
        if gaps.isEmpty {
            EventLog.log(.resolveOK, videoID: videoID,
                         message: "SABR 書き込み: 穴なし (\(sorted.count) 区間)")
        } else {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "SABR 書き込みに穴 \(gaps.prefix(5).joined(separator: ", "))")
        }

        // 4) ヘッダの並び
        EventLog.log(.resolveOK, videoID: videoID,
                     message: "SABR ヘッダ: " + headerLog.prefix(12).joined(separator: " / "))
    }

    /// 初期化セグメントを通常の再生 URL から取ってくる。
    ///
    /// ── なぜこうするのか ────────────────────────────────
    /// SABR は連番 1 以降しか送ってこない
    /// (`selected_format_ids` を外しても変わらなかった)。
    /// そのため先頭 1KB 程度が空のままで `moov` が無く、
    /// AVFoundation が Cannot Open で失敗していた。
    ///
    /// 一方、必要なのは **先頭 1KB だけ**。
    /// 1 MiB 制限が出ている状況でも、先頭領域は取得できる
    /// (実測: `bytes=0-524287` は 206 で通る)。
    ///
    /// SABR の作法としては邪道だが、目的は音を鳴らすこと。
    /// 初期化セグメントの位置は MEDIA_HEADER が
    /// `start_range` で教えてくれているので、そこまでを埋める。
    private func fillInitSegment() async {
        // 最初のセグメントの開始位置 = 初期化セグメントの長さ
        guard let firstStart = writtenRanges.map(\.0).min(), firstStart > 0 else {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "SABR: 初期化セグメントの範囲が分からない")
            return
        }

        // ANDROID_VR は直接 URL を返す唯一のクライアント。
        guard let raw = try? await InnerTube.shared.player(videoID: videoID,
                                                          client: .androidVR165) else {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "SABR: 初期化セグメント用の URL を取得できず")
            return
        }
        // SABR で選んだ形式と同じ itag を選ぶ。違う形式の moov では鳴らない。
        guard let urlString = raw["streamingData"]["adaptiveFormats"].array
                .first(where: { $0["itag"].int == itag })?["url"].string,
              let url = URL(string: urlString) else {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "SABR: itag=\(itag) の直接 URL が無い")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(firstStart - 1)", forHTTPHeaderField: "Range")
        for (name, value) in YouTubeClient.streamHeaders(forClientName: "ANDROID_VR") {
            request.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 206 || status == 200, !data.isEmpty else {
                EventLog.log(.resolveNG, videoID: videoID,
                             message: "SABR: 初期化セグメントを取得できず HTTP \(status)")
                return
            }
            write(data, at: 0)
            sawInitSegment = true
            EventLog.log(.resolveOK, videoID: videoID,
                         message: "SABR: 初期化セグメントを別途取得 \(data.count)B "
                             + "(0〜\(firstStart - 1))")
        } catch {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "SABR: 初期化セグメントの取得に失敗 "
                             + error.localizedDescription)
        }
    }

    /// mp4 として最低限の体裁が整っているか。
    ///
    /// `ftyp` で始まり `moov` を持つことを確かめる。
    /// どちらが欠けても AVFoundation は開けない。
    private func isPlayableContainer() -> Bool {
        guard fileData.count >= 8 else { return false }
        let type = String(data: fileData.subdata(in: 4..<8), encoding: .ascii)
        return type == "ftyp" && contains(ascii: "moov")
    }

    /// ファイル中に指定の 4 文字が含まれるか (先頭 256KiB まで)。
    private func contains(ascii text: String) -> Bool {
        guard let needle = text.data(using: .ascii) else { return false }
        return fileData.prefix(262_144).range(of: needle) != nil
    }

    // MARK: - 準備

    private func prepare() async throws {
        sessionStart = Date()

        // WEB は SABR 専用応答を返すので、この用途に向いている。
        let raw = try await InnerTube.shared.player(videoID: videoID, client: .web)

        // ── rev.85: セッション同一性の確保 ───────────────────────
        //
        // この player 応答を返したセッションの visitorData を控える。
        // 以後 SABR 要求の StreamerContext.ClientInfo で名乗り、
        // poToken もこれに紐づける。
        //
        // 応答に responseContext.visitorData があればそれが最も確実。
        // 無ければ InnerTube 側が保持している値に落とす。
        let fallbackVisitorData = await InnerTube.shared.visitorData
        if let fromResponse = raw["responseContext"]["visitorData"].string,
           !fromResponse.isEmpty {
            sessionVisitorData = fromResponse
        } else {
            sessionVisitorData = fallbackVisitorData
        }
        acceptLanguage = await InnerTube.shared.acceptLanguageHeader()

        guard let rawURL = raw["streamingData"]["serverAbrStreamingUrl"].string,
              let config = raw.path("playerConfig", "mediaCommonConfig",
                                    "mediaUstreamerRequestConfig",
                                    "videoPlaybackUstreamerConfig").string else {
            throw SABRError.missingConfig
        }

        // `n=` が変換前で降ってくるので必ず復号を通す。
        // ここを飛ばすと入口で 403 になる。
        abrURL = await PlayerJSService.shared.decipher(rawURL)
        ustreamerConfig = config

        // player を叩いたときと同じ clientVersion を控える。
        // ハードコードしていると食い違い、認証が通らない恐れがある。
        clientVersion = await WebClientVersion.shared.current()
        EventLog.log(.network, videoID: videoID,
                     message: "SABR: clientVersion=\(clientVersion) を使用")

        let audio = raw["streamingData"]["adaptiveFormats"].array.filter {
            ($0["mimeType"].string ?? "").hasPrefix("audio/")
        }
        // iOS で鳴らせる AAC を選ぶ。webm/opus は AVFoundation が扱えない。
        guard let format = audio.first(where: {
            ($0["mimeType"].string ?? "").hasPrefix("audio/mp4")
        }) else {
            throw SABRError.noAudioFormat
        }

        itag = format["itag"].int ?? 140
        lastModified = UInt64(format["lastModified"].string ?? "") ?? 0
        totalLength = Int(format["contentLength"].string ?? "") ?? 0
        mimeType = format["mimeType"].string ?? "audio/mp4"
        bitrate = format["bitrate"].int ?? 130_000

        // poToken を用意する。
        //
        // SABR では `StreamProtectionStatus.status = 2` (認証待ち) のまま
        // 約 1.08 MiB で打ち切られていた。visitorData 紐づけのトークンが
        // 受け付けられていないので、**videoId 紐づけ**でも作って
        // 両方を順に試せるようにする。
        //
        // ── rev.85 で直した点 ────────────────────────────────────
        //
        // 以前はここで `InnerTube.shared.visitorData` を紐づけ先に
        // 使っていた。しかしそれは検索やホームで先に走る WEB_REMIX
        // (music.youtube.com) が学習した値であることが多く、
        // 直前に叩いた WEB (www.youtube.com) の player 応答とは
        // 別セッションになりうる。結果として
        //
        //   poToken の紐づけ先 : WEB_REMIX 由来の visitorData
        //   player を叩いた相手 : WEB
        //   SABR で名乗る相手   : (名乗っていない)
        //
        // と三者がずれていた。上で控えた sessionVisitorData に
        // 統一することで、この三重ズレを解消する。
        if let sessionID = sessionVisitorData, !sessionID.isEmpty {
            let dataSyncID = await CookieAuthService.shared.credentials?.dataSyncID
            let sessionBinding = PoTokenBindingResolver.binding(dataSyncID: dataSyncID,
                                                                visitorData: sessionID)
            let pair = await PoTokenService.shared.tokens(videoID: videoID,
                                                          sessionID: sessionID,
                                                          binding: sessionBinding)
            poToken = pair?.streaming
            // player 用は videoId に紐づく。SABR の認証にはこちらが
            // 求められている可能性がある。
            videoBoundToken = pair?.player
            EventLog.log(.auth, videoID: videoID,
                         message: "SABR: セッション \(sessionID.prefix(12))… に"
                             + "紐づけて poToken を用意 "
                             + "(\(sessionBinding?.kind ?? "既定"))")
        } else {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "SABR: visitorData が取れず poToken を用意できない")
        }

        EventLog.log(.resolveOK, videoID: videoID,
                     message: "SABR 準備完了 itag=\(itag) "
                         + "全長 \(totalLength / 1024)KiB")
    }

    // MARK: - 1 往復

    private struct RoundTrip {
        var mediaBytes = 0
        var buffered: SABRProbe.BufferedRange?
        var backoffMs = 0
        /// 返ってきたパートの内訳 (診断用)
        var partSummary = ""
        /// STREAM_PROTECTION_STATUS の値 (1=OK / 2=認証待ち / 3=認証必要)
        var protectionStatus: Int?
        /// NEXT_REQUEST_POLICY の全項目
        var policyNotes: [String] = []
        /// 見えていない指示を探すため、パートの中身を 16 進で残す
        var rawDumps: [String] = []
    }

    /// いま送るトークン。
    private var activeToken: String? {
        tokenKind == "videoId" ? videoBoundToken : poToken
    }

    /// - Parameter sendPreferredFormat:
    ///   `preferred_audio_format_ids` を送るか。**必ず送る。**
    ///
    ///   rev.73 で「外すと FORMAT_INITIALIZATION_METADATA が返り、
    ///   取得量も 157KiB → 357KiB に増える」と見えたので既定を false に
    ///   したが、これは誤りだった。外すとサーバーが **opus/webm
    ///   (itag 251)** を選んで送ってくる。取得量が増えたのも初期化メタが
    ///   返るのも、単に別形式だっただけ。
    ///   実測の先頭 16 バイトは `1a45dfa3…` = EBML (WebM) で、
    ///   moov も moof も無く AVFoundation が開けなかった。
    ///
    ///   iOS で鳴らせるのは AAC (audio/mp4) だけなので外せない。
    private func roundTrip(playerTimeMs: Int,
                           buffered: SABRProbe.BufferedRange?,
                           sendPreferredFormat: Bool = true) async throws -> RoundTrip {
        guard var components = URLComponents(string: abrURL) else {
            throw SABRError.missingConfig
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "rn" }
        items.append(URLQueryItem(name: "rn", value: String(requestNumber)))
        components.queryItems = items
        requestNumber += 1

        guard let url = components.url else { throw SABRError.missingConfig }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // セッション開始からの実経過時間。
        // player_time_ms (メディア内の位置) とは別物なので分けて渡す。
        let elapsedWallTimeMs = max(0, Int(Date().timeIntervalSince(sessionStart) * 1000))

        request.httpBody = SABRProbe.buildBody(ustreamerConfig: ustreamerConfig,
                                               itag: itag,
                                               lastModified: lastModified,
                                               playerTimeMs: playerTimeMs,
                                               elapsedWallTimeMs: elapsedWallTimeMs,
                                               poToken: activeToken,
                                               playbackCookie: playbackCookie,
                                               sabrContexts: contexts,
                                               activeTypes: activeTypes,
                                               buffered: buffered,
                                               formatsInitialized: formatsInitialized,
                                               sendPreferredFormat: sendPreferredFormat,
                                               clientVersion: clientVersion,
                                               visitorData: sessionVisitorData,
                                               acceptLanguage: acceptLanguage)
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.yt-ump", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw SABRError.rejected(status: status) }

        return consume(UMPReader.parseDetailed(data))
    }

    /// 応答を取り込み、メディアをファイル本体へ書き込む。
    private func consume(_ parsed: UMPReader.ParseResult) -> RoundTrip {
        var result = RoundTrip()
        var headers: [UMPMediaHeader] = []

        for part in parsed.parts {
            switch UMPPartType(rawValue: part.type) {
            case .mediaHeader:
                let header = UMPMediaHeader(part.payload)
                // 要求した itag 以外は、そのヘッダに属する MEDIA だけ捨てる。
                // まとめて捨てると、正しい形式まで取りこぼす。
                if let received = header.itag, received != itag {
                    if let id = header.headerID { rejectedHeaderIDs.insert(id) }
                    if !hasUnexpectedFormat {
                        hasUnexpectedFormat = true
                        EventLog.log(.resolveNG, videoID: videoID,
                                     message: "SABR: 要求と違う形式が混ざっている "
                                         + "(要求 itag=\(itag) / 受信 itag=\(received))"
                                         + " — その分だけ捨てる")
                    }
                    break
                }
                if let id = header.headerID { rejectedHeaderIDs.remove(id) }
                headers.append(header)
                if let id = header.headerID {
                    // このヘッダに属するデータをどこへ書くか
                    let target = header.startRange ?? fileData.count
                    writeOffsets[id] = target
                    if headerLog.count < 30 {
                        headerLog.append("id=\(id) 連番=\(header.sequenceNumber ?? -1)"
                                         + " 位置=\(target)"
                                         + " 長さ=\(header.contentLength ?? -1)"
                                         + (header.isInitSegment == true ? " 初期化" : ""))
                    }
                    if header.sequenceNumber == 0 || header.isInitSegment == true {
                        sawInitSegment = true
                    }
                    // 同じ連番を二重に数えないようにする。
                    // 初期化セグメント (連番なし) は時間を持たないので除く。
                    if let seq = header.sequenceNumber, seq > 0,
                       !downloadedSegments.contains(seq) {
                        downloadedSegments.insert(seq)
                        downloadedDurationMs += header.durationMs ?? 0
                    }
                }

            case .media:
                // 先頭 1 バイトは header_id。残りが本体。
                guard part.payload.count > 1, let id = part.payload.first else { break }
                // 想定と違う形式のデータは混ぜない。
                // 混ざると mp4 の途中に WebM が入り、まるごと壊れる。
                guard !rejectedHeaderIDs.contains(Int(id)) else { break }
                let payload = part.payload.dropFirst()
                let offset = writeOffsets[Int(id)] ?? fileData.count
                write(payload, at: offset)
                writeOffsets[Int(id)] = offset + payload.count
                result.mediaBytes += payload.count

            case .formatInitializationMetadata:
                // FormatInitializationMetadata {
                //   mime_type = 5, init_range = 6, index_range = 7, ... }
                formatsInitialized = true
                var reader = ProtobufReader(part.payload)
                while let (field, value) = reader.next() {
                    if field == 6, let payload = value.data {
                        // misc.Range { start = 3, end = 4 }
                        var inner = ProtobufReader(payload)
                        var start: Int?
                        var end: Int?
                        while let (f, v) = inner.next() {
                            if f == 3 { start = v.int }
                            if f == 4 { end = v.int }
                        }
                        initRange = "\(start ?? -1)〜\(end ?? -1)"
                    }
                }

            case .sabrContextUpdate:
                if let ctx = SABRProbe.parseContextUpdate(part.payload) {
                    contexts[ctx.type] = ctx
                    if ctx.sendByDefault { activeTypes.insert(ctx.type) }
                }

            case .sabrContextSendingPolicy:
                var reader = ProtobufReader(part.payload)
                while let (field, value) = reader.next() {
                    guard let type = value.int else { continue }
                    switch field {
                    case 1: activeTypes.insert(type)
                    case 2: activeTypes.remove(type)
                    case 3: contexts.removeValue(forKey: type); activeTypes.remove(type)
                    default: break
                    }
                }

            case .streamProtectionStatus:
                // StreamProtectionStatus { status = 1, max_retries = 2 }
                var reader = ProtobufReader(part.payload)
                while let (field, value) = reader.next() {
                    if field == 1 { result.protectionStatus = value.int }
                }

            case .nextRequestPolicy:
                // NextRequestPolicy {
                //   target_audio_readahead_ms = 1, target_video_readahead_ms = 2,
                //   max_time_since_last_request_ms = 3, backoff_time_ms = 4,
                //   min_audio_readahead_ms = 5, min_video_readahead_ms = 6,
                //   playback_cookie = 7, video_id = 8 }
                var reader = ProtobufReader(part.payload)
                while let (field, value) = reader.next() {
                    switch field {
                    case 1: result.policyNotes.append("音声先読み=\(value.int ?? 0)")
                    case 3: result.policyNotes.append("要求間隔上限=\(value.int ?? 0)")
                    case 4:
                        result.backoffMs = value.int ?? 0
                        result.policyNotes.append("待機=\(value.int ?? 0)")
                    case 5: result.policyNotes.append("音声先読み下限=\(value.int ?? 0)")
                    case 7:
                        if let cookie = value.data, !cookie.isEmpty {
                            playbackCookie = cookie
                            result.policyNotes.append("cookie=\(cookie.count)B")
                        }
                    default: result.policyNotes.append("field\(field)")
                    }
                }

            default:
                // 見えていない指示があるかもしれないので中身を残す
                if result.rawDumps.count < 6 {
                    let hex = part.payload.prefix(40)
                        .map { String(format: "%02x", $0) }.joined()
                    result.rawDumps.append("type=\(part.type)/\(part.payload.count)B:\(hex)")
                }
            }
        }

        var counts: [String: Int] = [:]
        for part in parsed.parts {
            counts[UMPPartType(rawValue: part.type)?.label ?? "UNKNOWN(\(part.type))",
                   default: 0] += 1
        }
        result.partSummary = counts.sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }.joined(separator: " ")

        if let first = headers.first, let last = headers.last {
            let latest = SABRProbe.BufferedRange(
                startTimeMs: first.startMs ?? 0,
                durationMs: headers.reduce(0) { $0 + ($1.durationMs ?? 0) },
                startSegmentIndex: first.sequenceNumber ?? 1,
                endSegmentIndex: last.sequenceNumber ?? 1,
                timescale: first.timescale
            )
            // ── rev.85: 累積にする ─────────────────────────────────
            //
            // 直近 1 往復ぶんだけを返していたので、3 往復目でも
            // 「セグメント 5〜6 を持っている」としか伝わらなかった。
            // 公式のキャッシュ metadata は 1 から末尾まで連番で
            // 隙間なく並んでおり、先頭からの保持を申告している。
            if cumulativeBuffered != nil {
                cumulativeBuffered?.extend(with: latest)
            } else {
                cumulativeBuffered = latest
            }
            result.buffered = cumulativeBuffered
        }
        return result
    }

    /// 指定位置へ書き込む。足りなければ 0 で埋めて伸ばす。
    /// 指定位置へ書き込む。足りなければ 0 で埋めて伸ばす。
    ///
    /// `payload` が既存領域をはみ出す場合、重なる部分を置き換えてから
    /// 残りを追記する。`replaceSubrange` に長い方をそのまま渡すと
    /// 後続のバイトが押し出されて位置がずれるので、必ず長さを合わせる。
    private func write(_ payload: Data, at offset: Int) {
        // スライスは開始位置が 0 とは限らないので正規化する
        let bytes = Data(payload)
        guard !bytes.isEmpty else { return }
        writtenRanges.append((offset, offset + bytes.count))

        // 隙間を 0 で埋める
        if offset > fileData.count {
            fileData.append(Data(repeating: 0, count: offset - fileData.count))
        }

        // 既存部分と重なるところを置き換える
        let overlapEnd = min(offset + bytes.count, fileData.count)
        if overlapEnd > offset {
            let overlap = overlapEnd - offset
            fileData.replaceSubrange(offset..<overlapEnd, with: bytes.prefix(overlap))
        }

        // はみ出した分を追記する
        if offset + bytes.count > fileData.count {
            let already = max(fileData.count - offset, 0)
            fileData.append(bytes.suffix(bytes.count - already))
        }
    }
}
