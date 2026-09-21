# VIVI Music (iOS / Swift) — 詳細

[VIVI Music](https://github.com/vivizzz007/vivi-music) の iOS 版。

## 構成

```
.
├── project.yml                       # xcodegen 定義 (xcodeproj は生成物なのでコミットしない)
├── .github/workflows/build-ipa.yml   # 汎用 IPA ビルド (rev9, プロジェクト非依存)
├── Resources/Info.plist              # XcodeGen が生成 (リポジトリには空の雛形のみ)
├── docs/                             # README 以外のドキュメント
└── Source/
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
    │   ├── DSP/                      # イコライザー / 音響効果 (MusicPlayer から移植)
    │   │   ├── DSPEngine.swift       # AVAudioEngine (手動レンダリング) + effect chain
    │   │   ├── DSPTap.swift          # AVPlayer の音声を chain に通す MTAudioProcessingTap
    │   │   ├── DSPSettings.swift     # 全 DSP パラメータの永続化
    │   │   ├── DSPPreset.swift       # プリセットの保存 / 読込 (Documents/DSPPresets/)
    │   │   ├── AutoEQParser.swift / VDCParser.swift
    │   │   ├── CustomAUv3/           # DDC (BiQuad) / Convolver / Liveprog の AUv3
    │   │   └── Liveprog/             # EEL2 パーサ・バイトコード VM・サンプル
    │   ├── DownloadManager.swift     # オフライン保存
    │   ├── LibraryStore.swift        # お気に入り / 履歴
    │   └── LyricsService.swift       # LRCLib 同期歌詞
    └── Views/                        # SwiftUI 画面一式 (DSP/ はイコライザー / 音響効果の画面)
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
- **イコライザー / 音響効果** — プレイヤーの「…」→ イコライザー、または 設定 → イコライザー から開く。
  MusicPlayer と同じ画面・同じ効果 (10 バンド EQ / パラメトリック EQ / Graphic EQ / Bass Boost /
  リバーブ / ステレオ拡張 / Crossfeed / Compander / Tube / Limiter・Post-Gain / プリセット /
  AutoEQ / DDC / Convolver / Liveprog)
- **設定 → 診断ログ** — 種類別フィルタ、エラーのみ表示、書き出し

## 診断ログ

再生やダウンロードの失敗を追えるよう、主要な操作をすべて記録している。

記録される種類: 起動 / 通信 / ホーム / 探索 / 検索 / URL解決成功 / URL解決失敗 /
再生開始 / 再生停止 / 再生エラー / キュー / DL開始 / DL完了 / DL失敗 / 歌詞 / 保存 /
DSP / DSPエラー

- 通信は所要時間 (ms) つきで記録されるのでボトルネックが分かる
- エラーは型名・localizedDescription・URLError.code まで残す
- 設定 → 診断ログ → ファイルに書き出す で txt を共有できる

不具合報告の際はこのログを添付してもらうのが最短。

## ビルド

GitHub に push すると Actions が無署名 IPA を作る。
Actions タブ → Build iOS IPA → Run workflow でも手動実行できる。

成果物は 3 つで、すべて JST のビルド時刻とリポジトリ名が頭に付く。

- `<時刻>_<リポジトリ名>_ipa` … 中身は `<時刻>_<リポジトリ名>.ipa`
- `<時刻>_<リポジトリ名>_xcodebuild-log` … ビルドログ (成功時も出る)
- `<時刻>_<リポジトリ名>_Repository` … ビルド前のリポジトリのスナップショット

IPA は SideStore でサイドロードする。

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
- 再生統計、音質選択は未実装。
- イコライザー / 音響効果は MusicPlayer と同じ実装のため、同じ制約がある:
  Compander は単一バンド、ステレオ拡張と Crossfeed は簡易近似。
- DSP は再生中のストリームのサンプルレート (44.1kHz / 48kHz) で動く。
  IR / Liveprog / VDC はサンプルレートが変わるたびに読み込み直す。
- DSP の設定・プリセット・取り込んだファイルは 1.0.1 までのイコライザー設定とは別に保存される
  (1.0.1 の 10 バンド / プリアンプの値は引き継がない)。
- InnerTube は非公式 API のため、YouTube 側の変更で壊れることがある。
  その場合は診断ログの「URL解決失敗」「通信」を見ると原因が絞れる。

## ライセンス

GPL-3.0 (オリジナルの VIVI Music に合わせる)。
