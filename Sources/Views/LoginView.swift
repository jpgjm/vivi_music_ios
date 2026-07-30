//
//  LoginView.swift
//  ViviMusic
//
//  Google (YouTube) へのログイン画面。
//  デバイスフローなので、この画面ではコードを表示するだけ。
//  実際の認証は利用者が普段のブラウザで行う。
//

import SwiftUI
import UIKit

struct LoginView: View {
    @EnvironmentObject private var auth: GoogleAuthService
    @Environment(\.dismiss) private var dismiss

    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            Group {
                switch auth.state {
                case .signedOut:
                    signedOutView
                case .awaitingApproval(let code, let url):
                    awaitingView(code: code, url: url)
                case .signedIn:
                    signedInView
                }
            }
            .navigationTitle("Google にログイン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        if case .awaitingApproval = auth.state {
                            auth.cancelSignIn()
                        }
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - 未ログイン

    private var signedOutView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 24)

                Text("ログインすると再生できるようになります")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 10) {
                    Label("YouTube が bot 判定で再生を拒否するのを防げます",
                          systemImage: "checkmark.circle")
                    Label("再生が途中で止まる問題が解消します",
                          systemImage: "checkmark.circle")
                    Label("パスワードはこのアプリに入力しません",
                          systemImage: "lock.shield")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)

                if let message = auth.statusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Button {
                    Task { await auth.startSignIn() }
                } label: {
                    Label("ログインを開始", systemImage: "arrow.right.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .padding(.horizontal, 24)
                .padding(.top, 8)

                Text("アプリ内にログイン画面は表示しません。"
                     + "Google は埋め込みブラウザからのログインを拒否するため、"
                     + "テレビなどと同じ「コードを入力する」方式を使います。"
                     + "アカウント情報の入力は Google の正規ページ上でのみ行われます。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
        }
    }

    // MARK: - 承認待ち

    private func awaitingView(code: String, url: String) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("次の手順で承認してください")
                    .font(.headline)
                    .padding(.top, 20)

                VStack(alignment: .leading, spacing: 12) {
                    stepRow(number: 1, text: "下のボタンで Google のページを開く")
                    stepRow(number: 2, text: "このコードを入力する")
                    stepRow(number: 3, text: "承認するとこの画面が自動で切り替わります")
                }
                .padding(.horizontal, 24)

                // コード表示
                VStack(spacing: 8) {
                    Text(code)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button {
                        UIPasteboard.general.string = code
                        didCopy = true
                    } label: {
                        Label(didCopy ? "コピーしました" : "コードをコピー",
                              systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.footnote)
                    }
                }
                .padding(.horizontal, 24)

                Button {
                    if let target = URL(string: url) {
                        UIApplication.shared.open(target)
                    }
                } label: {
                    Label("Google のページを開く", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .padding(.horizontal, 24)

                Text(url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(auth.statusMessage ?? "承認を待っています…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)

                Button("やめる") { auth.cancelSignIn() }
                    .font(.footnote)
                    .padding(.bottom, 24)
            }
        }
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Theme.accent)
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
    }

    // MARK: - ログイン済み

    private var signedInView: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("ログイン済みです")
                .font(.headline)

            Text("再生時に自動でアカウント情報が使われます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(role: .destructive) {
                auth.signOut()
            } label: {
                Label("ログアウト", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 40)
            .padding(.top, 8)

            Spacer()
        }
        .padding(.top, 40)
    }
}
