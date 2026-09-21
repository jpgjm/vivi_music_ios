//
//  ConvolverView.swift
//  ViviMusic
//
//  Convolver: IR (Impulse Response) ファイルによる畳み込み。
//
//  Phase 2a: IR ファイル (WAV/FLAC/AIFF) の選択、情報表示、有効化トグル。
//  Phase 2b: Custom AUv3 で FFT ベースのリアルタイム畳み込み実装。
//

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct ConvolverView: View {
    @ObservedObject private var settings = DSPSettings.shared
    @ObservedObject private var engine = DSPEngine.shared

    @State private var showImporter = false
    @State private var irInfo: IRFileInfo?
    @State private var errorMessage: String?

    struct IRFileInfo {
        let filename: String
        let sampleRate: Double
        let channelCount: Int
        let durationSeconds: Double
        let sampleCount: AVAudioFramePosition
    }

    var body: some View {
        Form {
            Section {
                Toggle("有効にする", isOn: $settings.convolverEnabled)
                    .disabled(settings.convolverIRPath == nil)
                if !engine.customUnitsReady {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Custom AUv3 初期化中…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("IR ファイルとの畳み込みを **Custom AUv3 + vDSP FFT (Overlap-Save 法)** でリアルタイム実行します (Phase 2b-2 実装済み)。部屋の反射・スピーカー特性・HRTF などをシミュレート可能。")
            }

            // 説明
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("実装済み仕様")
                            .font(.footnote.weight(.medium))
                    } icon: {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    Text("FFT サイズ 8192 (185 ms @ 44.1kHz)。IR は最大 8191 サンプル。ステレオ IR は自動的にモノラル化して L/R に適用。異なるサンプルレートの IR は 44.1kHz にリサンプリング (線形補間)。ピーク正規化 (-6 dB safety) 済み。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            // IR ファイル
            Section {
                if let info = irInfo {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "waveform")
                                .foregroundStyle(.tint)
                            Text(info.filename)
                                .font(.subheadline)
                            Spacer()
                        }
                        Group {
                            LabeledContent("サンプルレート") {
                                Text(String(format: "%.0f Hz", info.sampleRate))
                                    .font(.footnote.monospacedDigit())
                            }
                            LabeledContent("チャンネル") {
                                Text("\(info.channelCount) ch")
                                    .font(.footnote.monospacedDigit())
                            }
                            LabeledContent("長さ") {
                                Text(String(format: "%.3f 秒 (%d サンプル)",
                                            info.durationSeconds, info.sampleCount))
                                    .font(.footnote.monospacedDigit())
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } else if let name = settings.convolverIRName {
                    HStack {
                        Image(systemName: "waveform")
                            .foregroundStyle(.secondary)
                        Text(name).font(.subheadline)
                        Spacer()
                    }
                } else {
                    Text("IR ファイルが選択されていません")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }

                Button {
                    showImporter = true
                } label: {
                    Label(settings.convolverIRPath == nil ? "IR ファイルを選択…" : "別のファイルを選択…",
                          systemImage: "doc.badge.plus")
                }
            } header: {
                Text("IR ファイル")
            } footer: {
                Text("対応形式: WAV / FLAC / AIFF / M4A。ステレオ IR は True Stereo、モノラルは L/R 両方に適用。")
            }

            // 畳み込みモード
            Section {
                Picker("モード", selection: $settings.convolverMode) {
                    Text("Full").tag(0)
                    Text("True Stereo").tag(1)
                    Text("OMSCE").tag(2)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("畳み込みモード")
            } footer: {
                Text("Full: 全チャンネルに適用 / True Stereo: 左右独立 / OMSCE: 中央のみ")
            }
            .disabled(!settings.convolverEnabled)

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Convolver")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio, .wav, .mp3, .mpeg4Audio, .aiff],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .onAppear {
            if irInfo == nil, let path = settings.convolverIRPath {
                loadStoredIR(relativePath: path)
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
                let savedName = url.lastPathComponent
                // Documents/Convolver/ にコピー
                let relPath = try saveToLocalStorage(sourceURL: url, filename: savedName)
                let localURL = documentsURL(for: relPath)

                let info = try loadIRInfo(from: localURL)

                self.irInfo = info
                self.errorMessage = nil
                settings.convolverIRPath = relPath
                settings.convolverIRName = savedName
            } catch {
                self.errorMessage = "読み込みエラー: \(error.localizedDescription)"
            }
        case .failure(let error):
            self.errorMessage = "ファイル選択エラー: \(error.localizedDescription)"
        }
    }

    private func loadIRInfo(from url: URL) throws -> IRFileInfo {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        return IRFileInfo(
            filename: url.lastPathComponent,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            durationSeconds: Double(file.length) / format.sampleRate,
            sampleCount: file.length
        )
    }

    private func saveToLocalStorage(sourceURL: URL, filename: String) throws -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Convolver", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        return "Convolver/\(filename)"
    }

    private func documentsURL(for relativePath: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(relativePath)
    }

    private func loadStoredIR(relativePath: String) {
        let url = documentsURL(for: relativePath)
        do {
            let info = try loadIRInfo(from: url)
            self.irInfo = info
        } catch {
            self.errorMessage = "保存されたファイルの読み込みに失敗: \(error.localizedDescription)"
        }
    }
}
