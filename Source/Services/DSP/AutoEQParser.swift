//
//  AutoEQParser.swift
//  ViviMusic
//
//  AutoEQ プロジェクトの Parametric EQ プロファイルテキストを解析して、
//  ParametricBand の配列に変換する。
//
//  典型的な入力フォーマット (AutoEQ の "ParametricEQ.txt"):
//
//    Preamp: -6.5 dB
//    Filter 1: ON PK Fc 20 Hz Gain 4.5 dB Q 0.71
//    Filter 2: ON PK Fc 105 Hz Gain -1.5 dB Q 1.20
//    Filter 3: ON LSC Fc 105 Hz Gain 6.7 dB Q 0.70
//    Filter 4: ON HSC Fc 10000 Hz Gain -4.0 dB Q 0.70
//    ...
//
//  Filter type コード:
//    PK  = Peaking (parametric)
//    LSC = Low Shelf
//    HSC = High Shelf
//    LPQ = Low Pass (Q)
//    HPQ = High Pass (Q)
//    NO  = Notch
//

import Foundation

enum AutoEQParseError: LocalizedError {
    case noFiltersFound
    case invalidFilterLine(String)

    var errorDescription: String? {
        switch self {
        case .noFiltersFound:
            return "有効なフィルタ行が見つかりませんでした。AutoEQ プロファイル形式を確認してください。"
        case .invalidFilterLine(let line):
            return "解析できない行があります: \(line)"
        }
    }
}

struct AutoEQProfile {
    /// Preamp (dB)。指定がなければ 0。
    var preampDB: Double
    /// 変換されたパラメトリックバンド
    var bands: [ParametricBand]
    /// 解析中スキップされた行 (デバッグ用)
    var skippedLines: [String]
}

struct AutoEQParser {

    /// AutoEQ プロファイルテキストを解析
    static func parse(_ text: String) throws -> AutoEQProfile {
        var preamp: Double = 0
        var bands: [ParametricBand] = []
        var skipped: [String] = []

        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Preamp 行
            if let pre = parsePreamp(line) {
                preamp = pre
                continue
            }

            // Filter 行
            if let band = parseFilter(line) {
                bands.append(band)
            } else if line.lowercased().contains("filter") {
                skipped.append(line)
            }
        }

        if bands.isEmpty {
            throw AutoEQParseError.noFiltersFound
        }

        return AutoEQProfile(preampDB: preamp, bands: bands, skippedLines: skipped)
    }

    // MARK: - Preamp

    private static let preampRegex: NSRegularExpression = {
        let pattern = #"Preamp:\s*(-?\d+(?:\.\d+)?)\s*dB"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static func parsePreamp(_ line: String) -> Double? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = preampRegex.firstMatch(in: line, options: [], range: range),
              let r = Range(m.range(at: 1), in: line)
        else { return nil }
        return Double(line[r])
    }

    // MARK: - Filter

    private static let filterRegex: NSRegularExpression = {
        // Filter <N>: <ON|OFF> <TYPE> Fc <FREQ> Hz Gain <GAIN> dB Q <Q>
        // タイプによっては Gain がない場合もある (LPQ/HPQ/NO)。
        let pattern = #"Filter\s+\d+\s*:\s*(ON|OFF)\s+(\w+)\s+Fc\s+(\d+(?:\.\d+)?)\s*Hz(?:\s+Gain\s+(-?\d+(?:\.\d+)?)\s*dB)?\s+Q\s+(\d+(?:\.\d+)?)"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static func parseFilter(_ line: String) -> ParametricBand? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = filterRegex.firstMatch(in: line, options: [], range: range) else {
            return nil
        }

        func capture(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: line) else { return nil }
            return String(line[r])
        }

        guard let onOff = capture(1), onOff.uppercased() == "ON" else { return nil }
        guard let typeStr = capture(2) else { return nil }
        guard let fcStr = capture(3), let fc = Double(fcStr) else { return nil }
        let gain = capture(4).flatMap(Double.init) ?? 0
        guard let qStr = capture(5), let q = Double(qStr) else { return nil }

        let type = mapType(typeStr)
        return ParametricBand(
            frequency: fc,
            gainDB: gain,
            q: q,
            type: type
        )
    }

    private static func mapType(_ code: String) -> ParametricBand.BandType {
        switch code.uppercased() {
        case "PK": return .parametric
        case "LSC", "LS": return .lowShelf
        case "HSC", "HS": return .highShelf
        case "LPQ", "LP": return .lowPass
        case "HPQ", "HP": return .highPass
        case "NO", "NOTCH": return .bandPass  // 近似
        default: return .parametric
        }
    }
}
