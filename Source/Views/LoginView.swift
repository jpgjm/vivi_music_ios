//
//  LoginView.swift
//  ViviMusic
//
//  Google (YouTube) へのログイン画面。
//  デバイスフローなので、この画面ではコードを表示するだけ。
//  実際の認証は SFSafariViewController でアプリ内に開く Google の正規ページで行う。
//
//  なぜアプリ内ブラウザ (SFSafariViewController) なのか:
//    以前は `UIApplication.shared.open` で Safari に切り替えていたが、
//    アプリを離れて承認し、手動で戻ってくる必要があり手間が多かった。
//    SFSafariViewController ならアプリ内にモーダルで開き、
//    承認が終われば自動で閉じてログイン完了までひと続きになる。
//    Safari とクッキーを共有するので、既に Google にログイン済みなら
//    アカウント選択だけで済むのも利点。
//

import SwiftUI
import UIKit

struct LoginView: View {
    @EnvironmentObject private var auth: GoogleAuthService
    @Environment(\.dismiss) private var dismiss

    @State private var didCopy = false
    /// アプリ内ブラウザで開く対象。nil でない間だけ Safari 画面が出る。
    /// `Bool` + `URL?` の 2 本立てにすると、シートの中身が確定する前に
    /// 提示が始まって 1 回目だけ空になるため `item:` 方式にしている。
    @State private var safariTarget: SafariTarget?

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
            // アプリ内ブラウザ。Opaline と同じく画面全体を覆うモーダルで出す。
            .fullScreenCover(item: $safariTarget) { target in
                SafariView(url: target.url) {
                    safariTarget = nil
                }
                .ignoresSafeArea()
            }
            // 承認が通ったら Safari 画面を自動で閉じ、ログイン済み表示に切り替える。
            // (利用者が自分で閉じる操作をしなくて済む)
            .onChange(of: auth.state) { _, newState in
                if case .signedIn = newState {
                    safariTarget = nil
                }
            }
        }
    }

    /// アプリ内ブラウザで承認ページを開く。
    /// クリップボードには触らない。コピーは利用者が「コードをコピー」ボタンで
    /// 明示的に行う (勝手にコピーするとクリップボードの中身を上書きしてしまうため)。
    private func openVerificationPage(url: String) {
        guard let target = URL(string: url),
              let scheme = target.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            // SFSafariViewController は http/https しか開けない。
            // 想定外の URL が来たときだけ従来どおり外部アプリに投げる。
            if let fallback = URL(string: url) {
                UIApplication.shared.open(fallback)
            }
            return
        }
        safariTarget = SafariTarget(url: target)
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

                Text("パスワードはこのアプリに入力しません。"
                     + "テレビなどと同じ「コードを入力する」方式で、"
                     + "アカウント情報の入力はアプリ内に開く Google の正規ページ上でのみ行われます。"
                     + "このページは Safari と同じ仕組み (SFSafariViewController) なので、"
                     + "埋め込みブラウザとして拒否されることはありません。")
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
                    stepRow(number: 1, text: "「コードをコピー」でコードをコピーする")
                    stepRow(number: 2, text: "下のボタンでアプリ内に Google のページを開く")
                    stepRow(number: 3, text: "貼り付けて承認するとブラウザが自動で閉じます")
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
                    openVerificationPage(url: url)
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
