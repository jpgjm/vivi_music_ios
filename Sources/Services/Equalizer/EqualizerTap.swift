//
//  EqualizerTap.swift
//  ViviMusic
//
//  AVPlayer が流している音声を取り出して、イコライザーをかけて返す。
//
//  なぜこの作りなのか:
//    MusicPlayer は AVAudioEngine を使っているため AVAudioUnitEQ を
//    そのまま挟めた。ViviMusic の再生は AVPlayer なので同じことができない。
//    AVPlayer で音声を加工する手段は MTAudioProcessingTap しかないため、
//    フィルタ処理を自前で書いて (BiquadFilter) ここから呼んでいる。
//
//  MTAudioProcessingTap は C の関数ポインタでやり取りするので、
//  Swift のオブジェクトを直接渡せない。
//  そのため clientInfo に Unmanaged で包んだ箱を渡している。
//

import Foundation
import AVFoundation
import MediaToolbox

/// タップの内部で持ち回す状態。
/// C のコールバックから触るため、参照型にして Unmanaged で受け渡す。
private final class TapContext {
    /// 左右それぞれのフィルタ列
    var chains: [BiquadChain] = []
    var sampleRate: Double = 44100

    /// 有効かどうか。切っているときは何も加工しない。
    var isEnabled = false
    var frequencies: [Double] = EqualizerConstants.frequencies
    var gains: [Double] = Array(repeating: 0,
                                count: EqualizerConstants.frequencies.count)
    var preampDB: Double = 0

    /// 設定が変わったので係数を作り直す必要がある。
    var needsReconfigure = true

    /// 設定の読み書きを守る。UI 側と音声処理側で同時に触るため。
    let lock = NSLock()

    func updateSettings(enabled: Bool, gains: [Double], preampDB: Double) {
        lock.lock()
        self.isEnabled = enabled
        self.gains = gains
        self.preampDB = preampDB
        self.needsReconfigure = true
        lock.unlock()
    }

    /// 係数を作り直す (音声処理側から呼ぶ)。
    func reconfigureIfNeeded(channelCount: Int) {
        lock.lock()
        defer { lock.unlock() }

        if chains.count != channelCount {
            chains = (0..<channelCount).map { _ in
                BiquadChain(bandCount: frequencies.count)
            }
            needsReconfigure = true
        }
        guard needsReconfigure else { return }

        for index in chains.indices {
            chains[index].configure(frequencies: frequencies,
                                    gains: gains,
                                    preampDB: preampDB,
                                    sampleRate: sampleRate)
        }
        needsReconfigure = false
    }

    func resetFilters() {
        lock.lock()
        for index in chains.indices { chains[index].reset() }
        lock.unlock()
    }
}

/// AVPlayerItem に取り付けるイコライザー。
@MainActor
final class EqualizerTap {

    private var context: TapContext?
    /// MTAudioProcessingTap は Swift に自動ブリッジされるので、
    /// Unmanaged で包まずそのまま保持できる。
    private var tap: MTAudioProcessingTap?

    /// この AVPlayerItem 用の audioMix を組み立てて返す。
    /// 取り付けに失敗した場合は nil (その場合は加工なしで再生される)。
    func makeAudioMix(for asset: AVAsset,
                      track: AVAssetTrack,
                      settings: (enabled: Bool, gains: [Double], preampDB: Double)) -> AVAudioMix? {

        let context = TapContext()
        context.updateSettings(enabled: settings.enabled,
                               gains: settings.gains,
                               preampDB: settings.preampDB)
        self.context = context

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )

        var tapRef: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            // PostEffects: 音量調整などの後に受け取る
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tapRef
        )

        guard status == noErr, let tapRef else {
            EventLog.log(.playError,
                         message: "イコライザーの取り付けに失敗 (status=\(status))")
            return nil
        }
        self.tap = tapRef

        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tapRef

        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    /// 設定を反映する。曲を止めずに変えられる。
    func update(settings: (enabled: Bool, gains: [Double], preampDB: Double)) {
        context?.updateSettings(enabled: settings.enabled,
                                gains: settings.gains,
                                preampDB: settings.preampDB)
    }

    /// 曲が変わるときに呼ぶ。フィルタの履歴を捨てて雑音を防ぐ。
    func reset() {
        context?.resetFilters()
    }
}

// MARK: - C コールバック

private func tapInit(tap: MTAudioProcessingTap,
                     clientInfo: UnsafeMutableRawPointer?,
                     tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    // clientInfo で渡した箱を、そのまま tapStorage に置いて以後の呼び出しで使う
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    // init のときに passRetained したぶんを解放する
    Unmanaged<TapContext>.fromOpaque(storage).release()
}

private func tapPrepare(tap: MTAudioProcessingTap,
                        maxFrames: CMItemCount,
                        processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()

    context.lock.lock()
    context.sampleRate = processingFormat.pointee.mSampleRate
    context.needsReconfigure = true
    context.lock.unlock()
}

private func tapUnprepare(tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()
    context.resetFilters()
}

private func tapProcess(tap: MTAudioProcessingTap,
                        numberFrames: CMItemCount,
                        flags: MTAudioProcessingTapFlags,
                        bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
                        numberFramesOut: UnsafeMutablePointer<CMItemCount>,
                        flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {

    // まず元の音声を受け取る。ここで得た buffer を書き換えると出力に反映される。
    let status = MTAudioProcessingTapGetSourceAudio(tap,
                                                    numberFrames,
                                                    bufferListInOut,
                                                    flagsOut,
                                                    nil,
                                                    numberFramesOut)
    guard status == noErr else { return }

    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()

    // 切っているときは触らずそのまま流す
    context.lock.lock()
    let enabled = context.isEnabled
    context.lock.unlock()
    guard enabled else { return }

    let bufferList = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    context.reconfigureIfNeeded(channelCount: bufferList.count)

    context.lock.lock()
    defer { context.lock.unlock() }

    for (channelIndex, buffer) in bufferList.enumerated() {
        guard channelIndex < context.chains.count,
              let raw = buffer.mData else { continue }

        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let samples = raw.bindMemory(to: Float.self, capacity: sampleCount)

        for i in 0..<sampleCount {
            samples[i] = context.chains[channelIndex].process(samples[i])
        }
    }
}
