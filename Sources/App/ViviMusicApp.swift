//
//  ViviMusicApp.swift
//  ViviMusic
//

import SwiftUI

@main
struct ViviMusicApp: App {

    init() {
        // UIDevice は @MainActor のためログ書き出し時には触れない。
        // App.init() は MainActor 上で走るので、ここで値を拾ってキャッシュする。
        DeviceInfo.prime()

        // EventLog はどのスレッドからでも呼べる (actor 隔離していない) ため
        // ここで起動を記録できる。シングルトンの初期化は MainActor 上で
        // 行いたいので RootView の .task に任せる。
        EventLog.log(.bootstrap, message: "アプリ起動 (rev.66 SABR を最後の逃げ道として組み込み)")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(PlayerManager.shared)
                .environmentObject(LibraryStore.shared)
                .environmentObject(DownloadManager.shared)
                .environmentObject(PlaylistStore.shared)
                .environmentObject(GoogleAuthService.shared)
                .environmentObject(CookieAuthService.shared)
                .environmentObject(TogetherManager.shared)
                .environmentObject(EqualizerSettings.shared)
                .preferredColorScheme(nil)   // 端末のライト/ダーク設定に従う
        }
    }
}
