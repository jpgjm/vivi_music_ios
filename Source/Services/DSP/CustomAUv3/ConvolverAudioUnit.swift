//
//  ConvolverAudioUnit.swift
//  ViviMusic
//
//  IR (Impulse Response) との畳み込みをリアルタイム実行する Custom AUv3。
//  Overlap-Save 法 + vDSP FFT で実装。
//
//  アルゴリズム:
//    - FFT サイズ N = 8192 (2^13、固定)
//    - IR 長 M (最大 N-1 = 8191、約 185 ms @ 44.1kHz)
//    - Hop size L = N - M + 1 (1 hop で処理する入力 sample 数)
//    - 各 hop:
//      1. 過去の (M-1) sample と新規の L sample を結合して N sample の入力ブロックを作る
//      2. N-point real FFT で X を得る
//      3. Y = X * H (要素毎複素乗算、H は事前計算した IR の FFT)
//      4. N-point inverse real FFT で y を得る
//      5. y[M-1 .. N-1] の L sample が出力 (先頭 M-1 sample は circular convolution artifact なので破棄)
//    - render block は可変 frameCount で呼ばれるので、入出力ともにリングバッファで吸収
//
//  スレッド安全性:
//    - IR ロード (loadIR) はメインスレッドで実行
//    - render block 内では H (frequency-domain IR) はロード時から不変
//    - loadIR 中はバイパスに切り替える (音の途切れが発生しうるがクラッシュはしない)
//

import Foundation
import AVFoundation
import AudioToolbox
import Accelerate

final class ConvolverAudioUnit: AUAudioUnit {

    // MARK: 定数

    /// FFT サイズ (2 の累乗、log2 = 13)
    static let fftSize: Int = 8192
    static let fftLog2: vDSP_Length = 13
    /// 最大 IR 長
    static let maxIRLength: Int = 8191
    /// リングバッファサイズ (十分な余裕を持つ)
    static let ringBufferSize: Int = 32768
    /// サポートするチャンネル数
    static let maxChannels: Int = 2

    // MARK: バス

    private var _inputBus: AUAudioUnitBus!
    private var _outputBus: AUAudioUnitBus!
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

    // MARK: FFT setup

    private let fftSetup: FFTSetup

    // MARK: IR (frequency-domain)

    /// IR の FFT 結果 (H)。実部と虚部を分けて保持。
    /// チャンネル毎に用意 (現在はモノラル IR を L/R 両方に使う)
    private var irRealPtr: UnsafeMutablePointer<Float>
    private var irImagPtr: UnsafeMutablePointer<Float>

    /// 現在の IR 長 (sample)
    private var irLength: Int = 0
    /// Hop size (= N - M + 1)
    private var hopSize: Int = ConvolverAudioUnit.fftSize

    // MARK: FFT 作業バッファ

    /// 時間領域入力バッファ (N samples)
    private var timeInputPtr: UnsafeMutablePointer<Float>
    /// 時間領域出力バッファ (N samples)
    private var timeOutputPtr: UnsafeMutablePointer<Float>
    /// 周波数領域バッファ (実部)
    private var freqRealPtr: UnsafeMutablePointer<Float>
    /// 周波数領域バッファ (虚部)
    private var freqImagPtr: UnsafeMutablePointer<Float>

    // MARK: リングバッファ (チャンネル毎)

    /// 入力リングバッファ (未処理サンプル)
    private var inputRings: [RingBuffer]
    /// 出力リングバッファ (処理済みサンプル)
    private var outputRings: [RingBuffer]
    /// 前 hop の末尾 (M-1) sample を保持 (overlap 部分)
    private var overlapBuffers: [UnsafeMutablePointer<Float>]
    /// overlap の有効長 (= M-1)
    private var overlapLength: Int = 0

    // MARK: 状態

    var chainBypass: Bool = true
    private var isReady: Bool = false

    // MARK: 初期化

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {

        // FFT setup 作成
        guard let setup = vDSP_create_fftsetup(Self.fftLog2, FFTRadix(kFFTRadix2)) else {
            throw AUError.invalidFormat
        }
        self.fftSetup = setup

        // IR 周波数領域バッファ (N/2 個の複素数 → 実部虚部それぞれ N/2 個)
        // Accelerate の split complex では長さ N の real FFT は N/2 個の split complex を出力
        let half = Self.fftSize / 2
        self.irRealPtr = UnsafeMutablePointer<Float>.allocate(capacity: half)
        self.irRealPtr.initialize(repeating: 0, count: half)
        self.irImagPtr = UnsafeMutablePointer<Float>.allocate(capacity: half)
        self.irImagPtr.initialize(repeating: 0, count: half)

        // 時間領域と周波数領域の作業バッファ
        self.timeInputPtr = UnsafeMutablePointer<Float>.allocate(capacity: Self.fftSize)
        self.timeInputPtr.initialize(repeating: 0, count: Self.fftSize)
        self.timeOutputPtr = UnsafeMutablePointer<Float>.allocate(capacity: Self.fftSize)
        self.timeOutputPtr.initialize(repeating: 0, count: Self.fftSize)
        self.freqRealPtr = UnsafeMutablePointer<Float>.allocate(capacity: half)
        self.freqRealPtr.initialize(repeating: 0, count: half)
        self.freqImagPtr = UnsafeMutablePointer<Float>.allocate(capacity: half)
        self.freqImagPtr.initialize(repeating: 0, count: half)

        // リングバッファ (channel 数分)
        self.inputRings = (0 ..< Self.maxChannels).map { _ in RingBuffer(capacity: Self.ringBufferSize) }
        self.outputRings = (0 ..< Self.maxChannels).map { _ in RingBuffer(capacity: Self.ringBufferSize) }

        // Overlap バッファ (channel 数分、最大 M-1 = maxIRLength-1 サンプル)
        self.overlapBuffers = (0 ..< Self.maxChannels).map { _ in
            let ptr = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxIRLength)
            ptr.initialize(repeating: 0, count: Self.maxIRLength)
            return ptr
        }

        try super.init(componentDescription: componentDescription, options: options)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        self._inputBus = try AUAudioUnitBus(format: format)
        self._outputBus = try AUAudioUnitBus(format: format)
        self._inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [_inputBus])
        self._outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [_outputBus])
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        let half = Self.fftSize / 2
        irRealPtr.deinitialize(count: half); irRealPtr.deallocate()
        irImagPtr.deinitialize(count: half); irImagPtr.deallocate()
        timeInputPtr.deinitialize(count: Self.fftSize); timeInputPtr.deallocate()
        timeOutputPtr.deinitialize(count: Self.fftSize); timeOutputPtr.deallocate()
        freqRealPtr.deinitialize(count: half); freqRealPtr.deallocate()
        freqImagPtr.deinitialize(count: half); freqImagPtr.deallocate()
        for ptr in overlapBuffers {
            ptr.deinitialize(count: Self.maxIRLength)
            ptr.deallocate()
        }
    }

    // MARK: AUAudioUnit オーバーライド

    override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        resetState()
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
    }

    /// リングバッファと overlap を全リセット
    func resetState() {
        for r in inputRings { r.reset() }
        for r in outputRings { r.reset() }
        for ptr in overlapBuffers {
            for i in 0 ..< Self.maxIRLength { ptr[i] = 0 }
        }
    }

    // MARK: - IR ロード

    /// AVAudioFile から IR を読み込み、モノラル化して FFT 変換する。
    /// - Note: メインスレッドから呼ぶ。処理中は自動的に chainBypass = true に切り替え。
    func loadIR(from url: URL, targetSampleRate: Double = 44100) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AUError.invalidFormat
        }
        try file.read(into: buffer)

        // モノラル化: 全チャンネルを平均
        var monoSamples = [Float](repeating: 0, count: Int(buffer.frameLength))
        if let channelData = buffer.floatChannelData {
            let channels = Int(format.channelCount)
            let length = Int(buffer.frameLength)
            for i in 0 ..< length {
                var sum: Float = 0
                for ch in 0 ..< channels {
                    sum += channelData[ch][i]
                }
                monoSamples[i] = sum / Float(channels)
            }
        }

        // サンプルレート調整 (簡易: 差があれば線形補間)
        if abs(format.sampleRate - targetSampleRate) > 1.0 {
            monoSamples = resample(monoSamples, from: format.sampleRate, to: targetSampleRate)
        }

        // IR 長は maxIRLength 以内にカット
        let irLen = min(monoSamples.count, Self.maxIRLength)
        var irData = Array(monoSamples.prefix(irLen))

        // 正規化 (ピーク = 1.0 になるようスケール) — 過度なブーストを防ぐ
        var peak: Float = 0
        vDSP_maxmgv(irData, 1, &peak, vDSP_Length(irLen))
        if peak > 0 {
            var scale: Float = 1.0 / peak * 0.5  // safety margin: -6 dB
            vDSP_vsmul(irData, 1, &scale, &irData, 1, vDSP_Length(irLen))
        }

        try applyIR(samples: irData)
    }

    /// 実際に IR を FFT 変換して内部状態に反映
    private func applyIR(samples: [Float]) throws {
        let m = samples.count
        guard m > 0 && m <= Self.maxIRLength else {
            throw AUError.invalidFormat
        }

        // 一時的にバイパスして render 中の不整合を回避
        let previousBypass = chainBypass
        chainBypass = true

        // ゼロパディング (N = fftSize)
        var padded = [Float](repeating: 0, count: Self.fftSize)
        for i in 0 ..< m { padded[i] = samples[i] }

        // 実数信号 → split complex にパック → FFT
        var splitComplex = DSPSplitComplex(realp: irRealPtr, imagp: irImagPtr)
        padded.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) { cptr in
                vDSP_ctoz(cptr, 2, &splitComplex, 1, vDSP_Length(Self.fftSize / 2))
            }
        }
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, Self.fftLog2, FFTDirection(FFT_FORWARD))

        // FFT のスケール調整 (vDSP は 2x のゲインが乗るので 0.5 で補正)
        var half: Float = 0.5
        vDSP_vsmul(splitComplex.realp, 1, &half, splitComplex.realp, 1, vDSP_Length(Self.fftSize / 2))
        vDSP_vsmul(splitComplex.imagp, 1, &half, splitComplex.imagp, 1, vDSP_Length(Self.fftSize / 2))

        // 状態更新
        irLength = m
        overlapLength = m - 1
        hopSize = Self.fftSize - overlapLength
        resetState()
        isReady = true
        chainBypass = previousBypass
    }

    /// IR をアンロード (bypass に戻す)
    func unloadIR() {
        chainBypass = true
        isReady = false
        irLength = 0
        overlapLength = 0
        hopSize = Self.fftSize
        resetState()
    }

    /// 単純な線形補間リサンプル (品質より簡潔さ優先)
    private func resample(_ input: [Float], from fromSR: Double, to toSR: Double) -> [Float] {
        let ratio = fromSR / toSR
        let outLen = Int(Double(input.count) / ratio)
        var output = [Float](repeating: 0, count: outLen)
        for i in 0 ..< outLen {
            let srcPos = Double(i) * ratio
            let idx = Int(srcPos)
            let frac = Float(srcPos - Double(idx))
            let a = idx < input.count ? input[idx] : 0
            let b = idx + 1 < input.count ? input[idx + 1] : 0
            output[i] = a * (1 - frac) + b * frac
        }
        return output
    }

    // MARK: - Render block

    override var internalRenderBlock: AUInternalRenderBlock {
        // キャプチャ
        let getBypass: () -> Bool = { [weak self] in self?.chainBypass ?? true }
        let getReady: () -> Bool = { [weak self] in self?.isReady ?? false }
        let getHop: () -> Int = { [weak self] in self?.hopSize ?? Self.fftSize }
        let getOverlap: () -> Int = { [weak self] in self?.overlapLength ?? 0 }
        let processHop: (Int) -> Void = { [weak self] ch in self?.processOneHop(channel: ch) }

        let inputRingsRef = self.inputRings
        let outputRingsRef = self.outputRings

        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData, realtimeEventListHead, pullInputBlock in

            // 1. 入力を outputData に pull
            let err = pullInputBlock?(actionFlags, timestamp, frameCount, 0, outputData) ?? noErr
            if err != noErr { return err }

            let bypass = getBypass()
            let ready = getReady()

            // バイパス or IR 未ロードなら素通し
            if bypass || !ready { return noErr }

            let hop = getHop()
            let overlap = getOverlap()

            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            let channelCount = min(abl.count, Self.maxChannels)
            let frames = Int(frameCount)

            // 2. 各チャンネル: 入力 → リング → hop 処理 → リング → 出力
            for ch in 0 ..< channelCount {
                guard let mData = abl[ch].mData else { continue }
                let samples = mData.assumingMemoryBound(to: Float.self)

                // 入力を inputRing に書き込む
                inputRingsRef[ch].write(from: samples, count: frames)

                // hop 単位で処理を回す
                while inputRingsRef[ch].availableToRead >= hop
                        && outputRingsRef[ch].availableToWrite >= hop {
                    processHop(ch)
                }

                // 出力リングから取り出す
                if outputRingsRef[ch].availableToRead >= frames {
                    outputRingsRef[ch].read(into: samples, count: frames)
                } else {
                    // 出力バッファに十分なデータがない場合 (初回等) は 0 埋め
                    for i in 0 ..< frames { samples[i] = 0 }
                    // (この後 hop が溜まれば正常化する。IR 長分の遅延は初回のみ)
                    let avail = outputRingsRef[ch].availableToRead
                    if avail > 0 {
                        outputRingsRef[ch].read(into: samples, count: avail)
                    }
                }

                // overlap 更新は processOneHop 内で
                _ = overlap  // suppress unused warning
            }

            return noErr
        }
    }

    /// 1 hop の畳み込み処理 (main 側のバッファを使うのでリアルタイムスレッド専用)
    /// 注: これは MainActor に isolated されていない (nonisolated) が、
    ///     関連バッファへのアクセスはこの関数内で完結するのでスレッド安全性を保つ。
    private func processOneHop(channel ch: Int) {
        let n = Self.fftSize
        let m = irLength
        let overlap = overlapLength
        let hop = hopSize
        guard m > 0 && ch < inputRings.count else { return }

        // 1. 時間領域入力の構築:
        //    先頭 (M-1) は前回の overlap、残り hop 分は inputRing から取り出し
        for i in 0 ..< overlap {
            timeInputPtr[i] = overlapBuffers[ch][i]
        }
        // inputRing から hop サンプル取り出し
        inputRings[ch].read(into: timeInputPtr.advanced(by: overlap), count: hop)

        // 次回の overlap 用に、今回の入力末尾 (M-1) サンプルをコピー
        for i in 0 ..< overlap {
            overlapBuffers[ch][i] = timeInputPtr[n - overlap + i]
        }

        // 2. real FFT
        var splitX = DSPSplitComplex(realp: freqRealPtr, imagp: freqImagPtr)
        timeInputPtr.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cptr in
            vDSP_ctoz(cptr, 2, &splitX, 1, vDSP_Length(n / 2))
        }
        vDSP_fft_zrip(fftSetup, &splitX, 1, Self.fftLog2, FFTDirection(FFT_FORWARD))

        // 3. Y = X * H (要素毎複素乗算)
        // vDSP_zvmul は complex 乗算 (splitX * splitH → splitX, use conjugate=1)
        // vDSP_fft_zrip の場合、DC 成分と Nyquist 成分が特殊な pack 方法で入っている:
        //   real[0] = DC の real
        //   imag[0] = Nyquist の real (実数信号なので Nyquist の imag は 0)
        // 通常の複素乗算では別扱いする必要がある。
        let halfN = n / 2

        // DC と Nyquist を保存
        let xDC = freqRealPtr[0]
        let xNy = freqImagPtr[0]
        let hDC = irRealPtr[0]
        let hNy = irImagPtr[0]

        // 通常のビン (1 .. halfN-1) は複素乗算
        freqRealPtr[0] = 0
        freqImagPtr[0] = 0
        var splitH = DSPSplitComplex(realp: irRealPtr, imagp: irImagPtr)
        vDSP_zvmul(&splitX, 1, &splitH, 1, &splitX, 1, vDSP_Length(halfN), 1)

        // DC と Nyquist は実数乗算
        freqRealPtr[0] = xDC * hDC
        freqImagPtr[0] = xNy * hNy

        // 4. 逆 FFT
        vDSP_fft_zrip(fftSetup, &splitX, 1, Self.fftLog2, FFTDirection(FFT_INVERSE))

        // split → real (デパック)
        timeOutputPtr.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cptr in
            vDSP_ztoc(&splitX, 1, cptr, 2, vDSP_Length(halfN))
        }

        // vDSP の inverse FFT は N/2 倍のゲインが乗るので補正 (× 1/N)
        var scale: Float = 1.0 / Float(n)
        vDSP_vsmul(timeOutputPtr, 1, &scale, timeOutputPtr, 1, vDSP_Length(n))

        // 5. Overlap-Save: 有効な出力は末尾 hop サンプル
        // (先頭 overlap サンプルは circular convolution artifact)
        outputRings[ch].write(from: timeOutputPtr.advanced(by: overlap), count: hop)
    }
}

// MARK: - Ring Buffer

/// リアルタイム対応の単純なリングバッファ (Float 用、シングルスレッド想定)
/// AU の render block と loadIR の間で使うが、実際は render block からのみアクセス。
final class RingBuffer {
    private let buffer: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private var count: Int = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    var availableToRead: Int { count }
    var availableToWrite: Int { capacity - count }

    func reset() {
        writeIndex = 0
        readIndex = 0
        count = 0
    }

    func write(from src: UnsafePointer<Float>, count srcCount: Int) {
        let writeCount = min(srcCount, availableToWrite)
        for i in 0 ..< writeCount {
            buffer[writeIndex] = src[i]
            writeIndex = (writeIndex + 1) % capacity
        }
        count += writeCount
    }

    func read(into dst: UnsafeMutablePointer<Float>, count dstCount: Int) {
        let readCount = min(dstCount, availableToRead)
        for i in 0 ..< readCount {
            dst[i] = buffer[readIndex]
            readIndex = (readIndex + 1) % capacity
        }
        count -= readCount
    }
}
