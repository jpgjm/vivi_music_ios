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
        EventLog.log(.bootstrap, message: "アプリ起動 (rev.85 ロック画面のアートワークを高解像度に)")

        // Documents/Liveprog/ に Liveprog サンプルスクリプトを配置 (未配置分のみ)
        let installed = LiveprogSamples.installIfNeeded()
        if installed > 0 {
            EventLog.log(.dsp, message: "Liveprog サンプルを \(installed) 件配置")
        }
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
                .environmentObject(DSPSettings.shared)
                .preferredColorScheme(nil)   // 端末のライト/ダーク設定に従う
        }
    }
}
