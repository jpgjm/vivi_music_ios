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
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = song.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let d = song.duration {
            info[MPMediaItemPropertyPlaybackDuration] = d
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // アートワークは重いので別タスクで取得して後から差し込む
        if let urlString = song.thumbnailURL, urlString != lastArtworkURL {
            lastArtworkURL = urlString
            Task { await loadArtwork(urlString: urlString, for: song.id) }
        }
    }

    /// 再生位置と再生状態を更新する。
    func updatePlaybackPosition() {
        guard let p = player, p.currentSong != nil else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = p.isPlaying ? 1.0 : 0.0
        if p.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = p.duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 情報を消す (停止時)。
    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        lastArtworkURL = nil
    }

    // MARK: - アートワーク

    private func loadArtwork(urlString: String, for videoID: String) async {
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return }

            // 取得中に別の曲へ移っていたら捨てる
            guard player?.currentSong?.id == videoID else { return }

            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        } catch {
            EventLog.logError(.network, videoID: videoID, error: error, context: "アートワーク取得")
        }
    }
}
