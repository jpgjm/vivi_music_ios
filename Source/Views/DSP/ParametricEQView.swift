//
//  ParametricEQView.swift
//  ViviMusic
//
//  パラメトリックEQ。最大 15 バンド、各バンドで frequency/Q/gain/type を編集。
//  RootlessJamesDSP の Parametric EQ 相当。
//

import SwiftUI

struct ParametricEQView: View {
    @ObservedObject private var settings = DSPSettings.shared

    private let maxBands = 15

    var body: some View {
        Form {
            Section {
                Toggle("有効にする", isOn: $settings.peqEnabled)
            } footer: {
                Text("最大 15 バンドまで追加できます。各バンドで周波数・Q・ゲイン・フィルタ種別を変更可能です。")
            }

            Section {
                if settings.peqBands.isEmpty {
                    Text("バンドがありません")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                } else {
                    ForEach($settings.peqBands) { $band in
                        ParametricBandRow(band: $band)
                    }
                    .onDelete { indexSet in
                        settings.peqBands.remove(atOffsets: indexSet)
                    }
                }

                Button {
                    guard settings.peqBands.count < maxBands else { return }
                    let newBand = ParametricBand(
                        frequency: 1000, gainDB: 0, q: 1.0, type: .parametric
                    )
                    settings.peqBands.append(newBand)
                } label: {
                    Label("バンドを追加", systemImage: "plus.circle")
                }
                .disabled(settings.peqBands.count >= maxBands)
            } header: {
                Text("バンド (\(settings.peqBands.count) / \(maxBands))")
            }
            .disabled(!settings.peqEnabled)
        }
        .navigationTitle("パラメトリック EQ")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 1 バンド編集行

struct ParametricBandRow: View {
    @Binding var band: ParametricBand

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("種別", selection: $band.type) {
                    ForEach(ParametricBand.BandType.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
            }

            HStack {
                Text("Freq")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { logFrequency(band.frequency) },
                        set: { band.frequency = expFrequency($0) }
                    ),
                    in: 0...1
                )
                Text(freqLabel(band.frequency))
                    .font(.caption.monospacedDigit())
                    .frame(width: 68, alignment: .trailing)
            }

            HStack {
                Text("Gain")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Slider(value: $band.gainDB, in: -24...24)
                Text(String(format: "%+.1f dB", band.gainDB))
                    .font(.caption.monospacedDigit())
                    .frame(width: 68, alignment: .trailing)
            }

            HStack {
                Text("Q")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Slider(value: $band.q, in: 0.1...10)
                Text(String(format: "%.2f", band.q))
                    .font(.caption.monospacedDigit())
                    .frame(width: 68, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }

    // 20 ~ 20000 Hz を対数スケール (0 ~ 1) に変換
    private func logFrequency(_ hz: Double) -> Double {
        let minLog = log10(20.0), maxLog = log10(20000.0)
        return (log10(max(20, min(20000, hz))) - minLog) / (maxLog - minLog)
    }
    private func expFrequency(_ ratio: Double) -> Double {
        let minLog = log10(20.0), maxLog = log10(20000.0)
        return pow(10.0, minLog + ratio * (maxLog - minLog))
    }

    private func freqLabel(_ hz: Double) -> String {
        if hz >= 1000 { return String(format: "%.1fk", hz / 1000) }
        return String(format: "%.0f", hz)
    }
}
