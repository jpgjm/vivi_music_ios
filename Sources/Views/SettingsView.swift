//
//  SettingsView.swift
//  ViviMusic
//
//  設定と診断の入口。現状は診断まわりが中心。
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var auth: GoogleAuthService
    @State private var showLogin = false
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteAllConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showLogin = true
                    } label: {
                        HStack {
                            Label("Google アカウント",
                                  systemImage: auth.isSignedIn
                                      ? "person.crop.circle.badge.checkmark"
                                      : "person.crop.circle")
                            Spacer()
                            Text(auth.isSignedIn ? "ログイン済み" : "未ログイン")
                                .font(.footnote)
                                .foregroundStyle(auth.isSignedIn ? .green : .secondary)
                        }
                    }
                    .tint(.primary)
                } header: {
                    Text("アカウント")
                } footer: {
                    Text(auth.isSignedIn
                         ? "ログイン中です。再生時にアカウント情報が使われます。"
                         : "YouTube が bot 判定で再生を拒否する場合、"
                           + "ログインすると解消します。")
                }

                Section("ストレージ") {
                    LabeledContent("ダウンロード済み",
                                   value: "\(downloads.downloadedSongs.count) 曲")
                    LabeledContent("使用容量", value: downloads.totalSizeText())

                    Button(role: .destructive) {
                        showDeleteAllConfirm = true
                    } label: {
                        Label("ダウンロードをすべて削除", systemImage: "trash")
                    }
                    .disabled(downloads.downloadedSongs.isEmpty)
                }

                Section("ライブラリ") {
                    LabeledContent("プレイリスト", value: "\(playlists.playlists.count) 件")
                    LabeledContent("お気に入り", value: "\(library.favorites.count) 曲")
                    LabeledContent("再生履歴", value: "\(library.history.count) 曲")
                }

                Section {
                    NavigationLink {
                        LogView()
                    } label: {
                        Label("診断ログ (\(EventLog.count()))", systemImage: "doc.text.magnifyingglass")
                    }
                    LabeledContent("PoToken",
                                   value: PoTokenService.shared.isReady ? "生成済み" : "未生成")
                    if let error = PoTokenService.shared.lastError {
                        Text("PoToken エラー: \(error)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("診断")
                } footer: {
                    Text("再生やダウンロードの失敗はここに記録されます。"
                         + "不具合を報告するときは、ログを書き出して添付してください。")
                }

                Section("このアプリ") {
                    LabeledContent("バージョン", value: appVersion)
                    LabeledContent("iOS", value: UIDevice.current.systemVersion)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(isPresented: $showLogin) {
                LoginView()
            }
            .confirmationDialog("ダウンロードをすべて削除しますか?",
                                isPresented: $showDeleteAllConfirm,
                                titleVisibility: .visible) {
                Button("すべて削除", role: .destructive) {
                    for song in downloads.downloadedSongs {
                        downloads.delete(song.id)
                    }
                }
                Button("キャンセル", role: .cancel) {}
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
