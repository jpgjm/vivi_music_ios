//
//  NowPlayingCenter.swift
//  ViviMusic
//
//  ロック画面 / コントロールセンター / AirPods の操作を担当する。
//  Flutter 版の audio_service に相当する部分。
//
//  MPRemoteCommandCenter … 外側からの操作 (再生ボタン等) を受け取る
//  MPNowPlayingInfoCenter … 曲名・アートワーク・再生位置を外側へ知らせる
//

import Foundation
import MediaPlayer
import UIKit

@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    private weak var player: PlayerManager?
    /// アートワーク取得の重複を防ぐため、直近に取得した URL を覚えておく。
    private var lastArtworkURL: String?

    /// いま外側へ知らせている内容の**手元の控え**。
    ///
    /// ── なぜ控えを持つのか (rev.86 でアートワークが消えた原因) ─────
    ///
    /// これまでは更新のたびに
    ///
    ///     var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    ///     info[…] = …
    ///     MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    ///
    /// と、**システムから読み戻して書き直して**いた。
    /// `updatePlaybackPosition()` は再生位置の観測にぶら下がっていて
    /// 0.5 秒ごとに走るので、この読み戻しも 0.5 秒ごとに起きる。
    ///
    /// ところが `nowPlayingInfo` のゲッターは、セッターに渡した辞書を
    /// そのまま返すとは限らない。プロセス境界をまたいで受け渡される
    /// 過程で `MPMediaItemArtwork` は素通りせず、読み戻した辞書から
    /// **抜け落ちることがある**。抜けたまま書き戻せばアートワークは
    /// 消え、しかも 0.5 秒後にまた同じことが起きるので二度と戻らない。
    ///
    /// 以前は動いていたのに iOS 26 で出なくなったのは、この読み戻しの
    /// 振る舞いに依存していたため。読み戻しをやめ、手元の控えを
    /// **常に丸ごと書く**ようにすれば、システム側の都合に左右されない。
    private var info: [String: Any] = [:]

    /// 差し込み済みのアートワークと、それがどの曲のものか。
    ///
    /// 同じ曲を鳴らし直したとき (リピート再生など) に取り直さず済ませる。
    /// `update(song:)` は辞書を作り直すので、控えが無いと
    /// 「URL が同じだから取得を飛ばす」判定と噛み合わず、
    /// アートワークの無い辞書のまま固まってしまう。
    private var artwork: MPMediaItemArtwork?
    private var artworkVideoID: String?

    private init() {}

    /// PlayerManager と接続し、リモートコマンドを有効化する。
    func attach(to player: PlayerManager) {
        self.player = player
        setupRemoteCommands()
    }

    // MARK: - リモートコマンド

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.playCommand.addTarget { [weak self] _ in
            guard let p = self?.player else { return .commandFailed }
            EventLog.log(.playStart, message: "リモート: 再生")
            p.resume()
            return .success
        }

        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.addTarget { [weak self] _ in
            guard let p = self?.player else { return .commandFailed }
            EventLog.log(.playStop, message: "リモート: 一時停止")
            p.pause()
            return .success
        }

        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let p = self?.player else { return .commandFailed }
            EventLog.log(.playStart, message: "リモート: 再生/停止トグル")
            p.togglePlayPause()
            return .success
        }

        center.nextTrackCommand.removeTarget(nil)
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let p = self?.player else { return .commandFailed }
            EventLog.log(.queue, message: "リモート: 次の曲")
            Task { await p.next() }
            return .success
        }

        center.previousTrackCommand.removeTarget(nil)
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let p = self?.player else { return .commandFailed }
            EventLog.log(.queue, message: "リモート: 前の曲")
            Task { await p.previous() }
            return .success
        }

        // ロック画面のシークバー
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let p = self?.player,
                  let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            EventLog.log(.queue, message: "リモート: シーク \(Int(e.positionTime))s")
            p.seek(to: e.positionTime)
            return .success
        }

        EventLog.log(.bootstrap, message: "MPRemoteCommandCenter 設定完了")
    }

    // MARK: - 情報の更新

    /// 曲が変わったときに呼ぶ。アートワークは非同期で後追い設定する。
    func update(song: Song) {
        info = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            // 位置と速度も最初から入れておく。
            // 曲が変わってから最初の位置観測 (最大 0.5 秒) までのあいだ、
            // ロック画面のシークバーが不定の位置を指さないようにする。
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 0.0,
        ]
        if let album = song.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let d = song.duration {
            info[MPMediaItemPropertyPlaybackDuration] = d
        }

        // 同じ曲を鳴らし直したなら、取得済みの絵をそのまま載せ直す。
        if artworkVideoID == song.id, let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            artwork = nil
            artworkVideoID = nil
        }
        publish()

        // アートワークは重いので別タスクで取得して後から差し込む
        if let urlString = song.thumbnailURL,
           artworkVideoID != song.id || urlString != lastArtworkURL {
            lastArtworkURL = urlString
            Task { await loadArtwork(urlString: urlString, for: song.id) }
        }
    }

    /// 再生位置と再生状態を更新する。
    func updatePlaybackPosition() {
        guard let p = player, p.currentSong != nil else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = p.isPlaying ? 1.0 : 0.0
        if p.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = p.duration
        }
        publish()
    }

    /// 手元の控えを丸ごと外側へ知らせる。
    /// **システムから読み戻さない**のがこの関数の要点。
    private func publish() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 情報を消す (停止時)。
    func clear() {
        info = [:]
        artwork = nil
        artworkVideoID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        lastArtworkURL = nil
    }

    // MARK: - アートワーク

    /// ロック画面 / コントロールセンターに出す絵を用意する。
    ///
    /// ── なぜ高解像度版を取りにいくか ────────────────────────
    /// `song.thumbnailURL` は一覧向けの大きさ (544px、動画なら
    /// mqdefault の 320x180) で持っている。一覧やミニプレイヤーには
    /// 十分だが、ロック画面は iPad だと 1000pt 近くまで引き伸ばされる。
    /// rev.84 まではこの URL をそのまま渡していたため、
    /// 再生画面より明らかに粗く見えていた。
    ///
    /// 再生画面と同じく、まず高解像度版 (最大 1280px) を試し、
    /// 無ければ元の URL に戻す。
    ///
    /// ── 元に戻す判定 ──────────────────────────────────
    /// `maxresdefault` は用意されていない動画がある。そのとき
    /// 404 が返るとは限らず、**120x90 程度の代替画像**が返ることがある。
    /// 状態番号だけでは見分けられないので、受け取った絵の幅も見る。
    private func loadArtwork(urlString: String, for videoID: String) async {
        // 高解像度版 → 元の URL の順に試す。
        var candidates = [urlString]
        if let high = ThumbnailURL.highResolution(urlString), high != urlString {
            candidates.insert(high, at: 0)
        }

        /// 小さすぎたが、他に何も無ければ使う絵。
        var fallbackImage: UIImage?

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }

            let image: UIImage
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard (200..<300).contains(status), let decoded = UIImage(data: data) else {
                    continue
                }
                image = decoded
            } catch {
                EventLog.logError(.network, videoID: videoID, error: error,
                                  context: "アートワーク取得")
                continue
            }

            // 取得中に別の曲へ移っていたら捨てる
            guard player?.currentSong?.id == videoID else { return }

            // 代替画像 (120x90 など) をつかんでいたら、次の候補を試す。
            if image.size.width < 400 {
                if fallbackImage == nil { fallbackImage = image }
                continue
            }

            apply(image: image, videoID: videoID,
                  isHighResolution: candidate != urlString)
            return
        }

        // どれも大きくなかった。手元にある中で最初のものを使う。
        if let fallbackImage, player?.currentSong?.id == videoID {
            apply(image: fallbackImage, videoID: videoID, isHighResolution: false)
        }
    }

    /// 用意できた絵を Now Playing に差し込む。
    private func apply(image: UIImage, videoID: String, isHighResolution: Bool) {
        let artwork = Self.makeArtwork(from: image)
        self.artwork = artwork
        self.artworkVideoID = videoID
        info[MPMediaItemPropertyArtwork] = artwork
        publish()

        EventLog.log(.playStart, videoID: videoID,
                     message: "ロック画面のアートワーク: "
                         + "\(Int(image.size.width))x\(Int(image.size.height))"
                         + (isHighResolution ? " (高解像度)" : " (元の大きさ)"))
    }

    /// `MPMediaItemArtwork` を作る。
    ///
    /// ── 要求された大きさに合わせて描き直す ──────────────────
    ///
    /// これまでは
    ///
    ///     MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    ///
    /// と、**要求された大きさを無視して**元の絵をそのまま返していた。
    /// ロック画面は自分の欲しい寸法を引数で渡してくるので、
    /// 返ってきた絵の寸法がそれと違うと、描き直しに失敗して
    /// 絵そのものが出ないことがある。
    /// 1280x1280 のような大きな絵ほど食い違いが大きくなる。
    ///
    /// 要求どおりの寸法で描き直して返せば、この食い違いは起きない。
    /// 同じ寸法を求められたときだけ元の絵を素通しする。
    ///
    /// この処理はロック画面側の都合で呼ばれるので、
    /// 主スレッドとは限らない。UIImage の描画は行えるが、
    /// 他の状態には触らないようにしておく。
    private nonisolated static func makeArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { requested in
            guard requested.width > 0, requested.height > 0,
                  requested != image.size else {
                return image
            }
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: requested, format: format)
            return renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: requested))
            }
        }
    }
}
