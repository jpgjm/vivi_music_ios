# VIVI Music (iOS / Swift)

[VIVI Music](https://github.com/vivizzz007/vivi-music) の iOS 版。

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

## rev.85 の変更

公式 iOS アプリ (YouTube 20.21.6 / YouTube Music 8.21.3) のバイナリと
データコンテナを解析した結果に基づく、セッション同一性まわりの修正。

### 実測でわかったこと

コンテナを 3 回 (サインアウト → サインイン → 再サインアウト) 取得して比較した。

- 公式は **visitorData をまったく引き直さない**。3 回とも完全に同一
  (visitor id・発行時刻・内部の `21.YT=` ブロブの sha1 まで一致)。
- その単一の visitorData のまま、itag 140 を **3.5〜4.1 MiB
  (約 240 秒ぶん)** 連続で取得できていた。1 MiB / 65 秒の制限に
  当たっていない。
- identity の分離は visitorData ではなく
  **`X-YouTube-DataSync-Id`** ヘッダで行われている。未ログイン時も
  端末固定の UUID を `<UUID>||` の形で必ず送っている。
- 音声フラグメントは **9.9846 秒 (440320 / 44100) 固定・約 161.5 KB**。
  1 MiB はちょうど 6.49 フラグメント = 64.8 秒に当たる。
- キャッシュの `cache_metadata` を見ると、セグメントは 1 から末尾まで
  **連番で隙間なく**並んでいる (= 先頭からの保持を申告している)。

### 修正内容

| # | 内容 | 対象 |
| --- | --- | --- |
| 1 | `StreamerContext.ClientInfo` に `visitorData` (field 14) を追加 | `SABRProbe` / `SABRStream` |
| 2 | poToken の紐づけ先を、SABR の player を叩いたセッションに統一 | `SABRStream.prepare()` |
| 3 | `ClientAbrState.elapsed_wall_time_ms` を実経過時間に変更 | `SABRProbe` / `SABRStream` |
| 4 | `buffered_ranges` を累積で送るよう変更 | `SABRProbe.BufferedRange.extend` |
| 5 | `X-YouTube-DataSync-Id` ヘッダを追加 (匿名時は端末固定 UUID) | `InnerTube` / `GuestIdentity` |
| 6 | `renewVisitorData()` を既定で無効化 | `InnerTube.allowVisitorDataRenewal` |

修正 #2 について、以前は poToken を `InnerTube.shared.visitorData`
(検索やホームで先に走る WEB_REMIX 由来) に紐づけていた。SABR は
WEB (www.youtube.com) で player を叩くので、

```
poToken の紐づけ先 : WEB_REMIX 由来の visitorData
player を叩いた相手 : WEB
SABR で名乗る相手   : (名乗っていない)
```

と三者がずれていた。#1 と #2 でこれを 1 本に揃えている。

### 切り戻し方

いずれも 1 箇所で戻せるようにしてある。

- #4 を戻す → `SABRStream.consume` の `cumulativeBuffered` 更新を止める
- #6 を戻す → `InnerTube.allowVisitorDataRenewal = true`

## rev.86 の変更

### ビルド修正

`SABRStream.prepare()` に追加したログ行で、`PoTokenBinding?` を
アンラップせずに `.kind` を参照していた (rev.85 のバグ)。

### 診断ログの不具合修正

実機ログ (2026-08-18) で見つかった 2 件。いずれもログの結論が
実態とずれており、判断を誤らせるもの。

**① 引き直していないのに「引き直した」と出る**

`InnerTube.allowVisitorDataRenewal` が rev.85 で既定 false に
なったため `renewVisitorData()` は何もせず false を返すが、
呼び出し側が戻り値を見ずに「visitorData を引き直して解決し直す」と
出力していた。戻り値で文言を分けるようにした。

対象: `StreamResourceLoader.swift` / `StreamFetcher.swift`

**② `range=` クエリ診断が誤った結論を出す**

3 か所 (先頭 / 1MiB跨ぎ / 1MiB以降) のうち **どれか 1 つでも**
200/206 なら「range= クエリ方式が使える」としていた。
先頭 512KiB は Range ヘッダでも普通に通るので、何も切り分けられて
いなかった。

実測:

```
範囲診断 (range= クエリ): 先頭=200(512KiB) / 1MiB跨ぎ=403(0KiB) / 1MiB以降=403(0KiB)
結論: range= クエリ方式が使える。Range ヘッダから切り替える価値がある   ← 誤り
```

**1 MiB 以降が取れたか**だけで判定するよう変更し、結論を 3 分岐に
した。本文が空の 200/206 も「通った」に数えないようにしている。

対象: `StreamProbe.probeRangeQuery`

## rev.87 の変更

### 再生中の 1 MiB 制限から SABR へエスカレート

rev.85 で入れた SABR 側の修正 (#1 `StreamerContext.visitorData` /
#2 poToken 紐づけ統一 / #3 `elapsed_wall_time_ms` / #4
`buffered_ranges` 累積) は、実機ログ上 **一度も実行されていなかった**
(`SABR 準備完了` が 0 回)。

原因は `playViaSABR` の発動条件。`PlayerManager` の catch ブロック
からしか呼ばれず、「最初の URL 解決が throw したとき」だけが条件に
なっていた。実際に起きているのは:

```
ANDROID_VR が URL を返す → 解決は成功 → 再生開始 → catch に入らない
→ offset 638976 付近で HTTP 403 → AVPlayer が「曲の終端」と判断
→ 次の曲へ
```

IOS / WEB は `adaptiveFormats` に url を持たない SABR 専用応答しか
返さないため、直接 URL を返すのは ANDROID_VR だけ。その ANDROID_VR が
1 MiB で切られる以上、ここで SABR に逃げられないと詰みになる
(実機ログでは 7 曲すべて途中で終わっていた)。

**変更点**

- `StreamResourceLoader` に `onBlockedByQuota` コールバックを追加。
  1 MiB 制限と判断できる 403 で、URL の取り直しもクライアントの
  切り替えも尽きたときに 1 曲 1 回だけ呼ぶ。
- `PlayerManager.escalateToSABR(videoID:token:)` を追加。
  MainActor へ戻してから `playViaSABR` を走らせ、成功したら
  聴いていた位置へ seek して戻す。一時停止中だった場合は
  再生を再開しない。

**判定条件** (期限切れの 403 と混同しないため両方を見る)

```
(HTTP 403 または再試行を使い切った -1) かつ
(要求範囲の終端 >= 1 MiB または開始 >= 1 MiB)
```

先頭付近の 403 は URL の失効が原因のことが多く、取り直しで通るので
対象外にしている。

### SABR 打ち切り時のログを強化

rev.85 の修正が効いたかを 1 行で判断できるようにした。

```
SABR: 2 往復続けて前進せず打ち切り
  (取得済み 1105KiB = 1.079MiB / 69秒 / 全長 4360KiB
   / 保護=2 / トークン種別=visitorData / セッション=CgtEZU1ZSVQw
   / 方針[...])
```

- `保護=1` → 認証が通った。rev.85 の修正が効いた
- `保護=2` → 認証待ちのまま。attestation 側が原因

あわせて、引き直しが無効化されているのに「引き直す」と出ていた
文言も戻り値で分けるようにした。

## rev.88 の変更

### 1 MiB 制限の切り分け導線

rev.85〜87 で SABR のリクエスト形状をすべて直したが、実機ログで
`StreamProtectionStatus = 2` は解けず、取得量は 1,105 KiB
(= 1.079 MiB / 69 秒) でバイト単位まで従来と同一だった。
`playbackCookie` の往復も `buffered_ranges` の累積も正しく動いた上での
結果なので、**リクエストの組み立て方は原因ではない**ことが確定した。

残る問いはひとつ。

> 1 MiB 制限は「URL」に紐づくのか、「取りに行くクライアント」に
> 紐づくのか。

ViviMusic が解決した URL を別の端末 (Termux の curl) から叩けば分かる。

| 結果 | 意味 | 次の設計 |
| --- | --- | --- |
| 403 / 0 バイト | URL・セッションに紐づく | 公式バイナリに再生を委ねる必要がある |
| 206 / 524288 バイト | ViviMusic の要求の出し方が原因 | 手元で直せる |

**変更点**

- `StreamURLDiagnostics` を追加。直近に解決した再生 URL を
  **メモリ上にだけ** 控える (ディスクには保存しない)。
- `StreamURL` に `fullURLForDiagnostics` / `redacted` /
  `diagnosticScript` を追加。
- 設定画面に「1 MiB 制限の切り分け」セクションを追加。
  検証スクリプト / URL 全文 / 伏字版をコピーできる。
- 「URL 全文をログに出す」トグルを追加。**既定は無効。**

### 秘匿情報の扱い

videoplayback URL には次が平文で入っている。

```
ip=    発行時のグローバル IP アドレス
sig=   署名
lsig=  別系統の署名
pot=   poToken (付いている場合)
```

そのため既定ではログに出さず、共有用には `redacted` で
`ip` / `sig` / `lsig` / `pot` / `id` / `ei` を伏字にしたものを使う。

### 実験の手順

1. 1 曲再生する (URL が控えられる)
2. 設定 → 「検証スクリプトをコピー」
3. iPad と同じ Wi-Fi の Termux に貼って実行
4. **(1) を先に実行する。** (2) を先にやると
   「先頭 512KiB を消費した」と解釈される余地が残る

URL は `expire` で失効し `ip` で回線に紐づくので、
コピーしてすぐ、同じ回線から実行すること。
対照の (2) が 206 でなければ結果は無効。

## Tools/

### gpb_fields.py

iOS の Mach-O バイナリから ObjC protobuf (GPBMessage) のフィールド番号を
抽出する。`.proto` が手元に無くても番号を確定できる。

```bash
# フィールド名から、それを含むメッセージの全フィールドを出す
python3 Tools/gpb_fields.py Payload/YouTube.app/YouTube visitorData

# どんなフィールド名があるか探す
python3 Tools/gpb_fields.py Payload/YouTube.app/YouTube --grep potoken

# JSON で出す
python3 Tools/gpb_fields.py Payload/YouTube.app/YouTube visitorData --json
```

既知の番号 (`clientName=16` / `clientVersion=17`) で自動的に検算するので、
レコード境界のずれに気付ける。**この検算を無視しないこと。**
`number` の読み取り位置を 1 レコード誤ると、すべての番号が 1 小さく出る。

`video_streaming::*` (SABR/UMP の `ClientAbrState` / `BufferedRange` /
`StreamerContext` / `MediaHeader` など) は C++ の protobuf-lite で
フィールド名が残っていないため、このスクリプトでは取れない。

## ライセンス

GPL-3.0 (オリジナルの VIVI Music に合わせる)。
