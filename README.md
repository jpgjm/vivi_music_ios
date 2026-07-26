# VIVI Music (iOS / Swift)

VIVI Music の iOS 版。Flutter 版を **ネイティブ Swift / SwiftUI に全面書き換え** したもの。

## Flutter 版からの変更点

| | Flutter 版 | Swift 版 (これ) |
| --- | --- | --- |
| UI | Flutter Material 3 | SwiftUI |
| 再生 | just_audio | AVPlayer |
| バックグラウンド再生 | audio_service | AVAudioSession + MPNowPlayingInfoCenter |
| YouTube 連携 | youtube_explode_dart | **InnerTube を Swift で自前実装** |
| ホーム/トレンド | なし | **あり** (FEmusic_home / FEmusic_charts) |
| 診断ログ | print のみ | **EventLog + アプリ内ログビューア** |
| ビルド | Flutter + CocoaPods | **xcodegen + xcodebuild のみ** |

ビルド面が大きく単純化されたのが実利的に一番大きい。Podfile 生成、
xcconfig の連結、Generated.xcconfig といった Flutter/CocoaPods 由来の
不安定要素が消え、CI は `xcodegen generate` → `xcodebuild` の 2 手順になった。

## 構成

```
.
├── project.yml                       # xcodegen 定義 (xcodeproj は生成物なのでコミットしない)
├── .github/workflows/build-ipa.yml   # macOS ランナーで無署名 IPA をビルド
└── Sources/
    ├── App/ViviMusicApp.swift
    ├── Core/
    │   ├── EventLog.swift            # 診断ログ (AlarmClock と同方式)
    │   ├── JSON.swift                # InnerTube の巨大 JSON を安全に辿る
    │   └── Models.swift
    ├── InnerTube/
    │   ├── YouTubeClient.swift       # WEB_REMIX / IOS / ANDROID_VR
    │   ├── InnerTube.swift           # HTTP 層
    │   ├── Parsers.swift             # レスポンス → モデル
    │   └── YouTubeAPI.swift          # 高レベル API
    ├── Playback/
    │   ├── PlayerManager.swift       # AVPlayer + キュー
    │   └── NowPlayingCenter.swift    # ロック画面 / コントロールセンター
    ├── Services/
    │   ├── DownloadManager.swift     # オフライン保存
    │   ├── LibraryStore.swift        # お気に入り / 履歴
    │   └── LyricsService.swift       # LRCLib 同期歌詞
    └── Views/                        # SwiftUI 画面一式
```

## 画面

- **ホーム** — YouTube Music のホームフィード (Quick picks / おすすめ)
- **探索** — チャート(トレンド) / 新着リリース / ムード
- **検索** — 入力中に候補(オートコンプリート)、検索履歴
- **ライブラリ** — プレイリスト / お気に入り / ダウンロード / 再生履歴
- **詳細** — アルバム / プレイリスト / アーティストのページ
  (一括再生・シャッフル再生・一括ダウンロード)
- **プレイヤー** — アートワーク / 同期歌詞 / キュー を切替、シャッフル・リピート、
  キューの並べ替えと削除、スリープタイマー
- **設定 → 診断ログ** — 種類別フィルタ、エラーのみ表示、書き出し

## 診断ログ

再生やダウンロードの失敗を追えるよう、主要な操作をすべて記録している。

記録される種類: 起動 / 通信 / ホーム / 探索 / 検索 / URL解決成功 / URL解決失敗 /
再生開始 / 再生停止 / 再生エラー / キュー / DL開始 / DL完了 / DL失敗 / 歌詞 / 保存

- 通信は所要時間 (ms) つきで記録されるのでボトルネックが分かる
- エラーは型名・localizedDescription・URLError.code まで残す
- 設定 → 診断ログ → ファイルに書き出す で txt を共有できる

不具合報告の際はこのログを添付してもらうのが最短。

## ビルド

GitHub に push すると Actions が無署名 IPA を作る。
Actions タブ → Build iOS IPA → Run workflow でも手動実行できる。

成果物は `vivi-music-ipa` artifact 内の `vivi_music.ipa`。
AltStore / SideStore / Sideloadly / TrollStore でサイドロードする。

ローカルで開くには:

```bash
brew install xcodegen
xcodegen generate
open ViviMusic.xcodeproj
```

## 現状の制約

- **App Store 配布は不可**。YouTube の非公式 API 利用は規約違反のため。
- ログイン連携 (自分の YouTube Music ライブラリ同期)、Discord RPC、
  ムード/ジャンル一覧からの絞り込みは未実装。
- アーティストページの「もっと見る」による続き読み込みは未対応。
- イコライザー、再生統計、音質選択は未実装。
- InnerTube は非公式 API のため、YouTube 側の変更で壊れることがある。
  その場合は診断ログの「URL解決失敗」「通信」を見ると原因が絞れる。

## ライセンス

GPL-3.0 (オリジナルの VIVI Music に合わせる)。
