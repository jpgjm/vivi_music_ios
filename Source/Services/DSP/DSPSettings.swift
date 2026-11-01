//
//  DSPSettings.swift
//  ViviMusic
//
//  RootlessJamesDSP 相当の全 DSP パラメータを @Published で公開し、
//  UserDefaults に永続化するシングルトン。
//
//  効果範囲: このアプリ内で再生する曲のみ。
//
//  DSPEngine がこの値を購読して AVAudioEngine の effect chain に反映する。
//  (ViviMusic では AVPlayer の音声を DSPTap で受け取り、その chain に通す)
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class DSPSettings: ObservableObject {
    static let shared = DSPSettings()

    // MARK: マスター ON/OFF
    @Published var masterEnabled: Bool { didSet { save(.masterEnabled, masterEnabled); pushChange() } }

    // MARK: Bass Boost
    @Published var bassEnabled: Bool { didSet { save(.bassEnabled, bassEnabled); pushChange() } }
    /// dB, 3.0 - 15.0
    @Published var bassMaxGain: Double { didSet { save(.bassMaxGain, bassMaxGain); pushChange() } }

    // MARK: Equalizer (10-band graphic, RJDSP 互換周波数)
    @Published var eqEnabled: Bool { didSet { save(.eqEnabled, eqEnabled); pushChange() } }
    /// 10 バンドのゲイン (dB, -12 ~ +12)
    /// 周波数: 31.25 / 62.5 / 125 / 250 / 500 / 1000 / 2000 / 4000 / 8000 / 16000 Hz
    @Published var eqBandGainsDB: [Double] { didSet { save(.eqBandGainsDB, eqBandGainsDB); pushChange() } }

    // MARK: Parametric EQ (最大 15 バンド、任意 freq/Q/gain)
    @Published var peqEnabled: Bool { didSet { save(.peqEnabled, peqEnabled); pushChange() } }
    /// バンド定義配列
    @Published var peqBands: [ParametricBand] { didSet { savePEQBands(); pushChange() } }

    // MARK: Graphic EQ (ノード編集式、周波数点を任意配置)
    @Published var geqEnabled: Bool { didSet { save(.geqEnabled, geqEnabled); pushChange() } }
    /// (Hz, dB) の配列
    @Published var geqNodes: [GraphicEQNode] { didSet { saveGEQNodes(); pushChange() } }

    // MARK: Compander (単一バンドコンプレッサーで代用)
    @Published var companderEnabled: Bool { didSet { save(.companderEnabled, companderEnabled); pushChange() } }
    /// dB, -60 ~ 0
    @Published var companderThreshold: Double { didSet { save(.companderThreshold, companderThreshold); pushChange() } }
    /// ratio, 1 ~ 20
    @Published var companderRatio: Double { didSet { save(.companderRatio, companderRatio); pushChange() } }
    /// ms, 1 ~ 500
    @Published var companderAttackMs: Double { didSet { save(.companderAttackMs, companderAttackMs); pushChange() } }
    /// ms, 10 ~ 2000
    @Published var companderReleaseMs: Double { didSet { save(.companderReleaseMs, companderReleaseMs); pushChange() } }
    /// makeup dB, -20 ~ +20
    @Published var companderMakeupDB: Double { didSet { save(.companderMakeupDB, companderMakeupDB); pushChange() } }

    // MARK: Reverb
    @Published var reverbEnabled: Bool { didSet { save(.reverbEnabled, reverbEnabled); pushChange() } }
    /// AVAudioUnitReverbPreset の rawValue
    @Published var reverbPreset: Int { didSet { save(.reverbPreset, reverbPreset); pushChange() } }
    /// 0 ~ 100 (wet/dry mix %)
    @Published var reverbWetDry: Double { didSet { save(.reverbWetDry, reverbWetDry); pushChange() } }

    // MARK: Stereo Widener
    @Published var widenerEnabled: Bool { didSet { save(.widenerEnabled, widenerEnabled); pushChange() } }
    /// 0 ~ 200 (% で、100 が原音、200 で最大拡張、0 で mono)
    @Published var widenerAmount: Double { didSet { save(.widenerAmount, widenerAmount); pushChange() } }

    // MARK: Crossfeed (簡易 BS2B 近似)
    @Published var crossfeedEnabled: Bool { didSet { save(.crossfeedEnabled, crossfeedEnabled); pushChange() } }
    /// 0 ~ 4 (BS2Bのプリセットに準拠: 0=default 1=cmoy 2=jmeier 3=strong 4=very strong)
    @Published var crossfeedPreset: Int { didSet { save(.crossfeedPreset, crossfeedPreset); pushChange() } }

    // MARK: Tube (真空管歪み)
    @Published var tubeEnabled: Bool { didSet { save(.tubeEnabled, tubeEnabled); pushChange() } }
    /// dB, -3 ~ +12
    @Published var tubeDriveDB: Double { didSet { save(.tubeDriveDB, tubeDriveDB); pushChange() } }

    // MARK: Output Control
    @Published var outputLimiterEnabled: Bool { didSet { save(.outputLimiterEnabled, outputLimiterEnabled); pushChange() } }
    /// dB, -60 ~ -0.1
    @Published var outputLimiterThreshold: Double { didSet { save(.outputLimiterThreshold, outputLimiterThreshold); pushChange() } }
    /// ms, 1.5 ~ 500
    @Published var outputLimiterReleaseMs: Double { didSet { save(.outputLimiterReleaseMs, outputLimiterReleaseMs); pushChange() } }
    /// dB, -15 ~ +15
    @Published var outputPostGainDB: Double { didSet { save(.outputPostGainDB, outputPostGainDB); pushChange() } }

    // MARK: Convolver (Phase 2: UI + IR ファイル取り込みのみ。実 DSP は Phase 2b)
    @Published var convolverEnabled: Bool { didSet { save(.convolverEnabled, convolverEnabled); pushChange() } }
    /// 選択された IR ファイルの Documents 相対パス (nil なら未設定)
    @Published var convolverIRPath: String? { didSet { saveOptional(.convolverIRPath, convolverIRPath); pushChange() } }
    /// IR ファイルの表示名 (UI 表示用、拡張子込み)
    @Published var convolverIRName: String? { didSet { saveOptional(.convolverIRName, convolverIRName); pushChange() } }
    /// 畳み込みモード: 0=Full, 1=True Stereo, 2=OMSCE-only (RJDSP 互換値、実 DSP は Phase 2b)
    @Published var convolverMode: Int { didSet { save(.convolverMode, convolverMode); pushChange() } }

    // MARK: DDC (Phase 2: VDC ファイル取り込み + PEQ 近似変換)
    @Published var ddcEnabled: Bool { didSet { save(.ddcEnabled, ddcEnabled); pushChange() } }
    /// 選択された VDC ファイルの Documents 相対パス
    @Published var ddcVDCPath: String? { didSet { saveOptional(.ddcVDCPath, ddcVDCPath); pushChange() } }
    /// 表示名
    @Published var ddcVDCName: String? { didSet { saveOptional(.ddcVDCName, ddcVDCName); pushChange() } }

    // MARK: Liveprog (Phase 2: UI + EEL2 スクリプト取り込みのみ。実行環境は Phase 3)
    @Published var liveprogEnabled: Bool { didSet { save(.liveprogEnabled, liveprogEnabled); pushChange() } }
    /// 選択された EEL2 スクリプトファイルの Documents 相対パス
    @Published var liveprogScriptPath: String? { didSet { saveOptional(.liveprogScriptPath, liveprogScriptPath); pushChange() } }
    /// 表示名
    @Published var liveprogScriptName: String? { didSet { saveOptional(.liveprogScriptName, liveprogScriptName); pushChange() } }
    /// スライダー値 (variableName → value)。スクリプト毎に異なる。
    /// pushChange してエンジンに通知するが、applySettings は軽量なので問題なし。
    @Published var liveprogSliderValues: [String: Double] {
        didSet { saveSliderValues(); pushChange() }
    }

    // MARK: - 変更通知 (DSPEngine 用)

    /// パラメータが変わったら 1 増える。DSPEngine は didChange を監視して chain を更新。
    @Published var changeToken: Int = 0
    private func pushChange() { changeToken &+= 1 }

    // MARK: - 保存キー

    private enum Key: String {
        case masterEnabled
        case bassEnabled, bassMaxGain
        case eqEnabled, eqBandGainsDB
        case peqEnabled, peqBandsData
        case geqEnabled, geqNodesData
        case companderEnabled, companderThreshold, companderRatio
        case companderAttackMs, companderReleaseMs, companderMakeupDB
        case reverbEnabled, reverbPreset, reverbWetDry
        case widenerEnabled, widenerAmount
        case crossfeedEnabled, crossfeedPreset
        case tubeEnabled, tubeDriveDB
        case outputLimiterEnabled, outputLimiterThreshold, outputLimiterReleaseMs, outputPostGainDB
        case convolverEnabled, convolverIRPath, convolverIRName, convolverMode
        case ddcEnabled, ddcVDCPath, ddcVDCName
        case liveprogEnabled, liveprogScriptPath, liveprogScriptName, liveprogSliderValuesData
    }

    private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard

        masterEnabled = d.object(forKey: Key.masterEnabled.rawValue) as? Bool ?? true

        bassEnabled = d.object(forKey: Key.bassEnabled.rawValue) as? Bool ?? false
        bassMaxGain = d.object(forKey: Key.bassMaxGain.rawValue) as? Double ?? 5.0

        eqEnabled = d.object(forKey: Key.eqEnabled.rawValue) as? Bool ?? false
        eqBandGainsDB = (d.object(forKey: Key.eqBandGainsDB.rawValue) as? [Double])
                        ?? Array(repeating: 0.0, count: 10)

        peqEnabled = d.object(forKey: Key.peqEnabled.rawValue) as? Bool ?? false
        peqBands = Self.loadPEQ(from: d) ?? []

        geqEnabled = d.object(forKey: Key.geqEnabled.rawValue) as? Bool ?? false
        geqNodes = Self.loadGEQ(from: d) ?? []

        companderEnabled = d.object(forKey: Key.companderEnabled.rawValue) as? Bool ?? false
        companderThreshold = d.object(forKey: Key.companderThreshold.rawValue) as? Double ?? -20.0
        companderRatio = d.object(forKey: Key.companderRatio.rawValue) as? Double ?? 2.0
        companderAttackMs = d.object(forKey: Key.companderAttackMs.rawValue) as? Double ?? 15.0
        companderReleaseMs = d.object(forKey: Key.companderReleaseMs.rawValue) as? Double ?? 200.0
        companderMakeupDB = d.object(forKey: Key.companderMakeupDB.rawValue) as? Double ?? 0.0

        reverbEnabled = d.object(forKey: Key.reverbEnabled.rawValue) as? Bool ?? false
        reverbPreset = d.object(forKey: Key.reverbPreset.rawValue) as? Int ?? 4  // MediumRoom
        reverbWetDry = d.object(forKey: Key.reverbWetDry.rawValue) as? Double ?? 30.0

        widenerEnabled = d.object(forKey: Key.widenerEnabled.rawValue) as? Bool ?? false
        widenerAmount = d.object(forKey: Key.widenerAmount.rawValue) as? Double ?? 100.0

        crossfeedEnabled = d.object(forKey: Key.crossfeedEnabled.rawValue) as? Bool ?? false
        crossfeedPreset = d.object(forKey: Key.crossfeedPreset.rawValue) as? Int ?? 0

        tubeEnabled = d.object(forKey: Key.tubeEnabled.rawValue) as? Bool ?? false
        tubeDriveDB = d.object(forKey: Key.tubeDriveDB.rawValue) as? Double ?? 2.0

        outputLimiterEnabled = d.object(forKey: Key.outputLimiterEnabled.rawValue) as? Bool ?? true
        outputLimiterThreshold = d.object(forKey: Key.outputLimiterThreshold.rawValue) as? Double ?? -0.1
        outputLimiterReleaseMs = d.object(forKey: Key.outputLimiterReleaseMs.rawValue) as? Double ?? 60.0
        outputPostGainDB = d.object(forKey: Key.outputPostGainDB.rawValue) as? Double ?? 0.0

        convolverEnabled = d.object(forKey: Key.convolverEnabled.rawValue) as? Bool ?? false
        convolverIRPath = d.object(forKey: Key.convolverIRPath.rawValue) as? String
        convolverIRName = d.object(forKey: Key.convolverIRName.rawValue) as? String
        convolverMode = d.object(forKey: Key.convolverMode.rawValue) as? Int ?? 0

        ddcEnabled = d.object(forKey: Key.ddcEnabled.rawValue) as? Bool ?? false
        ddcVDCPath = d.object(forKey: Key.ddcVDCPath.rawValue) as? String
        ddcVDCName = d.object(forKey: Key.ddcVDCName.rawValue) as? String

        liveprogEnabled = d.object(forKey: Key.liveprogEnabled.rawValue) as? Bool ?? false
        liveprogScriptPath = d.object(forKey: Key.liveprogScriptPath.rawValue) as? String
        liveprogScriptName = d.object(forKey: Key.liveprogScriptName.rawValue) as? String
        liveprogSliderValues = Self.loadSliderValues(from: d) ?? [:]
    }

    // MARK: - save

    private func save<T>(_ key: Key, _ value: T) {
        defaults.set(value, forKey: key.rawValue)
    }

    /// Optional 値専用の保存。nil の場合は removeObject する。
    /// generic save<T> に Optional を渡すと property list に null を入れようとしてクラッシュするため必須。
    private func saveOptional(_ key: Key, _ value: String?) {
        if let value = value {
            defaults.set(value, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
    }

    private func savePEQBands() {
        if let data = try? JSONEncoder().encode(peqBands) {
            defaults.set(data, forKey: Key.peqBandsData.rawValue)
        }
    }
    private func saveGEQNodes() {
        if let data = try? JSONEncoder().encode(geqNodes) {
            defaults.set(data, forKey: Key.geqNodesData.rawValue)
        }
    }

    private func saveSliderValues() {
        if let data = try? JSONEncoder().encode(liveprogSliderValues) {
            defaults.set(data, forKey: Key.liveprogSliderValuesData.rawValue)
        }
    }

    private static func loadSliderValues(from d: UserDefaults) -> [String: Double]? {
        guard let data = d.data(forKey: Key.liveprogSliderValuesData.rawValue) else { return nil }
        return try? JSONDecoder().decode([String: Double].self, from: data)
    }

    private static func loadPEQ(from d: UserDefaults) -> [ParametricBand]? {
        guard let data = d.data(forKey: Key.peqBandsData.rawValue) else { return nil }
        return try? JSONDecoder().decode([ParametricBand].self, from: data)
    }
    private static func loadGEQ(from d: UserDefaults) -> [GraphicEQNode]? {
        guard let data = d.data(forKey: Key.geqNodesData.rawValue) else { return nil }
        return try? JSONDecoder().decode([GraphicEQNode].self, from: data)
    }

    // MARK: - デフォルトプリセットの再構築

    /// 10バンドEQのデフォルト周波数 (Hz)
    static let eq10BandFrequencies: [Double] = [
        31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]

    /// 全パラメータをデフォルトに戻す
    func resetAllToDefaults() {
        masterEnabled = true
        bassEnabled = false; bassMaxGain = 5.0
        eqEnabled = false; eqBandGainsDB = Array(repeating: 0.0, count: 10)
        peqEnabled = false; peqBands = []
        geqEnabled = false; geqNodes = []
        companderEnabled = false
        companderThreshold = -20; companderRatio = 2
        companderAttackMs = 15; companderReleaseMs = 200; companderMakeupDB = 0
        reverbEnabled = false; reverbPreset = 4; reverbWetDry = 30
        widenerEnabled = false; widenerAmount = 100
        crossfeedEnabled = false; crossfeedPreset = 0
        tubeEnabled = false; tubeDriveDB = 2
        outputLimiterEnabled = true
        outputLimiterThreshold = -0.1; outputLimiterReleaseMs = 60
        outputPostGainDB = 0
        convolverEnabled = false; convolverIRPath = nil; convolverIRName = nil; convolverMode = 0
        ddcEnabled = false; ddcVDCPath = nil; ddcVDCName = nil
        liveprogEnabled = false; liveprogScriptPath = nil; liveprogScriptName = nil
        liveprogSliderValues = [:]
    }
}

// MARK: - 補助型

/// パラメトリック EQ の 1 バンド定義
struct ParametricBand: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var frequency: Double  // Hz, 20 ~ 20000
    var gainDB: Double     // dB, -24 ~ +24
    var q: Double          // 0.1 ~ 10
    var type: BandType = .parametric

    enum BandType: String, Codable, CaseIterable, Identifiable {
        case parametric, lowShelf, highShelf, lowPass, highPass, bandPass
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .parametric: return "Parametric"
            case .lowShelf:   return "Low Shelf"
            case .highShelf:  return "High Shelf"
            case .lowPass:    return "Low Pass"
            case .highPass:   return "High Pass"
            case .bandPass:   return "Band Pass"
            }
        }
    }
}

/// Graphic EQ の 1 ノード (周波数点)
struct GraphicEQNode: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var frequency: Double  // Hz
    var gainDB: Double     // dB
}
