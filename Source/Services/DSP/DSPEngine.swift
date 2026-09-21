//
//  DSPEngine.swift
//  ViviMusic
//
//  AVAudioEngine + 各種 effect chain。MusicPlayer の DSPEngine を移植したもの。
//
//  MusicPlayer との違いは「音の入口と出口」だけ:
//    - MusicPlayer: playerNode でファイルを再生し、outputNode からスピーカーへ出す。
//    - ViviMusic : 再生は AVPlayer なので、エンジンを手動レンダリング (realtime)
//                  で動かす。DSPTap が受け取った音声を inputNode から流し込み、
//                  chain を通った結果をタップへ書き戻す (DSPRenderer 経由)。
//  chain の並び・各 AudioUnit の設定・パラメータの反映方法は MusicPlayer と同じ。
//
//  effect chain 順序:
//    inputNode (AVPlayer の音声)
//     → bassBoost (Low Shelf EQ)
//     → equalizer10 (10 band graphic EQ)
//     → parametricEQ (可変バンドの PEQ)
//     → graphicEQNodes (自由ノード式)
//     → BiquadChain (DDC)         ※ Custom AUv3 の準備ができてから挿入
//     → Convolver (IR)            ※ 同上
//     → Liveprog (EEL2)           ※ 同上
//     → compressor (Dynamics Processor)
//     → distortion (Tube)
//     → crossfeed (L/R チャンネル分離処理)
//     → widener (Mid-Side 拡張)
//     → reverb
//     → peakLimiter
//     → mainMixer (post-gain)
//     → outputNode (手動レンダリングの出力 → タップへ書き戻し)
//
//  サンプルレート:
//    MusicPlayer は 44100Hz 固定だったが、ここではストリームの実際の
//    サンプルレート (YouTube は 44100 / 48000) で chain を組む。
//    そのため IR / Liveprog / VDC はレートが変わるたびに読み込み直す。
//
//  DSPSettings.changeToken を購読して、パラメータ変更時に chain を更新する。
//

import Foundation
import AVFoundation
import AudioToolbox
import Combine

@MainActor
final class DSPEngine: ObservableObject {

    static let shared = DSPEngine()

    /// 手動レンダリング 1 回あたりの最大フレーム数。
    /// タップがこれより大きいバッファを渡してきた場合は DSPRenderer が分割する。
    static let maximumFrameCount: AVAudioFrameCount = 4096

    // MARK: - コンポーネント

    let engine = AVAudioEngine()

    // Apple 提供 AudioUnit
    private let bassBoost: AVAudioUnitEQ
    private let equalizer10: AVAudioUnitEQ
    private let parametricEQ: AVAudioUnitEQ
    private let graphicEQNodes: AVAudioUnitEQ
    private let compressor: AVAudioUnitEffect
    private let distortion: AVAudioUnitDistortion
    private let crossfeedEQ: AVAudioUnitEQ    // 簡易実装: L/R 分離の LP shelf を per-channel EQ で
    private let widener: AVAudioUnitEQ        // 簡易 Mid-Side 拡張は難しいので、High shelf + ステレオ強調で近似
    private let reverb: AVAudioUnitReverb
    private let peakLimiter: AVAudioUnitEffect

    // Custom AUv3 (async 初期化なので Optional)
    private var biquadChainUnit: AVAudioUnit?
    private var convolverUnit: AVAudioUnit?
    private var liveprogUnit: AVAudioUnit?
    /// 現在 BiquadChain にロードされている VDC ファイルパス (キャッシュ判定用)
    private var lastLoadedDDCPath: String?
    /// 現在 Convolver にロードされている IR ファイルパス (キャッシュ判定用)
    private var lastLoadedIRPath: String?
    /// 現在 Liveprog にロードされているスクリプトパス (キャッシュ判定用)
    private var lastLoadedLiveprogPath: String?
    /// サンプルレートが変わったので、パスが同じでもファイルを読み直す
    private var needsFileReload = false

    /// 現在 chain を組んでいるフォーマット
    private(set) var sampleRate: Double = 44100
    private(set) var channelCount: AVAudioChannelCount = 2

    /// Liveprog のパフォーマンス統計を取得する (公開ヘルパ、Optional)
    func liveprogStatistics() -> LiveprogAudioUnit.Statistics? {
        guard let lpAU = liveprogUnit?.auAudioUnit as? LiveprogAudioUnit else { return nil }
        return lpAU.statistics()
    }

    /// Liveprog の統計をリセット
    func resetLiveprogStatistics() {
        (liveprogUnit?.auAudioUnit as? LiveprogAudioUnit)?.resetStatistics()
    }

    // Combine 購読 (DSPSettings の変更を監視)
    private var cancellables: Set<AnyCancellable> = []

    /// 手動レンダリングが動いていて、タップから使える状態か
    @Published private(set) var isEngineActive: Bool = false
    /// Custom AUv3 の初期化が完了しているか
    @Published private(set) var customUnitsReady: Bool = false

    // MARK: - 初期化

    private init() {
        // Bass Boost: 1 band Low Shelf
        bassBoost = AVAudioUnitEQ(numberOfBands: 1)
        let bass = bassBoost.bands[0]
        bass.filterType = .lowShelf
        bass.frequency = 120.0
        bass.bandwidth = 1.0
        bass.gain = 0.0
        bass.bypass = true

        // 10 band Graphic EQ
        equalizer10 = AVAudioUnitEQ(numberOfBands: 10)
        for (i, freq) in DSPSettings.eq10BandFrequencies.enumerated() {
            let b = equalizer10.bands[i]
            b.filterType = .parametric
            b.frequency = Float(freq)
            b.bandwidth = 1.0
            b.gain = 0.0
            b.bypass = false
        }

        // Parametric EQ (最大 15 バンド、動的に設定)
        parametricEQ = AVAudioUnitEQ(numberOfBands: 15)
        for b in parametricEQ.bands {
            b.filterType = .parametric
            b.frequency = 1000
            b.bandwidth = 1
            b.gain = 0
            b.bypass = true
        }

        // Graphic EQ ノード式 (最大 32 バンド)
        graphicEQNodes = AVAudioUnitEQ(numberOfBands: 32)
        for b in graphicEQNodes.bands {
            b.filterType = .parametric
            b.frequency = 1000
            b.bandwidth = 1
            b.gain = 0
            b.bypass = true
        }

        // Compressor (DynamicsProcessor)
        let compDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        compressor = AVAudioUnitEffect(audioComponentDescription: compDesc)

        // Distortion (Tube preset)
        distortion = AVAudioUnitDistortion()
        distortion.loadFactoryPreset(.multiEcho1)  // 効果は preGain / wetDry で調整
        distortion.bypass = true

        // Crossfeed 用 EQ: L と R で別々の EQ をかけるのは AVAudioUnitEQ では不可能
        // (2ch stereo で共通処理)。簡易近似として、ステレオ全体に mild high cut を入れる形にする
        crossfeedEQ = AVAudioUnitEQ(numberOfBands: 1)
        crossfeedEQ.bands[0].filterType = .highShelf
        crossfeedEQ.bands[0].frequency = 700
        crossfeedEQ.bands[0].bandwidth = 1
        crossfeedEQ.bands[0].gain = 0
        crossfeedEQ.bands[0].bypass = true

        // Stereo Widener (簡易近似: 高域 shelf)
        widener = AVAudioUnitEQ(numberOfBands: 1)
        widener.bands[0].filterType = .highShelf
        widener.bands[0].frequency = 2000
        widener.bands[0].bandwidth = 1
        widener.bands[0].gain = 0
        widener.bands[0].bypass = true

        // Reverb
        reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.mediumRoom)
        reverb.wetDryMix = 0
        reverb.bypass = true

        // Peak Limiter
        let limDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        peakLimiter = AVAudioUnitEffect(audioComponentDescription: limDesc)

        // === attach ===
        for node in appleNodes { engine.attach(node) }

        // === 手動レンダリングで chain を組む ===
        // inputNode / mainMixerNode に触る前に手動レンダリングへ切り替える
        // (先に触るとハードウェア入出力を前提に組まれてしまうため)。
        configureRendering(sampleRate: sampleRate, channelCount: channelCount, reason: "初期化")

        // 設定変更を購読
        DSPSettings.shared.$changeToken
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.applySettings()
                }
            }
            .store(in: &cancellables)

        // 初期パラメータ反映
        applySettings()

        // Custom AUv3 を async に初期化 (完了したら chain を再構築)
        Task { @MainActor in
            await setupCustomAudioUnits()
        }
    }

    /// Apple 提供 AudioUnit の並び (Custom AUv3 を除く)
    private var appleNodes: [AVAudioNode] {
        [bassBoost, equalizer10, parametricEQ, graphicEQNodes,
         compressor, distortion, crossfeedEQ, widener, reverb, peakLimiter]
    }

    // MARK: - Custom AUv3 初期化

    private func setupCustomAudioUnits() async {
        do {
            let bqUnit = try await instantiateCustomAudioUnit(
                type: BiquadChainAudioUnit.self,
                subType: "BiqC",
                name: "ViviMusic.BiquadChain"
            )
            biquadChainUnit = bqUnit

            let cvUnit = try await instantiateCustomAudioUnit(
                type: ConvolverAudioUnit.self,
                subType: "CnvL",
                name: "ViviMusic.Convolver"
            )
            convolverUnit = cvUnit

            let lpUnit = try await instantiateCustomAudioUnit(
                type: LiveprogAudioUnit.self,
                subType: "LvP2",
                name: "ViviMusic.Liveprog"
            )
            liveprogUnit = lpUnit

            rebuildEngineWithCustomUnits()
            customUnitsReady = true
            EventLog.log(.dsp, message: "Custom AUv3 (DDC / Convolver / Liveprog) の準備完了")
            // 設定を再反映 (DDC + Convolver + Liveprog 用)
            applySettings()
        } catch {
            EventLog.logError(.dspError, error: error, context: "Custom AUv3 の初期化")
        }
    }

    /// Custom AUv3 を挿入した chain に再構築する。
    private func rebuildEngineWithCustomUnits() {
        guard let biquadUnit = biquadChainUnit,
              let convUnit = convolverUnit,
              let lpUnit = liveprogUnit else { return }

        DSPRenderer.shared.detach()
        if engine.isRunning { engine.stop() }

        engine.attach(biquadUnit)
        engine.attach(convUnit)
        engine.attach(lpUnit)

        configureRendering(sampleRate: sampleRate, channelCount: channelCount,
                           reason: "Custom AUv3 を挿入")
    }

    // MARK: - 手動レンダリングの構成

    /// ストリームのフォーマットが今の構成と違うときに DSPTap から呼ばれる。
    func configureForStream(sampleRate: Double, channelCount: AVAudioChannelCount) {
        if isEngineActive,
           abs(self.sampleRate - sampleRate) < 0.5,
           self.channelCount == channelCount {
            return
        }
        configureRendering(sampleRate: sampleRate, channelCount: channelCount,
                           reason: "ストリームのフォーマットに合わせる")
        applySettings()
    }

    /// 指定フォーマットで手動レンダリングを組み直し、DSPRenderer に渡す。
    @discardableResult
    private func configureRendering(sampleRate sr: Double,
                                    channelCount ch: AVAudioChannelCount,
                                    reason: String) -> Bool {
        // 組み直している間、タップは素通しにする
        DSPRenderer.shared.detach()
        isEngineActive = false
        if engine.isRunning { engine.stop() }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: ch) else {
            EventLog.log(.dspError, message: "DSP フォーマットを作れません: \(Int(sr))Hz / \(ch)ch")
            return false
        }

        do {
            try engine.enableManualRenderingMode(.realtime,
                                                 format: format,
                                                 maximumFrameCount: Self.maximumFrameCount)
        } catch {
            // 既に手動レンダリング中でフォーマットだけ変えられなかった場合に備え、
            // 一度解除してからもう一度試す
            EventLog.logError(.dspError, error: error,
                              context: "手動レンダリングの開始 1 回目 (\(reason))。解除して再試行")
            engine.disableManualRenderingMode()
            do {
                try engine.enableManualRenderingMode(.realtime,
                                                     format: format,
                                                     maximumFrameCount: Self.maximumFrameCount)
            } catch {
                EventLog.logError(.dspError, error: error, context: "手動レンダリングの開始 (\(reason))")
                return false
            }
        }

        // inputNode の出力フォーマットを決めてから chain をつなぐ
        let inputOK = engine.inputNode.setManualRenderingInputPCMFormat(format) { frameCount in
            DSPRenderer.shared.provideInput(frameCount: frameCount)
        }
        guard inputOK else {
            EventLog.log(.dspError, message: "inputNode の設定に失敗 (\(reason))")
            return false
        }

        connectChain(format: format)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            EventLog.logError(.dspError, error: error, context: "DSP エンジンの起動 (\(reason))")
            return false
        }

        let changedRate = abs(sampleRate - sr) >= 0.5
        sampleRate = sr
        channelCount = ch
        if changedRate { needsFileReload = true }

        DSPRenderer.shared.attach(block: engine.manualRenderingBlock,
                                  sampleRate: sr,
                                  channelCount: Int(ch),
                                  maxFrames: Int(Self.maximumFrameCount))
        DSPRenderer.shared.setActive(DSPSettings.shared.masterEnabled)
        isEngineActive = true

        EventLog.log(.dsp, message: "DSP エンジン構成: \(Int(sr))Hz / \(ch)ch"
                     + " / Custom AUv3 \(biquadChainUnit != nil ? "あり" : "なし") (\(reason))")
        return true
    }

    /// inputNode → chain → mainMixer → outputNode を指定フォーマットでつなぐ。
    private func connectChain(format: AVAudioFormat) {
        var nodes: [AVAudioNode] = [
            engine.inputNode,
            bassBoost,
            equalizer10,
            parametricEQ,
            graphicEQNodes,
        ]
        if let biquadUnit = biquadChainUnit,
           let convUnit = convolverUnit,
           let lpUnit = liveprogUnit {
            nodes += [biquadUnit, convUnit, lpUnit]
        }
        nodes += [
            compressor,
            distortion,
            crossfeedEQ,
            widener,
            reverb,
            peakLimiter,
        ]

        for i in 0 ..< nodes.count - 1 {
            engine.disconnectNodeInput(nodes[i + 1])
            engine.connect(nodes[i], to: nodes[i + 1], format: format)
        }
        engine.disconnectNodeInput(engine.mainMixerNode)
        engine.connect(nodes.last!, to: engine.mainMixerNode, format: format)
        engine.disconnectNodeInput(engine.outputNode)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
    }

    // MARK: - 曲の切り替え

    /// 曲が変わるときに呼ぶ。リバーブの残響やフィルタの履歴を捨てて雑音を防ぐ。
    func resetEffectState() {
        DSPRenderer.shared.withLock {
            engine.reset()
        }
    }

    // MARK: - パラメータ反映

    private func applySettings() {
        let s = DSPSettings.shared

        // Master
        let master = s.masterEnabled
        DSPRenderer.shared.setActive(master)
        engine.mainMixerNode.outputVolume = master ? Float(dbToLinear(s.outputPostGainDB)) : 1.0

        // Bass Boost
        let bassOn = master && s.bassEnabled
        bassBoost.bypass = !bassOn
        bassBoost.bands[0].gain = Float(s.bassMaxGain)
        bassBoost.globalGain = 0

        // 10 band Graphic EQ
        let eqOn = master && s.eqEnabled
        equalizer10.bypass = !eqOn
        for (i, gain) in s.eqBandGainsDB.enumerated() where i < equalizer10.bands.count {
            equalizer10.bands[i].gain = Float(gain)
        }

        // Parametric EQ
        let peqOn = master && s.peqEnabled
        parametricEQ.bypass = !peqOn
        for i in 0 ..< parametricEQ.bands.count {
            if i < s.peqBands.count {
                let src = s.peqBands[i]
                let dst = parametricEQ.bands[i]
                dst.filterType = mapBandType(src.type)
                dst.frequency = Float(clamp(src.frequency, min: 20, max: 20000))
                dst.bandwidth = Float(1.0 / max(0.1, src.q))
                dst.gain = Float(src.gainDB)
                dst.bypass = false
            } else {
                parametricEQ.bands[i].bypass = true
            }
        }

        // Graphic EQ Nodes
        let geqOn = master && s.geqEnabled
        graphicEQNodes.bypass = !geqOn
        for i in 0 ..< graphicEQNodes.bands.count {
            if i < s.geqNodes.count {
                let src = s.geqNodes[i]
                let dst = graphicEQNodes.bands[i]
                dst.filterType = .parametric
                dst.frequency = Float(clamp(src.frequency, min: 20, max: 20000))
                dst.bandwidth = 0.5
                dst.gain = Float(src.gainDB)
                dst.bypass = false
            } else {
                graphicEQNodes.bands[i].bypass = true
            }
        }

        // Compressor
        let compOn = master && s.companderEnabled
        applyCompressor(enabled: compOn, s: s)

        // Distortion / Tube
        let tubeOn = master && s.tubeEnabled
        distortion.bypass = !tubeOn
        if tubeOn {
            // -3 ~ +12 dB を preGain (-80 ~ 20 dB) にマップ
            let pre = Float(s.tubeDriveDB * 4.0)  // -12 ~ +48 相当
            distortion.preGain = min(20, max(-80, pre))
            distortion.wetDryMix = 30
        }

        // Crossfeed 近似
        let crossOn = master && s.crossfeedEnabled
        crossfeedEQ.bypass = !crossOn
        if crossOn {
            // Preset 0..4 で high shelf cut 深さを変える
            let cut: Double = [-2, -3, -4, -6, -8][min(4, max(0, s.crossfeedPreset))]
            crossfeedEQ.bands[0].gain = Float(cut)
        }

        // Stereo Widener 近似
        let widerOn = master && s.widenerEnabled
        widener.bypass = !widerOn
        if widerOn {
            // 0 (mono) ~ 100 (原音) ~ 200 (拡張) を high shelf boost + globalGain で表現
            let shelfBoost = (s.widenerAmount - 100.0) * 0.05
            widener.bands[0].gain = Float(shelfBoost)
        }

        // Reverb
        let reverbOn = master && s.reverbEnabled
        reverb.bypass = !reverbOn
        if let preset = AVAudioUnitReverbPreset(rawValue: s.reverbPreset) {
            reverb.loadFactoryPreset(preset)
        }
        reverb.wetDryMix = Float(s.reverbWetDry)

        // Peak Limiter
        applyLimiter(enabled: master && s.outputLimiterEnabled, s: s)

        // ここから下はファイルを読む。サンプルレートが変わっていたら読み直す。
        let reload = needsFileReload && customUnitsReady
        if reload { needsFileReload = false }

        // DDC (BiquadChain Custom AUv3)
        applyDDC(enabled: master && s.ddcEnabled, path: s.ddcVDCPath, forceReload: reload)

        // Convolver Custom AUv3
        applyConvolver(enabled: master && s.convolverEnabled, path: s.convolverIRPath, forceReload: reload)

        // Liveprog Custom AUv3
        applyLiveprog(enabled: master && s.liveprogEnabled, path: s.liveprogScriptPath,
                      sliderValues: s.liveprogSliderValues, forceReload: reload)
    }

    private func applyDDC(enabled: Bool, path: String?, forceReload: Bool) {
        guard let biquadUnit = biquadChainUnit,
              let biquadAU = biquadUnit.auAudioUnit as? BiquadChainAudioUnit
        else { return }

        // VDC ファイルパスが変わっていたら再読み込み
        if forceReload || lastLoadedDDCPath != path {
            lastLoadedDDCPath = path
            loadVDCFileIntoBiquad(path: path, biquadAU: biquadAU)
        }
        biquadAU.chainBypass = !enabled
    }

    private func loadVDCFileIntoBiquad(path: String?, biquadAU: BiquadChainAudioUnit) {
        guard let path = path, !path.isEmpty else {
            biquadAU.setSections([])
            return
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent(path)
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let profile = try VDCParser.parse(text)
            // 今のサンプルレート用のチェインがあればそれを使う。無ければ代表チェイン。
            let rate = Int(sampleRate.rounded())
            let chosen: (sampleRate: Int, sections: [BiquadSection])?
            if let exact = profile.chains[rate] {
                chosen = (rate, exact)
            } else {
                chosen = profile.primaryChain
            }
            if let chosen {
                biquadAU.setSections(chosen.sections)
                EventLog.log(.dsp, message: "DDC: \(url.lastPathComponent) から BiQuad \(chosen.sections.count) 個を読み込み"
                             + " (VDC \(chosen.sampleRate)Hz / 再生 \(rate)Hz)")
            } else {
                biquadAU.setSections([])
            }
        } catch {
            EventLog.logError(.dspError, error: error, context: "VDC ファイルの読み込み (\(url.lastPathComponent))")
            biquadAU.setSections([])
        }
    }

    // MARK: - Convolver

    private func applyConvolver(enabled: Bool, path: String?, forceReload: Bool) {
        guard let convUnit = convolverUnit,
              let convAU = convUnit.auAudioUnit as? ConvolverAudioUnit
        else { return }

        // IR ファイルパスが変わっていたら再読み込み
        if forceReload || lastLoadedIRPath != path {
            lastLoadedIRPath = path
            loadIRFileIntoConvolver(path: path, convAU: convAU)
        }
        convAU.chainBypass = !enabled
    }

    private func loadIRFileIntoConvolver(path: String?, convAU: ConvolverAudioUnit) {
        guard let path = path, !path.isEmpty else {
            convAU.unloadIR()
            return
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent(path)
        do {
            try convAU.loadIR(from: url, targetSampleRate: sampleRate)
            EventLog.log(.dsp, message: "Convolver: \(url.lastPathComponent) を読み込み (\(Int(sampleRate))Hz)")
        } catch {
            EventLog.logError(.dspError, error: error, context: "IR ファイルの読み込み (\(url.lastPathComponent))")
            convAU.unloadIR()
        }
    }

    // MARK: - Liveprog

    private func applyLiveprog(enabled: Bool, path: String?, sliderValues: [String: Double], forceReload: Bool) {
        guard let lpUnit = liveprogUnit,
              let lpAU = lpUnit.auAudioUnit as? LiveprogAudioUnit
        else { return }

        // スクリプトパスが変わっていたら再ロード & @init 実行
        if forceReload || lastLoadedLiveprogPath != path {
            lastLoadedLiveprogPath = path
            loadLiveprogFile(path: path, lpAU: lpAU)
        }

        // 現在のプログラムのスライダーに値を反映
        if let sliders = lpAU.currentSliders() {
            for (i, s) in sliders.enumerated() {
                let value = sliderValues[s.variableName] ?? s.defaultValue
                lpAU.setSliderValue(sliderIndex: i, value: value)
            }
            // @slider セクションを 1 回実行して事前計算値を更新
            lpAU.runSliderSection()
        }

        lpAU.chainBypass = !enabled
    }

    private func loadLiveprogFile(path: String?, lpAU: LiveprogAudioUnit) {
        guard let path = path, !path.isEmpty else {
            lpAU.setProgram(nil)
            return
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent(path)
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let program = try EEL2Parser.parse(text)
            lpAU.setProgram(program, sampleRate: sampleRate)
            EventLog.log(.dsp, message: "Liveprog: \(url.lastPathComponent) を読み込み"
                         + " (変数 \(program.variableCount) / スライダー \(program.sliders.count) / \(Int(sampleRate))Hz)")
        } catch {
            EventLog.logError(.dspError, error: error, context: "Liveprog スクリプトの読み込み (\(url.lastPathComponent))")
            lpAU.setProgram(nil)
        }
    }

    private func applyCompressor(enabled: Bool, s: DSPSettings) {
        let unit = compressor.audioUnit
        if !enabled {
            // Threshold を高くしてほぼ効かなくする
            setParam(unit, id: kDynamicsProcessorParam_Threshold, value: 0.0)
            setParam(unit, id: kDynamicsProcessorParam_HeadRoom, value: 40.0)
            setParam(unit, id: kDynamicsProcessorParam_OverallGain, value: 0.0)
        } else {
            setParam(unit, id: kDynamicsProcessorParam_Threshold, value: Float(s.companderThreshold))
            let headroom = max(0.1, 20.0 / s.companderRatio)
            setParam(unit, id: kDynamicsProcessorParam_HeadRoom, value: Float(headroom))
            setParam(unit, id: kDynamicsProcessorParam_AttackTime, value: Float(s.companderAttackMs / 1000.0))
            setParam(unit, id: kDynamicsProcessorParam_ReleaseTime, value: Float(s.companderReleaseMs / 1000.0))
            setParam(unit, id: kDynamicsProcessorParam_OverallGain, value: Float(s.companderMakeupDB))
        }
    }

    private func applyLimiter(enabled: Bool, s: DSPSettings) {
        let unit = peakLimiter.audioUnit
        if !enabled {
            setParam(unit, id: kLimiterParam_PreGain, value: 0.0)
        } else {
            // preGain は 0dB とし、threshold を threshold として反映
            // PeakLimiter は AttackTime/DecayTime/PreGain の3つのみ
            setParam(unit, id: kLimiterParam_AttackTime, value: 0.012)
            setParam(unit, id: kLimiterParam_DecayTime, value: Float(s.outputLimiterReleaseMs / 1000.0))
            // preGain で threshold を近似 (limiter は 0dBFS でクリップさせる)
            // threshold が -6dB なら preGain を +6dB にして、天井 0dB で -6dB threshold と等価
            let pg = Float(-s.outputLimiterThreshold)  // -0.1 → +0.1 dB
            setParam(unit, id: kLimiterParam_PreGain, value: pg)
        }
    }

    // MARK: - AudioUnit パラメータ設定ヘルパ

    private func setParam(_ unit: AudioUnit, id: AudioUnitParameterID, value: AudioUnitParameterValue) {
        AudioUnitSetParameter(unit, id, kAudioUnitScope_Global, 0, value, 0)
    }

    private func mapBandType(_ t: ParametricBand.BandType) -> AVAudioUnitEQFilterType {
        switch t {
        case .parametric: return .parametric
        case .lowShelf:   return .lowShelf
        case .highShelf:  return .highShelf
        case .lowPass:    return .lowPass
        case .highPass:   return .highPass
        case .bandPass:   return .bandStop
        }
    }

    private func clamp<T: Comparable>(_ v: T, min lo: T, max hi: T) -> T {
        Swift.min(Swift.max(v, lo), hi)
    }

    private func dbToLinear(_ db: Double) -> Double {
        pow(10.0, db / 20.0)
    }
}
