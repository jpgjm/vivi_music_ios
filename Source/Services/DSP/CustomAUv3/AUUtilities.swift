//
//  AUUtilities.swift
//  ViviMusic
//
//  Custom AUv3 (AUAudioUnit サブクラス) を作成・登録するためのユーティリティ。
//

import Foundation
import AVFoundation
import AudioToolbox

// MARK: - 4-char code

/// 4 文字 ASCII 文字列を UInt32 (4-char code) に変換する。
/// AudioComponentDescription の componentSubType / componentManufacturer に使う。
func fourCharCode(_ string: String) -> OSType {
    precondition(string.utf8.count == 4, "4-char code must be exactly 4 ASCII characters: \(string)")
    var result: UInt32 = 0
    for byte in string.utf8.prefix(4) {
        result = (result << 8) | UInt32(byte)
    }
    return result
}

// MARK: - AudioComponentDescription

/// Custom AUv3 用共通 manufacturer コード ("MPly"。MusicPlayer から移植したまま)
let kAppManufacturer: OSType = fourCharCode("MPly")

// MARK: - 登録

/// AUAudioUnit サブクラスをコンポーネントとして登録し、AVAudioUnit を非同期にインスタンス化する。
/// - Parameters:
///   - type: 登録する AUAudioUnit サブクラス
///   - subType: 4-char code (例: "BiqC")
///   - name: コンポーネント名 (デバッグ用)
///   - version: バージョン番号
/// - Returns: AVAudioUnit (async)
@MainActor
func instantiateCustomAudioUnit<T: AUAudioUnit>(
    type: T.Type,
    subType: String,
    name: String,
    version: UInt32 = 1
) async throws -> AVAudioUnit {
    let desc = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCharCode(subType),
        componentManufacturer: kAppManufacturer,
        componentFlags: 0,
        componentFlagsMask: 0
    )
    AUAudioUnit.registerSubclass(type, as: desc, name: name, version: version)

    return try await withCheckedThrowingContinuation { cont in
        AVAudioUnit.instantiate(with: desc, options: []) { unit, error in
            if let error = error {
                cont.resume(throwing: error)
            } else if let unit = unit {
                cont.resume(returning: unit)
            } else {
                cont.resume(throwing: AUError.instantiationFailed)
            }
        }
    }
}

enum AUError: LocalizedError {
    case instantiationFailed
    case invalidFormat
    case renderResourcesNotAllocated

    var errorDescription: String? {
        switch self {
        case .instantiationFailed:      return "AUAudioUnit の初期化に失敗しました"
        case .invalidFormat:            return "サポートされていないオーディオフォーマットです"
        case .renderResourcesNotAllocated: return "AUAudioUnit の render resources が確保されていません"
        }
    }
}
