//
//  TVPlayerInfo.swift
//  ViviMusic
//
//  TVHTML5 クライアントを名乗るのに要る 3 つの値を用意する。
//
//    1. clientVersion       … www.youtube.com/tv が今名乗っている版数
//    2. signatureTimestamp  … **TV の player JS から取った** STS
//    3. livingRoomPoTokenId … この端末が名乗る居間デバイスの識別子
//
//  ── なぜ専用に用意するのか ──────────────────────────────
//
//  ViviMusic はこれまで TVHTML5 の player 要求に
//  `PlayerJSService.signatureTimestamp()` — つまり **WEB の base.js から
//  取った STS** を送っていた。これが原因で TVHTML5 の経路は常に
//    playabilityStatus.status = UNPLAYABLE
//    reason = 「ページを再読み込みする必要があります。」
//  で落ちていた。ログイン済みでも TV に落ちられないので、
//  匿名クライアントが全滅したら詰む状態だった。
//
//  2026-08-23 に実測して確定した (videoId=dQw4w9WgXcQ):
//
//    player JS                        signatureTimestamp   TVHTML5 の応答
//    ------------------------------   ------------------   --------------
//    tv-player-ias-tcl (TV が実行)    20683001             OK
//    tv-player-es6     (/tv が広告)   20683                UNPLAYABLE
//    player_ias_tce    (WEB)          20683                UNPLAYABLE
//
//  末尾の `001` は誤植ではない。TV が実際に走らせているビルドは
//  `tv-player-ias-tcl` で、そこに書かれている値がこれ。
//  `/tv` のページが `jsUrl` として広告するのは `tv-player-es6` だが、
//  そちらの STS では通らないので、**player ID だけ拝借して
//  ビルド名を差し替える**。Opaline も同じことをしている
//  (SignatureTimestampService+TVPlayer.tclVariant)。
//
//  ── clientVersion も固定できない ────────────────────────
//
//  従来は "7.20260311.12.00" を決め打ちしていた。
//  2026-08-23 時点の実際の値は "7.20260819.16.00" で、日付が入っている
//  以上ほぼ毎週変わる。古い版数を名乗ると googlevideo 側で
//  「知らないクライアント」として扱われる。/tv の HTML に
//  `"INNERTUBE_CLIENT_VERSION":"…"` があるので、そこから取る。
//

import Foundation

/// この端末が TV として名乗る識別子。
///
/// 実機の TV アプリは、インストール時に短い ID を 1 つ作って以後ずっと使い、
/// poToken をその ID に紐づける。ID は
///   ・player 要求の `context.client.tvAppInfo.livingRoomPoTokenId`
///   ・SABR 要求の `streamerContext.poToken`
/// の両方に効く。**同じ ID でなければ認証が成立しない**ので、
/// 一度作ったら UserDefaults に残す。
///
/// 長さは 12 文字 (9 バイトの base64)。Opaline が実機のセッションから
/// 採寸した値で、これがトークンの長さを決める。
enum TVDeviceIdentity {

    private static let storageKey = "TVDeviceIdentity.livingRoomPoTokenId"

    /// この端末の識別子。初回だけ作って以後は使い回す。
    static var livingRoomPoTokenId: String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: storageKey), !stored.isEmpty {
            return stored
        }
        let generated = generate()
        defaults.set(generated, forKey: storageKey)
        EventLog.log(.auth, message: "TV デバイス識別子を新規作成 (\(generated))")
        return generated
    }

    /// 9 バイトの乱数を base64 に。ちょうど 12 文字、パディング無し。
    private static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 9)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return Data(bytes).base64EncodedString()
    }
}

/// `youtube.com/tv` を見て TV クライアントの素性を取ってくる。
actor TVPlayerInfo {
    static let shared = TVPlayerInfo()

    /// 取り直す間隔。clientVersion は週単位で変わるので 12 時間で十分。
    private static let ttl: TimeInterval = 12 * 60 * 60
    /// 失敗したときに次を試すまでの間隔。
    private static let failureBackoff: TimeInterval = 5 * 60

    /// TV が実際に走らせている player のビルド名。
    /// `/tv` が広告する `tv-player-es6` ではこの STS が取れない。
    private static let tclVariant = "tv-player-ias-tcl"

    /// 取得に失敗したときの保険。実測した値なので当面は通るはずだが、
    /// 日付が入っている以上いずれ古くなる。
    static let fallbackClientVersion = "7.20260819.16.00"

    private struct Resolved {
        let clientVersion: String
        let signatureTimestamp: Int
        let playerID: String
    }

    private var resolved: Resolved?
    private var resolvedAt: Date?
    private var lastFailureAt: Date?
    private var inFlight: Task<Resolved?, Never>?

    // 起動をまたいで残す。毎回 2.5MB の JS を取りに行かずに済む。
    private static let versionKey = "TVPlayerInfo.clientVersion"
    private static let stsKey = "TVPlayerInfo.signatureTimestamp"
    private static let playerIDKey = "TVPlayerInfo.playerID"
    private static let fetchedAtKey = "TVPlayerInfo.fetchedAt"

    private init() {
        let defaults = UserDefaults.standard
        guard let version = defaults.string(forKey: Self.versionKey),
              let playerID = defaults.string(forKey: Self.playerIDKey),
              let fetchedAt = defaults.object(forKey: Self.fetchedAtKey) as? Date,
              Date().timeIntervalSince(fetchedAt) < Self.ttl else {
            return
        }
        let sts = defaults.integer(forKey: Self.stsKey)
        guard sts > 0 else { return }
        resolved = Resolved(clientVersion: version,
                            signatureTimestamp: sts,
                            playerID: playerID)
        resolvedAt = fetchedAt
    }

    // MARK: - 公開

    /// TV クライアントが名乗る版数。取れなければ実測済みの保険を返す。
    func clientVersion() async -> String {
        await ensureResolved()?.clientVersion ?? Self.fallbackClientVersion
    }

    /// TV の player 要求に入れる signatureTimestamp。
    /// **これが正しくないと TVHTML5 は必ず UNPLAYABLE になる。**
    /// 取れなければ nil。呼び出し側は付けずに続行してよい
    /// (どのみち他のクライアントを試すことになる)。
    func signatureTimestamp() async -> Int? {
        await ensureResolved()?.signatureTimestamp
    }

    /// 取り直しを促す。version / STS が古くなって拒否されたときに使う。
    func invalidate() {
        resolved = nil
        resolvedAt = nil
        lastFailureAt = nil
        UserDefaults.standard.removeObject(forKey: Self.fetchedAtKey)
    }

    // MARK: - 取得

    private func ensureResolved() async -> Resolved? {
        if let resolved, let resolvedAt,
           Date().timeIntervalSince(resolvedAt) < Self.ttl {
            return resolved
        }
        if let lastFailureAt,
           Date().timeIntervalSince(lastFailureAt) < Self.failureBackoff {
            return resolved   // 期限切れでも、あるなら古いものを使う
        }
        if let inFlight {
            return await inFlight.value
        }

        let task = Task<Resolved?, Never> { [weak self] in
            await self?.fetch()
        }
        inFlight = task
        let value = await task.value
        inFlight = nil
        return value ?? resolved
    }

    private func fetch() async -> Resolved? {
        let started = Date()

        guard let html = await text(from: "https://www.youtube.com/tv",
                                    userAgent: YouTubeClient.userAgentCobaltTV) else {
            lastFailureAt = Date()
            EventLog.log(.network, message: "TV: /tv のページを取得できませんでした")
            return nil
        }

        guard let version = Self.clientVersion(in: html) else {
            lastFailureAt = Date()
            EventLog.log(.network,
                         message: "TV: INNERTUBE_CLIENT_VERSION が見つかりません")
            return nil
        }
        guard let playerID = Self.playerID(in: html) else {
            lastFailureAt = Date()
            EventLog.log(.network, message: "TV: player ID が見つかりません")
            return nil
        }

        // /tv が広告するのは tv-player-es6 だが、その STS では拒否される。
        // player ID を保ったままビルド名だけ差し替える。
        let jsURL = "https://www.youtube.com/s/player/\(playerID)"
            + "/\(Self.tclVariant).vflset/\(Self.tclVariant).js"

        guard let js = await text(from: jsURL,
                                  userAgent: YouTubeClient.userAgentCobaltTV),
              let sts = Self.signatureTimestamp(in: js) else {
            lastFailureAt = Date()
            EventLog.log(.network,
                         message: "TV: \(Self.tclVariant) から STS を取れませんでした "
                             + "(player=\(playerID))")
            return nil
        }

        let value = Resolved(clientVersion: version,
                             signatureTimestamp: sts,
                             playerID: playerID)
        resolved = value
        resolvedAt = Date()
        lastFailureAt = nil

        let defaults = UserDefaults.standard
        defaults.set(version, forKey: Self.versionKey)
        defaults.set(sts, forKey: Self.stsKey)
        defaults.set(playerID, forKey: Self.playerIDKey)
        defaults.set(Date(), forKey: Self.fetchedAtKey)

        EventLog.logDuration(.network, start: started,
                             message: "TV クライアント情報を取得 "
                                 + "版数=\(version) STS=\(sts) player=\(playerID)")
        return value
    }

    private func text(from urlString: String, userAgent: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.httpShouldHandleCookies = false
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                EventLog.log(.network,
                             message: "TV: \(urlString) → HTTP \(status)")
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            EventLog.logError(.network, error: error, context: "TV: \(urlString)")
            return nil
        }
    }

    // MARK: - 切り出し

    static func clientVersion(in html: String) -> String? {
        firstGroup(in: html, pattern: "\"INNERTUBE_CLIENT_VERSION\":\"([^\"]+)\"")
    }

    /// `/s/player/<id>/…` の `<id>` を取る。
    /// ビルド名は差し替えるので、必要なのは ID だけ。
    static func playerID(in html: String) -> String? {
        firstGroup(in: html, pattern: "/s\\\\?/player\\\\?/([0-9a-zA-Z_-]{4,})\\\\?/")
            ?? firstGroup(in: html, pattern: "/s/player/([0-9a-zA-Z_-]{4,})/")
    }

    static func signatureTimestamp(in js: String) -> Int? {
        guard let digits = firstGroup(in: js, pattern: "signatureTimestamp:(\\d{4,})")
                ?? firstGroup(in: js, pattern: "\\bsts:(\\d{4,})") else {
            return nil
        }
        return Int(digits)
    }

    private static func firstGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let group = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[group])
    }
}
