//
//  DSPSettingsView.swift
//  ViviMusic
//
//  「⚙」→「イコライザー / 音響効果」から開くDSP設定のメイン画面。
//  RootlessJamesDSP と同じ機能一覧をカテゴリ別に並べる。
//
//  効果範囲はこのアプリ内で再生する曲 (ストリーム / ダウンロード済み)。
//  MusicPlayer の同名画面を移植したもの。
//

import SwiftUI

struct DSPSettingsView: View {
    @ObservedObject private var settings = DSPSettings.shared
    @ObservedObject private var presetStore = DSPPresetStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showPresets = false
    @State private var savePresetName = ""
    @State private var showSavePrompt = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: マスター
                Section {
                    Toggle(isOn: $settings.masterEnabled) {
                        HStack {
                            Image(systemName: "waveform")
                                .foregroundStyle(.tint)
                            Text("DSP を有効化")
                                .font(.body.weight(.medium))
                        }
                    }
                } footer: {
                    Text("すべての効果のマスタースイッチ。オフにすると全効果がバイパスされます。")
                }

                // MARK: EQ 系
                Section("イコライザー") {
                    NavigationLink {
                        Equalizer10BandView()
                    } label: {
                        DSPEffectRow(
                            iconSystemName: "slider.horizontal.3",
                            title: "グラフィック EQ (10band)",
                            enabled: settings.eqEnabled
                        )
                    }
                    NavigationLink {
                        ParametricEQView()
                    } label: {
                        DSPEffectRow(
                            iconSystemName: "waveform.path.ecg",
                            title: "パラメトリック EQ",
                            enabled: settings.peqEnabled,
                            detail: "\(settings.peqBands.count) バンド"
                        )
                    }
                    NavigationLink {
                        GraphicEQNodesView()
                    } label: {
                        DSPEffectRow(
                            iconSystemName: "chart.xyaxis.line",
                            title: "Graphic EQ (自由ノード)",
                            enabled: settings.geqEnabled,
                            detail: "\(settings.geqNodes.count) ノード"
                        )
                    }
                    NavigationLink {
                        BassBoostView()
                    } label: {
                        DSPEffectRow(
                            iconSystemName: "speaker.wave.3.fill",
                            title: "Bass Boost",
                            enabled: settings.bassEnabled,
                            detail: String(format: "+%.1f dB", settings.bassMaxGain)
                        )
                    }
                }

                // MARK: 空間 / 効果
                Section("音響効果") {
                    NavigationLink {
                        ReverbEffectView()
                    } label: {
                        DSPEffectRow(
                            iconSystemName: "cube.transparent",
                            title: "リバーブ",
                            enabled: settings.reverbEnabled,
                            detail: reverbPresetName(settings.reverbPreset)
                        )
                    }
                    NavigationLink {
                        StereoWidenerView()
                    } label: {
                        DSPEffectRow(
                            iconSystemName: "arrow.left.and.right.circle",
                            title: "ステレオ拡張",
                            enabled: settings.widenerEnabled,
                            detail: "\(Int(settings.widenerAmount))%"
                        )
                    }
                    NavigationLink {
                        CrossfeedView()
                    } label: {
                        DSPEffectRow(
                            iconSystemName: "headphones.circle",
                            title: "Crossfeed (ヘッドホン)",
                            enabled: settings.crossfeedEnabled,
                            detail: crossfeedPresetName(settings.crossfeedPreset)
                        )
                    }
                }

                // MARK: ダイナミクス / 歪み
                Section("ダイナミクス / 歪み") {
                    NavigationLink {
                        CompanderView()
                    } label: {
                        DSPEffectRow(
                            iconSystemName: "arrow.down.and.line.horizontal.and.arrow.up",
                            title: "Compander (コンプレッサー)",
                            enabled: settings.companderEnabled,
                            detail: String(format: "%.1f dB / %.1f:1", settings.companderThreshold, settings.companderRatio)
                        )
                    }
                    NavigationLink {
                        TubeView()
                    } label: {
                        DSPEffectRow(
                            iconSystemName: "flame",
                            title: "Tube (真空管歪み)",
                            enabled: settings.tubeEnabled,
                            detail: String(format: "%.1f dB", settings.tubeDriveDB)
                        )
                    }
                }

                // MARK: 出力制御
                Section("出力制御") {
                    NavigationLink {
                        OutputControlView()
                    } label: {
                        DSPEffectRow(
                            iconSystemName: "speaker.wave.2.circle",
                            title: "Limiter / Post-Gain",
                            enabled: settings.outputLimiterEnabled,
                            detail: String(format: "%.1f dB", settings.outputPostGainDB)
                        )
                    }
                }

                // MARK: プリセット
                Section("プリセット") {
                    Button {
                        showPresets = true
                    } label: {
                        Label("プリセットを開く", systemImage: "square.stack.3d.up")
                    }
                    Button {
                        savePresetName = "プリセット \(presetStore.presets.count + 1)"
                        showSavePrompt = true
                    } label: {
                        Label("現在の設定を保存…", systemImage: "square.and.arrow.down")
                    }
                }

                // MARK: 高度な音声処理 (Phase 2)
                Section {
                    NavigationLink {
                        AutoEQView()
                    } label: {
                        DSPEffectRow(
                            iconSystemName: "headphones",
                            title: "AutoEQ",
                            enabled: false,
                            detail: "プロファイルから PEQ 変換"
                        )
                    }
                    NavigationLink {
                        DDCView()
                    } label: {
                        DSPEffectRow(
                            iconSystemName: "waveform.badge.magnifyingglass",
                            title: "DDC",
                            enabled: settings.ddcEnabled,
                            detail: settings.ddcVDCName ?? "VDC ファイル未設定"
                        )
                    }
                    NavigationLink {
                        ConvolverView()
                    } label: {
                        DSPEffectRow(
                            iconSystemName: "waveform.and.mic",
                            title: "Convolver",
                            enabled: settings.convolverEnabled,
                            detail: settings.convolverIRName ?? "IR ファイル未設定"
                        )
                    }
                    NavigationLink {
                        LiveprogView()
                    } label: {
                        DSPEffectRow(
                            iconSystemName: "chevron.left.slash.chevron.right",
                            title: "Liveprog",
                            enabled: settings.liveprogEnabled,
                            detail: settings.liveprogScriptName ?? "スクリプト未設定"
                        )
                    }
                } header: {
                    Text("高度な音声処理")
                } footer: {
                    Text("AutoEQ はプロファイルをパラメトリック EQ に変換します。DDC / Convolver / Liveprog は再生中の音にリアルタイムで適用されます。")
                }

                // MARK: リセット
                Section {
                    Button(role: .destructive) {
                        settings.resetAllToDefaults()
                    } label: {
                        Label("すべてを初期設定に戻す", systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("効果範囲: このアプリ内で再生する曲のみ")
                }
            }
            .navigationTitle("イコライザー / 音響効果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { dismiss() }
                }
            }
            .sheet(isPresented: $showPresets) {
                DSPPresetListView()
            }
            .alert("プリセット名", isPresented: $showSavePrompt) {
                TextField("名前", text: $savePresetName)
                Button("保存") {
                    let name = savePresetName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    let preset = DSPPreset.capture(name: name, from: settings)
                    presetStore.save(preset)
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("現在の DSP 設定をプリセットとして保存します")
            }
        }
    }

    private func reverbPresetName(_ raw: Int) -> String {
        switch raw {
        case 0: return "SmallRoom"
        case 1: return "MediumRoom"
        case 2: return "LargeRoom"
        case 3: return "MediumHall"
        case 4: return "LargeHall"
        case 5: return "Plate"
        case 6: return "MediumChamber"
        case 7: return "LargeChamber"
        case 8: return "Cathedral"
        case 9: return "LargeRoom2"
        case 10: return "MediumHall2"
        case 11: return "MediumHall3"
        case 12: return "LargeHall2"
        default: return "Custom"
        }
    }

    private func crossfeedPresetName(_ i: Int) -> String {
        ["Default", "CMoy", "JMeier", "Strong", "Very Strong"][min(4, max(0, i))]
    }
}

// MARK: - 1行

struct DSPEffectRow: View {
    let iconSystemName: String
    let title: String
    let enabled: Bool
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconSystemName)
                .foregroundStyle(enabled ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail = detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if enabled {
                Text("ON")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.2))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - プリセット一覧

struct DSPPresetListView: View {
    @ObservedObject private var presetStore = DSPPresetStore.shared
    @ObservedObject private var settings = DSPSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if presetStore.presets.isEmpty {
                    ContentUnavailableView2(
                        title: "プリセットがありません",
                        systemImage: "square.stack.3d.up",
                        description: "DSP 設定画面下部の「現在の設定を保存…」から作成できます"
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(presetStore.presets) { preset in
                        Button {
                            preset.apply(to: settings)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .foregroundStyle(Color.primary)
                                Text(preset.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                presetStore.delete(preset)
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("プリセット")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}

struct ContentUnavailableView2: View {
    let title: String; let systemImage: String; let description: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(description).font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - 近日対応画面

struct ComingSoonView: View {
    let title: String
    let description: String

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 56))
                        .foregroundStyle(.tertiary)
                    Text("近日対応")
                        .font(.title2.weight(.semibold))
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
