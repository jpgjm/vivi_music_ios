//
//  JSON.swift
//  ViviMusic
//
//  InnerTube のレスポンスは 10 階層近くネストした巨大な JSON で、
//  しかもキーの有無が状況によって変わる。Codable で型を全部定義すると
//  YouTube 側の小さな仕様変更で全体が壊れるため、
//  「あれば取る、無ければ nil」の動的アクセスで扱う。
//
//  使用例:
//    json["contents"]["sectionListRenderer"]["contents"].array
//      .compactMap { $0["musicCarouselShelfRenderer"] }
//

import Foundation

/// `Any` をラップして安全に添字アクセスできるようにした軽量 JSON 型。
/// 存在しないキーを辿っても `.null` が返るだけでクラッシュしない。
struct JSON {
    let raw: Any?

    init(_ raw: Any?) {
        self.raw = raw
    }

    /// `Data` から生成する。パースできなければ `.null` 相当。
    init(data: Data) {
        self.raw = try? JSONSerialization.jsonObject(with: data, options: [])
    }

    static let null = JSON(nil)

    // MARK: - 添字アクセス

    subscript(key: String) -> JSON {
        guard let dict = raw as? [String: Any] else { return .null }
        return JSON(dict[key])
    }

    subscript(index: Int) -> JSON {
        guard let arr = raw as? [Any], index >= 0, index < arr.count else { return .null }
        return JSON(arr[index])
    }

    // MARK: - 値の取り出し

    var string: String? { raw as? String }
    var int: Int? {
        if let i = raw as? Int { return i }
        if let s = raw as? String { return Int(s) }
        if let d = raw as? Double { return Int(d) }
        return nil
    }
    var double: Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String { return Double(s) }
        return nil
    }
    var bool: Bool? { raw as? Bool }

    /// 配列として取り出す。配列でなければ空配列。
    var array: [JSON] {
        guard let arr = raw as? [Any] else { return [] }
        return arr.map { JSON($0) }
    }

    /// 辞書として取り出す。辞書でなければ空辞書。
    var dictionary: [String: JSON] {
        guard let dict = raw as? [String: Any] else { return [:] }
        return dict.mapValues { JSON($0) }
    }

    var exists: Bool { raw != nil }

    // MARK: - 深い階層を辿る

    /// 階層をまとめて辿る。数字だけのキーは配列の添字として扱う。
    ///
    /// なぜこれが必要か:
    ///   Swift は添字チェーンを改行で折り返せない。
    ///       let x = json["a"]["b"]
    ///           ["c"]["d"]          // ← これは配列リテラルと解釈されて別の式になる
    ///   InnerTube のパスは 8 階層を超えることが多く、1 行に収めると長すぎるので
    ///   関数呼び出しの形にして改行できるようにしている。
    ///   (関数の引数は改行しても 1 つの式として扱われる)
    ///
    /// InnerTube のキーに数字のみのものは存在しないため、
    /// "0" を添字と解釈しても衝突しない。
    func path(_ keys: String...) -> JSON {
        var node = self
        for key in keys {
            if let index = Int(key) {
                node = node[index]
            } else {
                node = node[key]
            }
        }
        return node
    }

    // MARK: - InnerTube 固有のヘルパ

    /// `{"runs": [{"text": "..."}, ...]}` から全テキストを連結して返す。
    /// InnerTube はタイトルもアーティスト名も全部この形。
    var runsText: String? {
        let runs = self["runs"].array
        guard !runs.isEmpty else { return self["simpleText"].string }
        let joined = runs.compactMap { $0["text"].string }.joined()
        return joined.isEmpty ? nil : joined
    }

    /// `runs` の各要素を配列で返す (アーティストごとに分解したい場合)。
    var runs: [JSON] { self["runs"].array }

    /// `thumbnails` 配列から最大解像度の URL を返す。
    var bestThumbnailURL: String? {
        let thumbs = self["thumbnails"].array
        guard !thumbs.isEmpty else { return nil }
        let best = thumbs.max { a, b in
            (a["width"].int ?? 0) < (b["width"].int ?? 0)
        }
        return best?["url"].string
    }
}
