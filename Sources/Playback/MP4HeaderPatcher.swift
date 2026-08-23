//
//  MP4HeaderPatcher.swift
//  ViviMusic
//
//  MP4 の先頭 (ftyp + moov) を読み、`duration` フィールドを 0 に書き換える。
//
//  ── なぜ必要か ────────────────────────────────────────────────
//  YouTube の itag 140 は「フラグメント化 MP4」だが、素直な形ではない。
//  実データを解析するとこうなっている (dQw4w9WgXcQ / 213秒の曲):
//
//      moov
//        mvhd  timescale=44100 duration=9397248  → 213.09s   ← 全長が入っている
//        mvex                                                 ← フラグメント宣言
//        trak/mdia/mdhd duration=9397248         → 213.09s
//        trak/.../stbl  stts/stsz/stco はすべて空 (サンプル 0 件)
//      sidx  subsegment duration 合計 = 9397248  → 213.09s   ← フラグメントの全長
//      moof/mdat × 22
//
//  本来の DASH 初期化セグメントは `mvhd.duration = 0` (長さ不明、
//  フラグメントから求めよ) にする。ところが YouTube は moov に全長を
//  入れたうえでフラグメントも持たせている。
//
//  AVFoundation はこの 2 つを **足して** しまい、再生時間が
//  ちょうど 2 倍 (426.18s) になる。ビットレート推定も半分になる。
//  実測でも「実測 525秒 / 想定 263秒」のように常にきっかり 2 倍だった。
//
//  ── 対策 ──────────────────────────────────────────────────────
//  リソースローダーが AVFoundation に先頭を渡す前に、
//  mvhd / tkhd / mdhd の duration を 0 に書き換え、
//  正規の初期化セグメントと同じ形にする。
//  長さは sidx から正しく求まる。
//
//  ── 安全側の設計 ──────────────────────────────────────────────
//  - moov が見つからない / 途中で切れている場合は **何もしない**。
//    書き換えた箱だけを報告し、呼び出し側がログに残せるようにする。
//  - 効かなかったときのために PlayerManager 側の事後補正
//    (forwardPlaybackEndTime) はそのまま残してある。
//

import Foundation

enum MP4HeaderPatcher {

    struct Result {
        /// 書き換え後のデータ (書き換えが無ければ元のまま)
        let data: Data
        /// 書き換えた箱の名前。ログ用。
        let patched: [String]
    }

    /// 先頭バッファ内の duration を 0 にする。
    static func zeroingDurations(in data: Data) -> Result {
        var buffer = data
        var patched: [String] = []
        walkTopLevel(&buffer, patched: &patched)
        return Result(data: buffer, patched: patched)
    }

    // MARK: - 箱をたどる

    private static func walkTopLevel(_ buffer: inout Data, patched: inout [String]) {
        var offset = 0
        while let box = readBox(buffer, at: offset) {
            if box.type == "moov" {
                walkChildren(&buffer,
                             from: box.contentStart,
                             to: box.end,
                             patched: &patched)
                // moov は 1 つだけ。見つけたら終わり。
                return
            }
            offset = box.end
        }
    }

    /// moov / trak / mdia の中を再帰的にたどる。
    private static func walkChildren(_ buffer: inout Data,
                                     from start: Int,
                                     to limit: Int,
                                     patched: inout [String]) {
        var offset = start
        while offset < limit, let box = readBox(buffer, at: offset), box.end <= limit {
            switch box.type {
            case "mvhd":
                // version+flags(4) creation modification timescale duration
                if zeroDuration(&buffer, box: box, v0Offset: 24, v1Offset: 32) {
                    patched.append("mvhd")
                }
            case "mdhd":
                // mvhd と同じ並び
                if zeroDuration(&buffer, box: box, v0Offset: 24, v1Offset: 32) {
                    patched.append("mdhd")
                }
            case "tkhd":
                // creation modification track_ID reserved duration
                if zeroDuration(&buffer, box: box, v0Offset: 28, v1Offset: 36) {
                    patched.append("tkhd")
                }
            case "trak", "mdia":
                walkChildren(&buffer,
                             from: box.contentStart,
                             to: box.end,
                             patched: &patched)
            default:
                break
            }
            offset = box.end
        }
    }

    // MARK: - 書き換え

    /// 指定位置の duration を 0 にする。範囲外なら何もせず false。
    private static func zeroDuration(_ buffer: inout Data,
                                     box: Box,
                                     v0Offset: Int,
                                     v1Offset: Int) -> Bool {
        // version は箱の中身の先頭バイト
        guard box.contentStart < buffer.count else { return false }
        let version = buffer[buffer.startIndex + box.contentStart]

        let fieldOffset = version == 0 ? v0Offset : v1Offset
        let fieldLength = version == 0 ? 4 : 8
        let start = box.start + fieldOffset

        guard start >= 0,
              start + fieldLength <= box.end,
              start + fieldLength <= buffer.count else {
            return false
        }

        var alreadyZero = true
        for index in 0..<fieldLength where buffer[buffer.startIndex + start + index] != 0 {
            alreadyZero = false
            break
        }
        if alreadyZero { return false }

        for index in 0..<fieldLength {
            buffer[buffer.startIndex + start + index] = 0
        }
        return true
    }

    // MARK: - 箱の読み取り

    private struct Box {
        let type: String
        /// 箱の先頭 (size フィールドの位置)
        let start: Int
        /// 中身の開始位置 (拡張サイズを考慮済み)
        let contentStart: Int
        /// 箱の終端 (次の箱の先頭)
        let end: Int
    }

    /// `offset` にある箱を読む。壊れている / バッファに収まらないなら nil。
    private static func readBox(_ buffer: Data, at offset: Int) -> Box? {
        guard offset >= 0, offset + 8 <= buffer.count else { return nil }

        let base = buffer.startIndex + offset
        var size = Int(readUInt32(buffer, at: offset))
        let typeBytes = buffer[(base + 4)..<(base + 8)]
        guard let type = String(data: Data(typeBytes), encoding: .ascii) else {
            return nil
        }

        var contentStart = offset + 8

        if size == 1 {
            // 64bit サイズ。size(4) type(4) largesize(8) の順。
            guard offset + 16 <= buffer.count else { return nil }
            let high = UInt64(readUInt32(buffer, at: offset + 8))
            let low = UInt64(readUInt32(buffer, at: offset + 12))
            let large = (high << 32) | low
            guard large <= UInt64(Int.max) else { return nil }
            size = Int(large)
            contentStart = offset + 16
        } else if size == 0 {
            // 「以降すべて」。バッファ末尾までとして扱う。
            size = buffer.count - offset
        }

        guard size >= 8 else { return nil }
        let end = offset + size
        guard end <= buffer.count, contentStart <= end else { return nil }

        return Box(type: type, start: offset, contentStart: contentStart, end: end)
    }

    private static func readUInt32(_ buffer: Data, at offset: Int) -> UInt32 {
        let base = buffer.startIndex + offset
        return (UInt32(buffer[base]) << 24)
            | (UInt32(buffer[base + 1]) << 16)
            | (UInt32(buffer[base + 2]) << 8)
            | UInt32(buffer[base + 3])
    }
}
