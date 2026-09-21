//
//  LiveprogView.swift
//  ViviMusic
//
//  EEL2 スクリプトの取り込み・解析・スライダー UI・リアルタイム実行。
//  Phase 3-1: 標準 EEL2 の subset で動作。JamesDSP 独自関数は Phase 3-2 で対応予定。
//

import SwiftUI
import UniformTypeIdentifiers

struct LiveprogView: View {
    @ObservedObject private var settings = DSPSettings.shared
    @ObservedObject private var engine = DSPEngine.shared

    @State private var showImporter = false
    @State private var sourceCode: String = ""
    @State private var parsedProgram: EEL2Parser.Program?
    @State private var parseError: String?
    @State private var showSource = false

    var body: some View {
        Form {
            // 有効化
            Section {
                Toggle("有効にする", isOn: $settings.liveprogEnabled)
                    .disabled(settings.liveprogScriptPath == nil || parsedProgram == nil)
                if !engine.customUnitsReady {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Custom AUv3 初期化中…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("EEL2 スクリプトの @sample セクションを毎サンプル (44100 × 2ch = 88200 回/秒) 実行します。標準 EEL2 の subset に対応。JamesDSP 独自の DSP 関数は Phase 3-2 で追加予定。")
            }

            // ファイル
            Section {
                if let name = settings.liveprogScriptName {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.tint)
                            Text(name).font(.subheadline)
                            Spacer()
                        }
                        if let prog = parsedProgram {
                            if !prog.desc.isEmpty {
                                Text(prog.desc)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("変数: \(prog.variableCount) / スライダー: \(prog.sliders.count) / @init: \(prog.initSection.count) 文 / @sample: \(prog.sampleSection.count) 文")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text("スクリプトが選択されていません")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    showImporter = true
                } label: {
                    Label(settings.liveprogScriptPath == nil ? "スクリプトを選択…" : "別のスクリプトを選択…",
                          systemImage: "doc.badge.plus")
                }
            } header: {
                Text("EEL2 スクリプト")
            } footer: {
                Text("対応形式: .eel / .txt")
            }

            // パースエラー
            if let error = parseError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

            // スライダー UI
            if let prog = parsedProgram, !prog.sliders.isEmpty {
                Section {
                    ForEach(prog.sliders) { slider in
                        LiveprogSliderRow(slider: slider)
                    }
                } header: {
                    Text("パラメータ")
                } footer: {
                    Text("スライダー変更は即座にスクリプトに反映されます (@sample 実行中の変数値が更新)。")
                }
            }

            // パフォーマンス統計 (Phase 4-1)
            if parsedProgram != nil {
                LiveprogStatisticsSection()
            }

            // 対応構文情報
            Section {
                DisclosureGroup("Phase 3-4 の対応構文・関数") {
                    VStack(alignment: .leading, spacing: 4) {
                        Group {
                            Text("実行エンジン: **Bytecode コンパイル + Stack-based VM** (Phase 3-4)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tint)
                            Text("• 単純な算術・比較・論理・ビット演算・代入は bytecode 化 (2-5倍高速)").font(.caption)
                            Text("• if/else、while、loop、三項演算子も bytecode 化").font(.caption)
                            Text("• メモリ mem[i], x[i] も bytecode 化").font(.caption)
                            Text("• 標準数学関数呼び出し (sin, cos, sqrt, ...) も bytecode 化").font(.caption)
                            Text("• ユーザー関数・JamesDSP built-in は AST fallback (次回 bytecode 化)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Group {
                            Text("対応構文:").font(.caption.weight(.medium)).padding(.top, 4)
                            Text("• セクション: @init, @slider, @sample").font(.caption)
                            Text("• function 定義: function name(a, *b) ( body )  ← *b は参照渡し").font(.caption)
                            Text("• 変数: 全て double。spl0/spl1/srate は特殊変数").font(.caption)
                            Text("• メモリ: mem[i], x[i] (x はオフセット変数、100k セル)").font(.caption)
                            Text("• 三項演算子: cond ? a : b").font(.caption)
                            Text("• 算術: + - * / % ^").font(.caption)
                            Text("• 代入: = += -= *= /=").font(.caption)
                            Text("• 比較: == != < <= > >=").font(.caption)
                            Text("• 論理: && || !").font(.caption)
                            Text("• ビット: & | ~ << >>").font(.caption)
                            Text("• 制御: if/else, while, loop(n, body)").font(.caption)
                            Text("• 定数: $pi, $e").font(.caption)
                        }
                        Group {
                            Text("数学関数:").font(.caption.weight(.medium)).padding(.top, 2)
                            Text("• 三角: sin/cos/tan/asin/acos/atan/atan2/sinh/cosh/tanh").font(.caption)
                            Text("• 冪/対数: sqrt/exp/log/log10/pow/sqr/invsqrt").font(.caption)
                            Text("• その他: abs/floor/ceil/min/max/sign").font(.caption)
                        }
                        Group {
                            Text("JamesDSP built-in:").font(.caption.weight(.medium)).padding(.top, 2)
                            Text("• IIRBandSplitterInit / IIRBandSplitterProcess").font(.caption)
                            Text("• memset / memcpy / rms").font(.caption)
                        }
                    }
                }
            }

            // ソースコード表示
            if !sourceCode.isEmpty {
                Section {
                    DisclosureGroup("ソースコード", isExpanded: $showSource) {
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(sourceCode)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle("Liveprog")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.plainText, .text, .data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .onAppear {
            if sourceCode.isEmpty, let path = settings.liveprogScriptPath {
                loadStoredScript(relativePath: path)
            }
        }
    }

    // MARK: - File handling

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let savedName = url.lastPathComponent
                let relPath = try saveToLocalStorage(text: text, filename: savedName)
                self.sourceCode = text
                self.parseError = nil
                settings.liveprogScriptPath = relPath
                settings.liveprogScriptName = savedName
                // スクリプト変更時はスライダー値もデフォルトに戻す
                settings.liveprogSliderValues = [:]
                parseCurrentScript()
            } catch {
                self.parseError = "ファイル読み込みエラー: \(error.localizedDescription)"
            }
        case .failure(let error):
            self.parseError = "ファイル選択エラー: \(error.localizedDescription)"
        }
    }

    private func saveToLocalStorage(text: String, filename: String) throws -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Liveprog", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return "Liveprog/\(filename)"
    }

    private func loadStoredScript(relativePath: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent(relativePath)
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            self.sourceCode = text
            parseCurrentScript()
        } catch {
            self.parseError = "保存されたファイルの読み込みに失敗: \(error.localizedDescription)"
        }
    }

    private func parseCurrentScript() {
        do {
            let program = try EEL2Parser.parse(sourceCode)
            self.parsedProgram = program
            self.parseError = nil
            // 未設定のスライダー値をデフォルトで埋める
            var newValues = settings.liveprogSliderValues
            for s in program.sliders {
                if newValues[s.variableName] == nil {
                    newValues[s.variableName] = s.defaultValue
                }
            }
            settings.liveprogSliderValues = newValues
        } catch {
            self.parsedProgram = nil
            self.parseError = error.localizedDescription
        }
    }
}

// MARK: - スライダー行

struct LiveprogSliderRow: View {
    let slider: EEL2Slider
    @ObservedObject private var settings = DSPSettings.shared

    private var value: Binding<Double> {
        Binding(
            get: { settings.liveprogSliderValues[slider.variableName] ?? slider.defaultValue },
            set: { newValue in
                var values = settings.liveprogSliderValues
                values[slider.variableName] = newValue
                settings.liveprogSliderValues = values
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(slider.label).font(.subheadline)
                    Text(slider.variableName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(formatValue(value.wrappedValue))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(formatValue(slider.minValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Slider(value: value, in: slider.minValue ... slider.maxValue, step: slider.step)
                Text(formatValue(slider.maxValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Spacer()
                Button {
                    var values = settings.liveprogSliderValues
                    values[slider.variableName] = slider.defaultValue
                    settings.liveprogSliderValues = values
                } label: {
                    Text("デフォルト (\(formatValue(slider.defaultValue)))")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatValue(_ v: Double) -> String {
        if slider.step >= 1 { return String(format: "%.0f", v) }
        if slider.step >= 0.1 { return String(format: "%.1f", v) }
        if slider.step >= 0.01 { return String(format: "%.2f", v) }
        return String(format: "%.3f", v)
    }
}

// MARK: - パフォーマンス統計セクション

/// Liveprog スクリプトの実行統計を表示する。
/// 500ms 毎に更新。ユーザーの参考用 (どれくらい重いスクリプトか把握)。
struct LiveprogStatisticsSection: View {
    @State private var stats: LiveprogAudioUnit.Statistics?
    @State private var timer: Timer?
    @State private var showStats: Bool = false

    var body: some View {
        Section {
            DisclosureGroup("パフォーマンス統計", isExpanded: $showStats) {
                if let stats = stats {
                    HStack {
                        Text("直前の @sample 命令数")
                            .font(.caption)
                        Spacer()
                        Text("\(stats.lastSampleInstructions)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("平均 命令数/@sample")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.1f", stats.averageInstructionsPerSample))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("累積 @sample 呼び出し回数")
                            .font(.caption)
                        Spacer()
                        Text("\(stats.cumulativeSampleCalls)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    HStack {
                        Spacer()
                        Button {
                            DSPEngine.shared.resetLiveprogStatistics()
                            refresh()
                        } label: {
                            Text("リセット").font(.caption2)
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Text("Liveprog は動作していません")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear {
            refresh()
            startTimer()
        }
        .onDisappear {
            stopTimer()
        }
        .onChange(of: showStats) { newValue in
            if newValue {
                refresh()
                startTimer()
            } else {
                stopTimer()
            }
        }
    }

    private func refresh() {
        stats = DSPEngine.shared.liveprogStatistics()
    }

    private func startTimer() {
        guard timer == nil, showStats else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            refresh()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
