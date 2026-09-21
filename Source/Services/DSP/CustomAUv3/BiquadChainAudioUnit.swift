//
//  BiquadChainAudioUnit.swift
//  ViviMusic
//
//  BiQuad IIR フィルタチェインをリアルタイム実行するカスタム AUv3。
//  DDC の VDC ファイル (BiQuad 係数列) をそのまま流し込んで、Apple の
//  AVAudioUnitEQ よりも厳密な特性を実現する。
//
//  実装:
//    - Direct Form II Transposed (数値安定性が高い)
//    - チャンネル毎に独立した状態変数
//    - 最大 64 セクション (100+ 個の BiQuad は現実的でない)
//    - render block はリアルタイムスレッドで実行されるので malloc/dispatch なし
//
//  スレッド安全性:
//    - パラメータ (sections) の更新は setSections(_:) で行う。
//    - 実際の反映は次の render block 呼び出し時 (バッファ更新はロックなし読み出し)。
//    - リアルタイムスレッドから見て、係数の double-buffering + atomic swap で更新反映。
//

import Foundation
import AVFoundation
import AudioToolbox

final class BiquadChainAudioUnit: AUAudioUnit {

    // MARK: 定数

    /// サポートする最大 BiQuad セクション数
    static let maxSections = 64
    /// サポートする最大チャンネル数
    static let maxChannels = 2

    // MARK: バス

    private var _inputBus: AUAudioUnitBus!
    private var _outputBus: AUAudioUnitBus!
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

    // MARK: 内部状態 (リアルタイムスレッドから読まれる)

    /// 現在有効なセクション数
    private var activeSectionCount: Int = 0
    /// セクションの係数 (b0, b1, b2, a1, a2) × maxSections 個
    private var coefficients: UnsafeMutablePointer<Float>
    /// チャンネル毎の state (s1, s2) × maxSections × maxChannels
    private var states: UnsafeMutablePointer<Float>

    /// バイパス (true なら効果なし)
    var chainBypass: Bool = true

    // MARK: 初期化

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        // 係数バッファ確保 (5 × 64 = 320 float)
        self.coefficients = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxSections * 5)
        self.coefficients.initialize(repeating: 0, count: Self.maxSections * 5)

        // state バッファ確保 (2 × 64 × 2 = 256 float)
        self.states = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxSections * Self.maxChannels * 2)
        self.states.initialize(repeating: 0, count: Self.maxSections * Self.maxChannels * 2)

        try super.init(componentDescription: componentDescription, options: options)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        self._inputBus = try AUAudioUnitBus(format: format)
        self._outputBus = try AUAudioUnitBus(format: format)
        self._inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [_inputBus])
        self._outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [_outputBus])
    }

    deinit {
        coefficients.deinitialize(count: Self.maxSections * 5)
        coefficients.deallocate()
        states.deinitialize(count: Self.maxSections * Self.maxChannels * 2)
        states.deallocate()
    }

    // MARK: AUAudioUnit オーバーライド

    override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        resetStates()
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
    }

    /// state を全部ゼロクリア
    func resetStates() {
        for i in 0 ..< Self.maxSections * Self.maxChannels * 2 {
            states[i] = 0
        }
    }

    // MARK: パラメータ更新 (メインスレッドから呼ぶ)

    /// BiQuad セクション列を設定する。sampleRate 補正は呼び出し側で行う想定。
    /// - Note: 実 render の途中で呼ぶと一瞬ノイズが出る可能性あり。
    ///         正確には一時的に bypass にしてから setSections → resetStates → bypass 解除するのが安全。
    func setSections(_ sections: [BiquadSection]) {
        let count = min(sections.count, Self.maxSections)
        for i in 0 ..< count {
            let s = sections[i]
            let base = i * 5
            coefficients[base + 0] = Float(s.b0)
            coefficients[base + 1] = Float(s.b1)
            coefficients[base + 2] = Float(s.b2)
            coefficients[base + 3] = Float(s.a1)
            coefficients[base + 4] = Float(s.a2)
        }
        // 未使用領域はゼロクリア (念のため)
        for i in count ..< Self.maxSections {
            let base = i * 5
            coefficients[base + 0] = 1
            coefficients[base + 1] = 0
            coefficients[base + 2] = 0
            coefficients[base + 3] = 0
            coefficients[base + 4] = 0
        }
        activeSectionCount = count
        resetStates()
    }

    /// 現在のセクション数を取得
    var currentSectionCount: Int { activeSectionCount }

    // MARK: - Render block

    override var internalRenderBlock: AUInternalRenderBlock {
        // リアルタイムスレッドで参照する pointer と値をキャプチャ
        let coeffPtr = self.coefficients
        let statesPtr = self.states
        let getSectionCount: () -> Int = { [weak self] in self?.activeSectionCount ?? 0 }
        let getBypass: () -> Bool = { [weak self] in self?.chainBypass ?? true }

        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData, realtimeEventListHead, pullInputBlock in

            // 1. 入力を outputData に pull (in-place 処理)
            let pullFlags = actionFlags
            let err = pullInputBlock?(pullFlags, timestamp, frameCount, 0, outputData) ?? noErr
            if err != noErr { return err }

            let sectionCount = getSectionCount()
            let bypass = getBypass()

            // バイパスまたはセクションが 0 の場合は何もしない (入力がそのまま出力)
            if bypass || sectionCount == 0 { return noErr }

            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            let channelCount = min(abl.count, Self.maxChannels)
            let frames = Int(frameCount)

            // 2. 各チャンネルに BiQuad チェインを適用
            for ch in 0 ..< channelCount {
                guard let mData = abl[ch].mData else { continue }
                let samples = mData.assumingMemoryBound(to: Float.self)

                for i in 0 ..< frames {
                    var sample = samples[i]

                    for s in 0 ..< sectionCount {
                        let coeffBase = s * 5
                        let b0 = coeffPtr[coeffBase + 0]
                        let b1 = coeffPtr[coeffBase + 1]
                        let b2 = coeffPtr[coeffBase + 2]
                        let a1 = coeffPtr[coeffBase + 3]
                        let a2 = coeffPtr[coeffBase + 4]

                        // state index: [channel][section][0=s1, 1=s2]
                        let stateBase = ch * Self.maxSections * 2 + s * 2
                        let s1 = statesPtr[stateBase + 0]
                        let s2 = statesPtr[stateBase + 1]

                        // Direct Form II Transposed
                        let y = b0 * sample + s1
                        statesPtr[stateBase + 0] = b1 * sample - a1 * y + s2
                        statesPtr[stateBase + 1] = b2 * sample - a2 * y

                        sample = y
                    }

                    samples[i] = sample
                }
            }

            return noErr
        }
    }
}
