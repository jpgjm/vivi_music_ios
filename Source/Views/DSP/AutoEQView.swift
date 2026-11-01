//
//  AutoEQView.swift
//  ViviMusic
//
//  AutoEQ プロファイルテキストを解析して、Parametric EQ に流し込む。
//  テキスト直接入力 or ファイル (.txt) 選択のどちらでも可。
//
//  Phase 2a で完全実装 (テキスト → PEQ 変換)。
//

import SwiftUI
import UniformTypeIdentifiers

struct AutoEQView: View {
    @ObservedObject private var settings = DSPSettings.shared

    @State private var pastedText: String = ""
    @State private var parsedProfile: AutoEQProfile?
    @State private var errorMessage: String?
    @State private var showImporter = false
    @State private var showAppliedAlert = false

    var body: some View {
        Form {
            // 説明
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AutoEQ は、ヘッドホン/イヤホンの周波数特性を Harman ターゲットに補正するプロファイルデータベースです。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("AutoEQ Results (GitHub)",
                         destination: URL(string: "https://github.com/jaakkopasanen/AutoEq/tree/master/results")!)
                        .font(.footnote)
                }
                .padding(.vertical, 4)
            }

            // 入力
            Section {
                Text("下記の欄に AutoEQ プロファイル (ParametricEQ.txt の中身) を貼り付けるか、ファイルをインポートしてください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if #available(iOS 16.0, *) {
                    TextEditor(text: $pastedText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                } else {
                    TextEditor(text: $pastedText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 140)
                }

                Button {
                    showImporter = true
                } label: {
                    Label("ファイルからインポート…", systemImage: "doc.text")
                }

                if !pastedText.isEmpty {
                    Button {
                        pastedText = ""
                        parsedProfile = nil
                        errorMessage = nil
                    } label: {
                        Label("入力をクリア", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("プロファイル入力")
            }

            // 解析ボタン
            Section {
                Button {
                    parseCurrentText()
                } label: {
                    Label("解析する", systemImage: "waveform.badge.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pastedText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // 結果
            if let profile = parsedProfile {
                Section {
                    LabeledContent("Preamp") {
                        Text(String(format: "%+.1f dB", profile.preampDB))
                            .font(.subheadline.monospacedDigit())
                    }
                    LabeledContent("バンド数") {
                        Text("\(profile.bands.count)")
                    }
                    if !profile.skippedLines.isEmpty {
                        LabeledContent("スキップ") {
                            Text("\(profile.skippedLines.count) 行")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("解析結果")
                }

                Section("バンド一覧") {
                    ForEach(profile.bands) { band in
                        HStack {
                            Text(band.type.displayName)
                                .font(.caption.weight(.medium))
                                .frame(width: 66, alignment: .leading)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(freqLabel(band.frequency))
                                    .font(.footnote.monospacedDigit())
                                Text(String(format: "%+.1f dB · Q %.2f", band.gainDB, band.q))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }

                Section {
                    Button {
                        applyToParametricEQ(profile: profile)
                    } label: {
                        Label("Parametric EQ に適用", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } footer: {
                    Text("既存の Parametric EQ 設定は上書きされます。Preamp は Output Post-Gain として適用されます。")
                }
            }

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("AutoEQ")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.plainText, .text, .data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert("適用しました", isPresented: $showAppliedAlert) {
            Button("OK") {}
        } message: {
            if let profile = parsedProfile {
                Text("Parametric EQ に \(profile.bands.count) バンドを設定し、Preamp \(String(format: "%+.1f", profile.preampDB)) dB を Post-Gain に反映しました。")
            }
        }
    }

    private func parseCurrentText() {
        do {
            let profile = try AutoEQParser.parse(pastedText)
            self.parsedProfile = profile
            self.errorMessage = nil
        } catch {
            self.parsedProfile = nil
            self.errorMessage = error.localizedDescription
        }
    }

    private func applyToParametricEQ(profile: AutoEQProfile) {
        // Parametric EQ を有効化 + バンド設定
        settings.peqEnabled = true
        settings.peqBands = profile.bands

        // Preamp は Post-Gain として適用 (AutoEQ の Preamp は負の値が多い)
        settings.outputPostGainDB = min(15, max(-15, profile.preampDB))

        showAppliedAlert = true
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                self.pastedText = text
                parseCurrentText()
            } catch {
                self.errorMessage = "ファイル読み込みエラー: \(error.localizedDescription)"
            }
        case .failure(let error):
            self.errorMessage = "ファイル選択エラー: \(error.localizedDescription)"
        }
    }

    private func freqLabel(_ hz: Double) -> String {
        if hz >= 1000 { return String(format: "%.2f kHz", hz / 1000) }
        return String(format: "%.0f Hz", hz)
    }
}
