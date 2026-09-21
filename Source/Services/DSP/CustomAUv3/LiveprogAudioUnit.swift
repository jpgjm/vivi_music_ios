//
//  LiveprogAudioUnit.swift
//  ViviMusic
//
//  EEL2 スクリプト (@sample セクション) を毎サンプル実行する Custom AUv3。
//  Phase 3-1: シンプルな AST インタプリタで実行。
//
//  安全性:
//    - スクリプトがない/コンパイル失敗時はバイパス
//    - 実行時例外は無音出力にフォールバック
//    - while ループは 100000 回で強制脱出 (EEL2Executor 内で制御)
//

import Foundation
import AVFoundation
import AudioToolbox

final class LiveprogAudioUnit: AUAudioUnit {

    static let maxChannels: Int = 2

    // MARK: バス

    private var _inputBus: AUAudioUnitBus!
    private var _outputBus: AUAudioUnitBus!
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

    // MARK: 状態

    /// バイパス (true なら効果なし)
    var chainBypass: Bool = true
    /// 実行エンジン (メインスレッドから setExecutor で設定)
    private var executor: EEL2Executor?
    /// エンジン差し替え用のロック (メインスレッドが更新、レンダースレッドが読む)
    /// リアルタイム安全のため atomic pointer swap で扱う
    private let executorLock = NSLock()

    // MARK: 初期化

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        self._inputBus = try AUAudioUnitBus(format: format)
        self._outputBus = try AUAudioUnitBus(format: format)
        self._inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [_inputBus])
        self._outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [_outputBus])
    }

    // MARK: AUAudioUnit オーバーライド

    override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
    }

    // MARK: - スクリプト管理

    /// スクリプトを設定 (メインスレッドから呼ぶ)
    func setProgram(_ program: EEL2Parser.Program?, sampleRate: Double = 44100) {
        executorLock.lock()
        defer { executorLock.unlock() }

        chainBypass = true

        guard let program = program else {
            executor = nil
            return
        }

        let newExec = EEL2Executor(program: program)
        newExec.setSampleRate(sampleRate)
        newExec.resetSlidersToDefaults()
        newExec.runInit()
        newExec.runSlider()  // 初回 @slider 実行 (事前計算)
        executor = newExec
    }

    /// スライダー値を更新 (メインスレッドから)
    /// 更新後に @slider セクションを実行して事前計算値を反映する。
    func setSliderValue(sliderIndex: Int, value: Double) {
        executorLock.lock()
        defer { executorLock.unlock() }
        executor?.applySliderValue(sliderIndex: sliderIndex, value: value)
    }

    /// スライダーの一括反映後に @slider セクションを実行する。
    /// 複数のスライダー値を setSliderValue で更新した後、この関数を呼ぶことで
    /// @slider を 1 回だけ実行する (毎スライダー変更で呼ぶよりも効率的)。
    func runSliderSection() {
        executorLock.lock()
        defer { executorLock.unlock() }
        executor?.runSlider()
    }

    /// 現在のプログラムのスライダー一覧
    func currentSliders() -> [EEL2Slider]? {
        executorLock.lock()
        defer { executorLock.unlock() }
        return executor?.program.sliders
    }

    /// パフォーマンス統計を取得
    struct Statistics {
        let lastSampleInstructions: Int
        let cumulativeSampleInstructions: UInt64
        let cumulativeSampleCalls: UInt64
        var averageInstructionsPerSample: Double {
            cumulativeSampleCalls == 0 ? 0 : Double(cumulativeSampleInstructions) / Double(cumulativeSampleCalls)
        }
    }

    func statistics() -> Statistics? {
        executorLock.lock()
        defer { executorLock.unlock() }
        guard let exec = executor else { return nil }
        return Statistics(
            lastSampleInstructions: exec.lastSampleInstructionCount,
            cumulativeSampleInstructions: exec.cumulativeSampleInstructions,
            cumulativeSampleCalls: exec.cumulativeSampleCalls
        )
    }

    /// 統計をリセット
    func resetStatistics() {
        executorLock.lock()
        defer { executorLock.unlock() }
        executor?.resetStatistics()
    }

    // MARK: - Render block

    override var internalRenderBlock: AUInternalRenderBlock {
        let getBypass: () -> Bool = { [weak self] in self?.chainBypass ?? true }
        let processFrames: (UnsafeMutableAudioBufferListPointer, Int) -> Void = { [weak self] abl, frames in
            self?.processFrames(abl: abl, frames: frames)
        }

        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData, realtimeEventListHead, pullInputBlock in
            let err = pullInputBlock?(actionFlags, timestamp, frameCount, 0, outputData) ?? noErr
            if err != noErr { return err }

            let bypass = getBypass()
            if bypass { return noErr }

            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            processFrames(abl, Int(frameCount))
            return noErr
        }
    }

    /// フレーム処理 (per-sample で EEL2 スクリプトを実行)
    private func processFrames(abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        // ロック内でエグゼキュータ参照を取得
        executorLock.lock()
        let exec = executor
        executorLock.unlock()
        guard let exec = exec else { return }

        let channelCount = min(abl.count, Self.maxChannels)
        // ステレオ想定: L と R を同時に処理
        guard channelCount >= 2 else {
            // モノラルの場合は spl0 のみ更新して spl1 は同じ
            if channelCount == 1, let mData = abl[0].mData {
                let ptr = mData.assumingMemoryBound(to: Float.self)
                let spl0Idx = exec.program.spl0Index
                let spl1Idx = exec.program.spl1Index
                let vars = exec.variables
                for i in 0 ..< frames {
                    vars[spl0Idx] = Double(ptr[i])
                    vars[spl1Idx] = Double(ptr[i])
                    exec.runSample()
                    ptr[i] = Float(vars[spl0Idx])
                }
            }
            return
        }

        guard let lData = abl[0].mData, let rData = abl[1].mData else { return }
        let lPtr = lData.assumingMemoryBound(to: Float.self)
        let rPtr = rData.assumingMemoryBound(to: Float.self)

        let vars = exec.variables
        let spl0Idx = exec.program.spl0Index
        let spl1Idx = exec.program.spl1Index

        for i in 0 ..< frames {
            vars[spl0Idx] = Double(lPtr[i])
            vars[spl1Idx] = Double(rPtr[i])
            exec.runSample()
            lPtr[i] = Float(vars[spl0Idx])
            rPtr[i] = Float(vars[spl1Idx])
        }
    }
}
