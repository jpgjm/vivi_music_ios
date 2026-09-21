//
//  VisitorIdentityProbe.swift
//  ViviMusic
//
//  再生を始める前に、いまの訪問者アイデンティティが
//  googlevideo に絞られていないかを確かめる。
//
//  ── 何が起きているか ────────────────────────────────────
//  2026-08 以降、googlevideo は **匿名セッション単位**で配信量を絞る。
//  絞られたセッションでは、どの動画でも、どの要求の仕方でも、
//  約 65 秒ぶん (音声なら約 1 MiB) を配ったところで 403 になる。
//
//  重要なのは「セッション内では完全に一貫している」こと。
//  一度悪い籤を引くと、そのセッションを使う限り必ず同じ秒数で死ぬ。
//  逆に良い籤なら最後まで再生できる。
//
//  Opaline の実測 (issue #76):
//
//    visitorData   1本目      2本目      3本目
//    #1            全ファイル  全ファイル  全ファイル
//    #2            65秒で403   65秒で403   65秒で403
//    #3            65秒で403   65秒で403   65秒で403
//
//  そして次の点が確認されている。
//    - PO トークン、URL の入れ替え、要求の間隔、クライアント、
//      range= クエリ、いずれも無関係
//    - 待っても回復しない
//    - **visitorData を引き直すと 3 回に 1 回ほど当たる**
//
//  ── なぜ HEAD で調べられるか ────────────────────────────
//  絞られたセッションは「枠を超える範囲」を最初から拒否する。
//  枠の 2 倍の範囲を HEAD で要求すれば、
//    絞られている → 403
//    健全         → 206
//  と即座に分かる。HEAD は本体を持たないので枠も消費しない。
//
//  開始位置は関係ない。制限は「配ったバイト数」を数えており、
//  ファイルのどこかは見ていない。
//  (ファイル後方の 1 バイトだけ調べる方式では、
//   直後に死ぬセッションを「健全」と誤判定した、と Opaline は書いている)
//
//  ── 限界 ────────────────────────────────────────────
//  これは回避策であって解決ではない。
//  健全なセッションが存在することに依存しており、
//  Opaline の観測ではその割合が 1 日で 42% → 25% に下がった。
//  Google 側がゼロにすれば効かなくなる。
//

import Foundation

enum VisitorIdentityProbe {

    /// 絞られたセッションが配ることを許される量。
    /// 音声で約 65 秒ぶん (約 1 MiB)。
    private static let throttleWindowBytes = 1_050_000

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// このアイデンティティで最後まで再生できそうかを調べる。
    ///
    /// - Returns: 健全なら true。絞られていれば false。
    ///   判断が付かないとき (通信エラーなど) は **true** を返す。
    ///   電波が悪いだけでアイデンティティを捨てるのは損なため。
    static func isHealthy(stream: StreamInfo, videoID: String) async -> Bool {
        guard let url = URL(string: stream.url) else { return true }

        // 枠より小さいファイルは、そもそも枠に当たらない。
        guard stream.contentLength > throttleWindowBytes else { return true }

        let start = 0
        let end = start + throttleWindowBytes * 2

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        for (name, value) in YouTubeClient.streamHeaders(forClientName: stream.clientName) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let status: Int
        do {
            let (_, response) = try await session.data(for: request)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            // 通信できなかった。「絞られている」とは断定しない。
            EventLog.log(.network, videoID: videoID,
                         message: "セッション検査: 判定できず "
                             + "(\(error.localizedDescription))")
            return true
        }

        // 403 だけが「このセッションは絞られている」の証拠。
        let healthy = status != 403
        EventLog.log(.network, videoID: videoID,
                     message: "セッション検査: \(healthy ? "健全" : "絞られている") "
                         + "(HTTP \(status) / bytes=\(start)-\(end))")
        return healthy
    }
}
