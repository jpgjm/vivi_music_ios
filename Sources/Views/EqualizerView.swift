//
//  EqualizerView.swift
//  ViviMusic
//
//  10 バンドのグラフィックイコライザーの画面。
//  MusicPlayer の `Equalizer10BandView` を移植したもので、
//  縦スライダーと内蔵プリセットの構成は同じ。
//

import SwiftUI

struct EqualizerView: View {
    @ObservedObject private var settings = EqualizerSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("有効にする", isOn: $settings.isEnabled)
                } footer: {
                    Text("10 バンド固定周波数のグラフィックイコライザーです。"
                         + "再生中でもすぐに反映されます。")
                }

                Section {
                    sliders
                    actions
                }
                .disabled(!settings.isEnabled)

                Section {
                    HStack {
                        Text("プリアンプ")
                        Spacer()
                        Text(gainLabel(settings.preampDB) + " dB")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.preampDB, in: -12...6, step: 0.5)
                        .tint(Theme.accent)
                } header: {
                    Text("全体の音量")
                } footer: {
                    Text("バンドを大きく上げると音が割れることがあります。"
                         + "その場合はここを下げてください。")
                }
                .disabled(!settings.isEnabled)
            }
            .navigationTitle("イコライザー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    // MARK: - スライダー

    private var sliders: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(EqualizerSettings.frequencies.indices, id: \.self) { index in
                    VStack(spacing: 4) {
                        Text(gainLabel(settings.gains[index]))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)

                        VerticalGainSlider(
                            value: Binding(
                                get: { settings.gains[index] },
                                set: { newValue in
                                    var updated = settings.gains
                                    updated[index] = newValue
                                    settings.gains = updated
                                }
                            ),
                            range: EqualizerSettings.gainRange,
                            height: 170
                        )

                        Text(frequencyLabel(EqualizerSettings.frequencies[index]))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var actions: some View {
        HStack {
            Button("フラット") {
                settings.flatten()
            }

            Spacer()

            Menu {
                ForEach(EqualizerSettings.presets) { preset in
                    Button {
                        settings.apply(preset: preset)
                    } label: {
                        if settings.matches(preset) {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            } label: {
                Label("プリセット", systemImage: "slider.horizontal.3")
            }
        }
    }

    // MARK: - 表示の整形

    private func gainLabel(_ value: Double) -> String {
        if abs(value) < 0.1 { return "0" }
        return String(format: "%+.1f", value)
    }

    private func frequencyLabel(_ hz: Double) -> String {
        if hz >= 1000 { return String(format: "%.0fk", hz / 1000) }
        return String(format: "%.0f", hz)
    }
}

// MARK: - 縦スライダー

/// 中央 (0dB) を基準に上下へ動かす縦スライダー。
/// MusicPlayer の `VerticalSlider` を移植したもの。
struct VerticalGainSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let centerX = width / 2
            let normalized = (value - range.lowerBound)
                / (range.upperBound - range.lowerBound)
            let thumbY = height * (1 - normalized)

            ZStack {
                // 溝
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 4, height: height)
                    .position(x: centerX, y: height / 2)

                // 0dB の目印
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 12, height: 1)
                    .position(x: centerX, y: height / 2)

                // 0dB からの増減を示す部分
                Capsule()
                    .fill(Theme.accent.opacity(0.6))
                    .frame(width: 4, height: abs(height / 2 - thumbY))
                    .position(x: centerX, y: (height / 2 + thumbY) / 2)

                // つまみ
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 20, height: 20)
                    .position(x: centerX, y: max(0, min(height, thumbY)))
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let y = min(max(0, gesture.location.y), height)
                        let ratio = 1 - Double(y / height)
                        value = range.lowerBound
                            + ratio * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        // 0dB の近くでは吸い付かせる
                        if abs(value) < 0.5 { value = 0 }
                    }
            )
        }
        .frame(height: height)
    }
}
