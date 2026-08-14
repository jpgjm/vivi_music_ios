//
//  CopyableInfoRow.swift
//  ViviMusic
//
//  「ラベル + 値 + コピーボタン」の 1 行。
//
//  設定画面の端末情報は、不具合報告のときにそのまま貼り付けたいことが多い。
//  `.textSelection(.enabled)` だけだと長押しで範囲選択する必要があって
//  取りこぼしやすいので、押せば確実に全文が入るボタンを添える。
//

import SwiftUI
import UIKit

struct CopyableInfoRow: View {
    let label: String
    let value: String

    /// コピー直後だけチェックマークに変える。
    @State private var justCopied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)

            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)

            Button {
                copy()
            } label: {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(justCopied ? Color.green : Theme.accent)
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label) をコピー")
        }
        // 行のどこを長押ししてもコピーできるようにしておく。
        .contextMenu {
            Button {
                copy()
            } label: {
                Label("コピー", systemImage: "doc.on.doc")
            }
        }
    }

    private func copy() {
        UIPasteboard.general.string = value
        justCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            justCopied = false
        }
    }
}
