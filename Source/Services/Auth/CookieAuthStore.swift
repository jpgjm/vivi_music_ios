//
//  CookieAuthStore.swift
//  ViviMusic
//
//  YouTube Music の **Cookie 認証**。browse / search / next に使う。
//
//  なぜ OAuth と別に必要なのか:
//    デバイスフローで得る OAuth トークンは TV 向けアプリの資格情報で発行される。
//    これを music.youtube.com の WEB_REMIX に付けると
//      "Request contains an invalid argument" (HTTP 400)
//    で弾かれるため、ホーム (FEmusic_home) をアカウント付きで叩く手段が無かった。
//    結果として、ログインしてもホームは常に匿名フィードのままだった
//    (2026-08-12 実測: ログイン前後で棚の構成が完全に同一。
//     初回オンボーディング用の musicTastebuilderShelfRenderer が
//     ログイン後も返り続けることが決め手になった)。
//
//    本家 VIVI Music (Android) は WebView でログインして Cookie を回収し、
//    `Cookie` ヘッダ + `Authorization: SAPISIDHASH ...` を付けている。
//    そちらに合わせる。
//
//  役割分担 (意図的に併存させている):
//    Cookie 認証 → browse / search / next          (このファイル)
//    OAuth       → player の TVHTML5 フォールバック  (GoogleAuthService)
//
//    再生系は ANDROID_VR → IOS → WEB_REMIX → TVHTML5 の経路が実績どおり
//    動いているため、あえて手を付けない。
//

import Foundation
import CryptoKit
import Security

/// WebView ログインで回収した資格情報一式。
struct CookieCredentials: Codable, Equatable {
    /// `name=value; name=value` 形式の Cookie 文字列。
    var cookie: String
    /// InnerTube のセッション識別子。本家と同様に永続化する。
    ///
    /// これを保存しないと起動のたびに新しい匿名セッションが割り当てられ、
    /// アカウントとの結び付きが弱くなる (実測で毎起動 visitorData が
    /// 変わっていた)。
    var visitorData: String?
    /// 複数アカウント時にどれを使うかの識別子。`context.user.onBehalfOfUser` に入れる。
    var dataSyncID: String?
    /// 設定画面に出す表示名 (取得できたときだけ)。
    var accountName: String?

    /// Cookie 文字列を `[名前: 値]` に分解する。
    var cookieMap: [String: String] {
        var result: [String: String] = [:]
        for part in cookie.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<separator])
            let value = String(trimmed[trimmed.index(after: separator)...])
            if !name.isEmpty { result[name] = value }
        }
        return result
    }

    /// SAPISIDHASH の材料になる Cookie。
    ///
    /// 通常は `SAPISID` だが、`__Secure-3PAPISID` しか降ってこない場合があるので
    /// そちらも見る (値は同じ)。
    var sapisid: String? {
        let map = cookieMap
        return map["SAPISID"] ?? map["__Secure-3PAPISID"] ?? map["__Secure-1PAPISID"]
    }

    /// 認証として成立しているか。
    var isUsable: Bool { sapisid != nil }
}

/// リクエストに乗せるヘッダ一式。
///
/// actor (InnerTube) と @MainActor (CookieAuthService) をまたいで渡すため、
/// トップレベルの Sendable な値型として定義する。
struct InnerTubeAuthHeaders: Sendable {
    let cookie: String
    let authorization: String
    let visitorData: String?
    let dataSyncID: String?
}

// MARK: - SAPISIDHASH

enum SAPISIDHash {
    /// `Authorization` ヘッダの値を組み立てる。
    ///
    ///   SAPISIDHASH <unixTime>_<sha1("<unixTime> <SAPISID> <origin>")>
    ///
    /// 本家 `InnerTube.kt` の ytClient() と同じ計算。
    /// 時刻を含むため毎リクエストで作り直す (使い回すと期限切れで弾かれる)。
    static func authorization(sapisid: String, origin: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let digest = sha1Hex("\(timestamp) \(sapisid) \(origin)")
        return "SAPISIDHASH \(timestamp)_\(digest)"
    }

    static func sha1Hex(_ text: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Keychain

/// Cookie 資格情報の永続化。
///
/// OAuth と同じ理由で Keychain に置く。Cookie は実質的にアカウントそのものなので
/// UserDefaults には絶対に書かない。
enum CookieStore {
    private static let service = "com.music.vivi.cookie"
    private static let account = "youtube-music"

    static func save(_ credentials: CookieCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        delete()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            EventLog.log(.auth, message: "Cookie の Keychain 保存に失敗 (status=\(status))")
        }
    }

    static func load() -> CookieCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(CookieCredentials.self, from: data)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
