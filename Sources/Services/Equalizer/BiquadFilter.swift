//
//  BiquadFilter.swift
//  ViviMusic
//
//  イコライザーの 1 バンド分を担う双二次 (biquad) フィルタ。
//
//  MusicPlayer では AVAudioUnitEQ が同じ役目を果たしていたが、
//  ViviMusic の再生は AVPlayer なので AVAudioUnitEQ を挟めない。
//  そのため音声を自前で加工する必要があり、フィルタもここで用意する。
//
//  係数は Robert Bristow-Johnson の Audio EQ Cookbook にある
//  peaking EQ の式に従っている (AVAudioUnitEQ の .parametric と同種)。
//

import Foundation

/// ピーキング型の双二次フィルタ。1 チャンネル分の状態を持つ。
struct BiquadFilter {

    // 係数 (a0 で正規化済み)
    private var b0: Double = 1
    private var b1: Double = 0
    private var b2: Double = 0
    private var a1: Double = 0
    private var a2: Double = 0

    // 直前の入出力 (Direct Form I)
    private var x1: Double = 0
    private var x2: Double = 0
    private var y1: Double = 0
    private var y2: Double = 0

    /// 係数を計算し直す。
    /// - Parameters:
    ///   - frequency: 中心周波数 (Hz)
    ///   - gainDB: 増減量 (dB)
    ///   - q: 鋭さ。値が小さいほど広い範囲に効く
    ///   - sampleRate: 標本化周波数 (Hz)
    mutating func configure(frequency: Double,
                            gainDB: Double,
                            q: Double,
                            sampleRate: Double) {
        // ナイキスト周波数を超える帯域は素通しにする
        guard sampleRate > 0, frequency < sampleRate / 2 else {
            makeBypass()
            return
        }

        let amplitude = pow(10.0, gainDB / 40.0)
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * max(q, 0.1))

        let a0 = 1.0 + alpha / amplitude

        b0 = (1.0 + alpha * amplitude) / a0
        b1 = (-2.0 * cosOmega) / a0
        b2 = (1.0 - alpha * amplitude) / a0
        a1 = (-2.0 * cosOmega) / a0
        a2 = (1.0 - alpha / amplitude) / a0
    }

    /// 何もしない状態にする。
    mutating func makeBypass() {
        b0 = 1; b1 = 0; b2 = 0; a1 = 0; a2 = 0
    }

    /// 直前の入出力を捨てる。曲が変わったときに呼ぶ。
    mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }

    /// 1 標本を通す。
    mutating func process(_ input: Double) -> Double {
        let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return output
    }
}

/// 10 バンドをまとめて扱う、1 チャンネル分のフィルタ列。
struct BiquadChain {
    private var filters: [BiquadFilter]
    /// 全体の音量倍率 (preamp を線形値にしたもの)
    private var preampScale: Double = 1

    init(bandCount: Int) {
        filters = Array(repeating: BiquadFilter(), count: bandCount)
    }

    /// 設定を反映する。
    /// - Parameter q: 隣り合うバンドが自然につながる程度の鋭さ。
    ///   10 バンドがオクターブ間隔なので 1.0 前後が扱いやすい。
    mutating func configure(frequencies: [Double],
                            gains: [Double],
                            preampDB: Double,
                            sampleRate: Double,
                            q: Double = 1.0) {
        preampScale = pow(10.0, preampDB / 20.0)

        for index in filters.indices {
            guard index < frequencies.count, index < gains.count else {
                filters[index].makeBypass()
                continue
            }
            let gain = gains[index]
            // ほぼ 0dB のバンドは計算を省いて素通しにする
            if abs(gain) < 0.05 {
                filters[index].makeBypass()
            } else {
                filters[index].configure(frequency: frequencies[index],
                                         gainDB: gain,
                                         q: q,
                                         sampleRate: sampleRate)
            }
        }
    }

    mutating func reset() {
        for index in filters.indices {
            filters[index].reset()
        }
    }

    /// 1 標本を全バンドに順に通す。
    mutating func process(_ input: Float) -> Float {
        var value = Double(input) * preampScale
        for index in filters.indices {
            value = filters[index].process(value)
        }
        // 音割れを防ぐため範囲内に収める
        return Float(max(-1.0, min(1.0, value)))
    }
}
