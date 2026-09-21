//
//  DSPEffectDetailViews.swift
//  ViviMusic
//
//  Bass Boost / Reverb / Compander / Stereo Widener / Crossfeed / Tube / Output Control
//  の各詳細画面を 1 ファイルにまとめる。
//

import SwiftUI
import AVFoundation

// MARK: - Bass Boost

struct BassBoostView: View {
    @ObservedObject private var settings = DSPSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("有効にする", isOn: $settings.bassEnabled)
            } footer: {
                Text("120Hz を中心とした Low Shelf ゲインで低音を強調します。RootlessJamesDSP の Bass Boost 相当。")
            }
            Section {
                LabeledSlider(
                    label: "最大ゲイン",
                    value: $settings.bassMaxGain,
                    range: 3...15,
                    step: 0.5,
                    unit: "dB"
                )
            }
            .disabled(!settings.bassEnabled)
        }
        .navigationTitle("Bass Boost")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Reverb

struct ReverbEffectView: View {
    @ObservedObject private var settings = DSPSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("有効にする", isOn: $settings.reverbEnabled)
            } footer: {
                Text("Apple 提供の Reverb2 AudioUnit を使用。プリセットで空間の広さ・種類を切り替えられます。")
            }
            Section("プリセット") {
                Picker("空間の種類", selection: $settings.reverbPreset) {
                    ForEach(reverbPresets, id: \.rawValue) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
            }
            Section("Wet / Dry ミックス") {
                LabeledSlider(
                    label: "ウェット",
                    value: $settings.reverbWetDry,
                    range: 0...100,
                    step: 1,
                    unit: "%"
                )
            }
            .disabled(!settings.reverbEnabled)
        }
        .navigationTitle("リバーブ")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var reverbPresets: [(rawValue: Int, displayName: String)] {
        [
            (0, "スモールルーム"),
            (1, "ミディアムルーム"),
            (2, "ラージルーム"),
            (3, "ミディアムホール"),
            (4, "ラージホール"),
            (5, "プレート"),
            (6, "ミディアムチェンバー"),
            (7, "ラージチェンバー"),
            (8, "カテドラル"),
            (9, "ラージルーム 2"),
            (10, "ミディアムホール 2"),
            (11, "ミディアムホール 3"),
            (12, "ラージホール 2"),
        ]
    }
}

// MARK: - Compander (Compressor)

struct CompanderView: View {
    @ObservedObject private var settings = DSPSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("有効にする", isOn: $settings.companderEnabled)
            } footer: {
                Text("Apple の DynamicsProcessor を使ったコンプレッサー。RootlessJamesDSP の多バンド Compander は iOS では単一バンドで代用します。")
            }
            Section("パラメータ") {
                LabeledSlider(label: "スレッショルド", value: $settings.companderThreshold, range: -60...0, step: 0.5, unit: "dB")
                LabeledSlider(label: "レシオ", value: $settings.companderRatio, range: 1...20, step: 0.1, unit: ":1")
                LabeledSlider(label: "アタック", value: $settings.companderAttackMs, range: 1...200, step: 1, unit: "ms")
                LabeledSlider(label: "リリース", value: $settings.companderReleaseMs, range: 10...2000, step: 10, unit: "ms")
                LabeledSlider(label: "メイクアップゲイン", value: $settings.companderMakeupDB, range: -20...20, step: 0.5, unit: "dB")
            }
            .disabled(!settings.companderEnabled)
        }
        .navigationTitle("Compander")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Stereo Widener

struct StereoWidenerView: View {
    @ObservedObject private var settings = DSPSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("有効にする", isOn: $settings.widenerEnabled)
            } footer: {
                Text("ステレオ感を拡張または縮小します。100% が原音、0% でモノラル寄りに、200% で最大拡張。")
            }
            Section {
                LabeledSlider(
                    label: "拡張量",
                    value: $settings.widenerAmount,
                    range: 0...200,
                    step: 1,
                    unit: "%"
                )
            } footer: {
                Text("iOS の AudioUnit で直接の Mid-Side 制御ができないため、高域 shelf での近似実装になります。RootlessJamesDSP と挙動は完全一致しません。")
            }
            .disabled(!settings.widenerEnabled)
        }
        .navigationTitle("ステレオ拡張")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Crossfeed (BS2B)

struct CrossfeedView: View {
    @ObservedObject private var settings = DSPSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("有効にする", isOn: $settings.crossfeedEnabled)
            } footer: {
                Text("ヘッドホン聴取時にステレオ音像を耳内空間に整えます。BS2B のプリセットに対応。")
            }
            Section {
                Picker("強度", selection: $settings.crossfeedPreset) {
                    Text("Default").tag(0)
                    Text("CMoy").tag(1)
                    Text("JMeier").tag(2)
                    Text("Strong").tag(3)
                    Text("Very Strong").tag(4)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("プリセット")
            } footer: {
                Text("iOS では 8-band BS2B の完全な実装ができないため、高域シェルフ量による近似実装になります。RootlessJamesDSP と挙動は完全一致しません。Phase 2 で改善予定。")
            }
            .disabled(!settings.crossfeedEnabled)
        }
        .navigationTitle("Crossfeed")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Tube

struct TubeView: View {
    @ObservedObject private var settings = DSPSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("有効にする", isOn: $settings.tubeEnabled)
            } footer: {
                Text("Apple 提供の Distortion AudioUnit で真空管風の温かな倍音を付加します。")
            }
            Section {
                LabeledSlider(
                    label: "ドライブ",
                    value: $settings.tubeDriveDB,
                    range: -3...12,
                    step: 0.5,
                    unit: "dB"
                )
            }
            .disabled(!settings.tubeEnabled)
        }
        .navigationTitle("Tube")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Output Control

struct OutputControlView: View {
    @ObservedObject private var settings = DSPSettings.shared

    var body: some View {
        Form {
            Section("Peak Limiter") {
                Toggle("Limiter を有効化", isOn: $settings.outputLimiterEnabled)
                LabeledSlider(
                    label: "スレッショルド",
                    value: $settings.outputLimiterThreshold,
                    range: -60 ... -0.1,
                    step: 0.1,
                    unit: "dB"
                )
                .disabled(!settings.outputLimiterEnabled)
                LabeledSlider(
                    label: "リリース",
                    value: $settings.outputLimiterReleaseMs,
                    range: 1.5...500,
                    step: 0.5,
                    unit: "ms"
                )
                .disabled(!settings.outputLimiterEnabled)
            }
            Section {
                LabeledSlider(
                    label: "出力ゲイン",
                    value: $settings.outputPostGainDB,
                    range: -15...15,
                    step: 0.1,
                    unit: "dB"
                )
            } header: {
                Text("Post-Gain")
            } footer: {
                Text("すべての効果を適用した後の最終出力ゲイン。ゲインを上げすぎるとクリップする可能性があります。Limiter で保護されます。")
            }
        }
        .navigationTitle("出力制御")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 汎用ラベル付きスライダー

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.1
    var unit: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.1f %@", value, unit).trimmingCharacters(in: .whitespaces))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
        .padding(.vertical, 2)
    }
}
