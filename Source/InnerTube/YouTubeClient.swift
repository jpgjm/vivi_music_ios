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
    /// WEB は版数が頻繁に変わるため、送信直前に差し替えられるよう var にしている。
    var clientVersion: String
    /// HTTP ヘッダ `X-YouTube-Client-Name` に入れる数値 ID。
    /// (ヘッダ名は Client-Name だが中身は ID。オリジナルにも同じ注記がある)
    let clientID: String
    let userAgent: String
    var osName: String?
    var osVersion: String?

    /// context.client に入れる端末情報。
    /// yt-dlp は ANDROID_VR / IOS でこれらを送っている。
    /// 欠けていると素性が曖昧になり bot 判定を受けやすい。
    var deviceMake: String?
    var deviceModel: String?
    var androidSdkVersion: Int?
    /// context.client.timeZone / utcOffsetMinutes。
    ///
    /// VISIONOS が Opaline で観測されたとおりに振る舞うのは、
    /// 向こうが送っている context をそのまま再現した場合。
    /// 欠けた項目があると別のクライアントと見なされる恐れがあるため、
    /// この 2 つも送れるようにしておく。
    var timeZone: String?
    var utcOffsetMinutes: Int?
    /// OAuth のアクセストークン (Bearer) を受け付けるか。
    ///
    /// **true にできるのは TVHTML5 だけ。**
    /// デバイスフローで得るトークンは TV 向けアプリの資格情報で発行されるため、
    /// 他のクライアントに付けると
    ///   "Request contains an invalid argument" (HTTP 400)
    /// で全リクエストが弾かれる。実際にそれで一度壊した。
    var acceptsOAuth: Bool = false

    /// Cookie 認証 (Cookie + SAPISIDHASH + onBehalfOfUser) を受け付けるか。
    ///
    /// **true にできるのは WEB_REMIX だけ。**
    /// 本家 `YouTubeClient.kt` の `loginSupported` と同じ。
    /// ANDROID_VR / IOS に Cookie を付けても意味が無く、
    /// TVHTML5 は Music 用ヘッダを嫌うので対象外。
    var loginSupported: Bool = false

    /// SAPISIDHASH / X-Origin / Referer に使う原点。
    ///
    /// music.youtube.com と www.youtube.com では別扱いになる。
    /// SAPISIDHASH は原点を材料にして計算するので、ここが食い違うと
    /// Cookie が正しくても認証が通らない。
    var origin: String = originYouTubeMusic

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

    /// `player` 要求に `playbackContext.contentPlaybackContext.signatureTimestamp`
    /// を付けるか。
    ///
    /// **TVHTML5 では必須。** 無い / 古いと再生情報が返らず
    ///   playabilityStatus.reason = "ページを再読み込みする必要があります。"
    /// になる。これが原因でログイン済み再生の経路が常に落ち、
    /// 匿名クライアントに落ちて bot 判定される状態になっていた。
    ///
    /// ANDROID_VR / IOS は署名復号済みの URL をそのまま返すため STS は不要。
    /// WEB_REMIX は現状 STS 無しで解決できているので、余計な変更で
    /// 壊さないようここでは対象にしない。
    var requiresSignatureTimestamp: Bool = false

    // MARK: - 定数

    static let originYouTubeMusic = "https://music.youtube.com"
    static let originYouTube = "https://www.youtube.com"
    static let refererYouTube = "https://www.youtube.com/"
    static let refererYouTubeMusic = "https://music.youtube.com/"
    static let apiURLYouTubeMusic = "https://music.youtube.com/youtubei/v1/"
    static let apiURLYouTube = "https://www.youtube.com/youtubei/v1/"

    static let userAgentWeb =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"

    /// visionOS の Safari。VISIONOS クライアント自身の UA。
    /// Opaline の `UserAgent.visionOS` と同じ文字列。
    static let userAgentVisionOS =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/26.0 Safari/605.1.15"

    /// TVHTML5 が名乗る UA。実機の TV アプリが走っているブラウザ。
    ///
    /// 従来ここは "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version" という
    /// **雛形のまま** の文字列だった。Opaline はこれを名乗ると
    /// googlevideo が TV のメディアを拒否すると記録している
    /// (同一アカウント・同一回線で並べて確認、2026-08-18)。
    static let userAgentWebOSTV =
        "Mozilla/5.0 (Web0S; Linux/SmartTV) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/85.0.4183.93/7.1 Safari/537.36 WebAppManager"

    /// Fire TV 上の Cobalt。`youtube.com/tv` を実機と同じ目で読むために使う。
    /// ページの中身 (player の場所・版数) が UA で変わるため。
    static let userAgentCobaltTV =
        "Mozilla/5.0 (Linux armeabi-v7a; Android 7.1.2; Fire OS 6.0) "
        + "Cobalt/22.lts.3.306369-gold (unlike Gecko) "
        + "v8/8.8.278.8-jit gles Starboard/13, "
        + "Amazon_ATV_mediatek8695_2019/NS6294 (Amazon, AFTMM, Wireless) "
        + "com.amazon.firetv.youtube/22.3.r2.v66.0"

    // MARK: - クライアント一覧

    /// YouTube Music Web。ホーム / 検索 / 探索 に使う。
    static let webRemix = YouTubeClient(
        clientName: "WEB_REMIX",
        clientVersion: "1.20260213.01.00",
        clientID: "67",
        userAgent: userAgentWeb,
        loginSupported: true,
        usesWebPoToken: true
    )

    /// TV 向けクライアント。**ログイン時の再生に使う唯一のクライアント**。
    ///
    /// OAuth デバイスフローで得たトークンはこのクライアント向けに発行される。
    /// Bearer と組み合わせることで bot 判定を回避できる。
    ///
    /// ── 2026-08-23 に直した点 ────────────────────────────
    ///
    /// この経路はこれまで **一度も通っていなかった**。原因は 2 つ。
    ///
    ///   1. signatureTimestamp に WEB の base.js から取った値を送っていた。
    ///      TV は自分の player JS (tv-player-ias-tcl) の STS でないと
    ///      受け付けず、必ず
    ///        「ページを再読み込みする必要があります。」
    ///      で拒否される。実測で確認済み (TVPlayerInfo の注記を参照)。
    ///
    ///   2. clientVersion を決め打ちしていた。実際の値は日付入りで
    ///      毎週変わる (2026-08-23 時点は 7.20260819.16.00)。
    ///
    /// どちらも `TVPlayerInfo` が実際の値を取ってくるので、
    /// ここに書いてある版数は取得に失敗したときの保険でしかない。
    /// UA も雛形のままだった値から実機のものに差し替えた。
    static let tvhtml5 = YouTubeClient(
        clientName: "TVHTML5",
        // 送信直前に TVPlayerInfo の値へ差し替える (InnerTube.player)。
        // ここはその取得に失敗したときの保険。
        clientVersion: TVPlayerInfo.fallbackClientVersion,
        clientID: "7",
        userAgent: userAgentWebOSTV,
        acceptsOAuth: true,
        apiBaseURL: apiURLYouTube,
        usesMusicHeaders: false,
        isTVClient: true,
        requiresSignatureTimestamp: true
    )

    /// 素の YouTube Web クライアント (www.youtube.com)。
    ///
    /// WEB_REMIX との違い:
    ///   WEB_REMIX は music.youtube.com の player なので、
    ///   音楽カタログの外にある通常動画を扱えない。
    ///   こちらにはその制限が無く、yt-dlp が主経路に使っているのもこれ。
    ///
    /// 必要な部品はすべて揃っている:
    ///   - 署名復号 / n 変換 → PlayerJSService
    ///   - poToken           → PoTokenService
    ///   - Cookie 認証       → CookieAuthService (原点は www.youtube.com)
    ///
    /// clientVersion は決め打ちにせず WebClientVersion から実際の値を取る。
    /// 古い版数を送ると「動画を再生できません」で拒否されることがあるため。
    static let web = YouTubeClient(
        clientName: "WEB",
        // ここは組み立て時に WebClientVersion の値で差し替える。
        // 直接使われることは無いが、取得に失敗したときの保険として置く。
        clientVersion: WebClientVersion.fallback,
        clientID: "1",
        userAgent: userAgentWeb,
        loginSupported: true,
        origin: originYouTube,
        apiBaseURL: apiURLYouTube,
        usesWebPoToken: true,
        requiresSignatureTimestamp: true
    )

    /// Apple Vision Pro のクライアント。**ストリーム解決の第一候補**。
    ///
    /// ── なぜこれを足すのか ──────────────────────────────────
    /// 2026-08 以降、匿名セッションに掛かる「先頭 1 MiB (音声で約 65 秒)
    /// より先を配らない」制限を、**このクライアントだけが受けない**。
    /// Opaline が 2026-08-18 に android_vr / android / ios と並べて測り、
    /// 他がすべて 59904〜69888ms で打ち切られるなか、これだけが
    /// 最後まで配られたと記録している (Opaline#76)。
    ///
    /// 2026-08-23 に同じ測定をこちらでも再現した (itag 140 / 3449447B):
    ///   VISIONOS        512KiB ずつ 7 回 → 全部 206、最後まで取得
    ///   ANDROID_VR 1.65 offset 1048576 (ちょうど 1 MiB) で 403
    ///   IOS             adaptiveFormats に url が無い (SABR 専用応答)
    ///
    /// ── 性質 ────────────────────────────────────────────
    ///   - 匿名。OAuth も Cookie も要らない (むしろ付けない)
    ///   - adaptiveFormats に **復号済みの url** が入る。
    ///     `signatureCipher` も `n` パラメータも無いので
    ///     PlayerJSService (JS 実行) を通す必要がない
    ///   - sparams に `pot` が含まれないので poToken も要らない
    ///     (実測の sparams: expire,ei,ip,id,itag,source,requiressl,
    ///      xpc,bui,spc,vprv,svpuc,mime)
    ///   - 宛先は www.youtube.com。music.youtube.com でも通るが、
    ///     素性を Opaline と揃えるため www 側にする
    ///
    /// ── 限界 ────────────────────────────────────────────
    /// 匿名クライアントである以上、bot 判定を受ければ
    /// LOGIN_REQUIRED になる (これは ANDROID_VR も同じ)。
    /// そのため「これ 1 本」にはせず、従来の候補は後ろに残す。
    static let visionOS = YouTubeClient(
        clientName: "VISIONOS",
        clientVersion: "1.02",
        clientID: "101",
        userAgent: userAgentVisionOS,
        osName: "visionOS",
        osVersion: "1.0.2.21O209",
        deviceMake: "Apple",
        deviceModel: "RealityDevice14,1",
        timeZone: "UTC",
        utcOffsetMinutes: 0,
        origin: originYouTube,
        apiBaseURL: apiURLYouTube
    )

    /// iOS ネイティブ。`player` の第一候補。
    static let ios = YouTubeClient(
        clientName: "IOS",
        clientVersion: "21.26.4",
        clientID: "5",
        userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        osName: "iPhone",
        osVersion: "18.3.2.22D82",
        deviceMake: "Apple",
        deviceModel: "iPhone16,2"
    )

    /// Oculus 版 (1.68.19)。
    ///
    /// 2026-08-14 実測: 1.43 / 1.61 が bot 判定で弾かれるなか、
    /// この版だけが player を通したので一度は第一候補にした。
    ///
    /// ただし yt-dlp のソースにこう書かれている:
    ///   「clientVersion > 1.65 だと SABR 専用ストリームしか
    ///     返らなくなることがある」
    /// 私が推測で足した版数だったので、実績のある 1.65 を先に試し、
    /// これはその次に回す。
    static let androidVR168 = YouTubeClient(
        clientName: "ANDROID_VR",
        clientVersion: "1.68.19",
        clientID: "28",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.68.19 "
            + "(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        osName: "Android",
        osVersion: "12L",
        deviceMake: "Oculus",
        deviceModel: "Quest 3",
        androidSdkVersion: 32
    )

    /// Oculus 版 (1.65.10)。**ストリーム解決の第一候補**。
    ///
    /// yt-dlp が 2026-08 時点で実際に採用している版数。
    /// 1.65 より新しいと SABR 専用応答になる場合があると
    /// 向こうのソースに明記されているため、ここを基準にする。
    static let androidVR165 = YouTubeClient(
        clientName: "ANDROID_VR",
        clientVersion: "1.65.10",
        clientID: "28",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 "
            + "(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        osName: "Android",
        osVersion: "12L",
        deviceMake: "Oculus",
        deviceModel: "Quest 3",
        androidSdkVersion: 32
    )

    /// Oculus 版 (1.43.32)。長く主力だったが 2026-08-14 に弾かれ始めた。
    /// 復活しうるので候補には残す。
    static let androidVR143 = YouTubeClient(
        clientName: "ANDROID_VR",
        clientVersion: "1.43.32",
        clientID: "28",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.43.32 "
            + "(Linux; U; Android 12; en_US; Quest 3; "
            + "Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)",
        osName: "Android",
        osVersion: "12",
        deviceMake: "Oculus",
        deviceModel: "Quest 3",
        androidSdkVersion: 32
    )

    /// URL の `c=` パラメータからクライアント名を引いて User-Agent を返す。
    /// ダウンロード時、URL を解決したクライアントと UA を一致させないと
    /// CDN 側で切断されることがある。
    static func userAgent(forClientName name: String) -> String {
        switch name {
        case "VISIONOS":
            return userAgentVisionOS
        case "IOS", "IOS_MUSIC":
            return ios.userAgent
        case "ANDROID_VR":
            return androidVR168.userAgent
        case "WEB_REMIX", "WEB", "MWEB":
            return userAgentWeb
        case "TVHTML5":
            return tvhtml5.userAgent
        default:
            return ios.userAgent
        }
    }

    /// googlevideo にメディアを取りに行くときのヘッダ一式。
    ///
    /// Metrolist の `YTPlayerUtils.streamHeaders()` と同じ構成にしている。
    /// 向こうは URL を解決したクライアントに合わせて
    /// User-Agent / Accept / Accept-Language / Referer / Origin の
    /// 5 つを送っており、vivi-music (Android) も同様。
    ///
    /// ViviMusic はこれまで Range と User-Agent (しかも Firefox 固定) の
    /// 2 つしか送っていなかった。
    /// rev.40 で UA だけ揃えて効果が無かったのは、
    /// Origin / Referer と組で意味を持つためだったと思われる。
    ///
    /// - Parameter clientName: URL の `c=` パラメータ (StreamInfo.clientName)
    static func streamHeaders(forClientName clientName: String) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": userAgent(forClientName: clientName),
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        ]

        switch clientName {
        case "WEB_REMIX":
            headers["Referer"] = refererYouTubeMusic
            headers["Origin"] = originYouTubeMusic
        case "VISIONOS":
            // Opaline の `PlaybackClient.streamHeaders` と同じ構成にする。
            //
            // ブラウザ由来のクライアントではないので Origin / Referer は
            // 付けず、代わりに自分が何者かを X-YouTube-Client-* で名乗る。
            // Accept-Language も "*" (向こうの実装どおり)。
            //
            // 2026-08-23 の実測では、この URL は無ヘッダでも 206 を返した。
            // つまり必須ではないが、素性を揃えておけば
            // googlevideo 側の扱いが変わったときに影響を受けにくい。
            headers["Accept-Language"] = "*"
            headers["X-YouTube-Client-Name"] = visionOS.clientID
            headers["X-YouTube-Client-Version"] = visionOS.clientVersion
        default:
            headers["Referer"] = refererYouTube
            headers["Origin"] = originYouTube
        }
        return headers
    }

    // MARK: - リクエスト用 context

    /// InnerTube のリクエストボディに入れる `context` を組み立てる。
    ///
    /// - Parameters:
    ///   - visitorData: セッション識別子。**ヘッダだけでなく context にも要る。**
    ///     本家 `Context.Client.visitorData` に相当。以前はヘッダにしか
    ///     入れていなかった。
    ///   - dataSyncID: ログイン中アカウントの識別子。`user.onBehalfOfUser` に入る。
    ///     これが無いと、Cookie が通っていても「どのアカウントか」が
    ///     伝わらない場合がある。
    func context(locale: (hl: String, gl: String),
                 visitorData: String? = nil,
                 dataSyncID: String? = nil) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": clientName,
            "clientVersion": clientVersion,
            "hl": locale.hl,
            "gl": locale.gl,
        ]
        if let osName { client["osName"] = osName }
        if let osVersion { client["osVersion"] = osVersion }
        if let deviceMake { client["deviceMake"] = deviceMake }
        if let deviceModel { client["deviceModel"] = deviceModel }
        if let androidSdkVersion { client["androidSdkVersion"] = androidSdkVersion }
        if let timeZone { client["timeZone"] = timeZone }
        if let utcOffsetMinutes { client["utcOffsetMinutes"] = utcOffsetMinutes }
        if let visitorData, !visitorData.isEmpty { client["visitorData"] = visitorData }

        // TV クライアントはこれらが無いとセッションを認識してもらえない
        if isTVClient {
            client["platform"] = "TV"
            client["clientFormFactor"] = "UNKNOWN_FORM_FACTOR"
            // 実機の TV アプリが名乗る自己紹介。
            //
            // `livingRoomPoTokenId` は「この居間のデバイス」の識別子で、
            // SABR 要求に載せる poToken の紐づけ先でもある。
            // player 要求とメディア要求で **同じ ID** を名乗らないと
            // 認証が成立しない。
            client["tvAppInfo"] = [
                "livingRoomPoTokenId": TVDeviceIdentity.livingRoomPoTokenId,
                "signedInAccountCount": 1,
                "appQuality": "TV_APP_QUALITY_FULL_ANIMATION",
            ]
            return [
                "client": client,
                "user": ["enableSafetyMode": false, "lockedSafetyMode": false],
                "request": ["useSsl": true, "internalExperimentFlags": [] as [Any]],
            ]
        }

        var user: [String: Any] = [:]
        if loginSupported, let dataSyncID, !dataSyncID.isEmpty {
            user["onBehalfOfUser"] = dataSyncID
        }

        return [
            "client": client,
            "user": user,
        ]
    }
}
