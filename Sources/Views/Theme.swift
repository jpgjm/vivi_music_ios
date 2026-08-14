//
//  Theme.swift
//  ViviMusic
//
//  VIVI Music (Material 3 / Expressive) の見た目に寄せるための共通定義。
//  角丸を大きめに、アクセントは紫系にしている。
//

import SwiftUI

enum Theme {
    /// VIVI Music のアクセントカラーに近い紫。
    static let accent = Color(red: 0.70, green: 0.53, blue: 1.00)

    /// カード / タイルの角丸。Material 3 は角丸が大きいのが特徴。
    static let cardRadius: CGFloat = 12
    static let artworkRadius: CGFloat = 16
    static let largeArtworkRadius: CGFloat = 24

    /// ホームの横スクロール棚 1 枚あたりの幅。
    static let shelfItemWidth: CGFloat = 148

    /// ミニプレイヤーの高さ (下部の余白計算に使う)。
    static let miniPlayerHeight: CGFloat = 64
}

extension View {
    /// カード風の背景をつける。
    func viviCard() -> some View {
        self
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}
