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

        // qlog はどのスレッドからでも呼べる (メインアクター以外からは
        // メインアクターへ送られる) ため、ここで起動を記録できる。
        qlogV(.info, "起動", message: "アプリ起動 (rev.88 共有シート ShareSheet を独立ファイルに復元)")

        // Documents/Liveprog/ に Liveprog サンプルスクリプトを配置 (未配置分のみ)
        let installed = LiveprogSamples.installIfNeeded()
        if installed > 0 {
            qlogV(.info, "DSP", message: "Liveprog サンプルを \(installed) 件配置")
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
