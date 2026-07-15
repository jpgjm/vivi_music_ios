# VIVI Music (iOS)

VIVI Music の **iOS 版** です。オリジナル(Kotlin/Android)を移植したものではなく、
Offline-Music-Player の IPA ビルド方式に合わせて **Flutter で新規実装** したものです。

## 主要機能

- YouTube / YouTube Music 検索・再生
- LRCLib による同期歌詞表示(タップで歌詞⇔アートワーク切り替え)
- **バックグラウンド再生**(ロック画面・コントロールセンター対応)
- お気に入り / 再生履歴
- Material 3 + ダークモード

## 技術スタック

| レイヤ | 使用ライブラリ |
| --- | --- |
| 音声再生 | `just_audio` |
| バックグラウンド / ロック画面 | `audio_service` |
| YouTube 連携 | `youtube_explode_dart`(Dart 実装の InnerTube クライアント) |
| 歌詞 | LRCLib REST API(認証不要・CC0) |
| UI | Flutter Material 3 + Google Fonts |

## リポジトリ構成

Offline-Music-Player と同じミニマル構成です。`ios/` は CI 上で
`flutter create --platforms=ios` により自動生成されるためコミットしません。

```
.
├── .github/workflows/build-ipa.yml   # macOS ランナー上で IPA をビルドする CI
├── lib/                              # Dart アプリコード
│   ├── main.dart
│   ├── models.dart
│   ├── theme.dart
│   ├── pages/                        # Home / Search / Library / Player
│   ├── services/                     # YouTube / 歌詞 / ストレージ / AudioHandler
│   └── widgets/                      # MiniPlayer / LyricsView / SongTile
├── pubspec.yaml
├── LICENSE                            # GPL-3.0
└── README.md
```

## IPA のビルド

GitHub にリポジトリを push すると、`build-ipa.yml` が macOS ランナー上で
以下を実行し、**無署名 IPA** を Artifact として出力します。

1. Flutter SDK セットアップ
2. `flutter create --platforms=ios --project-name vivi_music --org com.vivi .`
3. `ios/Runner/Info.plist` にバックグラウンド再生・表示名・ATS を追記
4. `flutter pub get` → `pod install` → `flutter build ios --release --no-codesign`
5. `Runner.app` を `Payload/` に入れて zip → `vivi_music.ipa`
6. `vivi-music-ipa` という名前で artifact アップロード

手動実行は Actions タブから **Run workflow** で可能です。

## インストール(サイドロード)

App Store には配布されません。以下の方法で iPhone にインストールできます。

- **AltStore / SideStore** — 無料。7 日ごとに再署名が必要。
- **Sideloadly** — PC から USB / Wi-Fi で送り込む。
- **TrollStore**(対応 iOS のみ) — 永続署名。

いずれもビルド成果物 `vivi_music.ipa` をそのまま食わせるだけです。

## ローカル開発

```bash
flutter create --platforms=ios --project-name vivi_music --org com.vivi .
flutter pub get
flutter run   # 実機 or シミュレータ
```

`ios/Runner/Info.plist` の下記キーは手動で追記するか、CI と同じ PlistBuddy
スクリプトを一度回してください。

- `UIBackgroundModes` = `[audio]`
- `CFBundleDisplayName` = `VIVI Music`
- `NSAppTransportSecurity.NSAllowsArbitraryLoads` = `true`(YouTube CDN 対応)

## 既知の制約

- **App Store 配布不可**。YouTube の非公式 API 利用はガイドライン違反のため。
- YouTube 側の仕様変更で `youtube_explode_dart` が一時的に壊れることがあります。
  その際はパッケージを最新版に上げて再ビルドしてください。
- 現状は 1 曲キューベース。プレイリスト作成 UI 等は未実装(拡張可能)。

## ライセンス

GPL-3.0。オリジナルの VIVI Music(Android)および Offline-Music-Player
と同じライセンスに揃えています。
