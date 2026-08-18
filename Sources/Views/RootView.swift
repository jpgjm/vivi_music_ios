//
//  RootView.swift
//  ViviMusic
//
//  タブバーとミニプレイヤーを重ねた最上位のレイアウト。
//  VIVI Music と同じく ホーム / 探索 / 検索 / ライブラリ の 4 タブ構成。
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var selectedTab = 0
    @State private var showPlayer = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                HomeView()
                    .tabItem { Label("ホーム", systemImage: "house.fill") }
                    .tag(0)

                ExploreView()
                    .tabItem { Label("探索", systemImage: "safari.fill") }
                    .tag(1)

                SearchView()
                    .tabItem { Label("検索", systemImage: "magnifyingglass") }
                    .tag(2)

                LibraryView()
                    .tabItem { Label("ライブラリ", systemImage: "books.vertical.fill") }
                    .tag(3)
            }
            .tint(Theme.accent)

            // ミニプレイヤーをタブバーの直上に重ねる
            if player.currentSong != nil {
                MiniPlayerView()
                    .onTapGesture { showPlayer = true }
                    .padding(.horizontal, 8)
                    // タブバーの高さぶん持ち上げる
                    .padding(.bottom, 49)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            // MainActor 上でシングルトンを起こし、初期化ログを起動直後に残す。
            _ = LibraryStore.shared
            _ = DownloadManager.shared
            _ = PlaylistStore.shared
            _ = GoogleAuthService.shared
            _ = CookieAuthService.shared
            _ = TogetherManager.shared
            _ = EqualizerSettings.shared
            _ = PlayerManager.shared

            // player JS (base.js) を先に取得しておく。
            // STS と署名復号関数の両方がここから来るため、
            // 最初の再生で 2MB の取得を待たされないようにする。
            // 失敗しても再生時に取り直すので、ここでは結果を見ない。
            Task.detached(priority: .utility) {
                await PlayerJSService.shared.warmUp()
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.currentSong?.id)
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerView()
        }
        // 再生エラーは画面のどこにいても分かるように出す
        .overlay(alignment: .top) {
            if let message = player.lastErrorMessage {
                ErrorBanner(message: message) {
                    player.lastErrorMessage = nil
                }
            }
        }
    }
}

/// 再生失敗などを知らせる赤帯。AlarmClock の警告バナーと同じ役割。
struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
        .task {
            // 8 秒で自動的に消す
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            onDismiss()
        }
    }
}
