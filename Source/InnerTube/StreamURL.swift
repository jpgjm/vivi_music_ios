//
//  StreamURL.swift
//  ViviMusic
//
//  googlevideo の再生 URL から、その URL 自身が何を要求しているかを読む。
//
//  ── なぜ URL に訊くのか ──────────────────────────────────
//  「このクライアントには pot を付ける／付けない」と決め打ちにすると、
//  YouTube 側の仕様が変わるたびにコードを直すことになる。
//  実際 2026-08 にそれで一度失敗した。
//
//  googlevideo の URL には `sparams` というパラメータがあり、
//  **署名 (`sig`) の対象になっているパラメータ名**が列挙されている。
//  ここに `pot` があるかどうかを見れば、その URL が poToken を
//  前提にしているかが分かる。決め打ちより確実で、将来にも追随できる。
//
//  2026-08-14 の実測 (ANDROID_VR / itag 140):
//    sparams = expire,ei,ip,id,itag,source,requiressl,xpc,gcr,bui,
//              spc,vprv,svpuc,mime
//    → pot は含まれない。よって pot= を足しても署名の対象外で意味が無い。
//

import Foundation

enum StreamURL {

    /// この URL が poToken (`pot=`) を前提にしているか。
    ///
    /// 判断の材料は `sparams`。
    /// 読み取れない URL では **false** を返す。
    /// 余計なパラメータを足すより、付けないほうが安全なため。
    static func requiresPoToken(_ urlString: String) -> Bool {
        signedParameters(of: urlString).contains("pot")
    }

    /// URL が指定のクエリパラメータを既に持っているか。
    /// 二重に足さないための確認に使う。
    static func hasParameter(_ name: String, in urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString),
              let items = components.queryItems else { return false }
        return items.contains { $0.name == name }
    }

    /// `sparams` に列挙されているパラメータ名の集合。
    static func signedParameters(of urlString: String) -> Set<String> {
        guard let components = URLComponents(string: urlString),
              let items = components.queryItems else { return [] }

        // sparams と lsparams の両方を見る。
        // 後者は lsig の対象で、別系統の署名に使われる。
        var names = Set<String>()
        for item in items where item.name == "sparams" || item.name == "lsparams" {
            guard let value = item.value else { continue }
            for name in value.split(separator: ",") {
                names.insert(String(name))
            }
        }
        return names
    }

    /// 診断ログ用。URL の素性を短くまとめる。
    /// 署名や pot の中身は出さない (長いうえに秘匿すべき値のため)。
    static func describe(_ urlString: String) -> String {
        guard let components = URLComponents(string: urlString),
              let items = components.queryItems else { return "解析不可" }

        var summary: [String] = []
        for key in ["c", "itag", "clen", "dur", "gcr"] {
            if let value = items.first(where: { $0.name == key })?.value {
                summary.append("\(key)=\(value)")
            }
        }
        let signed = signedParameters(of: urlString)
        summary.append("pot要求=\(signed.contains("pot") ? "あり" : "なし")")
        summary.append("pot付与済=\(items.contains { $0.name == "pot" } ? "あり" : "なし")")
        return summary.joined(separator: " / ")
    }
}
