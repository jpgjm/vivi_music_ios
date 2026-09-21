//
//  Equalizer10BandView.swift
//  ViviMusic
//
//  10 バンド固定周波数 (31.25 / 62.5 / 125 / 250 / 500 / 1000 / 2000 / 4000 / 8000 / 16000 Hz)
//  の縦スライダー式グラフィックイコライザー。
//  RootlessJamesDSP の Equalizer と互換のUI。
//

import SwiftUI

struct Equalizer10BandView: View {
    @ObservedObject private var settings = DSPSettings.shared

    /// -12dB ~ +12dB
    private let range: ClosedRange<Double> = -12...12

    var body: some View {
        Form {
            Section {
                Toggle("有効にする", isOn: $settings.eqEnabled)
            } footer: {
                Text("10 バンド固定周波数のグラフィックイコライザー。RootlessJamesDSP の Equalizer と互換。")
            }

            Section {
                VStack(spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(0 ..< 10, id: \.self) { i in
                            VStack(spacing: 4) {
                                Text(gainLabel(settings.eqBandGainsDB[i]))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                VerticalSlider(
                                    value: Binding(
                                        get: { settings.eqBandGainsDB[i] },
                                        set: { settings.eqBandGainsDB[i] = $0 }
                                    ),
                                    range: range,
                                    height: 180
                                )
                                Text(frequencyLabel(DSPSettings.eq10BandFrequencies[i]))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 8)

                    HStack {
                        Button("フラット") {
                            for i in 0 ..< 10 {
                                settings.eqBandGainsDB[i] = 0
                            }
                        }
                        Spacer()
                        Menu("プリセット") {
                            ForEach(builtInPresets, id: \.name) { p in
                                Button(p.name) {
                                    settings.eqBandGainsDB = p.gains
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .disabled(!settings.eqEnabled)
        }
        .navigationTitle("グラフィック EQ")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func gainLabel(_ v: Double) -> String {
        if abs(v) < 0.1 { return "0" }
        return String(format: "%+.1f", v)
    }

    private func frequencyLabel(_ hz: Double) -> String {
        if hz >= 1000 { return String(format: "%.0fk", hz / 1000) }
        return String(format: "%.0f", hz)
    }

    // MARK: プリセット (10 バンドゲイン)

    struct Preset { let name: String; let gains: [Double] }

    private var builtInPresets: [Preset] { [
        Preset(name: "フラット",       gains: [0,0,0,0,0,0,0,0,0,0]),
        Preset(name: "ロック",         gains: [4,3,2,1,-1,-1,0,2,3,4]),
        Preset(name: "ポップ",         gains: [-1,0,2,3,3,2,0,-1,-1,-2]),
        Preset(name: "ジャズ",         gains: [3,2,1,2,-1,-1,0,1,2,3]),
        Preset(name: "クラシック",      gains: [4,3,2,0,-1,-1,-1,1,2,3]),
        Preset(name: "ダンス",         gains: [6,4,1,-2,-1,1,4,5,4,3]),
        Preset(name: "ボーカル",       gains: [-2,-1,0,2,4,4,3,2,1,0]),
        Preset(name: "低音強調",       gains: [7,5,3,1,0,0,0,0,0,0]),
        Preset(name: "高音強調",       gains: [0,0,0,0,0,1,3,5,6,7]),
        Preset(name: "ラウドネス",     gains: [5,3,0,0,-2,-2,0,3,5,7]),
    ] }
}

// MARK: - 縦スライダー

struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let midX = w / 2
            let trackH = height
            let normalized = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let thumbY = trackH * (1 - normalized)

            ZStack {
                // トラック
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 4, height: trackH)
                    .position(x: midX, y: trackH / 2)

                // 中央線 (0dB)
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 12, height: 1)
                    .position(x: midX, y: trackH / 2)

                // アクティブ部分
                Capsule()
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 4, height: abs(trackH / 2 - thumbY))
                    .position(x: midX, y: (trackH / 2 + thumbY) / 2)

                // つまみ
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 22, height: 22)
                    .position(x: midX, y: max(0, min(trackH, thumbY)))
            }
            .frame(width: w, height: trackH)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let y = min(max(0, g.location.y), trackH)
                        let ratio = 1 - Double(y / trackH)
                        let newValue = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
                        value = newValue
                    }
                    .onEnded { _ in
                        // スナップ: 0dB近傍で吸着
                        if abs(value) < 0.5 { value = 0 }
                    }
            )
        }
        .frame(height: height)
    }
}
