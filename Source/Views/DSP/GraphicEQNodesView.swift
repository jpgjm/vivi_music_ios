//
//  GraphicEQNodesView.swift
//  ViviMusic
//
//  自由に (frequency, dB) の点を配置してカーブを描く自由ノード編集式Graphic EQ。
//  RootlessJamesDSP の Graphic EQ 相当。最大 32 ノード。
//

import SwiftUI

struct GraphicEQNodesView: View {
    @ObservedObject private var settings = DSPSettings.shared

    private let maxNodes = 32

    var body: some View {
        Form {
            Section {
                Toggle("有効にする", isOn: $settings.geqEnabled)
            } footer: {
                Text("周波数点を任意に配置してカーブを作成できます。RootlessJamesDSP の Graphic EQ 相当。最大 32 点まで。")
            }

            Section {
                if settings.geqNodes.isEmpty {
                    Text("ノードがありません")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                } else {
                    ForEach($settings.geqNodes) { $node in
                        GraphicEQNodeRow(node: $node)
                    }
                    .onDelete { indexSet in
                        settings.geqNodes.remove(atOffsets: indexSet)
                    }
                }

                Button {
                    guard settings.geqNodes.count < maxNodes else { return }
                    // 追加する位置: 空なら 1000 Hz、そうでなければ最後のノードの次の8va
                    let newFreq: Double = {
                        if let last = settings.geqNodes.last {
                            return min(20000, last.frequency * 2)
                        }
                        return 1000
                    }()
                    settings.geqNodes.append(GraphicEQNode(frequency: newFreq, gainDB: 0))
                    settings.geqNodes.sort { $0.frequency < $1.frequency }
                } label: {
                    Label("ノードを追加", systemImage: "plus.circle")
                }
                .disabled(settings.geqNodes.count >= maxNodes)

                Menu("プリセット挿入") {
                    Button("AutoEQ (Harman IE)") {
                        settings.geqNodes = harmanIE
                    }
                    Button("V字型ブースト") {
                        settings.geqNodes = vShapedBoost
                    }
                    Button("マット (フラット)") {
                        settings.geqNodes = flatMattress
                    }
                }
            } header: {
                Text("ノード (\(settings.geqNodes.count) / \(maxNodes))")
            } footer: {
                Text("ノードの周波数を変更すると、次回追加時の並びが自動的に整えられます。")
            }
            .disabled(!settings.geqEnabled)
        }
        .navigationTitle("Graphic EQ")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var harmanIE: [GraphicEQNode] {
        [
            .init(frequency: 20, gainDB: 6),
            .init(frequency: 50, gainDB: 5),
            .init(frequency: 100, gainDB: 3),
            .init(frequency: 200, gainDB: 0),
            .init(frequency: 500, gainDB: -1),
            .init(frequency: 1000, gainDB: 0),
            .init(frequency: 2000, gainDB: 3),
            .init(frequency: 3000, gainDB: 5),
            .init(frequency: 5000, gainDB: 4),
            .init(frequency: 8000, gainDB: 0),
            .init(frequency: 16000, gainDB: -3),
        ]
    }
    private var vShapedBoost: [GraphicEQNode] {
        [
            .init(frequency: 50, gainDB: 6),
            .init(frequency: 200, gainDB: 3),
            .init(frequency: 1000, gainDB: 0),
            .init(frequency: 5000, gainDB: 4),
            .init(frequency: 10000, gainDB: 6),
        ]
    }
    private var flatMattress: [GraphicEQNode] {
        (0 ..< 10).map { i in
            .init(frequency: 20 * pow(2.0, Double(i)), gainDB: 0)
        }
    }
}

struct GraphicEQNodeRow: View {
    @Binding var node: GraphicEQNode

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Freq")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { logFrequency(node.frequency) },
                        set: { node.frequency = expFrequency($0) }
                    ),
                    in: 0...1
                )
                Text(freqLabel(node.frequency))
                    .font(.caption.monospacedDigit())
                    .frame(width: 68, alignment: .trailing)
            }
            HStack {
                Text("Gain")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Slider(value: $node.gainDB, in: -24...24)
                Text(String(format: "%+.1f dB", node.gainDB))
                    .font(.caption.monospacedDigit())
                    .frame(width: 68, alignment: .trailing)
            }
        }
    }

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
