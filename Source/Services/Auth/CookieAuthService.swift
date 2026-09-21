//
//  CookieAuthService.swift
//  ViviMusic
//
//  Cookie 認証の状態管理。UI と InnerTube の両方から参照される。
//
//  GoogleAuthService (OAuth / 再生用) とは独立。
//  どちらか一方だけログインしている状態も普通に起こりうる。
//

import Foundation
import WebKit

@MainActor
final class CookieAuthService: ObservableObject {
    static let shared = CookieAuthService()

    @Published private(set) var credentials: CookieCredentials?

    var isSignedIn: Bool { credentials?.isUsable == true }

    /// 設定画面に出す表示名。取れていなければ nil。
    var accountName: String? { credentials?.accountName }

    private init() {
        credentials = CookieStore.load()
        if let credentials {
            EventLog.log(.auth,
                         message: "Cookie 認証を読み込み"
                             + " (SAPISID \(credentials.sapisid == nil ? "なし" : "あり")"
                             + " / dataSyncId \(credentials.dataSyncID == nil ? "なし" : "あり")"
                             + " / visitorData \(credentials.visitorData == nil ? "なし" : "あり"))")
            adoptVisitorData(credentials.visitorData)
        } else {
            EventLog.log(.auth, message: "Cookie 認証なし (ホームは匿名フィードになる)")
        }
    }

    // MARK: - InnerTube から使う

    /// browse / search / next / player に付けるヘッダを組み立てる。
    /// 未ログイン、または SAPISID が取れていなければ nil。
    ///
    /// - Parameter origin: SAPISIDHASH の材料にする原点。
    ///   music.youtube.com と www.youtube.com では別の値になるため、
    ///   叩く先に合わせて渡す。ここが食い違うと Cookie が正しくても
    ///   認証が通らない。
    func headers(origin: String = YouTubeClient.originYouTubeMusic) -> InnerTubeAuthHeaders? {
        guard let credentials, let sapisid = credentials.sapisid else { return nil }
        return InnerTubeAuthHeaders(
            cookie: credentials.cookie,
            authorization: SAPISIDHash.authorization(
                sapisid: sapisid,
                origin: origin
            ),
            visitorData: credentials.visitorData,
            dataSyncID: credentials.dataSyncID
        )
    }

    // MARK: - ログイン完了時

    /// WebView から回収した資格情報を取り込む。
    ///
    /// この時点ではまだ「使えるか」は分からないので、呼び出し側で
    /// `verify()` を通してから成功扱いにすること。
    func apply(cookie: String, visitorData: String?, dataSyncID: String?) {
        var next = CookieCredentials(
            cookie: cookie,
            visitorData: visitorData,
            dataSyncID: dataSyncID,
            accountName: credentials?.accountName
        )
        // 新しく取れなかった項目は前回の値を残す
        if next.visitorData == nil { next.visitorData = credentials?.visitorData }
        if next.dataSyncID == nil { next.dataSyncID = credentials?.dataSyncID }

        credentials = next
        CookieStore.save(next)
        adoptVisitorData(next.visitorData)

        let names = next.cookieMap.keys.sorted().joined(separator: ", ")
        EventLog.log(.auth, message: "Cookie を回収 (\(next.cookieMap.count) 個): \(names)")
        if next.sapisid == nil {
            EventLog.log(.auth,
                         message: "SAPISID が含まれていない。"
                             + "ログインが完了していない可能性がある")
        }
    }

    /// account_menu を叩いてアカウント名を取り、認証が本当に効いているか確かめる。
    /// 本家 `YouTube.accountInfo()` に相当。
    /// - Returns: 取得できたアカウント名。認証が効いていなければ nil。
    func verify() async -> String? {
        guard isSignedIn else { return nil }
        do {
            let json = try await InnerTube.shared.accountMenu()
            guard let name = Parsers.accountName(json) else {
                EventLog.log(.auth,
                             message: "account_menu にアカウント情報が無い。"
                                 + "Cookie が認証として効いていない")
                return nil
            }
            credentials?.accountName = name
            if let credentials { CookieStore.save(credentials) }
            EventLog.log(.auth, message: "Cookie 認証を確認: \(name)")
            return name
        } catch {
            EventLog.logError(.auth, error: error, context: "account_menu")
            return nil
        }
    }

    // MARK: - ログアウト

    func signOut() {
        credentials = nil
        CookieStore.delete()
        adoptVisitorData(nil)
        EventLog.log(.auth, message: "Cookie 認証を破棄")

        // WebView 側に残っている Cookie も消す。
        // これをしないと、次にログイン画面を開いたとき前のアカウントで
        // 自動的に入り直してしまう。
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let targets = records.filter {
                $0.displayName.contains("youtube") || $0.displayName.contains("google")
            }
            guard !targets.isEmpty else { return }
            store.removeData(ofTypes: types, for: targets) {
                EventLog.log(.auth, message: "WebView の Cookie を \(targets.count) 件削除")
            }
        }
    }

    // MARK: - 内部

    /// 保存済みの visitorData を InnerTube に反映する。
    ///
    /// InnerTube は応答から visitorData を学習するが、ログイン済みなら
    /// **アカウントに紐づいた方**を使わないと意味が無い。
    private func adoptVisitorData(_ value: String?) {
        Task { await InnerTube.shared.adoptVisitorData(value) }
    }
}
