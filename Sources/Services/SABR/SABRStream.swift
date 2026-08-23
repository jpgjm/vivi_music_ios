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

    /// このセッションが誰として流れるか。
    /// `prepare()` でログイン状態を見て決める。
    private var identity = SABRProbe.ClientIdentity.web(version: WebClientVersion.fallback)

    /// TV として張ったセッションか (ログや URL の飾りつけに使う)。
    private var isTV = false

    /// この再生セッションの識別子。実機の TV は毎回作って URL に付ける。
    private let cpn = SABRStream.makeCPN()

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
        // ── 2026-08-14 に直した点 ────────────────────────────
        //
        // 以前は buffered_ranges に「先頭からの累積」を入れていた。
        //   startTimeMs=0 / durationMs=69000 / seg 1〜7
        // これだと 7 セグメント (69 秒) でサーバーが送るのをやめる。
        //
        // 公式実装を読むと、送るのは **直近の応答で受け取ったぶんだけ**
        // だった。`lastMediaHeaders` は 1 往復ごとに空にしており、
        // 累積は `player_time_ms` (= これまでに落とした合計時間) が担う。
        //
        //   playerTimeMs   … 累積 (getTotalDownloadedDuration)
        //   bufferedRanges … 直近の受信ぶんのみ
        //
        // 役割が分かれているのに両方へ累積を入れていたので、
        // サーバーからは「同じ範囲を何度も持っていると言ってくる」
        // ように見えていたと思われる。
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
                EventLog.log(.resolveNG, videoID: videoID,
                             message: "SABR: \(stalledRounds) 往復続けて前進せず打ち切り "
                                 + "(取得済み \(fileData.count / 1024)KiB "
                                 + "/ \(downloadedDurationMs / 1000)秒 "
                                 + "/ 保護=\(next.protectionStatus.map(String.init) ?? "-"))")
                // 保護状態 2 は「認証待ち」で、約 1 分ぶんのプレビューを
                // 配ったところで打ち切られる (YouTube 側の仕様)。
                // トークンの種類や要求の形を変えても外れないことは
                // 実測で確認済みなので、ここでは触らない。
                //
                // 代わりに visitorData を引き直しておく。
                // 制限は訪問者アイデンティティ単位でかかっているらしく、
                // 次の曲で制限のかかっていないものが当たることがある。
                //
                // TV セッションでは引き直さない。TV の認証は
                // livingRoomPoTokenId に紐づいており、visitorData とは
                // 別系統だからで、捨てても得るものがない。
                if !isTV, (next.protectionStatus ?? 0) >= 2 {
                    await InnerTube.shared.renewVisitorData()
                    EventLog.log(.network, videoID: videoID,
                                 message: "SABR: 認証待ちの上限に達した。"
                                     + "次に備えて visitorData を引き直す")
                }
                if isTV, (next.protectionStatus ?? 0) >= 2 {
                    EventLog.log(.resolveNG, videoID: videoID,
                                 message: "SABR: TV として名乗ったが認証待ちのまま"
                                     + "打ち切られた。poToken か n 変換のどちらかが"
                                     + "受け付けられていない")
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
        // ── どのクライアントで SABR セッションを張るか ────────────────
        //
        // ログイン済みなら TVHTML5 + OAuth。
        //
        //   匿名の SABR は `StreamProtectionStatus = 2` (認証待ち) のまま
        //   約 1.08 MiB / 69 秒で打ち切られる。これは実測で確認済みで、
        //   トークンの種類や要求の形をいくら変えても外れなかった。
        //   打ち切りを外すには **アカウントとして認証される**必要がある。
        //
        //   OAuth のデバイスフローで得たトークンを載せられるのは
        //   TVHTML5 だけなので、ログイン中はこのクライアントで張る。
        //   Opaline も同じ構成 (tv.sabr) で 1 分の壁を越えている。
        //
        // 未ログインなら従来どおり WEB。69 秒で止まるが、
        // まったく鳴らないよりはましなので残す。
        let signedIn = await GoogleAuthService.shared.isSignedIn
        let client: YouTubeClient = signedIn ? .tvhtml5 : .web
        isTV = signedIn

        let raw = try await InnerTube.shared.player(videoID: videoID, client: client)

        // 認証済みでも TV が拒否することはある (年齢制限など)。
        // その場合は WEB に落として、せめて 69 秒ぶんは鳴らす。
        let status = raw["playabilityStatus"]["status"].string ?? ""
        var response = raw
        if isTV, status != "OK" {
            let reason = raw["playabilityStatus"]["reason"].string ?? status
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "SABR: TVHTML5 が拒否 (\(reason))。WEB で張り直す")
            isTV = false
            response = try await InnerTube.shared.player(videoID: videoID, client: .web)
        }

        guard let rawURL = response["streamingData"]["serverAbrStreamingUrl"].string,
              let config = response.path("playerConfig", "mediaCommonConfig",
                                         "mediaUstreamerRequestConfig",
                                         "videoPlaybackUstreamerConfig").string else {
            throw SABRError.missingConfig
        }

        // `n=` が変換前で降ってくるので必ず復号を通す。
        // ここを飛ばすと入口で 403 になる。
        //
        // ── TV の n について (2026-08-23 の調査) ──────────────────
        //
        // TV の serverAbrStreamingUrl にも `n` が付く。ところが TV が
        // 実際に走らせている player (tv-player-ias-tcl) を読むと、
        // 署名復号関数も n 変換関数も **JS としては存在しない**。
        // `__indirect_function_table` / `dynCall_` があり、WASM に
        // 移っている。JavaScriptCore で切り出す今の方式では取り出せない。
        //
        // ここでは WEB の base.js の変換を当てる。TV の n がそれで
        // 通るかは未検証なので、通らなかったときに分かるようログに残す。
        // (`n` は sparams に入っていない = 署名の対象外なので、
        //  認証さえ通れば拒否ではなく減速で済む可能性もある)
        abrURL = await PlayerJSService.shared.decipher(rawURL)
        ustreamerConfig = config

        // player を叩いたときと同じ clientVersion を控える。
        // ハードコードしていると食い違い、認証が通らない恐れがある。
        if isTV {
            clientVersion = await TVPlayerInfo.shared.clientVersion()
            identity = SABRProbe.ClientIdentity.tv(version: clientVersion)
        } else {
            clientVersion = await WebClientVersion.shared.current()
            identity = SABRProbe.ClientIdentity.web(version: clientVersion)
        }
        EventLog.log(.network, videoID: videoID,
                     message: "SABR: \(isTV ? "TVHTML5 (OAuth)" : "WEB (匿名)") "
                         + "clientVersion=\(clientVersion) を使用"
                         + (isTV ? "" : " / 69 秒で頭打ちになる見込み"))

        let audio = response["streamingData"]["adaptiveFormats"].array.filter {
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

        await prepareTokens()

        EventLog.log(.resolveOK, videoID: videoID,
                     message: "SABR 準備完了 itag=\(itag) "
                         + "全長 \(totalLength / 1024)KiB")
    }

    /// SABR 要求に載せる poToken を用意する。
    ///
    /// 紐づけ先はセッションの張り方で変わる:
    ///   TVHTML5 + OAuth … livingRoomPoTokenId
    ///     player 要求の `tvAppInfo.livingRoomPoTokenId` と同じ ID。
    ///     テレビは「この居間の機械である」ことを証明する形になっており、
    ///     ID が食い違えば認証は成立しない。
    ///   WEB (匿名)       … 従来どおり visitorData / dataSyncId
    private func prepareTokens() async {
        if isTV {
            let deviceID = TVDeviceIdentity.livingRoomPoTokenId
            guard let sessionID = await InnerTube.shared.visitorData else {
                EventLog.log(.resolveNG, videoID: videoID,
                             message: "SABR: visitorData がまだ無く poToken を作れない")
                return
            }
            let pair = await PoTokenService.shared.tokens(videoID: videoID,
                                                         sessionID: sessionID,
                                                         binding: .livingRoom(deviceID))
            poToken = pair?.streaming
            // TV では切り替え先を持たない。videoId 紐づけは
            // 「居間の機械の証明」にはならないため。
            videoBoundToken = nil
            tokenKind = "livingRoomPoTokenId"
            EventLog.log(.auth, videoID: videoID,
                         message: "SABR: TV 用 poToken を"
                             + (poToken == nil ? "作れなかった" : "用意した")
                             + " (紐づけ: livingRoomPoTokenId \(deviceID))")
            return
        }

        // poToken を用意する。
        //
        // SABR では `StreamProtectionStatus.status = 2` (認証待ち) のまま
        // 約 1.08 MiB で打ち切られていた。visitorData 紐づけのトークンが
        // 受け付けられていないので、**videoId 紐づけ**でも作って
        // 両方を順に試せるようにする。
        if let sessionID = await InnerTube.shared.visitorData {
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
        }
    }

    /// 実機の TV が毎回作る再生セッション識別子 (16 文字)。
    private static func makeCPN() -> String {
        let alphabet = Array(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        return String((0..<16).map { _ in alphabet.randomElement() ?? "A" })
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
        // 実機の TV が付ける 2 つ。応答の URL には入っていない。
        //   cpn … 再生セッションの識別子 (1 曲につき 1 つ)
        //   alr … 「リダイレクトで返してよい」の申告
        // Opaline の SABRDelivery.televisionParams と同じ。
        if isTV {
            items.removeAll { $0.name == "cpn" || $0.name == "alr" }
            items.append(URLQueryItem(name: "cpn", value: cpn))
            items.append(URLQueryItem(name: "alr", value: "yes"))
        }
        components.queryItems = items
        requestNumber += 1

        guard let url = components.url else { throw SABRError.missingConfig }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = SABRProbe.buildBody(ustreamerConfig: ustreamerConfig,
                                               itag: itag,
                                               lastModified: lastModified,
                                               playerTimeMs: playerTimeMs,
                                               poToken: activeToken,
                                               playbackCookie: playbackCookie,
                                               sabrContexts: contexts,
                                               activeTypes: activeTypes,
                                               buffered: buffered,
                                               formatsInitialized: formatsInitialized,
                                               sendPreferredFormat: sendPreferredFormat,
                                               identity: identity)
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.yt-ump", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // メディアを取りに行く相手も player を叩いた相手と揃える。
        // TV を名乗ったのに Firefox の UA で取りに行けば素性が食い違う。
        request.setValue(isTV ? YouTubeClient.userAgentWebOSTV
                              : YouTubeClient.userAgentWeb,
                         forHTTPHeaderField: "User-Agent")
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
            result.buffered = SABRProbe.BufferedRange(
                startTimeMs: first.startMs ?? 0,
                durationMs: headers.reduce(0) { $0 + ($1.durationMs ?? 0) },
                startSegmentIndex: first.sequenceNumber ?? 1,
                endSegmentIndex: last.sequenceNumber ?? 1,
                timescale: first.timescale
            )
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
