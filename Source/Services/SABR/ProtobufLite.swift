//
//  ProtobufLite.swift
//  ViviMusic
//
//  protobuf の読み書きを最小限だけ自前で行う。
//
//  ── なぜ SwiftProtobuf を使わないのか ─────────────────────
//  SABR の実験に必要なメッセージはごく一部で、しかも
//  `.proto` から Swift を生成するには protoc と protoc-gen-swift が要る。
//  実験の段階でビルド構成 (project.yml / CI) に手を入れると、
//  「SABR が使えるか」以外の要因で失敗したときの切り分けが難しくなる。
//
//  本実装に進むと決まったら SwiftProtobuf に置き換える。
//  そのときは QSProbe で使っているのと同じ流れで導入できる。
//
//  ── 対応範囲 ────────────────────────────────────────────
//  varint / 64bit / length-delimited / 32bit の 4 種類だけ。
//  SABR で使うのはこれで足りる。
//

import Foundation

// MARK: - 書き込み

/// protobuf のメッセージを組み立てる。
struct ProtobufWriter {
    private(set) var data = Data()

    /// タグ (フィールド番号 + 型) を書く。
    private mutating func writeTag(_ field: Int, _ wireType: Int) {
        writeVarint(UInt64(field << 3 | wireType))
    }

    mutating func writeVarint(_ value: UInt64) {
        var v = value
        while true {
            let byte = UInt8(v & 0x7F)
            v >>= 7
            if v == 0 {
                data.append(byte)
                return
            }
            data.append(byte | 0x80)
        }
    }

    /// int32 / int64 / uint / bool 用 (wire type 0)。
    mutating func write(field: Int, varint value: UInt64) {
        writeTag(field, 0)
        writeVarint(value)
    }

    mutating func write(field: Int, int value: Int) {
        // 負数は 10 バイトの varint になる決まり。
        write(field: field, varint: UInt64(bitPattern: Int64(value)))
    }

    mutating func write(field: Int, bool value: Bool) {
        write(field: field, varint: value ? 1 : 0)
    }

    /// bytes / string / 埋め込みメッセージ用 (wire type 2)。
    mutating func write(field: Int, bytes value: Data) {
        writeTag(field, 2)
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func write(field: Int, string value: String) {
        write(field: field, bytes: Data(value.utf8))
    }

    /// 埋め込みメッセージを書く。
    mutating func write(field: Int, message build: (inout ProtobufWriter) -> Void) {
        var inner = ProtobufWriter()
        build(&inner)
        write(field: field, bytes: inner.data)
    }
}

// MARK: - 読み取り

/// protobuf のメッセージを読む。
///
/// 使う側は「欲しいフィールド番号だけ拾う」形にする。
/// 知らないフィールドは読み飛ばす (protobuf の作法どおり)。
struct ProtobufReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }

    /// 1 つのフィールドを読む。終端なら nil。
    mutating func next() -> (field: Int, value: Value)? {
        guard let tag = readVarint() else { return nil }
        let field = Int(tag >> 3)
        let wireType = Int(tag & 0x7)

        switch wireType {
        case 0:
            guard let v = readVarint() else { return nil }
            return (field, .varint(v))
        case 1:
            guard let v = readFixed(8) else { return nil }
            return (field, .fixed64(v))
        case 2:
            guard let length = readVarint() else { return nil }
            let count = Int(length)
            guard offset + count <= data.endIndex else { return nil }
            let slice = data.subdata(in: offset..<(offset + count))
            offset += count
            return (field, .bytes(slice))
        case 5:
            guard let v = readFixed(4) else { return nil }
            return (field, .fixed32(UInt32(truncatingIfNeeded: v)))
        default:
            // 未知の型。ここから先は読めないので打ち切る。
            return nil
        }
    }

    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)

        var int: Int? {
            if case .varint(let v) = self { return Int(bitPattern: UInt(v)) }
            return nil
        }
        var uint: UInt64? {
            if case .varint(let v) = self { return v }
            return nil
        }
        var bool: Bool? {
            if case .varint(let v) = self { return v != 0 }
            return nil
        }
        var data: Data? {
            if case .bytes(let d) = self { return d }
            return nil
        }
        var string: String? {
            guard case .bytes(let d) = self else { return nil }
            return String(data: d, encoding: .utf8)
        }
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.endIndex {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    private mutating func readFixed(_ count: Int) -> UInt64? {
        guard offset + count <= data.endIndex else { return nil }
        var result: UInt64 = 0
        for i in 0..<count {
            result |= UInt64(data[offset + i]) << (8 * UInt64(i))
        }
        offset += count
        return result
    }
}
