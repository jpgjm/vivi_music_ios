import SwiftUI
import UIKit

//
//  ShareSheet.swift
//  ViviMusic
//
//  共有シート (UIActivityViewController) の SwiftUI ラッパー。
//  曲やダウンロードファイルの共有 (ItemMenuSheet / SongMenuSheet) で使う。
//  旧 LogView.swift 内に定義されていたものを、ログ画面の汎用化に伴い独立ファイルへ移した。
//

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
