//
//  Models.swift
//  ViviMusic
//
//  アプリ全体で使うデータモデル。
//  InnerTube のレスポンスをこれらに正規化してから UI に渡す。
//

import Foundation

// MARK: - 曲

/// 再生可能な 1 曲。
struct Song: Identifiable, Codable, Hashable {
    /// YouTube の videoId。アプリ内での一意キーも兼ねる。
    let id: String
    var title: String
    var artist: String
    var album: String?
    /// アルバムページへ飛ぶための browseId (あれば)
    var albumID: String?
    /// 秒数 (不明なら nil)
    var durationSeconds: Int?
    var thumbnailURL: String?
    /// アーティストページへ飛ぶための browseId (あれば)
    var artistID: String?

    var duration: TimeInterval? {
        durationSeconds.map { TimeInterval($0) }
    }

    /// "3:45" 形式。
    var durationText: String {
        guard let s = durationSeconds else { return "--:--" }
        return Song.formatDuration(TimeInterval(s))
    }

    /// アーティストページへの経路。browseId が取れていなければ nil。
    var artistRoute: BrowseRoute? {
        guard let artistID, !artistID.isEmpty else { return nil }
        return BrowseRoute(browseID: artistID, title: artist,
                           kind: .artist, thumbnailURL: nil)
    }

    /// アルバムページへの経路。browseId が取れていなければ nil。
    var albumRoute: BrowseRoute? {
        guard let albumID, !albumID.isEmpty else { return nil }
        return BrowseRoute(browseID: albumID, title: album ?? "アルバム",
                           kind: .album, thumbnailURL: thumbnailURL)
    }

    /// 共有用の YouTube URL。
    var shareURL: URL? {
        URL(string: "https://music.youtube.com/watch?v=\(id)")
    }

    static func formatDuration(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "--:--" }
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - アルバム / プレイリスト / アーティスト

/// ホームや検索に出てくるアルバム。
struct AlbumItem: Identifiable, Codable, Hashable {
    /// browseId (MPREb_... 形式)
    let id: String
    var title: String
    var subtitle: String?
    var thumbnailURL: String?
    var year: String?
}

/// ホームや検索に出てくるプレイリスト。
struct PlaylistItem: Identifiable, Codable, Hashable {
    /// browseId (VL... or PL... 形式)
    let id: String
    var title: String
    var subtitle: String?
    var thumbnailURL: String?
}

/// ホームや検索に出てくるアーティスト。
struct ArtistItem: Identifiable, Codable, Hashable {
    /// browseId (UC... 形式)
    let id: String
    var title: String
    var subtitle: String?
    var thumbnailURL: String?
}

// MARK: - ホーム画面のセクション

/// ホーム / 探索画面に並ぶ 1 セクション。
/// VIVI Music (と YouTube Music) のホームは「横スクロールする棚」の縦積み。
struct HomeSection: Identifiable {
    let id = UUID()
    var title: String
    /// "アルバム" などの上付きラベル (strapline)
    var label: String?
    var items: [HomeItem]
}

/// ホームフィードの 1 ページ分。
///
/// InnerTube の `FEmusic_home` は初回応答で先頭の数棚しか返さず、
/// 続きは `continuation` トークンを使った追加リクエストで取得する。
/// 「毎日のおすすめ」より下の「新作」「おすすめのアルバム」などは
/// この追加ページに入っているため、トークンを持ち回す必要がある。
struct HomeFeed {
    var sections: [HomeSection]
    /// 次のページを取るためのトークン。nil なら終端。
    var continuation: String?

    static let empty = HomeFeed(sections: [], continuation: nil)
}

/// セクション内の 1 アイテム。曲・アルバム・プレイリスト・アーティストのいずれか。
enum HomeItem: Identifiable, Hashable {
    case song(Song)
    case album(AlbumItem)
    case playlist(PlaylistItem)
    case artist(ArtistItem)

    var id: String {
        switch self {
        case .song(let s):     return "song:\(s.id)"
        case .album(let a):    return "album:\(a.id)"
        case .playlist(let p): return "playlist:\(p.id)"
        case .artist(let a):   return "artist:\(a.id)"
        }
    }

    var title: String {
        switch self {
        case .song(let s):     return s.title
        case .album(let a):    return a.title
        case .playlist(let p): return p.title
        case .artist(let a):   return a.title
        }
    }

    var subtitle: String? {
        switch self {
        case .song(let s):     return s.artist
        case .album(let a):    return a.subtitle
        case .playlist(let p): return p.subtitle
        case .artist(let a):   return a.subtitle
        }
    }

    var thumbnailURL: String? {
        switch self {
        case .song(let s):     return s.thumbnailURL
        case .album(let a):    return a.thumbnailURL
        case .playlist(let p): return p.thumbnailURL
        case .artist(let a):   return a.thumbnailURL
        }
    }

    /// アーティストのサムネイルだけ円形にする (YouTube Music と同じ)
    var isCircular: Bool {
        if case .artist = self { return true }
        return false
    }

    var song: Song? {
        if case .song(let s) = self { return s }
        return nil
    }
}

// MARK: - 詳細ページ

/// アルバム / プレイリスト / アーティストの詳細ページ。
struct BrowsePage {
    enum Kind: Hashable {
        case album, playlist, artist

        var displayName: String {
            switch self {
            case .album:    return "アルバム"
            case .playlist: return "プレイリスト"
            case .artist:   return "アーティスト"
            }
        }
    }

    var kind: Kind
    var title: String
    var subtitle: String?
    var thumbnailURL: String?
    /// アルバム / プレイリストの収録曲。
    var songs: [Song]
    /// アーティストページの「人気の曲」「アルバム」などの棚。
    var sections: [HomeSection]

    var isEmpty: Bool { songs.isEmpty && sections.isEmpty }
}

/// NavigationStack で詳細ページへ遷移するときの経路。
struct BrowseRoute: Hashable {
    let browseID: String
    let title: String
    let kind: BrowsePage.Kind
    /// 遷移前に分かっているサムネイル (詳細取得までの間に表示しておく)
    var thumbnailURL: String?
}

extension HomeItem {
    /// このアイテムをタップしたときの遷移先。曲の場合は nil (その場で再生する)。
    var route: BrowseRoute? {
        switch self {
        case .song:
            return nil
        case .album(let a):
            return BrowseRoute(browseID: a.id, title: a.title,
                               kind: .album, thumbnailURL: a.thumbnailURL)
        case .playlist(let p):
            return BrowseRoute(browseID: p.id, title: p.title,
                               kind: .playlist, thumbnailURL: p.thumbnailURL)
        case .artist(let a):
            return BrowseRoute(browseID: a.id, title: a.title,
                               kind: .artist, thumbnailURL: a.thumbnailURL)
        }
    }
}

// MARK: - ローカルプレイリスト

/// 端末内に保存するプレイリスト。
/// YouTube 側のプレイリストとは独立していて、ログイン不要で使える。
struct LocalPlaylist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var songs: [Song]
    var createdAt: Date

    init(name: String, songs: [Song] = []) {
        self.id = UUID()
        self.name = name
        self.songs = songs
        self.createdAt = Date()
    }

    /// 一覧に出す 4 枚組サムネイル用の URL (足りなければ少ない枚数で返す)。
    var coverURLs: [String] {
        songs.compactMap(\.thumbnailURL).prefix(4).map { $0 }
    }

    var subtitleText: String {
        songs.isEmpty ? "空のプレイリスト" : "\(songs.count) 曲"
    }
}

// MARK: - 検索候補

/// 検索欄に出すサジェスト。
enum SearchSuggestion: Identifiable, Hashable {
    /// 単なる検索語の候補
    case query(String)
    /// 曲そのものの候補 (タップで直接再生できる)
    case song(Song)

    var id: String {
        switch self {
        case .query(let q): return "q:\(q)"
        case .song(let s):  return "s:\(s.id)"
        }
    }

    var text: String {
        switch self {
        case .query(let q): return q
        case .song(let s):  return s.title
        }
    }
}

// MARK: - 検索

/// 検索の絞り込み。値は本家 VIVI Music の `SearchFilter` から移植。
enum SearchFilter: String, CaseIterable, Identifiable {
    case all
    case song
    case video
    case album
    case artist
    case playlist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:      return "すべて"
        case .song:     return "曲"
        case .video:    return "動画"
        case .album:    return "アルバム"
        case .artist:   return "アーティスト"
        case .playlist: return "プレイリスト"
        }
    }

    /// InnerTube の `params`。`all` のときは付けない。
    var params: String? {
        switch self {
        case .all:      return nil
        case .song:     return "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
        case .video:    return "EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D"
        case .album:    return "EgWKAQIYAWoKEAkQChAFEAMQBA%3D%3D"
        case .artist:   return "EgWKAQIgAWoKEAkQChAFEAMQBA%3D%3D"
        case .playlist: return "EgeKAQQoADgBagwQDhAKEAMQBRAJEAQ%3D"
        }
    }
}

/// 検索結果の 1 区画。「すべて」では複数、それ以外では 1 つだけ返る。
struct SearchSection: Identifiable {
    let id = UUID()
    var title: String
    var items: [HomeItem]
}

// MARK: - ストリーム情報

/// `player` エンドポイントで解決した再生用ストリーム。
struct StreamInfo {
    var url: String
    /// バイト長。ダウンロード時の `&range=0-N` に使う (これが無いと CDN が切断する)。
    var contentLength: Int
    var mimeType: String
    var bitrate: Int
    /// URL を解決したクライアント名 (URL の `c=` パラメータ)。
    /// ダウンロード時に一致する User-Agent を送るために使う。
    var clientName: String
    /// 曲の長さ (秒)。player 応答の videoDetails から取れる。
    /// 検索を経由せず再生した曲でも正しい長さを表示するために使う。
    var durationSeconds: Int?

    /// この URL を発行した YouTubeClient の名前 (例: "IOS", "WEB_REMIX")。
    ///
    /// 再生の途中で 403 になったときに「同じクライアントをもう一度使わない」
    /// 判断をするために持つ。`clientName` は URL の `c=` パラメータで
    /// 用途が違うため、別のフィールドにしている。
    var resolvedBy: String = ""
}

// MARK: - 歌詞

/// 同期歌詞の 1 行。
struct LyricLine: Identifiable, Hashable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}

/// 歌詞の取得結果。
struct LyricResult {
    var synced: Bool
    var lines: [LyricLine]
    var plainText: String

    static let empty = LyricResult(synced: false, lines: [], plainText: "")

    var isEmpty: Bool { lines.isEmpty && plainText.isEmpty }
}
