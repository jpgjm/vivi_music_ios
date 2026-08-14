//
//  PlayerManager.swift
//  ViviMusic
//
//  再生の中核。AVPlayer 1 台をアプリ全体で共有し、キューを自前で管理する。
//
//  Flutter 版 (just_audio + audio_service) との対応:
//    - just_audio        → AVPlayer
//    - audio_service     → AVAudioSession + MPNowPlayingInfoCenter (NowPlayingCenter.swift)
//    - _loadToken        → loadToken (同じ考え方。連打時に古い解決結果を捨てる)
//
//  再生の優先順位:
//    1. ダウンロード済みのローカルファイル (即時・オフライン可)
//    2. InnerTube から解決したストリーム URL
//

import Foundation
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    // MARK: - 公開状態

    @Published private(set) var currentSong: Song?
    @Published private(set) var queue: [Song] = []
    @Published private(set) var currentIndex: Int = -1
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// 直近のエラー。UI に赤帯で出す。
    @Published var lastErrorMessage: String?

    /// ローカルファイル再生中かどうか (UI にオフラインバッジを出す)
    @Published private(set) var isPlayingLocal: Bool = false

    // MARK: - シャッフル / リピート

    enum RepeatMode: String {
        case off, all, one

        /// ボタンを押したときの次の状態。off → all → one → off と巡回する。
        var next: RepeatMode {
            switch self {
            case .off: return .all
            case .all: return .one
            case .one: return .off
            }
        }

        var iconName: String {
            switch self {
            case .off, .all: return "repeat"
            case .one:       return "repeat.1"
            }
        }

        var isActive: Bool { self != .off }
    }

    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var isShuffled: Bool = false

    /// シャッフル解除時に元の並びへ戻すため、シャッフル前のキューを保持する。
    private var unshuffledQueue: [Song] = []

    // MARK: - 内部

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    /// 連打対策。最新の読み込み以外は破棄する。
    private var loadToken: Int = 0

    /// ストリーム再生時に通信を肩代わりする役。
    /// AVURLAsset は delegate を弱参照するので、こちらで保持しておく。
    private var resourceLoader: StreamResourceLoader?
    /// ローダーの処理を回す専用キュー。
    private let loaderQueue = DispatchQueue(label: "com.music.vivi.resourceloader")

    /// イコライザー。曲ごとに取り付け直す。
    private var equalizerTap: EqualizerTap?
    private var equalizerCancellable: AnyCancellable?

    /// 現在再生を試みているストリーム。AVPlayer が失敗したときの
    /// フォールバック (一時ファイルへ落として再生) で使う。
    private var currentStream: StreamInfo?
    /// 同じ曲でフォールバックを繰り返さないためのフラグ。
    private var didTryFileFallback = false
    /// AVPlayer による直接ストリーム再生が連続で失敗した回数。
    /// 続けて失敗する環境では毎回 1 秒近く無駄になるので、
    /// 一定回数を超えたら最初からファイル経由に切り替える。
    private var consecutiveStreamFailures = 0

    private init() {
        configureAudioSession()
        observePlayer()
        NowPlayingCenter.shared.attach(to: self)
        observeEqualizer()
        EventLog.log(.bootstrap, message: "PlayerManager 初期化")
    }

    // MARK: - オーディオセッション

    /// バックグラウンド再生とロック画面操作を有効にする。
    /// これを設定しないと画面を閉じた瞬間に音が止まる。
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            EventLog.log(.bootstrap, message: "AVAudioSession: playback で有効化")
        } catch {
            EventLog.logError(.playError, error: error, context: "AVAudioSession 設定")
        }
    }

    // MARK: - 監視

    private func observePlayer() {
        // 再生位置を 0.5 秒ごとに更新する
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                // ------------------------------------------------------
                // 曲の長さは YouTube のメタデータを優先する。
                //
                // AVFoundation が googlevideo の m4a を解析すると、
                // 実際の 2 倍の長さと判断することがある
                // (実測 449 秒 / 実際 225 秒 など)。
                // 検索やプレイリストから得た長さの方が正確なので、
                // 分かっている場合はそちらを表示に使う。
                // ------------------------------------------------------
                if let expected = self.currentSong?.duration, expected > 0 {
                    self.duration = expected
                } else if let item = self.player.currentItem {
                    let d = item.duration.seconds
                    if d.isFinite, d > 0 { self.duration = d }
                }
                NowPlayingCenter.shared.updatePlaybackPosition()
            }
        }

        // 曲の終端で次へ進む
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                // 差し替え前の古い item から届いた通知を無視する。
                // これがないと曲送りのたびに二重で次へ進んでしまう。
                guard let item = notification.object as? AVPlayerItem,
                      item === self.player.currentItem else { return }
                EventLog.log(.playStop, message: "曲の終端に到達 → 次の曲へ")
                await self.advanceAutomatically()
            }
        }
    }

    // MARK: - 再生開始

    /// 1 曲を再生する。`queue` を渡すとその並びをキューにする。
    func play(song: Song, queue newQueue: [Song]? = nil) async {
        let list = newQueue ?? [song]
        let index = list.firstIndex(where: { $0.id == song.id }) ?? 0
        await setQueue(list, startAt: index)
    }

    /// キューを差し替えて指定位置から再生する。
    func setQueue(_ songs: [Song], startAt index: Int) async {
        guard !songs.isEmpty else { return }
        queue = songs
        currentIndex = min(max(index, 0), songs.count - 1)
        // 別のキューに入れ替わったのでシャッフル状態は解除する。
        // (shufflePlay はこの後に自分でフラグを立て直す)
        isShuffled = false
        unshuffledQueue = []
        EventLog.log(.queue, message: "キュー \(songs.count) 件 / 開始位置 \(currentIndex)")
        await loadCurrent()
    }

    /// 現在位置の曲を読み込んで再生する。
    private func loadCurrent() async {
        guard currentIndex >= 0, currentIndex < queue.count else { return }
        let song = queue[currentIndex]
        loadToken += 1
        let token = loadToken

        // ---- UI を先に更新する ----
        // ストリーム解決を待たずにミニプレイヤーとロック画面を出す。
        // これが「タップした瞬間に反応する」体感を作る。
        currentSong = song
        isLoading = true
        lastErrorMessage = nil
        currentStream = nil
        didTryFileFallback = false
        duration = song.duration ?? 0
        currentTime = 0
        NowPlayingCenter.shared.update(song: song)

        let started = Date()

        // ---- 1. ローカルファイル優先 ----
        if let localURL = DownloadManager.shared.localFileURL(for: song.id) {
            guard token == loadToken else { return }
            isPlayingLocal = true
            replaceItem(url: localURL, song: song)
            EventLog.logDuration(.playStart, videoID: song.id, start: started,
                                 message: "ローカル再生: \(localURL.lastPathComponent)")
            isLoading = false
            player.play()
            isPlaying = true
            LibraryStore.shared.pushHistory(song)
            return
        }

        // ---- 2. ストリーム解決 ----
        isPlayingLocal = false
        do {
            let stream = try await YouTubeAPI.resolveStream(videoID: song.id)
            guard token == loadToken else {
                EventLog.log(.queue, videoID: song.id, message: "解決完了したが既に別の曲へ遷移済み。破棄")
                return
            }
            currentStream = stream

            // 検索を経由せず再生した曲は長さを持っていないことがある。
            // player 応答から分かるので、ここで補っておく。
            // これがないと AVFoundation の誤った長さが表示されてしまう。
            if song.durationSeconds == nil, let seconds = stream.durationSeconds, seconds > 0 {
                var updated = song
                updated.durationSeconds = seconds
                currentSong = updated
                if currentIndex >= 0 && currentIndex < queue.count {
                    queue[currentIndex] = updated
                }
                duration = TimeInterval(seconds)
                EventLog.log(.playStart, videoID: song.id,
                             message: "長さを player 応答から補完: \(seconds)秒")
            }

            // 直接ストリームが続けて失敗しているなら、待ち時間を無駄にせず
            // 最初からファイル経由で再生する。
            if consecutiveStreamFailures >= 2 {
                EventLog.log(.playStart, videoID: song.id,
                             message: "直近 \(consecutiveStreamFailures) 回失敗のため最初からファイル経由")
                await fallbackToTemporaryFile(song: song)
                return
            }

            guard Self.playbackURL(for: stream) != nil else {
                throw InnerTubeError.noStream(videoID: song.id)
            }
            replaceStreamItem(stream: stream, song: song)
            let rangeNote = "len=\(stream.contentLength)"
            EventLog.logDuration(.playStart, videoID: song.id, start: started,
                                 message: "ストリーム再生 \(stream.bitrate / 1000)kbps "
                                     + "\(stream.mimeType) \(rangeNote)")
            isLoading = false
            player.play()
            isPlaying = true
            LibraryStore.shared.pushHistory(song)
        } catch {
            guard token == loadToken else { return }

            // ---- 3. 最後の逃げ道: SABR ----
            //
            // 通常の再生 URL が全滅したときだけ使う。
            // 2026-08 以降、googlevideo が「先頭 1 MiB より先を返さない」
            // 状態になることがあり、そのときは Range 方式のどの経路も通らない。
            // SABR はサーバー主導で送る別系統の仕組みで、
            // 制限が出ている最中でも取得できることを実測で確認している。
            //
            // ただし曲全体を取り切ってから再生するので数秒かかる。
            // あくまで「鳴らないよりまし」の位置づけ。
            var isBlockedByPolicy = false
            if let innerTubeError = error as? InnerTubeError,
               case .playabilityBlocked = innerTubeError {
                isBlockedByPolicy = true
            }

            if !isBlockedByPolicy, await playViaSABR(song: song, token: token, started: started) {
                return
            }

            isLoading = false
            isPlaying = false

            // Premium 限定・地域制限などで元から再生できない曲は、
            // プレイリストに紛れているのが普通なので赤帯を出さず静かに次へ送る。
            if !isBlockedByPolicy {
                lastErrorMessage = "「\(song.title)」を再生できませんでした: \(error.localizedDescription)"
            }
            EventLog.logError(.playError, videoID: song.id, error: error, context: "loadCurrent")
            // 失敗した曲で止まらないよう次へ送る
            await advanceAutomatically()
        }
    }

    // MARK: - 再生 URL の組み立て

    /// 再生用の URL を作る。
    ///
    /// 注意: ここで `&range=0-N` を足してはいけない。
    ///   実測 (診断ログ) では、IOS クライアントが発行した URL に
    ///   `&range=` クエリを足すと **HTTP 403** で拒否される。
    ///   一方、素の URL は `Range: bytes=0-1` ヘッダに対して
    ///   HTTP 206 を正しく返す。つまり範囲指定は
    ///   「クエリではなく HTTP ヘッダで」行うのが正しい。
    ///
    ///   Flutter 版で `&range=` が有効だったのは ANDROID_VR クライアントの
    ///   URL だったためで、IOS クライアントでは逆効果になる。
    static func playbackURL(for stream: StreamInfo) -> URL? {
        URL(string: stream.url)
    }

    /// AVPlayerItem を差し替える。
    /// 再生時間が食い違ったときに、資産の中身をログへ残す。
    /// timescale や収録トラックが分かれば原因を絞り込める。
    private func logAssetDetails(item: AVPlayerItem, videoID: String) async {
        let asset = item.asset
        do {
            let assetDuration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .audio)

            var lines: [String] = [
                "asset=\(String(format: "%.1f", assetDuration.seconds))s",
                "timescale=\(assetDuration.timescale)",
                "音声トラック=\(tracks.count)",
            ]

            if let track = tracks.first {
                let timeRange = try await track.load(.timeRange)
                let naturalScale = try await track.load(.naturalTimeScale)
                let rate = try await track.load(.estimatedDataRate)
                lines.append("track=\(String(format: "%.1f", timeRange.duration.seconds))s")
                lines.append("naturalTimeScale=\(naturalScale)")
                lines.append("推定ビットレート=\(Int(rate / 1000))kbps")
            }

            // 2 倍問題が解決して以降、この行は「正常な状態の記録」になった。
            // エラー扱いのままだと赤く出て誤解を招くので通常のログにする。
            // (取得に失敗したときだけエラーとして残す)
            EventLog.log(.playStart, videoID: videoID,
                         message: "資産情報: " + lines.joined(separator: " / "))
        } catch {
            EventLog.logError(.playError, videoID: videoID, error: error,
                              context: "資産情報の取得")
        }
    }

    /// ストリームを再生する。通信は StreamResourceLoader が肩代わりする。
    ///
    /// AVPlayer に googlevideo の URL を直接渡すと、範囲リクエストの扱いが
    /// 噛み合わず再生時間が実際の 2 倍になる問題が起きたため、
    /// 独自 scheme の URL を渡して通信をこちらで行う。
    private func replaceStreamItem(stream: StreamInfo, song: Song) {
        statusObservation?.invalidate()

        guard let loaderURL = StreamResourceLoader.makeURL(from: stream.url) else {
            EventLog.log(.playError, videoID: song.id, message: "再生用 URL を作れませんでした")
            return
        }

        let videoID = song.id
        let loader = StreamResourceLoader(
            stream: stream,
            videoID: videoID,
            refresh: { blockedList in
                    // blockedList は「途中で 403 になったクライアント名」の
                    // カンマ区切り。同じものを引かないよう除外して解決し直す。
                    let excluding = Set(blockedList.split(separator: ",").map(String.init))
                    return try await YouTubeAPI.resolveStream(videoID: videoID,
                                                             excluding: excluding)
                }
        )
        // AVURLAsset は delegate を弱参照するため、こちらで持ち続ける
        resourceLoader = loader

        let asset = AVURLAsset(url: loaderURL)
        asset.resourceLoader.setDelegate(loader, queue: loaderQueue)

        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        observeStatus(of: item, song: song)
        attachEqualizer(to: item, asset: asset)
    }

    /// AVPlayerItem を差し替える。ローカルファイル再生に使う。
    private func replaceItem(url: URL,
                             song: Song,
                             mimeType: String? = nil,
                             clientName: String = "") {
        statusObservation?.invalidate()

        var options: [String: Any] = [:]
        if let mimeType {
            // 拡張子の無い URL でもコンテナ形式を判別できるよう MIME を明示する
            options["AVURLAssetOutOfBandMIMETypeKey"] = mimeType
            _ = clientName
            options["AVURLAssetHTTPHeaderFieldsKey"] = [
                "User-Agent": YouTubeClient.userAgentWeb
            ]
        }

        let asset = AVURLAsset(url: url, options: options.isEmpty ? nil : options)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        observeStatus(of: item, song: song)
        attachEqualizer(to: item, asset: asset)
    }

    // MARK: - イコライザー

    /// 再生中の音声にイコライザーを取り付ける。
    ///
    /// AVPlayer では AVAudioUnitEQ を挟めないので、
    /// MTAudioProcessingTap で音声を受け取って加工する。
    /// 音声トラックの取得は非同期なので、取り付けは少し遅れて行われる。
    private func attachEqualizer(to item: AVPlayerItem, asset: AVAsset) {
        // 前の曲のフィルタの履歴が残っていると、切り替わり際に雑音が出る
        equalizerTap?.reset()

        let tap = EqualizerTap()
        equalizerTap = tap

        Task { @MainActor in
            do {
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                    return
                }
                // 取得を待つ間に別の曲へ移っていたら何もしない
                guard self.player.currentItem === item else { return }

                let settings = EqualizerSettings.shared
                if let mix = tap.makeAudioMix(
                    for: asset,
                    track: track,
                    settings: (settings.isEnabled, settings.gains, settings.preampDB)
                ) {
                    item.audioMix = mix
                }
            } catch {
                EventLog.logError(.playError, error: error, context: "イコライザーの取り付け")
            }
        }
    }

    /// 設定画面での変更を、再生中の音にそのまま反映する。
    private func observeEqualizer() {
        let settings = EqualizerSettings.shared
        equalizerCancellable = settings.changed
            .sink { [weak self] _ in
                self?.equalizerTap?.update(
                    settings: (settings.isEnabled, settings.gains, settings.preampDB)
                )
            }
    }

    /// 読み込み状態を監視し、失敗したらログに残してファイル経由へ切り替える。
    private func observeStatus(of item: AVPlayerItem, song: Song) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    // 直接ストリームが通ったのでカウンタを戻す
                    self.consecutiveStreamFailures = 0

                    let actual = item.duration.seconds
                    if let expected = song.duration, actual.isFinite, expected > 0 {
                        let ratio = actual / expected
                        if ratio > 1.2 || ratio < 0.8 {
                            EventLog.log(.playError, videoID: song.id,
                                         message: "再生時間が不一致: "
                                             + "実測 \(Int(actual))秒 / 想定 \(Int(expected))秒")

                            // AVFoundation が実際より長いと判断した場合、
                            // そのままだと曲が終わったあと無音が続いてしまう。
                            // 終端を明示して、想定の時刻で次へ進ませる。
                            item.forwardPlaybackEndTime =
                                CMTime(seconds: expected, preferredTimescale: 600)
                            EventLog.log(.queue, videoID: song.id,
                                         message: "終端を \(Int(expected))秒に設定")
                        }
                        // 何が起きているか追えるよう資産の情報を残す
                        await self.logAssetDetails(item: item, videoID: song.id)
                    }

                case .failed:
                    let msg = item.error?.localizedDescription ?? "不明なエラー"
                    EventLog.log(.playError, videoID: song.id,
                                 message: "AVPlayerItem.status = failed | \(msg)")
                    if !self.isPlayingLocal {
                        self.consecutiveStreamFailures += 1
                    }
                    // ストリーム再生が駄目でも、ファイルに落とせば再生できることが多い。
                    await self.fallbackToTemporaryFile(song: song)

                default:
                    break
                }
            }
        }
    }

    // MARK: - フォールバック (一時ファイル経由)

    /// AVPlayer によるストリーム再生が失敗したときの逃げ道。
    ///
    /// URL 自体は正常なのに AVPlayer がコンテナを解析できない場合、
    /// いったんファイルに落として `.m4a` の拡張子を付けてから渡すと再生できる。
    /// ダウンロード側は範囲指定つきで実績があるので、同じ手順を使う。
    ///
    /// 開始まで数秒待たされる代わりに、確実に音が出ることを優先する。
    /// SABR で曲全体を取得し、一時ファイルに落として再生する。
    ///
    /// 通常の再生 URL がすべて駄目だったときの最後の手段。
    /// 曲を取り切ってから鳴らすので数秒かかるが、
    /// 1 MiB 制限が出ている状況ではこれしか通らない。
    ///
    /// - Returns: 再生を開始できたら true
    private func playViaSABR(song: Song, token: Int, started: Date) async -> Bool {
        isLoading = true
        EventLog.log(.playStart, videoID: song.id,
                     message: "通常の経路が全滅。SABR で取得を試みる")

        do {
            let stream = SABRStream(videoID: song.id)
            let result = try await stream.fetchAll()

            guard token == loadToken, currentSong?.id == song.id else {
                EventLog.log(.queue, videoID: song.id,
                             message: "SABR の取得中に別の曲へ遷移済み。破棄")
                return false
            }

            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("sabr-\(song.id).m4a")
            try? FileManager.default.removeItem(at: destination)
            try result.data.write(to: destination)

            isPlayingLocal = false
            replaceItem(url: destination, song: song)

            EventLog.logDuration(.playStart, videoID: song.id, start: started,
                                 message: "SABR 再生 \(result.bitrate / 1000)kbps "
                                     + "\(result.mimeType) "
                                     + "\(result.data.count / 1024)KiB")
            isLoading = false
            player.play()
            isPlaying = true
            LibraryStore.shared.pushHistory(song)
            return true
        } catch {
            EventLog.logError(.playError, videoID: song.id, error: error,
                              context: "SABR 再生")
            return false
        }
    }

    private func fallbackToTemporaryFile(song: Song) async {
        guard !didTryFileFallback else {
            // 2 回目は諦めてユーザーに知らせる
            lastErrorMessage = "「\(song.title)」を再生できませんでした。"
            isLoading = false
            isPlaying = false
            return
        }
        guard let stream = currentStream else { return }
        guard currentSong?.id == song.id else { return }

        didTryFileFallback = true
        let token = loadToken
        let started = Date()

        isLoading = true
        EventLog.log(.playStart, videoID: song.id, message: "ストリーム再生に失敗。一時ファイルに落として再試行")

        // 分割取得でファイルに落とす。
        // 一括取得は 403 で拒否されるため、StreamFetcher が 1MiB ずつ
        // Range ヘッダ付きで要求する (診断で 206 を確認済みの形式)。
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-\(song.id).m4a")

        do {
            let videoID = song.id
            let written = try await StreamFetcher.downloadToFile(
                stream: stream,
                videoID: videoID,
                destination: dest,
                // 403 を受けたら URL を取り直して同じ範囲から再開する
                refresh: { blockedList in
                    // blockedList は「途中で 403 になったクライアント名」の
                    // カンマ区切り。同じものを引かないよう除外して解決し直す。
                    let excluding = Set(blockedList.split(separator: ",").map(String.init))
                    return try await YouTubeAPI.resolveStream(videoID: videoID,
                                                             excluding: excluding)
                }
            )

            guard token == loadToken, currentSong?.id == song.id else {
                try? FileManager.default.removeItem(at: dest)
                return
            }

            // 期待サイズより明らかに小さい = 転送が途中で切れている
            if stream.contentLength > 0 && written < stream.contentLength - 1024 {
                EventLog.log(.playError, videoID: song.id,
                             message: "転送が途中で切れた可能性: \(written) / \(stream.contentLength) バイト")
            }

            // AVFoundation は拡張子でコンテナを判定するので .m4a を付けてある。
            replaceItem(url: dest, song: song)
            EventLog.logDuration(
                .playStart, videoID: song.id, start: started,
                message: "ファイルから再生 "
                    + ByteCountFormatter.string(fromByteCount: Int64(written), countStyle: .file)
            )
            isLoading = false
            player.play()
            isPlaying = true
            LibraryStore.shared.pushHistory(song)

        } catch is CancellationError {
            return
        } catch {
            guard token == loadToken else { return }
            EventLog.logError(.playError, videoID: song.id, error: error,
                              context: "分割取得")
            lastErrorMessage = "「\(song.title)」を再生できませんでした: \(error.localizedDescription)"
            isLoading = false
            isPlaying = false
        }
    }

    // MARK: - トランスポート操作

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func resume() {
        guard currentSong != nil else { return }
        player.play()
        isPlaying = true
        EventLog.log(.playStart, videoID: currentSong?.id, message: "再開")
        NowPlayingCenter.shared.updatePlaybackPosition()
    }

    func pause() {
        player.pause()
        isPlaying = false
        EventLog.log(.playStop, videoID: currentSong?.id, message: "一時停止")
        NowPlayingCenter.shared.updatePlaybackPosition()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentSong = nil
        currentIndex = -1
        queue = []
        EventLog.log(.playStop, message: "停止 / キュー破棄")
        NowPlayingCenter.shared.clear()
    }

    func seek(to seconds: TimeInterval) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time) { [weak self] _ in
            Task { @MainActor in
                self?.currentTime = seconds
                NowPlayingCenter.shared.updatePlaybackPosition()
            }
        }
        // Listen Together のホストなら、同じ位置へ全員を合わせる
        TogetherManager.shared.broadcastSeek(to: seconds)
    }

    func next() async {
        guard currentIndex + 1 < queue.count else {
            EventLog.log(.queue, message: "キュー末尾のため次へ進めない")
            return
        }
        currentIndex += 1
        await loadCurrent()
    }

    func previous() async {
        // 5 秒以上再生していたら曲の頭に戻す (一般的な挙動)
        if currentTime > 5 {
            seek(to: 0)
            return
        }
        guard currentIndex > 0 else {
            seek(to: 0)
            return
        }
        currentIndex -= 1
        await loadCurrent()
    }

    func skip(to index: Int) async {
        guard index >= 0, index < queue.count else { return }
        currentIndex = index
        await loadCurrent()
    }

    /// 曲の終端 / 失敗時の自動遷移。
    /// リピート設定を尊重し、キュー末尾に到達したら関連曲を取ってきて継続する
    /// (YouTube Music と同じ挙動)。
    private func advanceAutomatically() async {
        // 「曲の終わりで停止」が有効ならここで打ち切る
        if sleepAtEndOfTrack {
            EventLog.log(.timer, videoID: currentSong?.id, message: "曲の終わりに到達したため停止")
            pause()
            seek(to: 0)
            cancelSleepTimer()
            return
        }

        // 1 曲リピートは同じ曲を頭から流し直す
        if repeatMode == .one {
            EventLog.log(.queue, videoID: currentSong?.id, message: "1曲リピート")
            seek(to: 0)
            resume()
            return
        }

        // まだ後ろに曲がある
        if currentIndex + 1 < queue.count {
            currentIndex += 1
            await loadCurrent()
            return
        }

        // 全曲リピートは先頭へ戻る
        if repeatMode == .all, !queue.isEmpty {
            EventLog.log(.queue, message: "全曲リピート: 先頭へ戻る")
            currentIndex = 0
            await loadCurrent()
            return
        }

        // 関連曲でキューを伸ばす
        if let last = currentSong {
            let related = await YouTubeAPI.related(videoID: last.id)
            let fresh = related.filter { r in !queue.contains(where: { $0.id == r.id }) }
            if !fresh.isEmpty {
                queue.append(contentsOf: fresh)
                currentIndex += 1
                EventLog.log(.queue, message: "関連曲 \(fresh.count) 件でキューを延長")
                await loadCurrent()
                return
            }
        }

        isPlaying = false
        EventLog.log(.playStop, message: "キュー終端。再生終了")
    }

    // MARK: - シャッフル / リピート操作

    /// リピートモードを off → all → one → off と切り替える。
    func cycleRepeatMode() {
        repeatMode = repeatMode.next
        EventLog.log(.queue, message: "リピート: \(repeatMode.rawValue)")
    }

    /// シャッフルを切り替える。
    /// 再生中の曲は止めず、その曲を先頭に置いて残りを並べ替える。
    func toggleShuffle() {
        guard !queue.isEmpty else { return }
        let current = currentSong

        if isShuffled {
            // 元の並びへ戻す
            let restored = unshuffledQueue.isEmpty ? queue : unshuffledQueue
            queue = restored
            currentIndex = current.flatMap { c in restored.firstIndex(where: { $0.id == c.id }) } ?? 0
            unshuffledQueue = []
            isShuffled = false
            EventLog.log(.queue, message: "シャッフル解除 (\(queue.count) 曲)")
        } else {
            unshuffledQueue = queue
            var rest = queue
            if let c = current {
                rest.removeAll { $0.id == c.id }
                rest.shuffle()
                queue = [c] + rest
                currentIndex = 0
            } else {
                rest.shuffle()
                queue = rest
                currentIndex = 0
            }
            isShuffled = true
            EventLog.log(.queue, message: "シャッフル開始 (\(queue.count) 曲)")
        }
    }

    /// 指定の曲リストをシャッフルして再生する (「シャッフル再生」ボタン用)。
    func shufflePlay(_ songs: [Song]) async {
        guard !songs.isEmpty else { return }
        var shuffled = songs
        shuffled.shuffle()
        EventLog.log(.queue, message: "シャッフル再生 \(songs.count) 曲")
        await setQueue(shuffled, startAt: 0)
        // setQueue がシャッフル状態を解除するので、その後に立て直す。
        unshuffledQueue = songs
        isShuffled = true
    }

    /// キューの末尾に追加する。
    func addToQueue(_ song: Song) {
        queue.append(song)
        EventLog.log(.queue, videoID: song.id, message: "キュー末尾に追加")
    }

    /// 次に再生する位置へ差し込む。
    func playNext(_ song: Song) {
        let insertAt = min(currentIndex + 1, queue.count)
        queue.insert(song, at: insertAt)
        EventLog.log(.queue, videoID: song.id, message: "次に再生へ挿入")
    }

    // MARK: - キューの編集

    /// キューを並べ替える。再生中の曲を見失わないよう index を追従させる。
    func moveQueueItems(from source: IndexSet, to destination: Int) {
        let playing = currentSong
        queue.move(fromOffsets: source, toOffset: destination)
        if let playing, let newIndex = queue.firstIndex(where: { $0.id == playing.id }) {
            currentIndex = newIndex
        }
        EventLog.log(.queue, message: "キューを並べ替え (現在位置 \(currentIndex))")
    }

    /// キューから曲を削除する。
    /// 再生中の曲を消した場合は次の曲へ移り、最後の 1 曲なら停止する。
    func removeFromQueue(at offsets: IndexSet) {
        let removingCurrent = offsets.contains(currentIndex)
        // 現在位置より前で消えた件数だけ index を戻す
        let removedBefore = offsets.filter { $0 < currentIndex }.count

        queue.remove(atOffsets: offsets)

        if queue.isEmpty {
            EventLog.log(.queue, message: "キューが空になったため停止")
            stop()
            return
        }

        if removingCurrent {
            // 消した位置にずれ込んできた曲を再生する
            currentIndex = min(currentIndex - removedBefore, queue.count - 1)
            EventLog.log(.queue, message: "再生中の曲を削除したため次の曲へ")
            Task { await loadCurrent() }
        } else {
            currentIndex = max(0, currentIndex - removedBefore)
            EventLog.log(.queue, message: "キューから削除 (現在位置 \(currentIndex))")
        }
    }

    // MARK: - スリープタイマー

    /// タイマー終了予定時刻。nil ならタイマー未設定。
    @Published private(set) var sleepTimerEndDate: Date?
    /// 「現在の曲の終わりで停止」が有効かどうか。
    @Published private(set) var sleepAtEndOfTrack: Bool = false

    private var sleepTimerTask: Task<Void, Never>?

    /// 指定分後に再生を止める。
    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEndDate = end
        EventLog.log(.timer, message: "スリープタイマー \(minutes) 分後に設定")

        sleepTimerTask = Task { [weak self] in
            let seconds = end.timeIntervalSinceNow
            guard seconds > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                EventLog.log(.timer, message: "スリープタイマー発火。再生を停止")
                self.pause()
                self.sleepTimerEndDate = nil
            }
        }
    }

    /// 今かかっている曲が終わったら止める。
    func setSleepAtEndOfTrack() {
        cancelSleepTimer()
        sleepAtEndOfTrack = true
        EventLog.log(.timer, message: "曲の終わりで停止するよう設定")
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        if sleepTimerEndDate != nil || sleepAtEndOfTrack {
            EventLog.log(.timer, message: "スリープタイマー解除")
        }
        sleepTimerEndDate = nil
        sleepAtEndOfTrack = false
    }

    /// タイマーが有効かどうか (UI のアイコン色分け用)。
    var isSleepTimerActive: Bool {
        sleepTimerEndDate != nil || sleepAtEndOfTrack
    }
}
