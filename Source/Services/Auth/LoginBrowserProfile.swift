//
//  LoginBrowserProfile.swift
//  ViviMusic
//
//  Cookie ログイン画面で使う「名乗り方」と「入口」の選択肢。
//
//  なぜ切り替え式にするのか:
//    Google は埋め込みブラウザからのログインを拒否することがある
//    (「このブラウザまたはアプリは安全でない可能性があります」)。
//    どの組み合わせなら通るかは実際に試さないと分からず、
//    ビルドし直して確かめるのは時間がかかりすぎる。
//
//  2026-08-12 の実測:
//    デスクトップ Firefox の UA を名乗ったところ拒否された。
//    navigator.userAgent は Firefox なのに実際のエンジンは WebKit という
//    不整合を検出されたと思われる。
//    → 既定 (WKWebView そのままの UA) が最も自然で通りやすいはず。
//
//  補足:
//    Cookie を取ったブラウザと InnerTube を叩くクライアントで UA が
//    食い違っても問題ない。SAPISIDHASH 認証は UA に紐づかないため。
//    (本家 Android も WebView は Chrome Android、InnerTube は
//     デスクトップ Firefox を名乗っており、食い違ったまま動いている)
//

import Foundation

/// ログイン WebView が名乗る User-Agent。
enum LoginUserAgent: String, CaseIterable, Identifiable {
    // 並びは推奨順。上から試す。
    case safariiPad
    case safariMac
    case chromeMac
    case systemDefault
    case firefoxDesktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .safariiPad:     return "Safari (iPad) (推奨)"
        case .systemDefault:  return "既定"
        case .safariMac:      return "Safari (Mac)"
        case .chromeMac:      return "Chrome (Mac)"
        case .firefoxDesktop: return "Firefox (デスクトップ)"
        }
    }

    var note: String {
        switch self {
        case .safariiPad:
            return "iPad の Safari を名乗る。2026-08-12 にこれで成功した。"
        case .systemDefault:
            return "WKWebView 本来の名乗り。Google のログイン判定は通るが、"
                + "YouTube Music 側が未知のブラウザとみなし "
                + "「お使いのブラウザ向けに最適化されていません」を出す。"
        case .safariMac:
            return "Mac の Safari を名乗る。同じ WebKit なので矛盾は出にくい。"
        case .chromeMac:
            return "Chrome を名乗る。エンジンは WebKit なので不整合が残る。"
        case .firefoxDesktop:
            return "2026-08-12 に拒否された設定。比較用に残してある。"
        }
    }

    /// `WKWebView.customUserAgent` に入れる値。nil なら既定のまま。
    var value: String? {
        switch self {
        case .systemDefault:
            return nil
        case .safariiPad:
            return "Mozilla/5.0 (iPad; CPU OS 18_5 like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
                + "Version/18.5 Safari/605.1.15"
        case .safariMac:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
                + "Version/18.5 Safari/605.1.15"
        case .chromeMac:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) "
                + "Chrome/139.0.0.0 Safari/537.36"
        case .firefoxDesktop:
            return YouTubeClient.userAgentWeb
        }
    }
}

/// ログインをどこから始めるか。
enum LoginEntry: String, CaseIterable, Identifiable {
    /// music.youtube.com を開き、利用者が右上からログインする。
    case musicHome
    /// Google のログインページに直接入る。
    case serviceLogin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .musicHome:    return "YouTube Music から (推奨)"
        case .serviceLogin: return "Google ログインページから"
        }
    }

    var note: String {
        switch self {
        case .musicHome:
            return "先に YouTube Music を開き、右上のアイコンからログインします。"
                + "ログイン画面に直接入るより通りやすい傾向があります。"
        case .serviceLogin:
            return "Google のログイン画面をいきなり開きます。"
                + "埋め込みブラウザ判定を受けやすい入口です。"
        }
    }

    var url: String {
        switch self {
        case .musicHome:
            return "https://music.youtube.com/"
        case .serviceLogin:
            return "https://accounts.google.com/ServiceLogin"
                + "?continue=https%3A%2F%2Fmusic.youtube.com"
        }
    }
}
