//
//  Components.swift
//  ViviMusic
//
//  画面をまたいで使う小さな部品。
//

import SwiftUI

// MARK: - アートワーク

/// URL からアートワークを読み込んで表示する。読み込み中・失敗時はプレースホルダ。
struct Artwork: View {
    let url: String?
    var size: CGFloat?
    var radius: CGFloat = Theme.artworkRadius
    var circular: Bool = false

    /// 画像の見せ方。
    ///
    /// - `.fill` : 枠いっぱいに敷き詰め、はみ出しを切る。
    ///             一覧・カード・ミニプレイヤーなど、並びを揃えたい場所向け。
    /// - `.fit`  : 元の縦横比のまま収める。
    ///             プレイヤー画面のように、絵をそのまま見せたい場所向け。
    ///             16:9 のサムネイルが正方形に切られてしまうのを避けられる。
    var contentMode: ContentMode = .fill

    /// `url` が取得できなかったときに代わりに使う URL。
    ///
    /// 高解像度版 (maxresdefault) は **存在しない動画がある** ため、
    /// 404 になったら元の URL へ静かに切り替える。
    /// これが無いと、そういう動画でアートワークが真っ白になる。
    var fallbackURL: String? = nil

    /// 高解像度版の取得に失敗したか。失敗したら fallbackURL に切り替える。
    @State private var didFallBack = false

    private var effectiveURL: String? {
        if didFallBack, let fallbackURL { return fallbackURL }
        return url
    }

    var body: some View {
        Group {
            if let effectiveURL, let parsed = URL(string: effectiveURL) {
                AsyncImage(url: parsed) { phase in
                    switch phase {
                    case .success(let image):
                        if contentMode == .fill {
                            fill(image)
                        } else {
                            // 縦横比をそのまま残す。
                            // scaledToFit は提案されたサイズに収まる形で
                            // 大きさを返すので、fill のときのような
                            // レイアウトのはみ出しは起きない。
                            image.resizable().scaledToFit()
                        }
                    case .failure:
                        // ここで直接 state を書けないので onAppear に逃がす。
                        placeholderBox.onAppear {
                            if !didFallBack, fallbackURL != nil {
                                didFallBack = true
                            }
                        }
                    case .empty:
                        placeholderBox.overlay(ProgressView().controlSize(.small))
                    @unknown default:
                        placeholderBox
                    }
                }
            } else {
                placeholderBox
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        // 曲が変わったら判定をやり直す。
        .onChange(of: url) { _, _ in didFallBack = false }
    }

    /// 読み込み中・失敗時の枠。
    ///
    /// `.fit` かつサイズ未指定だと縦横比を決めるものが無く、
    /// 置ける場所いっぱいまで広がってしまう。
    /// 画像が来るまでは正方形にしておき、表示の飛びを抑える。
    @ViewBuilder
    private var placeholderBox: some View {
        if contentMode == .fit && size == nil {
            placeholder.aspectRatio(1, contentMode: .fit)
        } else {
            placeholder
        }
    }

    /// 画像を枠いっぱいに敷き詰め、はみ出した分を切り落とす。
    ///
    /// `image.resizable().scaledToFill()` をそのまま置くと、
    /// **画像自身の縦横比がレイアウト上のサイズになってしまう**。
    /// 正方形のサムネイルなら気づかないが、16:9 の横長サムネイル
    /// (ライブ映像や MV) では枠より横に 1.7 倍ほど広がる。
    /// `size` を指定していない箇所ではそれを止めるものが無いので、
    /// 親の VStack ごと画面の外まで押し広げてしまう。
    /// (2026-08-14 実測: プレイヤー画面でアートワークが全面を覆い、
    ///  曲名が画面の左外へ出て見えなくなっていた)
    ///
    /// `Color.clear` に提案サイズを受け取らせ、画像はその上に
    /// overlay として描いてから `clipped()` で切る。
    /// こうすれば画像の縦横比がレイアウトへ伝わらない。
    private func fill(_ image: Image) -> some View {
        Color.clear
            .overlay {
                image
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
    }

    /// 角丸か円かを実行時に選ぶため AnyShape で型を消す。
    private var shape: AnyShape {
        circular
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Color(.tertiarySystemFill)
            Image(systemName: "music.note")
                .font(.system(size: (size ?? 48) * 0.32))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 曲の行

/// 検索結果・ライブラリなどで使う曲 1 行。
struct SongRow: View {
    let song: Song
    var showDownloadBadge: Bool = true
    /// 三点リーダー (曲メニュー) を出すか。
    var showMenuButton: Bool = true
    /// メニューからアルバム / アーティストへ遷移したいときに呼ばれる。
    var onNavigate: ((BrowseRoute) -> Void)? = nil
    var trailing: AnyView? = nil

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager

    @State private var showMenu = false

    private var isCurrent: Bool { player.currentSong?.id == song.id }

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: song.thumbnailURL, size: 48, radius: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)

                HStack(spacing: 4) {
                    if showDownloadBadge, downloads.isDownloaded(song.id) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                    }
                    Text(song.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isCurrent && player.isPlaying {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.variableColor.iterative)
            } else if song.durationSeconds != nil {
                Text(song.durationText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let trailing { trailing }

            if showMenuButton {
                Button {
                    showMenu = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        // 押しやすいよう当たり判定を広げる
                        .frame(width: 32, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // 長押しでも同じメニューを出す
        .onLongPressGesture(minimumDuration: 0.4) {
            showMenu = true
        }
        .sheet(isPresented: $showMenu) {
            SongMenuSheet(song: song, onNavigate: onNavigate)
        }
    }
}

// MARK: - 横スクロールの棚

/// ホーム / 探索に並ぶ 1 セクション (横スクロール)。
struct ShelfSection: View {
    let section: HomeSection
    let onTapItem: (HomeItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let label = section.label, !label.isEmpty {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                Text(section.title)
                    .font(.title3.weight(.bold))
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(section.items) { item in
                        ShelfCard(item: item)
                            .onTapGesture { onTapItem(item) }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

/// 棚の中のカード 1 枚。
struct ShelfCard: View {
    let item: HomeItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: item.thumbnailURL,
                    size: Theme.shelfItemWidth,
                    circular: item.isCircular)

            Text(item.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: Theme.shelfItemWidth, alignment: .leading)
        .multilineTextAlignment(item.isCircular ? .center : .leading)
    }
}

// MARK: - 状態表示

/// 読み込み中 / 空 / エラーの共通表示。
struct StateMessage: View {
    enum Kind {
        case loading(String)
        case empty(icon: String, title: String, message: String)
        case error(String, retry: () -> Void)
    }

    let kind: Kind

    var body: some View {
        VStack(spacing: 12) {
            switch kind {
            case .loading(let text):
                ProgressView()
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            case .empty(let icon, let title, let message):
                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary)
                Text(title).font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

            case .error(let message, let retry):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text("読み込みに失敗しました").font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                Button("再試行", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}
