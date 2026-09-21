//
//  UMPReader.swift
//  ViviMusic
//
//  UMP (Ultra Media Protocol) の読み取り。
//  SABR の応答はこの形式で返ってくる。
//
//  ── 形式 ────────────────────────────────────────────────
//  可変長整数で区切られたパートが並ぶだけの単純な構造。
//
//    [パート種別 (varint)][パート長 (varint)][本体 (パート長バイト)]
//    [パート種別 (varint)][パート長 (varint)][本体]
//    ...
//
//  ただし varint の書き方が protobuf と違う。
//  **先頭バイトの上位ビットで全体の長さが決まる**方式で、
//  下位バイトから順に値が入る (リトルエンディアン)。
//
//  移植元: googlevideo の `src/core/UmpReader.ts` (140 行)
//  https://github.com/LuanRT/googlevideo
//

import Foundation

/// UMP のパート種別。実験で見分けたいものだけ定義する。
/// 値の出典: googlevideo の `protos/video_streaming/ump_part_id.proto`
enum UMPPartType: Int {
    case onesieHeader = 10
    case onesieData = 11
    case mediaHeader = 20
    case media = 21
    case mediaEnd = 22
    case nextRequestPolicy = 35
    case formatInitializationMetadata = 42
    case sabrRedirect = 43
    case sabrError = 44
    case sabrSeek = 45
    case reloadPlayerResponse = 46
    case sabrContextUpdate = 57
    case streamProtectionStatus = 58
    case sabrContextSendingPolicy = 59
    case snackbarMessage = 67

    var label: String {
        switch self {
        case .onesieHeader:                 return "ONESIE_HEADER"
        case .onesieData:                   return "ONESIE_DATA"
        case .mediaHeader:                  return "MEDIA_HEADER"
        case .media:                        return "MEDIA"
        case .mediaEnd:                     return "MEDIA_END"
        case .nextRequestPolicy:            return "NEXT_REQUEST_POLICY"
        case .formatInitializationMetadata: return "FORMAT_INIT_METADATA"
        case .sabrRedirect:                 return "SABR_REDIRECT"
        case .sabrError:                    return "SABR_ERROR"
        case .sabrSeek:                     return "SABR_SEEK"
        case .reloadPlayerResponse:         return "RELOAD_PLAYER_RESPONSE"
        case .sabrContextUpdate:            return "SABR_CONTEXT_UPDATE"
        case .streamProtectionStatus:       return "STREAM_PROTECTION_STATUS"
        case .sabrContextSendingPolicy:     return "SABR_CONTEXT_SENDING_POLICY"
        case .snackbarMessage:              return "SNACKBAR_MESSAGE"
        }
    }
}

struct UMPPart {
    let type: Int
    let payload: Data

    var typeLabel: String {
        UMPPartType(rawValue: type)?.label ?? "UNKNOWN(\(type))"
    }
}

enum UMPReader {

    /// 与えられたバイト列からパートを切り出す。
    ///
    /// 実験では応答を全部受け取ってから解析するので、
    /// 途中で切れたパートは捨てる (本実装では持ち越しが要る)。
    /// 走査の結果。どこまで読めたかを呼び出し側が確認できるようにする。
    struct ParseResult {
        var parts: [UMPPart] = []
        /// 読み切れずに残ったバイト数。0 でなければ解釈を誤っている。
        var remaining = 0
        /// 各パートの (種別, 長さ) を順に記録したもの。診断用。
        var trace: [String] = []
    }

    static func parse(_ data: Data) -> [UMPPart] {
        parseDetailed(data).parts
    }

    /// パートを切り出しつつ、走査の様子も残す。
    ///
    /// 2026-08-14 に「本体 324KB なのに MEDIA を 64KiB しか数えていない」
    /// という食い違いが出た。どこで解釈がずれているかを見るために、
    /// 各パートの種別と長さ、読み残しを記録する。
    static func parseDetailed(_ data: Data) -> ParseResult {
        var result = ParseResult()
        var offset = data.startIndex

        while offset < data.endIndex {
            guard let (type, afterType) = readVarint(data, at: offset) else {
                result.trace.append("種別を読めず offset=\(offset)")
                break
            }
            guard let (size, afterSize) = readVarint(data, at: afterType) else {
                result.trace.append("長さを読めず offset=\(afterType)")
                break
            }

            let end = afterSize + Int(size)
            guard end <= data.endIndex else {
                result.trace.append("切れている type=\(type) 必要=\(size) "
                                    + "残り=\(data.endIndex - afterSize)")
                break
            }

            result.parts.append(UMPPart(type: Int(type),
                                        payload: data.subdata(in: afterSize..<end)))
            if result.trace.count < 20 {
                result.trace.append("\(type):\(size)")
            }
            offset = end
        }

        result.remaining = data.endIndex - offset
        return result
    }

    /// UMP の可変長整数を読む。
    ///
    /// protobuf の varint とは **別物**。
    /// 先頭バイトの値で全長が決まり、
    /// **先頭バイトの下位ビットが値の下位側**に来る。
    ///
    ///   1 バイト: 0xxxxxxx                → そのまま
    ///   2 バイト: 10xxxxxx b1             → (b0 & 0x3f) + 64 * b1
    ///   3 バイト: 110xxxxx b1 b2          → (b0 & 0x1f) + 32 * (b1 + 256 * b2)
    ///   4 バイト: 1110xxxx b1 b2 b3       → (b0 & 0x0f) + 16 * (b1 + 256*(b2 + 256*b3))
    ///   5 バイト: 1111xxxx b1 b2 b3 b4    → 続く 4 バイトのリトルエンディアン
    ///
    /// ── 2026-08-14 の誤り ────────────────────────────────
    /// 当初これを「先頭バイトの下位ビットが値の **上位**」と実装していた。
    /// 1 バイトと 2 バイトでは偶然一致するため気づけず、
    /// 大きな値でだけ壊れていた。
    ///   162191 (正) を 988108 と読む
    ///    66560 (正) を   2080 と読む
    /// MEDIA パートの長さを短く読み、次のパート開始位置がずれ、
    /// 存在しない種別 (243 など) と 1GB といった長さが現れていた。
    ///
    /// 移植元: googlevideo の `UmpReader.readVarInt`
    private static func readVarint(_ data: Data, at start: Int) -> (UInt64, Int)? {
        guard start < data.endIndex else { return nil }
        let first = data[start]

        let length: Int
        if first < 128       { length = 1 }
        else if first < 192  { length = 2 }
        else if first < 224  { length = 3 }
        else if first < 240  { length = 4 }
        else                 { length = 5 }

        guard start + length <= data.endIndex else { return nil }

        func byte(_ offset: Int) -> UInt64 { UInt64(data[start + offset]) }

        switch length {
        case 1:
            return (byte(0), start + 1)
        case 2:
            return ((byte(0) & 0x3F) + 64 * byte(1), start + 2)
        case 3:
            return ((byte(0) & 0x1F) + 32 * (byte(1) + 256 * byte(2)), start + 3)
        case 4:
            return ((byte(0) & 0x0F)
                    + 16 * (byte(1) + 256 * (byte(2) + 256 * byte(3))), start + 4)
        default:
            // 先頭バイトは長さの表示だけに使い、値は続く 4 バイト
            var value: UInt64 = 0
            for i in 0..<4 { value |= byte(1 + i) << (8 * UInt64(i)) }
            return (value, start + 5)
        }
    }
}

// MARK: - MEDIA_HEADER

/// `MEDIA_HEADER` パートの中身 (欲しいものだけ)。
/// 出典: `protos/video_streaming/media_header.proto`
struct UMPMediaHeader {
    var headerID: Int?
    var videoID: String?
    var itag: Int?
    var startRange: Int?
    var isInitSegment: Bool?
    var sequenceNumber: Int?
    var contentLength: Int?
    var durationMs: Int?
    var startMs: Int?
    /// time_range.timescale。buffered_ranges を組み立てるのに要る。
    var timescale: Int?

    init(_ payload: Data) {
        var reader = ProtobufReader(payload)
        while let (field, value) = reader.next() {
            switch field {
            case 1:  headerID = value.int
            case 2:  videoID = value.string
            case 3:  itag = value.int
            case 6:  startRange = value.int
            case 8:  isInitSegment = value.bool
            case 9:  sequenceNumber = value.int
            case 11: startMs = value.int
            case 12: durationMs = value.int
            case 14: contentLength = value.int
            case 15:
                // TimeRange { start_ticks = 1, duration_ticks = 2, timescale = 3 }
                if let payload = value.data {
                    var inner = ProtobufReader(payload)
                    while let (f, v) = inner.next() {
                        if f == 3 { timescale = v.int }
                    }
                }
            default: break
            }
        }
    }

    var summary: String {
        var parts: [String] = []
        if let itag { parts.append("itag=\(itag)") }
        if let startRange { parts.append("開始=\(startRange)") }
        if let contentLength { parts.append("長さ=\(contentLength)") }
        if let sequenceNumber { parts.append("連番=\(sequenceNumber)") }
        if let startMs { parts.append("開始ms=\(startMs)") }
        if let durationMs { parts.append("長さms=\(durationMs)") }
        if isInitSegment == true { parts.append("初期化セグメント") }
        return parts.joined(separator: " ")
    }
}
