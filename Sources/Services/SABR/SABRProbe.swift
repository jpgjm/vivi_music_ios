//
//  SABRProbe.swift
//  ViviMusic
//
//  SABR リクエストの組み立てと、そこで使う型の置き場。
//
//  ── 経緯 ────────────────────────────────────────────────
//  もとは「SABR なら 1 MiB 制限を越えて取れるか」を 1 往復だけ
//  測る実験だった。結論が出た (越えられるが、未認証セッションでは
//  69 秒あたりで頭打ちになる) ので、rev.79 で実験部分は撤去した。
//
//  いま残っているのは SABRStream が使う部分だけ:
//    ・BufferedRange / SabrContext … 往復のあいだ持ち回る型
//    ・buildBody              … VideoPlaybackAbrRequest を組む
//    ・parseContextUpdate     … SABR_CONTEXT_UPDATE を読む
//
//  移植元: googlevideo (LuanRT) の SabrStream.buildRequestBody
//

import Foundation

/// SABR の共有部品。
///
/// 元は「SABR が 1 MiB 制限を回避できるか」を確かめる実験だったが、
/// 目的を果たしたので実験部分は撤去した。
/// リクエストの組み立てと型定義は `SABRStream` が使うので残している。
enum SABRProbe {

    /// MediaCapabilities.AudioFormatCapability.audio_codec に入れる値。
    ///
    /// YouTube 内部の番号で、公開された対応表は無い。
    /// AAC を指す想定で 1 を使う。効果が無ければ他の値を試す余地がある。
    static let audioCodecAAC = 1

    /// コンテキストをどう返すか。
    ///
    /// `sabr.malformed_config` の原因を切り分けるために用意した。
    /// 中身の書き方が悪いのか、そもそも返すべきでないのかを分ける。
    enum ContextMode: String {
        /// 何も載せない (待機だけ従う)
        case none = "載せない"
        /// 番号だけ伝える
        case unsentOnly = "番号のみ"
        /// type と value を正しい番号で返す
        case full = "正しい番号で返す"
    }

    /// buffered_ranges の書き方。
    ///
    /// 公式実装は「まだ何も持っていない」ときは **空配列** を送る。
    /// 私は長さ 0 の範囲を 1 つ入れていたので、そこも疑って比べられるようにする。
    enum BufferedMode: String {
        case empty = "空"
        case zeroRange = "長さ0の範囲"
    }

    /// これまでに受け取った範囲。次の要求に「ここまで持っている」と伝える。
    ///
    /// SABR は **バイト位置ではなくセグメント番号**で進む。
    /// 受け取った MEDIA_HEADER から範囲を組み立てて返さないと、
    /// サーバーは次に何を送るべきか判断できない。
    struct BufferedRange {
        var startTimeMs: Int
        var durationMs: Int
        var startSegmentIndex: Int
        var endSegmentIndex: Int
        var timescale: Int?

        /// 直近の応答ぶんを取り込んで、累積の範囲に広げる。
        ///
        /// ── なぜ累積にするのか ────────────────────────────────
        /// 公式 iOS アプリのキャッシュ (`Media/CacheV2` の
        /// `cache_metadata`) を解析したところ、1 曲を通して
        /// **セグメント 1 から末尾までが連番で隙間なく**並んでいた。
        /// 公式は「先頭からここまで持っている」を伝え続けている。
        ///
        /// 以前このコードは直近 1 往復ぶんだけを送っていた。
        /// 3 往復目でも「セグメント 5〜6 を持っている」としか伝わらず、
        /// サーバーから見ると断片的にしか保持していないクライアントに
        /// 見える。`NextRequestPolicy` の先読み量が絞られる原因になる。
        ///
        /// - Note: 累積にすると 69 秒で止まるという観測が rev.72 頃に
        ///   あったが、あれは `player_time_ms` にも同じ累積を入れて
        ///   二重に申告していたため。`player_time_ms` は
        ///   `downloadedDurationMs` が担い、こちらは範囲だけを表す。
        mutating func extend(with latest: BufferedRange) {
            let newStartSegment = min(startSegmentIndex, latest.startSegmentIndex)
            let newEndSegment = max(endSegmentIndex, latest.endSegmentIndex)
            let newStartTime = min(startTimeMs, latest.startTimeMs)
            let end = max(startTimeMs + durationMs,
                          latest.startTimeMs + latest.durationMs)

            startSegmentIndex = newStartSegment
            endSegmentIndex = newEndSegment
            startTimeMs = newStartTime
            durationMs = max(0, end - newStartTime)
            if timescale == nil { timescale = latest.timescale }
        }
    }

    /// サーバーから渡される SABR コンテキスト。
    ///
    /// `SABR_CONTEXT_UPDATE` (パート 57) で降ってきて、
    /// **次の要求の StreamerContext.sabr_contexts に返す**決まり。
    /// 返さないとサーバーは同じ指示を繰り返すだけで、メディアを送らない。
    struct SabrContext {
        var type: Int
        var scope: Int?
        var value: Data
        var sendByDefault: Bool
        var writePolicy: Int?

        var scopeLabel: String {
            switch scope {
            case 1: return "PLAYBACK"
            case 2: return "REQUEST"
            case 3: return "WATCH_ENDPOINT"
            case 4: return "CONTENT_ADS"
            default: return "不明(\(scope.map(String.init) ?? "-"))"
            }
        }
    }

    // MARK: - リクエストの組み立て

    /// `VideoPlaybackAbrRequest` を組み立てる。
    ///
    /// フィールド番号の出典:
    ///   protos/video_streaming/video_playback_abr_request.proto
    ///     1  client_abr_state
    ///     2  selected_format_ids
    ///     3  buffered_ranges
    ///     5  video_playback_ustreamer_config
    ///     16 preferred_audio_format_ids
    ///     19 streamer_context
    /// 呼び出し元は `SABRStream` だけ。引数はすべて明示する。
    static func buildBody(ustreamerConfig: String,
                          itag: Int,
                          lastModified: UInt64,
                          playerTimeMs: Int,
                          elapsedWallTimeMs: Int,
                          poToken: String?,
                          playbackCookie: Data?,
                          sabrContexts: [Int: SabrContext],
                          activeTypes: Set<Int>,
                          buffered: BufferedRange?,
                          formatsInitialized: Bool,
                          sendPreferredFormat: Bool = true,
                          clientVersion: String,
                          visitorData: String?,
                          acceptLanguage: String?) -> Data {
        buildRequestBody(ustreamerConfig: ustreamerConfig,
                         itag: itag,
                         lastModified: lastModified,
                         playerTimeMs: playerTimeMs,
                         elapsedWallTimeMs: elapsedWallTimeMs,
                         poToken: poToken,
                         playbackCookie: playbackCookie,
                         contextMode: .full,
                         bufferedMode: .empty,
                         buffered: buffered,
                         sabrContexts: sabrContexts,
                         activeTypes: activeTypes,
                         formatsInitialized: formatsInitialized,
                         sendPreferredFormat: sendPreferredFormat,
                         clientVersion: clientVersion,
                         visitorData: visitorData,
                         acceptLanguage: acceptLanguage)
    }

    /// SABR_CONTEXT_UPDATE を読む。実験と本番で共用する。
    static func parseContextUpdate(_ payload: Data) -> SabrContext? {
        var reader = ProtobufReader(payload)
        var type: Int?
        var scope: Int?
        var value: Data?
        var sendByDefault = false
        var writePolicy: Int?
        while let (field, v) = reader.next() {
            switch field {
            case 1: type = v.int
            case 2: scope = v.int
            case 3: value = v.data
            case 4: sendByDefault = v.bool ?? false
            case 5: writePolicy = v.int
            default: break
            }
        }
        guard let type, let value, !value.isEmpty else { return nil }
        return SabrContext(type: type, scope: scope, value: value,
                           sendByDefault: sendByDefault, writePolicy: writePolicy)
    }

    private static func buildRequestBody(ustreamerConfig: String,
                                         itag: Int,
                                         lastModified: UInt64,
                                         playerTimeMs: Int,
                                         elapsedWallTimeMs: Int,
                                         poToken: String?,
                                         playbackCookie: Data?,
                                         contextMode: ContextMode,
                                         bufferedMode: BufferedMode,
                                         buffered: BufferedRange?,
                                         sabrContexts: [Int: SabrContext],
                                         activeTypes: Set<Int>,
                                         formatsInitialized: Bool,
                                         sendPreferredFormat: Bool,
                                         clientVersion: String,
                                         visitorData: String?,
                                         acceptLanguage: String?) -> Data {
        var writer = ProtobufWriter()

        // 1: ClientAbrState
        writer.write(field: 1) { state in
            // 28: player_time_ms — ここを動かすと「その時刻から送れ」になる
            state.write(field: 28, int: playerTimeMs)
            // 36: elapsed_wall_time_ms
            //
            // ── rev.85 で直した点 ────────────────────────────────
            // ここには **セッション開始からの実経過時間** を入れる。
            // player_time_ms (メディア内の再生位置) とは別物。
            //
            // 以前は両方に playerTimeMs を入れていた。そうすると
            // サーバーからは「壁時計時間と再生位置が寸分違わず一致する
            // = 実時間ちょうど 1.000 倍速で進んでいる」ように見える。
            // 実際の再生では必ずズレるので、これは人間が再生していない
            // ことを示す分かりやすい指紋になってしまう。
            //
            // 公式クライアントは取得を先行させる (先読みする) ので、
            // 通常は player_time_ms < elapsed_wall_time_ms にはならず、
            // むしろ player_time_ms のほうが先に進む。
            state.write(field: 36, int: elapsedWallTimeMs)
            // 38: media_capabilities
            //
            // 「この端末が再生できる形式」を申告する。
            // SABR は Server *Adaptive* BitRate の名のとおり
            // サーバーが最終的な形式を決めるので、
            // opus を再生できないことを伝えておかないと
            // itag 251 (webm/opus) を送られる恐れがある。
            //
            // MediaCapabilities {
            //   video_format_capabilities = 1
            //   audio_format_capabilities = 2   ← AudioFormatCapability
            //   hdr_mode_bitmask = 5 }
            //
            // AudioFormatCapability {
            //   audio_codec = 1, num_channels = 2,
            //   max_bitrate_bps = 3, spatial_capability_bitmask = 6 }
            //
            // audio_codec の番号は公開されていない。
            // itag 140 (AAC) だけを希望する意図で 1 を入れている。
            // 効かない場合は preferred_audio_format_ids 側で担保する。
            state.write(field: 38) { caps in
                caps.write(field: 2) { audio in
                    audio.write(field: 1, int: audioCodecAAC)
                    audio.write(field: 2, int: 2)             // ステレオ
                    audio.write(field: 3, int: 160_000)       // 上限ビットレート
                }
            }
            // 40: enabled_track_types_bitfield
            //     1 = 音声のみ (googlevideo の EnabledTrackTypes に合わせる)
            state.write(field: 40, int: 1)
        }

        // 2: selected_format_ids
        //
        // rev.57 ではこれを送っておらず、応答が制御パートだけ (105B) だった。
        // 「どの形式を選んだか」が伝わらないと、サーバーは何を送るか決められない。
        writer.write(field: 2) { format in
            format.write(field: 1, int: itag)
            format.write(field: 2, varint: lastModified)
        }

        // 3: buffered_ranges
        //
        // 「ここまで持っている」を伝える。まだ何も持っていないので
        // 長さ 0 の範囲を 1 つだけ入れる。
        // proto 上 start_time_ms / duration_ms / 各 segment_index は
        // required なので、0 でも明示的に書く必要がある。
        if let buffered {
            // 実際に受け取った範囲を伝える。
            // これが無いとサーバーは「まだ何も持っていない」と解釈し、
            // 毎回先頭のセグメントを送り直す (または何も送らない)。
            writer.write(field: 3) { range in
                range.write(field: 1) { format in
                    format.write(field: 1, int: itag)
                    format.write(field: 2, varint: lastModified)
                }
                range.write(field: 2, int: buffered.startTimeMs)
                range.write(field: 3, int: buffered.durationMs)
                range.write(field: 4, int: buffered.startSegmentIndex)
                range.write(field: 5, int: buffered.endSegmentIndex)
                if let timescale = buffered.timescale {
                    range.write(field: 6) { timeRange in
                        timeRange.write(field: 1, int: buffered.startTimeMs)
                        timeRange.write(field: 2, int: buffered.durationMs)
                        timeRange.write(field: 3, int: timescale)
                    }
                }
            }
        } else if bufferedMode == .zeroRange {
            writer.write(field: 3) { range in
                range.write(field: 1) { format in            // format_id
                    format.write(field: 1, int: itag)
                    format.write(field: 2, varint: lastModified)
                }
                range.write(field: 2, int: 0)                // start_time_ms
                range.write(field: 3, int: 0)                // duration_ms
                range.write(field: 4, int: 0)                // start_segment_index
                range.write(field: 5, int: 0)                // end_segment_index
            }
        }
        // .empty のときは field 3 を一切書かない。
        // 公式実装も、まだ何も持っていないときは空配列を渡している。

        // 16: preferred_audio_format_ids — misc.FormatId
        //
        // FORMAT_INITIALIZATION_METADATA が一度も返らないため、
        // ここを外すとどうなるかを切り分けられるようにしている。
        if sendPreferredFormat {
            writer.write(field: 16) { format in
                format.write(field: 1, int: itag)             // itag
                format.write(field: 2, varint: lastModified)  // last_modified
            }
        }

        // 5: video_playback_ustreamer_config (base64 → バイト列)
        if let config = decodeBase64URL(ustreamerConfig) {
            writer.write(field: 5, bytes: config)
        }

        // 19: StreamerContext
        writer.write(field: 19) { context in
            // 1: ClientInfo
            //
            // **player 要求と同じ値を送ること。**
            //
            // ここが食い違うと、サーバーから見て
            // 「player を叩いた相手」と「メディアを取りに来た相手」が
            // 別人になり、認証 (StreamProtectionStatus) が
            // 通らない可能性がある。
            //
            // rev.75 まで clientVersion をハードコードしていた
            // ("2.20260813.01.00")。実際に player へ送っている値は
            // WebClientVersion が www.youtube.com から取ってきたもので、
            // 一致している保証が無かった。
            // player 要求では os_name / os_version を送っていないので、
            // ここでも送らない。余計な項目で食い違うほうが危ない。
            //
            // ── rev.85 で追加: visitorData (フィールド 14) ─────────
            //
            // ここが最大の穴だった。
            // player 要求では context.client.visitorData を送っているのに、
            // SABR 要求では名乗っていなかった。サーバーから見ると
            // 「player を叩いた相手」と「メディアを取りに来た相手」が
            // 別セッションになる。
            //
            // 公式 iOS アプリのコンテナを解析したところ、公式は
            // 単一の visitorData を player と videoplayback の双方で
            // 一貫して名乗っており、それで 1 MiB 制限に当たらない。
            //
            // フィールド番号 14 の根拠:
            //   YouTube.app のバイナリから ObjC protobuf の
            //   GPBMessageFieldDescription 配列を抽出して確定した。
            //   再現手順は Tools/gpb_fields.py を参照。
            //     12 = deviceMake / 13 = deviceModel
            //     14 = visitorData  ★
            //     15 = userAgent / 16 = clientName / 17 = clientVersion
            //   (clientName=16 / clientVersion=17 が既存の実績値と
            //    一致することで、読み取り位置のずれが無いことを検算済み)
            context.write(field: 1) { info in
                info.write(field: 16, int: 1)                 // client_name = WEB
                info.write(field: 17, string: clientVersion)  // client_version
                if let visitorData, !visitorData.isEmpty {
                    info.write(field: 14, string: visitorData)
                }
                // 21: accept_language
                //
                // InnerTube 要求では Accept-Language ヘッダを送っているのに
                // ここでは何も名乗っていなかったので揃える。
                // 公式の ClientInfo にも同じフィールドがある。
                if let acceptLanguage, !acceptLanguage.isEmpty {
                    info.write(field: 21, string: acceptLanguage)
                }
            }
            // 2: po_token
            //
            // SABR の入口が 403 を返したので、認証が要ると見て入れる。
            // googlevideo も streamerContext.poToken に入れている。
            if let poToken, let bytes = decodeBase64URL(poToken) {
                context.write(field: 2, bytes: bytes)
            }
            // 3: playback_cookie
            //    サーバーが NEXT_REQUEST_POLICY で返してきたものを
            //    次の要求にそのまま返す決まり。空なら送らない。
            if let playbackCookie, !playbackCookie.isEmpty {
                context.write(field: 3, bytes: playbackCookie)
            }

            // 5: sabr_contexts / 6: unsent_sabr_contexts
            //
            // ここが rev.58 まで欠けていた部分。
            // サーバーは SABR_CONTEXT_UPDATE (パート 57) で
            // 「このコンテキストを次から付けて送れ」と指示してくる。
            // 返さないと同じ指示を繰り返すだけで、メディアが降りてこない。
            // (2026-08-14 実測: 105B の制御パートだけが毎回返ってきていた)
            // 5: sabr_contexts / 6: unsent_sabr_contexts
            //
            // ── ここを rev.59〜61 で間違えていた ──────────────────
            //
            // 受け取るときの型と返すときの型が **別物** だった。
            //
            //   受信: SabrContextUpdate {
            //           type = 1, scope = 2, value = 3,
            //           send_by_default = 4, write_policy = 5 }
            //
            //   送信: StreamerContext.SabrContext {
            //           type = 1, value = 2 }          ← 2 項目だけ
            //
            // 私は受信側の番号のまま返していたので、
            //   ・scope (int) を value (bytes) の位置に書いた
            //   ・value を存在しないフィールド 3 に書いた
            // となり、サーバーが sabr.malformed_config を返していた。
            //
            // 「載せない」「番号のみ」で正常応答が返り、
            // 中身を書いた 2 通りだけがエラーになった事実とも一致する。
            switch contextMode {
            case .none:
                break   // 何も載せない

            case .unsentOnly:
                for type in sabrContexts.keys.sorted() {
                    context.write(field: 6, int: type)
                }

            case .full:
                for (type, ctx) in sabrContexts.sorted(by: { $0.key < $1.key }) {
                    if activeTypes.contains(type) {
                        context.write(field: 5) { item in
                            item.write(field: 1, int: ctx.type)     // type
                            item.write(field: 2, bytes: ctx.value)  // value
                        }
                    } else {
                        context.write(field: 6, int: type)
                    }
                }
            }
        }

        return writer.data
    }

    /// base64 / base64url のどちらでも読めるようにする。
    private static func decodeBase64URL(_ text: String) -> Data? {
        var s = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

}
