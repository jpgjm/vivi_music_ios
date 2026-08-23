//
//  WebClientVersion.swift
//  ViviMusic
//
//  素の WEB クライアント (www.youtube.com) の `clientVersion` を実際の
//  ページから取ってくる。
//
//  なぜ決め打ちにしないのか:
//    WEB の版数は数週間で変わる。古い値を送ると player が
//    「動画を再生できません」を返すことがある。
//    TVHTML5 や WEB_REMIX のように定数で持つと、そのたびに
//    ソースを書き換えてビルドし直す必要が出てくる。
//    www.youtube.com の HTML には ytcfg として現在の版数が
//    埋まっているので、それを読むほうが確実で手間もかからない。
//
//  取得に失敗したときは `fallback` を使う。
//  何も送らないよりは古い値でも送ったほうが通る見込みがある。
//

import Foundation

actor WebClientVersion {
    static let shared = WebClientVersion()

    /// 取得できなかったときに使う値。
    /// 2026-08 時点の形式に合わせてある。古くなっても致命的ではない。
    static let fallback = "2.20260311.01.00"

    private var cached: String?
    private var fetchedAt: Date?
    /// 1 回取れれば当分は変わらない。起動ごとに取り直せば十分。
    private let lifetime: TimeInterval = 6 * 60 * 60

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        return URLSession(configuration: cfg)
    }()

    /// 現在の WEB クライアント版数。取れなければ `fallback`。
    func current() async -> String {
        if let cached, let fetchedAt, Date().timeIntervalSince(fetchedAt) < lifetime {
            return cached
        }

        guard let value = await fetch() else {
            EventLog.log(.network,
                         message: "WEB クライアント版数を取得できず既定値を使用 "
                             + "(\(Self.fallback))")
            return cached ?? Self.fallback
        }

        cached = value
        fetchedAt = Date()
        EventLog.log(.network, message: "WEB クライアント版数: \(value)")
        return value
    }

    private func fetch() async -> String? {
        guard let url = URL(string: "https://www.youtube.com/") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")
        // Cookie を付けない。ここは版数を見るだけなので認証は不要。
        request.httpShouldHandleCookies = false

        guard let (data, _) = try? await session.data(for: request),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }

        // ytcfg の中に "INNERTUBE_CLIENT_VERSION":"2.2026...." の形で入っている
        let pattern = #""INNERTUBE_CLIENT_VERSION"\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html,
                                           range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let value = String(html[range])
        return value.isEmpty ? nil : value
    }
}
