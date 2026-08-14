//
//  OAuthTokens.swift
//  ViviMusic
//
//  Google (YouTube) の OAuth トークン。
//  アクセストークンは数時間で失効するので、リフレッシュトークンと一緒に保存する。
//
//  保存先は Keychain。UserDefaults はバックアップやファイル共有経由で
//  読み出される可能性があるため、認証情報には使わない。
//

import Foundation
import Security

struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String
    /// アクセストークンの失効時刻
    var expiryDate: Date
    /// デバイスフローで取得したクライアント資格情報。更新時にも必要。
    var clientID: String
    var clientSecret: String

    /// 期限が近い (残り 5 分未満) なら更新すべき。
    var needsRefresh: Bool {
        Date().addingTimeInterval(5 * 60) >= expiryDate
    }
}

/// Keychain への読み書き。
enum TokenStore {
    private static let service = "com.music.vivi.oauth"
    private static let account = "youtube"

    static func save(_ tokens: OAuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }

        // 既存を消してから入れ直す (SecItemUpdate より単純で確実)
        delete()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // 端末ロック解除後のみ読める。バックアップにも含めない。
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            EventLog.log(.auth, message: "Keychain 保存に失敗 (status=\(status))")
        }
    }

    static func load() -> OAuthTokens? {
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
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
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
