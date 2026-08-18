//
//  StreamURLDiagnostics.swift
//  ViviMusic
//
//  1 MiB 制限の切り分け実験のために、直近に解決した再生 URL を控える。
//
//  ── 何を確かめたいのか ──────────────────────────────────────
//
//  2026-08 以降、googlevideo が「先頭 1 MiB より先を返さない」状態に
//  なっている。SABR も約 1.08 MiB (69 秒) で打ち切られる。
//
//  rev.85〜87 で SABR のリクエスト形状 (StreamerContext.visitorData /
//  poToken の紐づけ統一 / elapsed_wall_time_ms / buffered_ranges の
//  累積) をすべて直したが、`StreamProtectionStatus = 2` は解けず、
//  取得量は 1,105 KiB でバイト単位まで従来と同一だった。
//
//  つまり **リクエストの組み立て方は原因ではない**。
//  残る問いはひとつ:
//
//      1 MiB 制限は「URL」に紐づくのか、「取りに行くクライアント」に
//      紐づくのか。
//
//  ViviMusic が解決した URL を、まったく別の端末 (Termux の curl) から
//  叩けば一発で分かる。
//
//      403 → URL・セッションに紐づく → 公式バイナリに再生を委ねる必要がある
//      206 → ViviMusic の要求の出し方が原因 → 手元で直せる
//
//  この判定でその後の設計が大きく変わるため、実験の導線を用意する。
//
//  ── 秘匿情報の扱い ──────────────────────────────────────────
//
//  videoplayback URL には次が **平文で** 入っている。
//
//      ip=    発行時のグローバル IP アドレス
//      sig=   署名
//      lsig=  別系統の署名
//      pot=   poToken (付いている場合)
//
//  そのため:
//
//    - 直近 URL は **メモリ上にだけ** 持つ。ディスクには保存しない。
//    - ログへの全文出力は **既定で無効**。設定画面で明示的に有効にする。
//    - 共有用には `StreamURL.redacted` で伏字にしたものを使う。
//

import Foundation

/// 検証用に直近の再生 URL を控えるところ。
actor StreamURLDiagnostics {

    static let shared = StreamURLDiagnostics()

    /// 直近に解決した再生 URL の記録。
    struct Record {
        let url: String
        let videoID: String
        let clientName: String
        let resolvedAt: Date

        /// URL が失効している可能性が高いか。
        ///
        /// `expire` の実値を読むのが正確だが、実験で問題になるのは
        /// 「取ってから時間が経ちすぎていないか」だけなので、
        /// 解決からの経過時間で十分。
        var isStale: Bool {
            Date().timeIntervalSince(resolvedAt) > 300
        }

        var ageDescription: String {
            let seconds = Int(Date().timeIntervalSince(resolvedAt))
            if seconds < 60 { return "\(seconds)秒前" }
            return "\(seconds / 60)分\(seconds % 60)秒前"
        }
    }

    private(set) var latest: Record?

    /// ログに URL 全体を出すか。
    ///
    /// **既定は false。** URL に ip= と sig= が平文で入っているため、
    /// 有効にしたままログを共有すると自宅の IP が漏れる。
    /// 実験のときだけ設定画面から有効にし、終わったら戻すこと。
    ///
    /// `nonisolated(unsafe)` にしているのは、ログ出力の直前に
    /// 同期的に読みたいだけの Bool で、競合しても実害が無いため。
    /// (取りこぼしても次の解決で拾える)
    nonisolated(unsafe) static var logsFullURL: Bool {
        get { UserDefaults.standard.bool(forKey: logsFullURLKey) }
        set { UserDefaults.standard.set(newValue, forKey: logsFullURLKey) }
    }

    private static let logsFullURLKey = "diagnostics.logsFullStreamURL"

    /// 解決できた URL を控える。上書きしていくので常に最新の 1 件だけ。
    func record(url: String, videoID: String, clientName: String) {
        guard !url.isEmpty else { return }
        latest = Record(url: url,
                        videoID: videoID,
                        clientName: clientName,
                        resolvedAt: Date())
    }

    /// 控えを捨てる。
    func clear() {
        latest = nil
    }
}
