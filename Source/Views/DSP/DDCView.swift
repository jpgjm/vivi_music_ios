//
//  DDCView.swift
//  ViviMusic
//
//  DDC (Digital Room Correction) 用 VDC ファイルを取り込み、BiQuad チェインを
//  Parametric EQ に近似変換して適用する。
//
//  Phase 2a: VDC 解析 + PEQ 近似変換で PEQ に適用 (実 BiQuad 実行は Phase 2b)
//

import SwiftUI
import UniformTypeIdentifiers

struct DDCView: View {
    @ObservedObject private var settings = DSPSettings.shared

    @State private var showImporter = false
    @State private var parsedProfile: VDCProfile?
    @State private var errorMessage: String?
    @State private var loadedFilename: String?
    @State private var showAppliedAlert = false
    @State private var appliedAsPEQCount: Int = 0

    @ObservedObject private var engine = DSPEngine.shared

    var body: some View {
        Form {
            Section {
                Toggle("有効にする", isOn: $settings.ddcEnabled)
                    .disabled(settings.ddcVDCPath == nil)
                if !engine.customUnitsReady {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Custom AUv3 初期化中…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("VDC ファイルの BiQuad チェインを **Custom AUv3 経由でリアルタイム実行** します (Phase 2b 実装済み)。有効にすると VDC の全 BiQuad が Direct Form II Transposed で厳密適用されます。")
            }

            // 説明
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("VDC は BiQuad IIR フィルタの係数をテキスト形式で保存したファイルです。RootlessJamesDSP や JamesDSPManager と互換の VDC ファイルを読み込めます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("形式: SR_44100:b0,b1,b2,a1,a2,b0,b1,b2,a1,a2,...")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }

            // ファイル読込
            Section {
                if let filename = loadedFilename ?? settings.ddcVDCName {
                    HStack {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(filename)
                                .font(.subheadline)
                            if let profile = parsedProfile {
                                Text(profileSummary(profile))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
                Button {
                    showImporter = true
                } label: {
                    Label(loadedFilename == nil ? "VDC ファイルを選択…" : "別のファイルを選択…",
                          systemImage: "doc.badge.plus")
                }
            } header: {
                Text("VDC ファイル")
            }

            // 解析結果
            if let profile = parsedProfile {
                Section {
                    ForEach(Array(profile.chains.keys.sorted()), id: \.self) { sr in
                        if let sections = profile.chains[sr] {
                            LabeledContent("SR \(sr) Hz") {
                                Text("\(sections.count) BiQuads")
                                    .font(.subheadline.monospacedDigit())
                            }
                        }
                    }
                } header: {
                    Text("解析結果")
                }

                if let primary = profile.primaryChain {
                    Section("BiQuad プレビュー (SR \(primary.sampleRate) Hz)") {
                        ForEach(Array(primary.sections.prefix(20).enumerated()), id: \.offset) { idx, section in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("[#\(idx + 1)]")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                Text(String(format: "b: %.4f, %.4f, %.4f", section.b0, section.b1, section.b2))
                                    .font(.caption2.monospaced())
                                Text(String(format: "a: 1.0, %.4f, %.4f", section.a1, section.a2))
                                    .font(.caption2.monospaced())
                            }
                            .padding(.vertical, 1)
                        }
                        if primary.sections.count > 20 {
                            Text("… ほか \(primary.sections.count - 20) セクション")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Section {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("BiquadChain で自動ロード済み")
                                    .font(.subheadline.weight(.medium))
                                Text("上のトグルを ON にすると即座に反映されます。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("Custom AUv3 (推奨)")
                    } footer: {
                        Text("VDC ファイルの全 BiQuad が Direct Form II Transposed で厳密に実行されます。パラメータ変更もリアルタイムです。")
                    }

                    Section {
                        Button {
                            applyAsPEQ(profile: profile, primary: primary)
                        } label: {
                            Label("Parametric EQ に近似変換して適用", systemImage: "waveform.path.ecg")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } header: {
                        Text("補助: Parametric EQ 近似変換")
                    } footer: {
                        Text("VDC の BiQuad チェインを Parametric EQ の 15 バンドに近似します。BiquadChain が使えない場合の代替手段。近似計算のため厳密な応答とは若干の差が出ます。")
                    }
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
        .navigationTitle("DDC")
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
            Text("Parametric EQ に \(appliedAsPEQCount) バンドを近似設定しました。DDC (BiquadChain) は無効化しました (二重適用を避けるため)。")
        }
        .onAppear {
            // 起動時に保存されたファイルがあれば読み込み
            if parsedProfile == nil, let name = settings.ddcVDCName, let path = settings.ddcVDCPath {
                loadedFilename = name
                loadStoredFile(relativePath: path)
            }
        }
    }

    private func profileSummary(_ profile: VDCProfile) -> String {
        let counts = profile.chains.sorted(by: { $0.key < $1.key }).map { sr, sections in
            "SR\(sr): \(sections.count)"
        }.joined(separator: " / ")
        return counts
    }

    private func applyAsPEQ(profile: VDCProfile, primary: (sampleRate: Int, sections: [BiquadSection])) {
        let bands = BiquadToPEQConverter.convert(
            sections: primary.sections,
            sampleRate: Double(primary.sampleRate),
            maxBands: 15
        )
        settings.peqEnabled = true
        settings.peqBands = bands
        // BiquadChain と PEQ 両方 ON にすると二重適用になるので、PEQ 変換適用時は BiquadChain を OFF にする
        settings.ddcEnabled = false
        appliedAsPEQCount = bands.count
        showAppliedAlert = true
    }

    // MARK: - File handling

    /// ファイルインポート → Documents/DDC/ にコピーして保存
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let profile = try VDCParser.parse(text)
                // Documents/DDC/ に保存
                let savedName = url.lastPathComponent
                let relPath = try saveToLocalStorage(text: text, filename: savedName)

                self.parsedProfile = profile
                self.loadedFilename = savedName
                self.errorMessage = nil
                settings.ddcVDCPath = relPath
                settings.ddcVDCName = savedName
            } catch {
                self.errorMessage = "読み込みエラー: \(error.localizedDescription)"
                self.parsedProfile = nil
            }
        case .failure(let error):
            self.errorMessage = "ファイル選択エラー: \(error.localizedDescription)"
        }
    }

    private func saveToLocalStorage(text: String, filename: String) throws -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("DDC", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return "DDC/\(filename)"
    }

    private func loadStoredFile(relativePath: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent(relativePath)
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let profile = try VDCParser.parse(text)
            self.parsedProfile = profile
        } catch {
            self.errorMessage = "保存されたファイルの読み込みに失敗: \(error.localizedDescription)"
        }
    }
}
