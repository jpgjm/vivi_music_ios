//
//  DSPTap.swift
//  ViviMusic
//
//  AVPlayer が流している音声を取り出して、DSPEngine の effect chain に通して返す。
//
//  なぜこの作りなのか:
//    MusicPlayer は AVAudioEngine で再生しているため、effect chain に
//    直接音を流せた。ViviMusic の再生は AVPlayer なので、音声を加工する
//    手段は MTAudioProcessingTap しかない。
//    そこで DSPEngine の AVAudioEngine を「手動レンダリング (realtime)」で
//    動かし、タップが受け取った音声を inputNode から流し込んで、
//    chain を通った結果をタップのバッファへ書き戻している。
//    こうすると Apple 標準の AudioUnit (EQ / Reverb / DynamicsProcessor /
//    Distortion / PeakLimiter) と自作 AUv3 を MusicPlayer と同じ構成で使える。
//
//  スレッド:
//    - process コールバックはリアルタイムスレッドで呼ばれる。
//      ここではロックの「試行」だけを行い、取れなければ加工せずに流す。
//      メモリ確保・ログ書き込み・メインスレッドへの投げは一切しない。
//    - prepare / unprepare はリアルタイムではないので、ログはここで残す。
//

import Foundation
import AVFoundation
import MediaToolbox
import os

// MARK: - レンダラ (タップと DSPEngine の橋渡し)

/// DSPEngine の手動レンダリングをタップから呼ぶための窓口。
///
/// DSPEngine は @MainActor なので、リアルタイムスレッドから触る状態は
/// ここにまとめ、ロックで守る。
final class DSPRenderer: @unchecked Sendable {

    static let shared = DSPRenderer()

    /// タップ 1 本分の処理統計。unprepare 時にログへ残す。
    struct Stats {
        /// DSP を通したバッファ数
        var processed = 0
        /// マスターオフなどで素通ししたバッファ数
        var bypassed = 0
        /// エンジン再構成中などでロックが取れず素通ししたバッファ数
        var busy = 0
        /// レンダリングに失敗して素通ししたバッファ数
        var failed = 0
        /// 最後に失敗したときの状態 (AVAudioEngineManualRenderingStatus.rawValue)
        var lastFailureStatus = 0
        /// 最後に失敗したときの OSStatus
        var lastFailureError: OSStatus = noErr
    }

    private let lockPtr: UnsafeMutablePointer<os_unfair_lock>

    // --- ここから下はロックで守る ---

    private var renderBlock: AVAudioEngineManualRenderingBlock?
    private var sampleRate: Double = 0
    private var channelCount = 0
    private var maxFrames = 0

    /// 出力を受ける自前のバッファ (チャンネルごと)
    private var outputStorage: [UnsafeMutablePointer<Float>] = []
    private var outputList: UnsafeMutableAudioBufferListPointer?
    /// inputNode に渡す入力 (タップのバッファの一部を指す)
    private var inputList: UnsafeMutableAudioBufferListPointer?

    /// マスタースイッチ。オフなら chain に通さず素通しする。
    private var isActive = false

    /// 現在 DSP を通してよいタップの番号。新しい曲のタップが来たら差し替わる。
    private var ownerToken = 0
    private var nextToken = 0
    private var stats = Stats()

    // --- レンダリング中だけ使う (ロック保持中のみ触る) ---

    private var source: UnsafeMutableAudioBufferListPointer?
    private var sourceOffset = 0
    private var sourceFrames = 0

    private init() {
        lockPtr = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lockPtr.initialize(to: os_unfair_lock())
    }

    private func lock() { os_unfair_lock_lock(lockPtr) }
    private func unlock() { os_unfair_lock_unlock(lockPtr) }

    /// ロックを取って処理する (メインスレッド・準備処理用)。
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }

    // MARK: DSPEngine から

    /// エンジンの再構成前に呼ぶ。以後、再度 attach されるまで素通しになる。
    func detach() {
        lock()
        renderBlock = nil
        let storage = outputStorage
        let outList = outputList
        let inList = inputList
        outputStorage = []
        outputList = nil
        inputList = nil
        sampleRate = 0
        channelCount = 0
        maxFrames = 0
        unlock()

        // ロックを外してから解放する (以後リアルタイム側からは参照されない)
        for p in storage { p.deallocate() }
        // AudioBufferList.allocate は calloc で確保するので free で解放する
        if let outList { free(outList.unsafeMutablePointer) }
        if let inList { free(inList.unsafeMutablePointer) }
    }

    /// エンジンの構成が済んだら呼ぶ。バッファはここで確保する。
    func attach(block: @escaping AVAudioEngineManualRenderingBlock,
                sampleRate: Double,
                channelCount: Int,
                maxFrames: Int) {
        let storage = (0..<channelCount).map { _ -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
            p.initialize(repeating: 0, count: maxFrames)
            return p
        }
        let outList = AudioBufferList.allocate(maximumBuffers: channelCount)
        let inList = AudioBufferList.allocate(maximumBuffers: channelCount)
        for ch in 0..<channelCount {
            outList[ch] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: storage[ch])
            inList[ch] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        }

        lock()
        renderBlock = block
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.maxFrames = maxFrames
        outputStorage = storage
        outputList = outList
        inputList = inList
        unlock()
    }

    func setActive(_ active: Bool) {
        lock()
        isActive = active
        unlock()
    }

    // MARK: タップの準備 / 片付け (リアルタイムではない)

    /// 新しいタップが使い始める。以後はこのタップだけが DSP を通る。
    /// - Returns: タップの番号と、今のエンジンの構成がこのフォーマットに合っているか
    func claim(sampleRate: Double, channelCount: Int) -> (token: Int, matches: Bool) {
        lock()
        defer { unlock() }
        nextToken += 1
        ownerToken = nextToken
        stats = Stats()
        let matches = renderBlock != nil
            && abs(self.sampleRate - sampleRate) < 0.5
            && self.channelCount == channelCount
        return (ownerToken, matches)
    }

    /// タップを片付ける。自分が現役なら統計を返す。
    func release(token: Int) -> Stats? {
        lock()
        defer { unlock() }
        guard token != 0, token == ownerToken else { return nil }
        ownerToken = 0
        return stats
    }

    // MARK: リアルタイム

    /// inputNode から呼ばれる。レンダリング中 (ロック保持中) にだけ呼ばれる。
    func provideInput(frameCount: AVAudioFrameCount) -> UnsafePointer<AudioBufferList>? {
        guard let source, let inputList else { return nil }
        let frames = Int(frameCount)
        guard sourceOffset + frames <= sourceFrames else { return nil }

        let bytes = UInt32(frames * MemoryLayout<Float>.size)
        let count = min(source.count, inputList.count)
        for ch in 0..<count {
            guard let base = source[ch].mData else { return nil }
            inputList[ch].mData = base.advanced(by: sourceOffset * MemoryLayout<Float>.size)
            inputList[ch].mDataByteSize = bytes
        }
        sourceOffset += frames
        return UnsafePointer(inputList.unsafePointer)
    }

    /// タップのバッファを chain に通して書き戻す。
    /// - Returns: 加工したら true (false なら元の音のまま)
    @discardableResult
    func process(bufferList: UnsafeMutablePointer<AudioBufferList>,
                 frames: Int,
                 token: Int) -> Bool {
        guard frames > 0, token != 0 else { return false }

        // リアルタイムスレッドなので待たない。取れなければ素通し。
        guard os_unfair_lock_trylock(lockPtr) else { return false }
        defer { os_unfair_lock_unlock(lockPtr) }

        guard token == ownerToken else { return false }
        guard isActive else {
            stats.bypassed += 1
            return false
        }
        guard let block = renderBlock, let outputList, maxFrames > 0 else {
            stats.busy += 1
            return false
        }

        let list = UnsafeMutableAudioBufferListPointer(bufferList)
        guard list.count == channelCount else {
            stats.busy += 1
            return false
        }
        let needBytes = frames * MemoryLayout<Float>.size
        for ch in 0..<list.count {
            guard list[ch].mData != nil, Int(list[ch].mDataByteSize) >= needBytes else {
                stats.busy += 1
                return false
            }
        }

        source = list
        sourceOffset = 0
        sourceFrames = frames
        defer { source = nil }

        var done = 0
        while done < frames {
            let chunk = min(frames - done, maxFrames)
            let chunkBytes = UInt32(chunk * MemoryLayout<Float>.size)
            for ch in 0..<outputList.count {
                outputList[ch].mData = UnsafeMutableRawPointer(outputStorage[ch])
                outputList[ch].mDataByteSize = chunkBytes
            }

            var error: OSStatus = noErr
            let status = block(AVAudioFrameCount(chunk), outputList.unsafeMutablePointer, &error)
            guard status == .success else {
                stats.failed += 1
                stats.lastFailureStatus = status.rawValue
                stats.lastFailureError = error
                // ここまでに書き戻したぶんは加工済み、残りは元の音のまま
                return done > 0
            }

            for ch in 0..<list.count {
                guard let dst = list[ch].mData, let src = outputList[ch].mData else { continue }
                memcpy(dst.advanced(by: done * MemoryLayout<Float>.size), src, Int(chunkBytes))
            }
            done += chunk
        }

        stats.processed += 1
        return true
    }
}

// MARK: - タップ

/// タップの内部で持ち回す状態。
/// C のコールバックから触るため、参照型にして Unmanaged で受け渡す。
private final class TapContext {
    let renderer = DSPRenderer.shared
    /// claim で受け取った番号。0 なら DSP を通さない (非対応フォーマットなど)。
    var token = 0
    var formatDescription = ""
}

/// AVPlayerItem に取り付ける DSP。
@MainActor
final class DSPTap {

    /// MTAudioProcessingTap は Swift に自動ブリッジされるので、
    /// Unmanaged で包まずそのまま保持できる。
    private var tap: MTAudioProcessingTap?

    /// この AVPlayerItem 用の audioMix を組み立てて返す。
    /// 取り付けに失敗した場合は nil (その場合は加工なしで再生される)。
    func makeAudioMix(track: AVAssetTrack) -> AVAudioMix? {
        let context = TapContext()

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
            EventLog.log(.dspError, message: "DSP タップの取り付けに失敗 (status=\(status))")
            return nil
        }
        self.tap = tapRef

        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tapRef

        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
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
    // makeAudioMix で passRetained したぶんを解放する
    Unmanaged<TapContext>.fromOpaque(storage).release()
}

private func tapPrepare(tap: MTAudioProcessingTap,
                        maxFrames: CMItemCount,
                        processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()

    let asbd = processingFormat.pointee
    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    let sampleRate = asbd.mSampleRate
    let channels = Int(asbd.mChannelsPerFrame)
    let description = "\(Int(sampleRate))Hz / \(channels)ch / \(asbd.mBitsPerChannel)bit"
        + (isFloat ? " float" : " int")
        + (isNonInterleaved ? " non-interleaved" : " interleaved")
        + " / maxFrames=\(maxFrames)"
    context.formatDescription = description

    // Custom AUv3 が 2ch までなので 1〜2ch の float / non-interleaved だけ扱う
    let supported = asbd.mFormatID == kAudioFormatLinearPCM
        && isFloat && isNonInterleaved
        && asbd.mBitsPerChannel == 32
        && (1...2).contains(channels)
        && sampleRate > 0

    guard supported else {
        context.token = 0
        DispatchQueue.main.async {
            EventLog.log(.dspError, message: "DSP 非対応の音声フォーマットのため素通し: \(description)")
        }
        return
    }

    let (token, matches) = context.renderer.claim(sampleRate: sampleRate, channelCount: channels)
    context.token = token

    DispatchQueue.main.async {
        EventLog.log(.dsp, message: "DSP タップ準備: \(description)"
                     + (matches ? "" : " (エンジンを再構成)"))
        if !matches {
            MainActor.assumeIsolated {
                DSPEngine.shared.configureForStream(sampleRate: sampleRate,
                                                    channelCount: AVAudioChannelCount(channels))
            }
        }
    }
}

private func tapUnprepare(tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()

    guard let stats = context.renderer.release(token: context.token) else { return }
    let message = "DSP タップ終了: 処理 \(stats.processed) / 素通し \(stats.bypassed)"
        + " / 待機 \(stats.busy) / 失敗 \(stats.failed)"
    let failed = stats.failed > 0
    let detail = failed
        ? " (最後の失敗: status=\(stats.lastFailureStatus), error=\(stats.lastFailureError))"
        : ""
    DispatchQueue.main.async {
        EventLog.log(failed ? .dspError : .dsp, message: message + detail)
    }
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

    context.renderer.process(bufferList: bufferListInOut,
                             frames: Int(numberFramesOut.pointee),
                             token: context.token)
}
