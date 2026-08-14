//
//  EqualizerSettings.swift
//  ViviMusic
//
//  10 バンドのグラフィックイコライザーの設定。
//  周波数・プリセットの値は MusicPlayer (同じ作者の別アプリ) の
//  `DSPSettings` / `Equalizer10BandView` から移植している。
//

import Foundation
import Combine

/// イコライザーの固定値。
///
/// 音声処理は別スレッドで走るため、@MainActor の付いた型の中に置くと
/// そこから参照できない。定数はここに分けておく。
enum EqualizerConstants {
    /// 固定周波数。RootlessJamesDSP の Equalizer と同じ並び。
    static let frequencies: [Double] = [
        31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
    ]

    /// 各バンドで動かせる幅 (dB)
    static let gainRange: ClosedRange<Double> = -12...12
}

@MainActor
final class EqualizerSettings: ObservableObject {
    static let shared = EqualizerSettings()

    /// 画面から使いやすいよう、定数への入口も用意しておく。
    static var frequencies: [Double] { EqualizerConstants.frequencies }
    static var gainRange: ClosedRange<Double> { EqualizerConstants.gainRange }

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            notifyChange()
        }
    }

    /// 各バンドのゲイン (dB)。要素数は必ず 10。
    @Published var gains: [Double] {
        didSet {
            UserDefaults.standard.set(gains, forKey: Keys.gains)
            notifyChange()
        }
    }

    /// 全体の音量調整 (dB)。ゲインを上げたときの音割れを抑えるのに使う。
    @Published var preampDB: Double {
        didSet {
            UserDefaults.standard.set(preampDB, forKey: Keys.preamp)
            notifyChange()
        }
    }

    /// 設定が変わったことを音声処理側に知らせる。
    let changed = PassthroughSubject<Void, Never>()

    private enum Keys {
        static let enabled = "Equalizer.enabled"
        static let gains = "Equalizer.gains"
        static let preamp = "Equalizer.preamp"
    }

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Keys.enabled)
        preampDB = defaults.object(forKey: Keys.preamp) as? Double ?? 0

        let stored = defaults.object(forKey: Keys.gains) as? [Double]
        if let stored, stored.count == EqualizerConstants.frequencies.count {
            gains = stored
        } else {
            gains = Array(repeating: 0, count: EqualizerConstants.frequencies.count)
        }
    }

    private func notifyChange() {
        changed.send()
    }

    // MARK: - 操作

    func flatten() {
        gains = Array(repeating: 0, count: EqualizerConstants.frequencies.count)
        preampDB = 0
    }

    func apply(preset: Preset) {
        gains = preset.gains
    }

    /// 現在の設定が、指定のプリセットと一致しているか。
    func matches(_ preset: Preset) -> Bool {
        guard gains.count == preset.gains.count else { return false }
        for (a, b) in zip(gains, preset.gains) where abs(a - b) > 0.05 {
            return false
        }
        return true
    }

    // MARK: - プリセット

    struct Preset: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let gains: [Double]
    }

    /// 内蔵プリセット。値は MusicPlayer から移植。
    static let presets: [Preset] = [
        Preset(name: "フラット",   gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Preset(name: "ロック",     gains: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4]),
        Preset(name: "ポップ",     gains: [-1, 0, 2, 3, 3, 2, 0, -1, -1, -2]),
        Preset(name: "ジャズ",     gains: [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]),
        Preset(name: "クラシック", gains: [4, 3, 2, 0, -1, -1, -1, 1, 2, 3]),
        Preset(name: "ダンス",     gains: [6, 4, 1, -2, -1, 1, 4, 5, 4, 3]),
        Preset(name: "ボーカル",   gains: [-2, -1, 0, 2, 4, 4, 3, 2, 1, 0]),
        Preset(name: "低音強調",   gains: [7, 5, 3, 1, 0, 0, 0, 0, 0, 0]),
        Preset(name: "高音強調",   gains: [0, 0, 0, 0, 0, 1, 3, 5, 6, 7]),
        Preset(name: "ラウドネス", gains: [5, 3, 0, 0, -2, -2, 0, 3, 5, 7]),
    ]
}
