//
//  RangeRequestGate.swift
//  ViviMusic
//
//  googlevideo への範囲要求を間引くための仕切り。
//
//  なぜ必要か:
//    AVFoundation は再生開始時に複数の範囲を **同時に** 要求してくる。
//    ところが googlevideo はこれを嫌うようで、
//    2026-08-14 の実測では次のようになっていた。
//
//      14:38:50.473  bytes=0-65535        → HTTP 206
//      14:38:50.492  offset=147456        → HTTP 403   (19ms 後)
//
//    4 曲すべて offset=147456 ちょうどで 403 になっており、
//    時間経過による URL の失効では説明がつかない
//    (それなら止まる位置がばらつく)。
//    先に投げた要求が通っている以上 URL 自体は有効で、
//    「短い間隔で連続して要求したこと」が拒否の理由と考えられる。
//
//  やっていること:
//    要求を投げてよい時刻を先に予約する方式にしている。
//    待っている間に別の呼び出しが入ってきても、
//    予約済みの時刻より後ろの枠が割り当たるので、
//    同時に何本走っても間隔が保たれる。
//
//    actor の再入を考慮し、`nextAvailable` の更新は
//    **待つ前に** 済ませてある。待ってから更新すると、
//    同時に入った複数の呼び出しが同じ枠を取り合ってしまう。
//

import Foundation

actor RangeRequestGate {
    /// 要求と要求の間に最低限空ける時間。
    private let minimumInterval: TimeInterval
    /// 次に要求を投げてよい時刻。
    private var nextAvailable = Date.distantPast

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    /// 自分の枠が来るまで待つ。
    func acquire() async {
        let now = Date()
        let slot = max(now, nextAvailable)
        // 枠を確保してから待つ (順番が入れ替わらないようにするため)
        nextAvailable = slot.addingTimeInterval(minimumInterval)

        let delay = slot.timeIntervalSince(now)
        guard delay > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
}

/// 呼び出し側を短く書くための別名。
typealias RangeGate = RangeRequestGate
