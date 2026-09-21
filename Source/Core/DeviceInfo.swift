//
//  DeviceInfo.swift
//  ViviMusic
//
//  診断ログのヘッダに載せる端末情報をまとめて取得する。
//
//  なぜ独立したファイルにするのか:
//    `UIDevice` は UIKit のクラスで、最近の SDK では `@MainActor` が付いている。
//    一方 `EventLog.exportText()` はどこからでも呼べる同期関数なので、
//    そこから直接 `UIDevice.current` に触ると隔離違反でコンパイルが通らない。
//    そのため UIKit 由来の値だけを起動時に一度だけ拾ってキャッシュし、
//    書き出し時にはキャッシュを読むだけにしている。
//
//    値が変わりうるもの (発熱状態・低電力モード) は `ProcessInfo` から取る。
//    こちらは隔離されていないので、書き出しのたびに現在値を読む。
//

import Foundation
import UIKit

enum DeviceInfo {

    // MARK: - 起動時に一度だけ拾う値

    /// UIKit 由来の値。起動時に `prime()` で埋める。
    private struct UIKitSnapshot {
        let model: String
        let systemName: String
        let idiom: String
    }

    private static var snapshot: UIKitSnapshot?

    /// アプリ起動時に呼ぶ。UIKit の値をメインスレッドで拾ってキャッシュする。
    @MainActor
    static func prime() {
        let device = UIDevice.current
        snapshot = UIKitSnapshot(
            model: device.model,
            systemName: device.systemName,
            idiom: idiomText(device.userInterfaceIdiom)
        )
    }

    /// "iPad" / "iPhone" など。ざっくりした種別しか返らない。
    static var model: String { snapshot?.model ?? "不明" }

    /// "iPadOS" / "iOS" など。
    static var systemName: String { snapshot?.systemName ?? "不明" }

    /// "pad" / "phone" など。
    static var idiom: String { snapshot?.idiom ?? "不明" }

    // MARK: - 機種識別子

    /// `iPad12,2` のような内部識別子。
    ///
    /// 商品名 ("iPad 第9世代") を返す公開 API は存在しないため、
    /// ここで得られるのはあくまで識別子。対応表は持っていないので
    /// そのまま出す。
    ///
    /// 起動のたびに変わる値ではないので一度だけ計算する。
    static let machineIdentifier: String = {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return "不明"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else {
            return "不明"
        }
        return String(cString: buffer)
    }()

    // MARK: - 書き出しのたびに読む値

    /// OS のバージョン文字列 (例: "Version 26.6 (Build 23G71)")。
    static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// 総メモリ (バイト)。
    static var physicalMemory: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// CPU コア数 (現在有効なもの)。
    static var processorCount: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }

    /// 発熱状態。再生が途切れる・動作が重いといった症状の説明材料になる。
    static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "通常"
        case .fair:     return "やや高い"
        case .serious:  return "高い"
        case .critical: return "危険"
        @unknown default: return "不明"
        }
    }

    /// 低電力モード。バックグラウンド処理やネットワークが抑制されるため、
    /// 「遅い」「途切れる」の原因になりうる。
    static var isLowPowerMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    // MARK: - 整形

    /// 総メモリを読みやすい形にする。
    ///
    /// `ByteCountFormatter` は 1000 進で計算するため 3 GB の端末が
    /// 「3.22 GB」と表示されてしまう。メモリは 1024 進で見るのが自然なので
    /// 自前で割る。
    static var physicalMemoryText: String {
        let bytes = physicalMemory
        let gb = Double(bytes) / 1024 / 1024 / 1024
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        return String(format: "%.0f MB", Double(bytes) / 1024 / 1024)
    }

    private static func idiomText(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .phone:       return "phone"
        case .pad:         return "pad"
        case .tv:          return "tv"
        case .carPlay:     return "carPlay"
        case .mac:         return "mac"
        case .vision:      return "vision"
        case .unspecified: return "unspecified"
        @unknown default:  return "unknown"
        }
    }
}
