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

    // MARK: - 検証用の全文出力

    /// 1 MiB 制限の切り分け実験のために、**URL 全体**を返す。
    ///
    /// ── 何のためにあるか (rev.88) ────────────────────────────
    ///
    /// 「1 MiB 制限は URL に紐づくのか、取りに行くクライアントに
    /// 紐づくのか」を確かめるため、ViviMusic が解決した URL を
    /// 別の端末 (Termux の curl など) から叩けるようにする。
    ///
    ///   403 → URL・セッションに紐づく制限
    ///   206 → ViviMusic の要求の出し方が原因
    ///
    /// 判定はこの一点で分かれ、その後の設計が変わる。
    ///
    /// ── 注意 ────────────────────────────────────────────────
    ///
    /// この URL には次のものが含まれる。**そのまま公開しないこと。**
    ///
    ///   ip=      … 発行時のグローバル IP アドレス (平文)
    ///   sig=     … 署名
    ///   lsig=    … 別系統の署名
    ///   pot=     … poToken (付いている場合)
    ///
    /// また `expire` で失効し、`ip` で発行時の回線に紐づくため、
    /// **同じ回線から数分以内**に使う必要がある。
    static func fullURLForDiagnostics(_ urlString: String) -> String {
        urlString
    }

    /// 上の URL に含まれる秘匿値を伏せたもの。
    ///
    /// 実験結果を共有するときはこちらを使う。
    /// どのパラメータが有るかは分かるが、値は出ない。
    static func redacted(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString),
              let items = components.queryItems else { return "解析不可" }

        let secrets: Set<String> = ["ip", "sig", "lsig", "pot", "id", "ei"]
        components.queryItems = items.map { item in
            guard secrets.contains(item.name) else { return item }
            let length = item.value?.count ?? 0
            return URLQueryItem(name: item.name, value: "<伏字:\(length)文字>")
        }
        return components.url?.absoluteString ?? "組み立て不可"
    }

    /// 実験手順をそのまま貼り付けられる形で返す。
    ///
    /// Termux などへ持っていって実行するだけで判定できるようにする。
    /// **① を先に実行すること。** ② を先にやると「先頭 512KiB を
    /// 消費した」と解釈される余地が残り、結果が濁る。
    static func diagnosticScript(_ urlString: String, clientName: String) -> String {
        let userAgent = YouTubeClient.userAgent(forClientName: clientName)
        return """
        # ViviMusic 1 MiB 制限の切り分け
        # 注意: この URL には ip= と sig= が平文で入っている。共有しないこと。
        # 注意: iPad と同じ Wi-Fi から、数分以内に実行すること。

        URL='\(urlString)'
        UA='\(userAgent)'

        echo "--- (1) 1 MiB 以降をいきなり要求 [本命]"
        curl -s -o /dev/null -w '%{http_code} %{size_download}\\n' \\
          -H "User-Agent: $UA" -H 'Accept: */*' \\
          -H 'Accept-Language: en-US,en;q=0.9' \\
          -H 'Origin: https://www.youtube.com' \\
          -H 'Referer: https://www.youtube.com/' \\
          -H 'Range: bytes=1048576-1572863' "$URL"

        echo "--- (2) 対照: 先頭 512KiB"
        curl -s -o /dev/null -w '%{http_code} %{size_download}\\n' \\
          -H "User-Agent: $UA" -H 'Accept: */*' \\
          -H 'Accept-Language: en-US,en;q=0.9' \\
          -H 'Origin: https://www.youtube.com' \\
          -H 'Referer: https://www.youtube.com/' \\
          -H 'Range: bytes=0-524287' "$URL"

        # 判定:
        #   (1) 403 0      -> URL/セッションに紐づく制限
        #   (1) 206 524288 -> ViviMusic の要求の出し方が原因
        #   (2) が 206 でなければ URL 失効か回線違い。取り直すこと
        """
    }
}
