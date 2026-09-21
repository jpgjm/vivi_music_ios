//
//  LiveprogSamples.swift
//  ViviMusic
//
//  起動時に Documents/Liveprog/Samples/ にサンプル EEL2 スクリプトを配置する。
//  ユーザーが Liveprog ファイル選択で即座に試せる。
//
//  一度書き出したファイルは上書きしない (ユーザーが編集した場合の保護)。
//  ただしファイル名を `Sample_XXX.eel` にすることで、ユーザーのファイルと区別。
//

import Foundation

enum LiveprogSamples {

    struct Sample {
        let filename: String
        let source: String
    }

    /// 全サンプル
    static let all: [Sample] = [
        Sample(filename: "Sample_01_SimpleGain.eel", source: simpleGain),
        Sample(filename: "Sample_02_SoftClip.eel", source: softClip),
        Sample(filename: "Sample_03_SimpleDelay.eel", source: simpleDelay),
        Sample(filename: "Sample_04_TremoloLFO.eel", source: tremoloLFO),
        Sample(filename: "Sample_05_3BandSplitter.eel", source: threeBandSplitter),
    ]

    /// 起動時に呼び出す。ファイルが存在しない場合のみ書き出す。
    @discardableResult
    static func installIfNeeded() -> Int {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let sampleDir = docs.appendingPathComponent("Liveprog", isDirectory: true)
        try? FileManager.default.createDirectory(at: sampleDir, withIntermediateDirectories: true)

        var installed = 0
        for sample in all {
            let url = sampleDir.appendingPathComponent(sample.filename)
            if !FileManager.default.fileExists(atPath: url.path) {
                do {
                    try sample.source.write(to: url, atomically: true, encoding: .utf8)
                    installed += 1
                } catch {
                    EventLog.logError(.dspError, error: error, context: "Liveprog サンプルの書き出し (\(sample.filename))")
                }
            }
        }
        return installed
    }

    // MARK: - サンプルコード

    static let simpleGain = """
    desc: Simple Gain
    // 基本のゲイン調整。dB → linear 変換のよくあるパターン。

    gain:0<-24,24,0.5>Gain (dB)

    @slider
    // スライダー変更時に一度だけ実行 (毎サンプル計算を避ける)
    gainLinear = 10^(gain / 20);

    @sample
    spl0 = spl0 * gainLinear;
    spl1 = spl1 * gainLinear;
    """

    static let softClip = """
    desc: Soft Clip Distortion
    // 真空管風の温かい歪みを atan() で作る。

    drive:2<1,10,0.1>Drive
    mix:100<0,100,1>Mix (%)
    outGain:0<-12,12,0.1>Output Gain (dB)

    // ユーザー関数: 参照渡し不要のシンプルな例
    function softClipSample(x, d) (
        atan(x * d) / atan(d)
    );

    @slider
    mixNorm = mix / 100;
    outLin = 10^(outGain / 20);

    @sample
    // Dry/wet mix
    dry_l = spl0;
    dry_r = spl1;
    wet_l = softClipSample(spl0, drive);
    wet_r = softClipSample(spl1, drive);
    spl0 = (dry_l * (1 - mixNorm) + wet_l * mixNorm) * outLin;
    spl1 = (dry_r * (1 - mixNorm) + wet_r * mixNorm) * outLin;
    """

    static let simpleDelay = """
    desc: Simple Delay with Feedback
    // メモリ (100k セル) を使って circular buffer で delay を作る。
    // 三項演算子 ? : による境界チェックの例。

    delayMs:200<1,500,1>Delay (ms)
    feedback:35<0,90,1>Feedback (%)
    mix:30<0,100,1>Wet Mix (%)

    @init
    // メモリレイアウト: [0..22049] = L 用、[22050..44099] = R 用
    delayBufL = 0;
    delayBufR = 22050;
    writeIdx = 0;
    bufSize = 22050;    // 500ms @ 44.1kHz

    @slider
    delaySamples = delayMs * srate / 1000;
    delaySamples = delaySamples < 1 ? 1 : delaySamples;
    delaySamples = delaySamples >= bufSize ? bufSize - 1 : delaySamples;
    fb = feedback / 100;
    mixNorm = mix / 100;

    @sample
    // 読み出し位置 (循環バッファ)
    readIdx = writeIdx - delaySamples;
    readIdx = readIdx < 0 ? readIdx + bufSize : readIdx;

    // Delay 出力
    dL = delayBufL[readIdx];
    dR = delayBufR[readIdx];

    // Feedback 込みで書き込み
    delayBufL[writeIdx] = spl0 + dL * fb;
    delayBufR[writeIdx] = spl1 + dR * fb;

    // Wet/dry mix
    spl0 = spl0 * (1 - mixNorm) + dL * mixNorm;
    spl1 = spl1 * (1 - mixNorm) + dR * mixNorm;

    // Write index 更新
    writeIdx = writeIdx + 1;
    writeIdx = writeIdx >= bufSize ? 0 : writeIdx;
    """

    static let tremoloLFO = """
    desc: Tremolo (LFO Amplitude Modulation)
    // sin() で作る LFO で振幅を変調する。@sample の位相累積の例。

    rate:5<0.1,20,0.1>Rate (Hz)
    depth:50<0,100,1>Depth (%)
    shape:0<0,1,1>Shape (0=Sine, 1=Square)

    @init
    phase = 0;

    @slider
    phaseInc = 2 * $pi * rate / srate;
    depthNorm = depth / 100;

    @sample
    // LFO 値 (-1 ~ +1)
    lfoRaw = sin(phase);
    lfoRaw = shape > 0 ? (lfoRaw > 0 ? 1 : -1) : lfoRaw;
    // 振幅係数を 0 ~ 1 にマップ
    amp = 1 - depthNorm * (0.5 - 0.5 * lfoRaw);

    spl0 = spl0 * amp;
    spl1 = spl1 * amp;

    // Phase 累積 (2π を超えたら折り返し)
    phase = phase + phaseInc;
    phase = phase >= 2 * $pi ? phase - 2 * $pi : phase;
    """

    static let threeBandSplitter = """
    desc: 3-Band Splitter
    // RootlessJamesDSP 由来のマルチバンドイコライザー。
    // IIRBandSplitter (JamesDSP built-in) を使って L/R 各チャンネルを 3 帯域に分割し、
    // それぞれの帯域にゲインを適用する。

    freqSplit1:400<20,20000,1>Low/Mid Split (Hz)
    freqSplit2:4000<20,20000,1>Mid/High Split (Hz)
    bandLow:0<-30,15,0.1>Low Gain (dB)
    bandMid:0<-30,15,0.1>Mid Gain (dB)
    bandHigh:0<-30,15,0.1>High Gain (dB)

    @init
    DB_2_LOG = 0.11512925464970228420089957273422;
    // L 用の splitter (メモリオフセット 0)
    iirBPS1 = 0;
    reqSize = IIRBandSplitterInit(iirBPS1, srate, freqSplit1, freqSplit2);
    // R 用の splitter (L の直後に配置)
    iirBPS2 = iirBPS1 + reqSize;
    reqSize = IIRBandSplitterInit(iirBPS2, srate, freqSplit1, freqSplit2);

    @slider
    // スライダー変更時に一度だけ、gain を linear に事前計算
    gLow = exp(bandLow * DB_2_LOG);
    gMid = exp(bandMid * DB_2_LOG);
    gHigh = exp(bandHigh * DB_2_LOG);

    @sample
    // L 用の 3-band split (参照引数 low1/mid1/high1 に結果が書き込まれる)
    IIRBandSplitterProcess(iirBPS1, spl0, low1, mid1, high1);
    // R 用の 3-band split
    IIRBandSplitterProcess(iirBPS2, spl1, low2, mid2, high2);
    // 各帯域にゲインを適用して合成
    spl0 = low1 * gLow + mid1 * gMid + high1 * gHigh;
    spl1 = low2 * gLow + mid2 * gMid + high2 * gHigh;
    """
}
