//
//  DSPPreset.swift
//  ViviMusic
//
//  DSP 設定を丸ごとプリセットとして保存/読み込みする。
//  Documents/DSPPresets/ に .json ファイルとして永続化。
//

import Foundation

struct DSPPreset: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date

    // 各機能のスナップショット
    var masterEnabled: Bool

    var bassEnabled: Bool
    var bassMaxGain: Double

    var eqEnabled: Bool
    var eqBandGainsDB: [Double]

    var peqEnabled: Bool
    var peqBands: [ParametricBand]

    var geqEnabled: Bool
    var geqNodes: [GraphicEQNode]

    var companderEnabled: Bool
    var companderThreshold: Double
    var companderRatio: Double
    var companderAttackMs: Double
    var companderReleaseMs: Double
    var companderMakeupDB: Double

    var reverbEnabled: Bool
    var reverbPreset: Int
    var reverbWetDry: Double

    var widenerEnabled: Bool
    var widenerAmount: Double

    var crossfeedEnabled: Bool
    var crossfeedPreset: Int

    var tubeEnabled: Bool
    var tubeDriveDB: Double

    var outputLimiterEnabled: Bool
    var outputLimiterThreshold: Double
    var outputLimiterReleaseMs: Double
    var outputPostGainDB: Double

    // MARK: 現在の DSPSettings から取得

    @MainActor
    static func capture(name: String, from s: DSPSettings) -> DSPPreset {
        DSPPreset(
            name: name, createdAt: Date(),
            masterEnabled: s.masterEnabled,
            bassEnabled: s.bassEnabled, bassMaxGain: s.bassMaxGain,
            eqEnabled: s.eqEnabled, eqBandGainsDB: s.eqBandGainsDB,
            peqEnabled: s.peqEnabled, peqBands: s.peqBands,
            geqEnabled: s.geqEnabled, geqNodes: s.geqNodes,
            companderEnabled: s.companderEnabled,
            companderThreshold: s.companderThreshold,
            companderRatio: s.companderRatio,
            companderAttackMs: s.companderAttackMs,
            companderReleaseMs: s.companderReleaseMs,
            companderMakeupDB: s.companderMakeupDB,
            reverbEnabled: s.reverbEnabled,
            reverbPreset: s.reverbPreset,
            reverbWetDry: s.reverbWetDry,
            widenerEnabled: s.widenerEnabled, widenerAmount: s.widenerAmount,
            crossfeedEnabled: s.crossfeedEnabled, crossfeedPreset: s.crossfeedPreset,
            tubeEnabled: s.tubeEnabled, tubeDriveDB: s.tubeDriveDB,
            outputLimiterEnabled: s.outputLimiterEnabled,
            outputLimiterThreshold: s.outputLimiterThreshold,
            outputLimiterReleaseMs: s.outputLimiterReleaseMs,
            outputPostGainDB: s.outputPostGainDB
        )
    }

    /// このプリセットを DSPSettings に適用
    @MainActor
    func apply(to s: DSPSettings) {
        s.masterEnabled = masterEnabled
        s.bassEnabled = bassEnabled; s.bassMaxGain = bassMaxGain
        s.eqEnabled = eqEnabled; s.eqBandGainsDB = eqBandGainsDB
        s.peqEnabled = peqEnabled; s.peqBands = peqBands
        s.geqEnabled = geqEnabled; s.geqNodes = geqNodes
        s.companderEnabled = companderEnabled
        s.companderThreshold = companderThreshold
        s.companderRatio = companderRatio
        s.companderAttackMs = companderAttackMs
        s.companderReleaseMs = companderReleaseMs
        s.companderMakeupDB = companderMakeupDB
        s.reverbEnabled = reverbEnabled
        s.reverbPreset = reverbPreset
        s.reverbWetDry = reverbWetDry
        s.widenerEnabled = widenerEnabled; s.widenerAmount = widenerAmount
        s.crossfeedEnabled = crossfeedEnabled; s.crossfeedPreset = crossfeedPreset
        s.tubeEnabled = tubeEnabled; s.tubeDriveDB = tubeDriveDB
        s.outputLimiterEnabled = outputLimiterEnabled
        s.outputLimiterThreshold = outputLimiterThreshold
        s.outputLimiterReleaseMs = outputLimiterReleaseMs
        s.outputPostGainDB = outputPostGainDB
    }
}

// MARK: - プリセットストア

@MainActor
final class DSPPresetStore: ObservableObject {
    static let shared = DSPPresetStore()

    @Published private(set) var presets: [DSPPreset] = []

    private var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("DSPPresets", isDirectory: true)
    }

    private init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            ?? []
        var loaded: [DSPPreset] = []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let preset = try? JSONDecoder().decode(DSPPreset.self, from: data) {
                loaded.append(preset)
            }
        }
        loaded.sort { $0.createdAt > $1.createdAt }
        self.presets = loaded
    }

    @discardableResult
    func save(_ preset: DSPPreset) -> Bool {
        let url = directory.appendingPathComponent(preset.id.uuidString + ".json")
        do {
            let data = try JSONEncoder().encode(preset)
            try data.write(to: url, options: .atomic)
            reload()
            EventLog.log(.dsp, message: "プリセットを保存: \(preset.name)")
            return true
        } catch {
            EventLog.logError(.dspError, error: error, context: "プリセットの保存 (\(preset.name))")
            return false
        }
    }

    func delete(_ preset: DSPPreset) {
        let url = directory.appendingPathComponent(preset.id.uuidString + ".json")
        try? FileManager.default.removeItem(at: url)
        reload()
    }
}
