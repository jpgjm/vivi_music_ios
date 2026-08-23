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

    /// SABR セッションが「誰として」流れるか。
    ///
    /// ── なぜ要るのか ────────────────────────────────────────
    /// SABR の `streamerContext.client_info` は、`player` を叩いた相手と
    /// 一致していなければならない。ここが食い違うと、サーバーから見て
    /// 「player を叩いた相手」と「メディアを取りに来た相手」が別人になり、
    /// 認証 (StreamProtectionStatus) が通らない。
    ///
    /// これまでは WEB 固定 (client_name = 1) で組み立てていた。
    /// TVHTML5 + OAuth でセッションを張るには TV として名乗る必要があるので、
    /// 素性を引数で渡せるようにする。
    struct ClientIdentity {
        /// `client_info.client_name`。WEB=1 / TVHTML5=7。
        var clientNameID: Int
        /// `client_info.client_version`。player 要求で送ったものと同じ値。
        var clientVersion: String
        /// `client_info.os_name` / `os_version`。
        /// WEB では送っていないので nil のまま。
        var osName: String?
        var osVersion: String?
        /// TV として名乗るか。`ClientAbrState` の形が変わる。
        var isTV: Bool = false

        /// 従来どおりの WEB。
        static func web(version: String) -> ClientIdentity {
            ClientIdentity(clientNameID: 1, clientVersion: version)
        }

        /// 居間のテレビ。os_name / os_version は Cobalt のもの。
        /// Opaline が実機セッションから採寸した値と同じ。
        static func tv(version: String) -> ClientIdentity {
            ClientIdentity(clientNameID: 7,
                           clientVersion: version,
                           osName: "Cobalt",
                           osVersion: "22.lts.3.306369-gold",
                           isTV: true)
        }
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
                          poToken: String?,
                          playbackCookie: Data?,
                          sabrContexts: [Int: SabrContext],
                          activeTypes: Set<Int>,
                          buffered: BufferedRange?,
                          formatsInitialized: Bool,
                          sendPreferredFormat: Bool = true,
                          identity: ClientIdentity) -> Data {
        buildRequestBody(ustreamerConfig: ustreamerConfig,
                         itag: itag,
                         lastModified: lastModified,
                         playerTimeMs: playerTimeMs,
                         poToken: poToken,
                         playbackCookie: playbackCookie,
                         contextMode: .full,
                         bufferedMode: .empty,
                         buffered: buffered,
                         sabrContexts: sabrContexts,
                         activeTypes: activeTypes,
                         formatsInitialized: formatsInitialized,
                         sendPreferredFormat: sendPreferredFormat,
                         identity: identity)
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
                                         poToken: String?,
                                         playbackCookie: Data?,
                                         contextMode: ContextMode,
                                         bufferedMode: BufferedMode,
                                         buffered: BufferedRange?,
                                         sabrContexts: [Int: SabrContext],
                                         activeTypes: Set<Int>,
                                         formatsInitialized: Bool,
                                         sendPreferredFormat: Bool,
                                         identity: ClientIdentity) -> Data {
        var writer = ProtobufWriter()

        // 1: ClientAbrState
        writer.write(field: 1) { state in
            // ── TV として名乗るときだけ足す項目 ────────────────────
            //
            // Opaline が実機の TV セッションから採寸した形
            // (TVClient.sabrAbrState)。視野角・可視状態・デコード上限など、
            // 「テレビらしさ」を示す項目が並ぶ。
            // 欠けていると別のクライアントと見なされる恐れがあるので、
            // 番号と値をそのまま写している。
            //
            // ただし 2 点だけ向こうと違える:
            //   ・38 (media_capabilities) と 40 (enabled_track_types) は残す。
            //     Opaline は映像も受け取るので送っていないが、
            //     ViviMusic は音声だけが要る。外すと itag 251 (opus) や
            //     映像まで降ってきて、AVFoundation が開けなくなる。
            if identity.isTV {
                state.write(field: 18, int: 1_920)   // client_viewport_width
                state.write(field: 19, int: 1_080)   // client_viewport_height
                state.write(field: 21, int: 0)       // sticky_resolution
            }
            // 28: player_time_ms — ここを動かすと「その時刻から送れ」になる
            state.write(field: 28, int: playerTimeMs)
            // 36: elapsed_wall_time_ms
            state.write(field: 36, int: playerTimeMs)
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
            if identity.isTV {
                state.write(field: 34, int: 0)       // visibility (TV は 0)
                state.write(field: 46, bool: true)   // drc_enabled
                state.write(field: 58, bool: false)  // prefer_vp9
                state.write(field: 59, int: 1_080)   // av1_quality_threshold
                state.write(field: 72, bytes: tvDecodeCeilings())
                state.write(field: 73, int: 2)
                state.write(field: 79, bytes: tvTrackAuthorization())
                state.write(field: 80, int: 1)
                state.write(field: 85, int: 1)
            }
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
            context.write(field: 1) { info in
                info.write(field: 16, int: identity.clientNameID)     // client_name
                info.write(field: 17, string: identity.clientVersion) // client_version
                if let osName = identity.osName {
                    info.write(field: 18, string: osName)
                }
                if let osVersion = identity.osVersion {
                    info.write(field: 19, string: osVersion)
                }
                // TV はロケールと画面の情報まで名乗る。
                // Opaline の SABRClientInfo.commonTail() と同じ並び。
                // WEB では従来どおり送らない (送っていない状態で
                // 69 秒まで通っている実績があるので触らない)。
                if identity.isTV {
                    info.write(field: 21, string: "en-US")
                    info.write(field: 22, string: "US")
                    info.write(field: 37, int: 1_920)
                    info.write(field: 38, int: 1_080)
                    info.write(field: 41, int: 1)
                    info.write(field: 46, int: 2)
                    info.write(field: 55, int: 1_920)
                    info.write(field: 56, int: 1_080)
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

    /// TV が申告する「ここまでなら復号できる」上限 (ClientAbrState 72)。
    /// 実機のテレビは 1080 を名乗る。音声しか要らなくても、
    /// テレビとして通る形をそのまま送る。
    private static func tvDecodeCeilings() -> Data {
        var writer = ProtobufWriter()
        writer.write(field: 1, int: 0)
        writer.write(field: 2, int: 1_080)
        writer.write(field: 3, int: 0)
        writer.write(field: 4, int: 0)
        writer.write(field: 5, int: 1_080)
        writer.write(field: 6, int: 0)
        return writer.data
    }

    /// TV が受け取ってよいトラック種別 (ClientAbrState 79)。
    /// 音声 / SDR 映像 / HDR 映像 の 3 つ。実機は毎回この 3 件を送る。
    private static func tvTrackAuthorization() -> Data {
        var writer = ProtobufWriter()
        for entry in [(1, false), (2, false), (2, true)] {
            var format = ProtobufWriter()
            format.write(field: 1, int: entry.0)    // track_type
            format.write(field: 2, bool: entry.1)   // is_hdr
            writer.write(field: 1, bytes: format.data)
        }
        return writer.data
    }

}
