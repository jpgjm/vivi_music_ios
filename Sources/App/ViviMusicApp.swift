//
//  ViviMusicApp.swift
//  ViviMusic
//

import SwiftUI

@main
struct ViviMusicApp: App {

    init() {
        // EventLog はどのスレッドからでも呼べる (actor 隔離していない) ため
        // ここで起動を記録できる。シングルトンの初期化は MainActor 上で
        // 行いたいので RootView の .task に任せる。
        EventLog.log(.bootstrap, message: "アプリ起動 (rev.22 イコライザー/ビルド修正)")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(PlayerManager.shared)
                .environmentObject(LibraryStore.shared)
                .environmentObject(DownloadManager.shared)
                .environmentObject(PlaylistStore.shared)
                .environmentObject(GoogleAuthService.shared)
                .environmentObject(TogetherManager.shared)
                .environmentObject(EqualizerSettings.shared)
                .preferredColorScheme(nil)   // 端末のライト/ダーク設定に従う
        }
    }
}
