//
//  SafariView.swift
//  ViviMusic
//
//  SFSafariViewController を SwiftUI から使うためのラッパ。
//
//  なぜ UIApplication.shared.open ではなく SFSafariViewController か:
//    `open` は Safari など別アプリに切り替わってしまう。
//    ログインのたびにアプリを離れ、承認後に手動で戻ってくる必要があり手間が多い。
//    SFSafariViewController ならアプリ内にモーダルで開くので、
//    閉じればそのままログイン画面に戻る。
//    しかも Safari とクッキーを共有するため、既に Google にログイン済みなら
//    パスワード入力すら省ける (WKWebView ではクッキーが共有されない)。
//
//    Opaline も同じ理由で `SFSafariViewController` を使っている。
//
//  注意:
//    SFSafariViewController は http / https の URL しか開けない。
//    それ以外を渡すと実行時に落ちるので、呼び出し側で URL を検証すること。
//

import SwiftUI
import UIKit
import SafariServices

/// 表示対象を `.fullScreenCover(item:)` に渡すための入れ物。
/// URL 自体は Identifiable ではないのでラップする。
struct SafariTarget: Identifiable {
    let id = UUID()
    let url: URL
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    /// 利用者が Safari 画面の閉じるボタンを押したときに呼ばれる。
    /// SwiftUI 側の `item` を nil に戻すために必要。
    var onFinish: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = false

        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.delegate = context.coordinator
        controller.dismissButtonStyle = .close
        controller.preferredControlTintColor = UIColor(Theme.accent)
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // URL の差し替えはできない (別 URL なら別インスタンスを出す)。
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onFinish()
        }
    }
}
