//
//  PoTokenBinding.swift
//  ViviMusic
//
//  GVS (googlevideo) 用 poToken を **何に紐づけて発行するか** を決める。
//
//  ── 経緯 ────────────────────────────────────────────────
//  2026-08 に「再生 URL が 1 MiB ちょうどで 403 になる」症状が出た。
//  出るときと出ないときがあり、コード変更との対応も付かなかった。
//
//  yt-dlp のソースに答えがあった:
//
//    # Since 2026.07, intermittent/selective POT enforcement has been
//    # observed for non-HLS formats
//
//    gvs_bind_to_video_id = False
//    experiments = ytcfg['WEB_PLAYER_CONTEXT_CONFIGS'][*]['serializedExperimentFlags']
//    if 'true' in experiments['html5_generate_content_po_token']:
//        gvs_bind_to_video_id = True
//
//  つまり YouTube 側の実験フラグ `html5_generate_content_po_token` が
//  有効なとき、GVS の poToken は **videoId に紐づけて** 発行しなければ
//  ならない。従来どおり visitorData に紐づけたトークンを付けても、
//  サーバーからは「無効な pot」= 実質 pot 無しとして扱われ、
//  典型的な 1 MiB スロットリングに落ちる。
//
//  実験は動画やセッション単位で on/off されるため、症状が断続的になる。
//  観測されたすべての不可解さがこれで説明できる。
//
//  ── 紐づけ先の決まり ─────────────────────────────────────
//    実験フラグ有効 → videoId
//    ログイン済み   → dataSyncId
//    それ以外       → visitorData
//

import Foundation

/// GVS poToken を何に紐づけるか。
enum PoTokenBinding: Equatable {
    case videoID(String)
    case dataSyncID(String)
    case visitorData(String)
    /// 居間のテレビとして名乗る識別子 (TVDeviceIdentity)。
    ///
    /// TVHTML5 + OAuth で SABR セッションを張るときはこれに紐づける。
    /// `player` 要求の `tvAppInfo.livingRoomPoTokenId` と
    /// SABR 要求の `streamerContext.poToken` が同じ ID を指していないと
    /// 認証が成立しない (Opaline の TVClient.attestationBinding と同じ)。
    case livingRoom(String)

    /// BotGuard に渡す識別子。
    var identifier: String {
        switch self {
        case .videoID(let value):     return value
        case .dataSyncID(let value):  return value
        case .visitorData(let value): return value
        case .livingRoom(let value):  return value
        }
    }

    /// ログや、トークンを覚えておくときの見出しに使う。
    var kind: String {
        switch self {
        case .videoID:     return "videoId"
        case .dataSyncID:  return "dataSyncId"
        case .visitorData: return "visitorData"
        case .livingRoom:  return "livingRoomPoTokenId"
        }
    }

    /// トークンを覚えておくときの鍵。
    /// 紐づけ先が変われば別のトークンが要るので、種別も含める。
    var cacheKey: String { "\(kind):\(identifier)" }
}

enum PoTokenBindingResolver {

    // ── 撤去した機能について ─────────────────────────────
    //
    // rev.50 で `html5_generate_content_po_token` という実験フラグを
    // player の応答から探す処理を入れたが、rev.51 で応答そのものを
    // 保存して確かめたところ、**10 ファイルすべてに
    // `serializedExperimentFlags` が存在しなかった**。
    //
    // yt-dlp が読んでいるのは www.youtube.com の HTML に埋まった
    // `ytcfg` であって、InnerTube の player 応答ではない。
    // 発火しようのないコードだったので消した。
    //
    // なお「pot を付けるべきか」は、この後に分かった
    // **URL の `sparams` を見る方法** (StreamURL.requiresPoToken) の
    // ほうが確実。実験フラグを追う必要はなくなった。

    /// 紐づけ先を決める。
    ///
    /// - Parameters:
    ///   - videoID: 対象の動画
    ///   - dataSyncID: Cookie ログイン中なら入る
    ///   - visitorData: セッション識別子
    ///
    /// `videoID` 紐づけは、将来 YouTube がそれを要求してきたときのために
    /// 型としては残してあるが、現状は使っていない
    /// (判断材料が API 応答から得られないため)。
    static func binding(dataSyncID: String?,
                        visitorData: String?) -> PoTokenBinding? {
        if let dataSyncID, !dataSyncID.isEmpty {
            return .dataSyncID(dataSyncID)
        }
        if let visitorData, !visitorData.isEmpty {
            return .visitorData(visitorData)
        }
        return nil
    }
}
