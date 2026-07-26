//
//  YouTubeClient.swift
//  ViviMusic
//
//  InnerTube (YouTube 内部 API) のクライアント定義。
//  値はオリジナル VIVI Music (Android) の
//  `innertube/src/main/kotlin/com/music/innertube/models/YouTubeClient.kt`
//  から移植している。
//
//  なぜクライアントを使い分けるのか:
//    - WEB_REMIX  : YouTube Music の Web クライアント。
//                   ホーム / 検索 / 探索 の "音楽用 UI 構造" を返すのはこれだけ。
//    - IOS        : `player` エンドポイントで **署名復号済み** の再生 URL を
//                   そのまま返す。player.js の取得と JS 実行が不要なので
//                   桁違いに速く、スロットリングもされにくい。
//    - ANDROID_VR : IOS で解決できない動画のフォールバック。
//

import Foundation

struct YouTubeClient {
    let clientName: String
    let clientVersion: String
    /// HTTP ヘッダ `X-YouTube-Client-Name` に入れる数値 ID。
    /// (ヘッダ名は Client-Name だが中身は ID。オリジナルにも同じ注記がある)
    let clientID: String
    let userAgent: String
    var osName: String?
    var osVersion: String?
    /// OAuth のアクセストークン (Bearer) を受け付けるか。
    ///
    /// **true にできるのは TVHTML5 だけ。**
    /// デバイスフローで得るトークンは TV 向けアプリの資格情報で発行されるため、
    /// 他のクライアントに付けると
    ///   "Request contains an invalid argument" (HTTP 400)
    /// で全リクエストが弾かれる。実際にそれで一度壊した。
    var acceptsOAuth: Bool = false

    /// リクエストの宛先。既定は YouTube Music。
    /// TVHTML5 は www.youtube.com に投げないと
    /// 「ページを再読み込みする必要があります」で拒否される。
    var apiBaseURL: String = apiURLYouTubeMusic

    /// Music 用のヘッダ (X-Origin / Referer / X-YouTube-Client-*) を付けるか。
    /// TVHTML5 に付けるとセッション不整合と見なされて弾かれるため false にする。
    var usesMusicHeaders: Bool = true

    /// TV クライアント特有の context フィールドを足すか。
    var isTVClient: Bool = false

    /// BotGuard で作る web 版 poToken を使うか。
    /// WEB 系のクライアントだけが対象。
    var usesWebPoToken: Bool = false

    // MARK: - 定数

    static let originYouTubeMusic = "https://music.youtube.com"
    static let refererYouTubeMusic = "https://music.youtube.com/"
    static let apiURLYouTubeMusic = "https://music.youtube.com/youtubei/v1/"
    static let apiURLYouTube = "https://www.youtube.com/youtubei/v1/"

    static let userAgentWeb =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"

    // MARK: - クライアント一覧

    /// YouTube Music Web。ホーム / 検索 / 探索 に使う。
    static let webRemix = YouTubeClient(
        clientName: "WEB_REMIX",
        clientVersion: "1.20260213.01.00",
        clientID: "67",
        userAgent: userAgentWeb,
        usesWebPoToken: true
    )

    /// TV 向けクライアント。**ログイン時の再生に使う唯一のクライアント**。
    ///
    /// OAuth デバイスフローで得たトークンはこのクライアント向けに発行される。
    /// Bearer と組み合わせることで bot 判定を回避できる。
    static let tvhtml5 = YouTubeClient(
        clientName: "TVHTML5",
        clientVersion: "7.20260311.12.00",
        clientID: "7",
        userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
        acceptsOAuth: true,
        apiBaseURL: apiURLYouTube,
        usesMusicHeaders: false,
        isTVClient: true
    )

    /// iOS ネイティブ。`player` の第一候補。
    static let ios = YouTubeClient(
        clientName: "IOS",
        clientVersion: "21.03.1",
        clientID: "5",
        userAgent: "com.google.ios.youtube/21.03.1 (iPhone16,2; U; CPU iOS 18_2 like Mac OS X;)",
        osName: "iPhone",
        osVersion: "18.2.22C152"
    )

    /// Oculus 版 (1.43.32)。**ストリーム解決の第一候補**。
    ///
    /// 本家 VIVI Music の `YTPlayerUtils.MAIN_CLIENT` がこれ。
    /// 署名復号も PoToken も不要で、発行される URL の制限が最も緩い。
    /// (IOS クライアントの URL は Range ヘッダを小分けにしないと 403 になるが、
    ///  ANDROID_VR の URL は素直に扱える)
    static let androidVR143 = YouTubeClient(
        clientName: "ANDROID_VR",
        clientVersion: "1.43.32",
        clientID: "28",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.43.32 "
            + "(Linux; U; Android 12; en_US; Quest 3; "
            + "Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)",
        osName: "Android",
        osVersion: "12"
    )

    /// Oculus 版 (1.61.48)。本家のフォールバック 1 番目。
    static let androidVR161 = YouTubeClient(
        clientName: "ANDROID_VR",
        clientVersion: "1.61.48",
        clientID: "28",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.61.48 "
            + "(Linux; U; Android 12; en_US; Oculus Quest 3; "
            + "Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)",
        osName: "Android",
        osVersion: "12"
    )

    /// URL の `c=` パラメータからクライアント名を引いて User-Agent を返す。
    /// ダウンロード時、URL を解決したクライアントと UA を一致させないと
    /// CDN 側で切断されることがある。
    static func userAgent(forClientName name: String) -> String {
        switch name {
        case "IOS", "IOS_MUSIC":
            return ios.userAgent
        case "ANDROID_VR":
            return androidVR143.userAgent
        case "WEB_REMIX", "WEB":
            return userAgentWeb
        case "TVHTML5":
            return tvhtml5.userAgent
        default:
            return ios.userAgent
        }
    }

    // MARK: - リクエスト用 context

    /// InnerTube のリクエストボディに入れる `context` を組み立てる。
    func context(locale: (hl: String, gl: String)) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": clientName,
            "clientVersion": clientVersion,
            "hl": locale.hl,
            "gl": locale.gl,
        ]
        if let osName { client["osName"] = osName }
        if let osVersion { client["osVersion"] = osVersion }

        // TV クライアントはこれらが無いとセッションを認識してもらえない
        if isTVClient {
            client["platform"] = "TV"
            client["clientFormFactor"] = "UNKNOWN_FORM_FACTOR"
            return [
                "client": client,
                "user": ["enableSafetyMode": false, "lockedSafetyMode": false],
                "request": ["useSsl": true, "internalExperimentFlags": [] as [Any]],
            ]
        }

        return [
            "client": client,
            "user": [:] as [String: Any],
        ]
    }
}
