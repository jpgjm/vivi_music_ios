//
//  VDCParser.swift
//  ViviMusic
//
//  RootlessJamesDSP の VDC ファイル形式を解析。
//
//  形式:
//    SR_44100:b0,b1,b2,a1,a2,b0,b1,b2,a1,a2,...
//    SR_48000:b0,b1,b2,a1,a2,b0,b1,b2,a1,a2,...
//
//  各行は「サンプルレート: BiQuad 係数」で、5 つずつが 1 つの BiQuad (a0 = 1.0 が仮定)。
//
//  BiQuad の伝達関数:
//    H(z) = (b0 + b1*z^-1 + b2*z^-2) / (1 + a1*z^-1 + a2*z^-2)
//
//  Phase 2a では、BiQuad 係数から近似的な PEQ (freq/Q/gain) を計算して
//  既存の ParametricEQ に流し込む。
//  Phase 2b で Custom AUv3 を実装し、BiQuad チェインを厳密に実行する。
//

import Foundation

// MARK: - BiQuad モデル

/// BiQuad IIR フィルタの 1 セクション (Direct Form の係数)。
/// a0 = 1.0 は正規化済み前提。
struct BiquadSection: Hashable {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double

    /// 与えられた周波数 f [Hz] における振幅応答 |H(f)| を計算 (単位: linear)
    /// - Parameter fs: サンプルレート [Hz]
    func magnitudeResponse(at f: Double, sampleRate fs: Double) -> Double {
        // z = e^{j*omega}, omega = 2π f / fs
        let omega = 2.0 * .pi * f / fs
        let cosw = cos(omega)
        let cos2w = cos(2 * omega)
        let sinw = sin(omega)
        let sin2w = sin(2 * omega)

        // 分子: b0 + b1*e^{-jω} + b2*e^{-j2ω}
        let numRe = b0 + b1 * cosw + b2 * cos2w
        let numIm = -(b1 * sinw + b2 * sin2w)
        // 分母: 1 + a1*e^{-jω} + a2*e^{-j2ω}
        let denRe = 1.0 + a1 * cosw + a2 * cos2w
        let denIm = -(a1 * sinw + a2 * sin2w)

        let numMag = sqrt(numRe * numRe + numIm * numIm)
        let denMag = sqrt(denRe * denRe + denIm * denIm)
        return denMag > 0 ? numMag / denMag : 0
    }
}

// MARK: - VDC モデル

struct VDCProfile {
    /// サンプルレートごとの BiQuad チェイン
    /// key = サンプルレート (Hz), value = BiQuad セクション配列
    var chains: [Int: [BiquadSection]]

    /// 代表チェイン (44100 → 48000 → 最初のもの の優先順で返す)
    var primaryChain: (sampleRate: Int, sections: [BiquadSection])? {
        if let s = chains[44100] { return (44100, s) }
        if let s = chains[48000] { return (48000, s) }
        return chains.min(by: { $0.key < $1.key }).map { ($0.key, $0.value) }
    }
}

enum VDCParseError: LocalizedError {
    case noSampleRateHeader
    case invalidCoefficientCount(Int)
    case noBiquads

    var errorDescription: String? {
        switch self {
        case .noSampleRateHeader:
            return "VDC ファイルにサンプルレートヘッダ (例: SR_44100:) が見つかりません"
        case .invalidCoefficientCount(let n):
            return "係数の個数 (\(n)) が 5 の倍数ではありません。VDC 形式を確認してください。"
        case .noBiquads:
            return "有効な BiQuad セクションが見つかりませんでした。"
        }
    }
}

// MARK: - パーサ

struct VDCParser {
    /// VDC テキストを解析する
    static func parse(_ text: String) throws -> VDCProfile {
        var chains: [Int: [BiquadSection]] = [:]

        // SR_XXXXX: の行を抽出
        let lines = text.split(whereSeparator: { $0.isNewline })
        var foundHeader = false

        for rawLine in lines {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // "SR_44100:1.0,2.0,..." のパターン
            guard let (sr, dataStr) = splitHeader(line) else { continue }
            foundHeader = true

            let values = dataStr.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard !values.isEmpty else { continue }

            // 5 の倍数チェック (末尾に 1e-13, 0, 0, 0, 0 のような "終端マーカー" がある場合がある)
            // JamesDSP の VDC では末尾に (1e-13, 0, 0, 0, 0) のような小さな値が入る場合が多いので、それを除外
            let sections = try parseBiquads(from: values)
            if !sections.isEmpty {
                chains[sr] = sections
            }
        }

        if !foundHeader { throw VDCParseError.noSampleRateHeader }
        if chains.isEmpty { throw VDCParseError.noBiquads }

        return VDCProfile(chains: chains)
    }

    private static let headerRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^SR_(\d+)\s*:\s*(.+)$"#, options: [])
    }()

    private static func splitHeader(_ line: String) -> (Int, String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = headerRegex.firstMatch(in: line, options: [], range: range) else { return nil }
        guard let srRange = Range(m.range(at: 1), in: line),
              let dataRange = Range(m.range(at: 2), in: line),
              let sr = Int(line[srRange]) else { return nil }
        return (sr, String(line[dataRange]))
    }

    private static func parseBiquads(from values: [Double]) throws -> [BiquadSection] {
        guard values.count % 5 == 0 else {
            throw VDCParseError.invalidCoefficientCount(values.count)
        }
        var sections: [BiquadSection] = []
        var i = 0
        while i + 4 < values.count {
            let b0 = values[i]
            let b1 = values[i + 1]
            let b2 = values[i + 2]
            let a1 = values[i + 3]
            let a2 = values[i + 4]

            // 終端マーカー (b0 が非常に小さく他が 0) はスキップ
            let isTerminator = abs(b0) < 1e-9 && abs(b1) < 1e-9 && abs(b2) < 1e-9
                && abs(a1) < 1e-9 && abs(a2) < 1e-9
            if !isTerminator {
                sections.append(BiquadSection(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2))
            }
            i += 5
        }
        return sections
    }
}

// MARK: - BiQuad チェイン → PEQ 近似変換

struct BiquadToPEQConverter {

    /// BiQuad チェインの結合周波数応答から近似的な Parametric EQ バンドを推定する。
    /// - Parameters:
    ///   - sections: BiQuad セクション列
    ///   - sampleRate: サンプルレート
    ///   - maxBands: 生成するPEQバンドの最大数
    /// - Returns: 近似 Parametric バンド配列
    static func convert(sections: [BiquadSection], sampleRate: Double, maxBands: Int = 15) -> [ParametricBand] {
        // BiQuad セクションを 1 個 = 1 バンドとして近似する。
        // (BiQuad は本来 PEQ / LS / HS / LP / HP を含む一般的な形式なので、
        //  1 個の BiQuad は 1 個の PEQ バンドに対応する。)
        var bands: [ParametricBand] = []

        for section in sections.prefix(maxBands) {
            if let band = estimateBand(from: section, sampleRate: sampleRate) {
                bands.append(band)
            }
        }
        return bands
    }

    /// 単一 BiQuad の周波数応答からピーク周波数、ピークゲイン、Q を推定する。
    private static func estimateBand(from section: BiquadSection, sampleRate: Double) -> ParametricBand? {
        // 対数スケールで 512 点サンプリング (20Hz ~ sampleRate/2)
        let n = 512
        let fMin = 20.0
        let fMax = sampleRate / 2.0
        let logMin = log10(fMin)
        let logMax = log10(fMax)

        var freqs = [Double](repeating: 0, count: n)
        var mags = [Double](repeating: 0, count: n)

        for i in 0 ..< n {
            let ratio = Double(i) / Double(n - 1)
            let f = pow(10.0, logMin + ratio * (logMax - logMin))
            freqs[i] = f
            mags[i] = section.magnitudeResponse(at: f, sampleRate: sampleRate)
        }

        // Boost/Cut の判定: mid frequency 付近を基準に、最大偏差の点を見る
        var peakIdx = 0
        var peakMagDBAbs: Double = -1
        var peakSignedDB: Double = 0
        for i in 0 ..< n {
            let dB = 20.0 * log10(max(mags[i], 1e-12))
            if abs(dB) > peakMagDBAbs {
                peakMagDBAbs = abs(dB)
                peakSignedDB = dB
                peakIdx = i
            }
        }

        // 変動が非常に小さいものはスキップ (ほぼフラット)
        if peakMagDBAbs < 0.1 { return nil }

        let peakFreq = freqs[peakIdx]

        // -3 dB 帯域幅を求めて Q を計算
        let targetDB = peakSignedDB > 0 ? (peakSignedDB - 3.0) : (peakSignedDB + 3.0)

        var lower: Double = fMin
        var upper: Double = fMax

        // 左側
        for i in stride(from: peakIdx, through: 0, by: -1) {
            let dB = 20.0 * log10(max(mags[i], 1e-12))
            if (peakSignedDB > 0 && dB < targetDB) || (peakSignedDB < 0 && dB > targetDB) {
                lower = freqs[i]
                break
            }
        }
        // 右側
        for i in peakIdx ..< n {
            let dB = 20.0 * log10(max(mags[i], 1e-12))
            if (peakSignedDB > 0 && dB < targetDB) || (peakSignedDB < 0 && dB > targetDB) {
                upper = freqs[i]
                break
            }
        }

        let bandwidth = max(upper - lower, 1.0)
        let q = peakFreq / bandwidth
        // Q は 0.1 ~ 10 に丸める
        let clampedQ = min(10.0, max(0.1, q))
        // Gain は -24 ~ +24 に丸める
        let clampedGain = min(24.0, max(-24.0, peakSignedDB))
        // Freq は 20 ~ 20000 に丸める
        let clampedFreq = min(20000.0, max(20.0, peakFreq))

        return ParametricBand(
            frequency: clampedFreq,
            gainDB: clampedGain,
            q: clampedQ,
            type: .parametric
        )
    }
}
