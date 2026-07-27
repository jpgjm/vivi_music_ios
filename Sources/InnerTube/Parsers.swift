//
//  Parsers.swift
//  ViviMusic
//
//  InnerTube の巨大な JSON をアプリのモデルに変換する。
//  構造はオリジナル VIVI Music の innertube/pages/*.kt に対応する。
//
//  InnerTube の項目には主に 2 形式ある:
//    - musicResponsiveListItemRenderer : リスト行 (検索結果 / Quick picks)
//    - musicTwoRowItemRenderer         : カード (ホームの横スクロール棚)
//  どちらも扱えるようにしておく。
//

import Foundation

enum Parsers {

    // MARK: - 共通ヘルパ

    /// `runs` を " • " などの区切りごとに分解して、区切り文字でない要素だけ返す。
    /// InnerTube は ["宇多田ヒカル", " • ", "アルバム", " • ", "2024"] のような形。
    static func meaningfulRuns(_ node: JSON) -> [JSON] {
        node.runs.filter { run in
            guard let t = run["text"].string else { return false }
            let trimmed = t.trimmingCharacters(in: .whitespaces)
            return trimmed != "•" && !trimmed.isEmpty
        }
    }

    /// runs を " • " で連結した文字列にする。
    static func subtitleText(_ node: JSON) -> String? {
        let parts = meaningfulRuns(node).compactMap { $0["text"].string }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " • ")
    }

    /// "3:45" 形式の文字列を秒に変換する。
    private static func parseDuration(_ text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// サムネイル URL を取り出す。renderer によって階層が違うので両方見る。
    static func thumbnail(_ renderer: JSON) -> String? {
        // musicResponsiveListItemRenderer 形式
        if let url = renderer["thumbnail"]["musicThumbnailRenderer"]["thumbnail"].bestThumbnailURL {
            return upgradeThumbnail(url)
        }
        // musicTwoRowItemRenderer 形式
        if let url = renderer["thumbnailRenderer"]["musicThumbnailRenderer"]["thumbnail"].bestThumbnailURL {
            return upgradeThumbnail(url)
        }
        return nil
    }

    /// YouTube のサムネ URL は末尾に `=w60-h60-...` とサイズが入っている。
    /// 大きい画像が欲しいので 544x544 に差し替える。
    static func upgradeThumbnail(_ url: String) -> String {
        guard let range = url.range(of: "=w") else { return url }
        return String(url[..<range.lowerBound]) + "=w544-h544-l90-rj"
    }

    // MARK: - 曲 (musicResponsiveListItemRenderer)

    /// 検索結果や Quick picks の 1 行を Song に変換する。
    static func song(fromResponsiveListItem renderer: JSON) -> Song? {
        // videoId は再生ボタンの watchEndpoint に入っている
        let videoID =
            renderer["overlay"]["musicItemThumbnailOverlayRenderer"]["content"]["musicPlayButtonRenderer"]["playNavigationEndpoint"]["watchEndpoint"]["videoId"].string
            ?? renderer["playlistItemData"]["videoId"].string
            ?? renderer["navigationEndpoint"]["watchEndpoint"]["videoId"].string

        guard let videoID else { return nil }

        let columns = renderer["flexColumns"].array
        guard let title = columns.first?["musicResponsiveListItemFlexColumnRenderer"]["text"].runsText
        else { return nil }

        // 2 列目に "アーティスト • アルバム • 再生時間" が入る
        let secondColumn = columns.count > 1
            ? columns[1]["musicResponsiveListItemFlexColumnRenderer"]["text"]
            : JSON.null
        let runs = meaningfulRuns(secondColumn)

        // browseId が UC で始まる run がアーティスト
        let artistRun = runs.first {
            $0["navigationEndpoint"]["browseEndpoint"]["browseId"].string?.hasPrefix("UC") == true
        }
        let artistName = artistRun?["text"].string
            ?? runs.first?["text"].string
            ?? "Unknown"
        let artistID = artistRun?["navigationEndpoint"]["browseEndpoint"]["browseId"].string

        // 最後の run が "3:45" 形式なら再生時間。
        // アルバム / プレイリストの行では flexColumns ではなく
        // fixedColumns に再生時間が入るため、そちらも見る。
        var seconds = parseDuration(runs.last?["text"].string)
        if seconds == nil {
            let fixed = renderer["fixedColumns"][0]["musicResponsiveListItemFlexColumnRenderer"]["text"]
            seconds = parseDuration(fixed.runsText)
        }

        // アルバム (browseId が MPREb_ で始まる run)。
        // 曲メニューから「アルバムを表示」できるよう browseId も持っておく。
        let albumRun = runs.first {
            $0.path("navigationEndpoint", "browseEndpoint", "browseId")
                .string?.hasPrefix("MPREb") == true
        }
        let albumName = albumRun?["text"].string
        let albumID = albumRun.flatMap {
            $0.path("navigationEndpoint", "browseEndpoint", "browseId").string
        }

        return Song(
            id: videoID,
            title: title,
            artist: artistName,
            album: albumName,
            albumID: albumID,
            durationSeconds: seconds,
            thumbnailURL: thumbnail(renderer),
            artistID: artistID
        )
    }

    // MARK: - カード (musicTwoRowItemRenderer)

    /// ホームの横スクロール棚にあるカード 1 枚を HomeItem に変換する。
    static func homeItem(fromTwoRowItem renderer: JSON) -> HomeItem? {
        guard let title = renderer["title"].runsText else { return nil }
        let thumb = thumbnail(renderer)
        let subtitle = subtitleText(renderer["subtitle"])

        // 曲: navigationEndpoint に watchEndpoint がある
        if let videoID = renderer["navigationEndpoint"]["watchEndpoint"]["videoId"].string {
            let runs = meaningfulRuns(renderer["subtitle"])
            let artistRun = runs.first {
                $0["navigationEndpoint"]["browseEndpoint"]["browseId"].string?.hasPrefix("UC") == true
            }
            return .song(Song(
                id: videoID,
                title: title,
                artist: artistRun?["text"].string ?? runs.first?["text"].string ?? "Unknown",
                album: nil,
                albumID: nil,
                durationSeconds: nil,
                thumbnailURL: thumb,
                artistID: artistRun?["navigationEndpoint"]["browseEndpoint"]["browseId"].string
            ))
        }

        // それ以外は browseEndpoint の browseId で種別を判定する
        let browse = renderer["navigationEndpoint"]["browseEndpoint"]
        guard let browseID = browse["browseId"].string else { return nil }

        // pageType でアルバム / プレイリスト / アーティストを見分ける
        let pageType = browse.path("browseEndpointContextSupportedConfigs",
                                   "browseEndpointContextMusicConfig",
                                   "pageType").string ?? ""

        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK":
            return .album(AlbumItem(id: browseID, title: title,
                                    subtitle: subtitle, thumbnailURL: thumb, year: nil))
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL":
            return .artist(ArtistItem(id: browseID, title: title,
                                      subtitle: subtitle, thumbnailURL: thumb))
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            return .playlist(PlaylistItem(id: browseID, title: title,
                                          subtitle: subtitle, thumbnailURL: thumb))
        default:
            // pageType が無い場合は browseId の接頭辞で推測する
            if browseID.hasPrefix("MPREb") {
                return .album(AlbumItem(id: browseID, title: title,
                                        subtitle: subtitle, thumbnailURL: thumb, year: nil))
            }
            if browseID.hasPrefix("UC") {
                return .artist(ArtistItem(id: browseID, title: title,
                                          subtitle: subtitle, thumbnailURL: thumb))
            }
            return .playlist(PlaylistItem(id: browseID, title: title,
                                          subtitle: subtitle, thumbnailURL: thumb))
        }
    }

    // MARK: - 検索結果

    /// 検索レスポンス全体から曲のリストを取り出す。
    static func searchSongs(_ json: JSON) -> [Song] {
        let sections = json.path("contents", "tabbedSearchResultsRenderer", "tabs", "0",
                                 "tabRenderer", "content",
                                 "sectionListRenderer", "contents").array

        var songs: [Song] = []
        for section in sections {
            let shelf = section["musicShelfRenderer"]
            guard shelf.exists else { continue }
            for content in shelf["contents"].array {
                let item = content["musicResponsiveListItemRenderer"]
                guard item.exists else { continue }
                if let s = song(fromResponsiveListItem: item) {
                    songs.append(s)
                }
            }
        }
        return songs
    }

    /// 検索レスポンスを区画ごとに分類して返す。
    ///
    /// 「すべて」で検索すると、YouTube Music は
    ///   Top result / Songs / Videos / Albums / Artists / Playlists
    /// のように複数の棚に分けて返す。それぞれ見出しを保ったまま取り出す。
    ///
    /// 絞り込み付きの検索では棚が 1 つだけになるが、同じ処理で扱える。
    static func searchSections(_ json: JSON) -> [SearchSection] {
        var shelves = json.path("contents", "tabbedSearchResultsRenderer", "tabs", "0",
                                "tabRenderer", "content",
                                "sectionListRenderer", "contents").array

        // 絞り込み検索では tabbedSearchResultsRenderer を挟まないことがある
        if shelves.isEmpty {
            shelves = json.path("contents", "sectionListRenderer", "contents").array
        }

        var sections: [SearchSection] = []

        for shelf in shelves {
            // --- Top result (大きなカード 1 枚) ---
            let card = shelf["musicCardShelfRenderer"]
            if card.exists {
                var items: [HomeItem] = []
                if let top = homeItem(fromCardShelf: card) {
                    items.append(top)
                }
                // カードの下にぶら下がる関連項目
                for content in card["contents"].array {
                    let listItem = content["musicResponsiveListItemRenderer"]
                    if listItem.exists, let item = homeItem(fromResponsiveListItem: listItem) {
                        items.append(item)
                    }
                }
                if !items.isEmpty {
                    let title = card["header"]["musicCardShelfHeaderBasicRenderer"]["title"]
                        .runsText ?? "上位の結果"
                    sections.append(SearchSection(title: title, items: items))
                }
                continue
            }

            // --- 通常の棚 (曲 / 動画 / アルバム / アーティスト / プレイリスト) ---
            let musicShelf = shelf["musicShelfRenderer"]
            if musicShelf.exists {
                let title = musicShelf["title"].runsText ?? ""
                var items: [HomeItem] = []
                for content in musicShelf["contents"].array {
                    let listItem = content["musicResponsiveListItemRenderer"]
                    if listItem.exists, let item = homeItem(fromResponsiveListItem: listItem) {
                        items.append(item)
                    }
                }
                if !items.isEmpty {
                    sections.append(SearchSection(
                        title: title.isEmpty ? "結果" : title,
                        items: items
                    ))
                }
                continue
            }

            // --- 横スクロールの棚 (関連アーティストなど) ---
            let carousel = shelf["musicCarouselShelfRenderer"]
            if carousel.exists {
                let header = carousel["header"]["musicCarouselShelfBasicHeaderRenderer"]
                let title = header["title"].runsText ?? ""
                var items: [HomeItem] = []
                for content in carousel["contents"].array {
                    let twoRow = content["musicTwoRowItemRenderer"]
                    if twoRow.exists, let item = homeItem(fromTwoRowItem: twoRow) {
                        items.append(item)
                    }
                }
                if !items.isEmpty {
                    sections.append(SearchSection(
                        title: title.isEmpty ? "関連" : title,
                        items: items
                    ))
                }
            }
        }

        return sections
    }

    /// リスト行を種別つきの項目に変換する。
    ///
    /// 検索結果の行は曲とは限らず、アルバム・アーティスト・プレイリストも
    /// 同じ `musicResponsiveListItemRenderer` で来る。
    /// `watchEndpoint` があれば曲、無ければ `browseEndpoint` の種別で振り分ける。
    static func homeItem(fromResponsiveListItem renderer: JSON) -> HomeItem? {
        // 曲 (再生できるもの) を先に判定する
        if let s = song(fromResponsiveListItem: renderer) {
            return .song(s)
        }

        let browse = renderer["navigationEndpoint"]["browseEndpoint"]
        guard let browseID = browse["browseId"].string else { return nil }

        let columns = renderer["flexColumns"].array
        guard let title = columns.first?["musicResponsiveListItemFlexColumnRenderer"]["text"]
            .runsText else { return nil }

        let secondColumn = columns.count > 1
            ? columns[1]["musicResponsiveListItemFlexColumnRenderer"]["text"]
            : JSON.null
        let subtitle = subtitleText(secondColumn)
        let thumb = thumbnail(renderer)

        return classify(browseID: browseID,
                        pageType: browse.path("browseEndpointContextSupportedConfigs",
                                              "browseEndpointContextMusicConfig",
                                              "pageType").string ?? "",
                        title: title,
                        subtitle: subtitle,
                        thumbnail: thumb)
    }

    /// Top result の大きなカードを項目に変換する。
    static func homeItem(fromCardShelf renderer: JSON) -> HomeItem? {
        guard let title = renderer["title"].runsText else { return nil }
        let subtitle = subtitleText(renderer["subtitle"])
        let thumb = renderer.path("thumbnail", "musicThumbnailRenderer", "thumbnail")
            .bestThumbnailURL.map(upgradeThumbnail)

        let onTap = renderer["onTap"]

        // 曲
        if let videoID = onTap["watchEndpoint"]["videoId"].string {
            let runs = meaningfulRuns(renderer["subtitle"])
            let artistRun = runs.first {
                $0.path("navigationEndpoint", "browseEndpoint", "browseId")
                    .string?.hasPrefix("UC") == true
            }
            return .song(Song(
                id: videoID,
                title: title,
                artist: artistRun?["text"].string ?? runs.first?["text"].string ?? "Unknown",
                album: nil,
                albumID: nil,
                durationSeconds: nil,
                thumbnailURL: thumb,
                artistID: artistRun.flatMap {
                    $0.path("navigationEndpoint", "browseEndpoint", "browseId").string
                }
            ))
        }

        // アルバム / アーティスト / プレイリスト
        let browse = onTap["browseEndpoint"]
        guard let browseID = browse["browseId"].string else { return nil }
        return classify(browseID: browseID,
                        pageType: browse.path("browseEndpointContextSupportedConfigs",
                                              "browseEndpointContextMusicConfig",
                                              "pageType").string ?? "",
                        title: title,
                        subtitle: subtitle,
                        thumbnail: thumb)
    }

    /// browseId と pageType から種別を決める。
    private static func classify(browseID: String,
                                 pageType: String,
                                 title: String,
                                 subtitle: String?,
                                 thumbnail thumb: String?) -> HomeItem {
        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK":
            return .album(AlbumItem(id: browseID, title: title,
                                    subtitle: subtitle, thumbnailURL: thumb, year: nil))
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL":
            return .artist(ArtistItem(id: browseID, title: title,
                                      subtitle: subtitle, thumbnailURL: thumb))
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            return .playlist(PlaylistItem(id: browseID, title: title,
                                          subtitle: subtitle, thumbnailURL: thumb))
        default:
            // pageType が無い場合は browseId の接頭辞で推測する
            if browseID.hasPrefix("MPREb") {
                return .album(AlbumItem(id: browseID, title: title,
                                        subtitle: subtitle, thumbnailURL: thumb, year: nil))
            }
            if browseID.hasPrefix("UC") {
                return .artist(ArtistItem(id: browseID, title: title,
                                          subtitle: subtitle, thumbnailURL: thumb))
            }
            return .playlist(PlaylistItem(id: browseID, title: title,
                                          subtitle: subtitle, thumbnailURL: thumb))
        }
    }

    // MARK: - ホーム / 探索

    /// browse レスポンスからセクション配列を取り出す。
    /// ホーム (FEmusic_home) も 探索 (FEmusic_explore) も同じ構造。
    static func sections(_ json: JSON) -> [HomeSection] {
        // 応答の形が数通りあるので、候補を順に試して最初に中身があったものを使う。
        var shelves = json.path("contents", "singleColumnBrowseResultsRenderer", "tabs", "0",
                                "tabRenderer", "content",
                                "sectionListRenderer", "contents").array

        // 2 カラム応答 (デスクトップ形式)
        if shelves.isEmpty {
            shelves = json.path("contents", "twoColumnBrowseResultsRenderer", "tabs", "0",
                                "tabRenderer", "content",
                                "sectionListRenderer", "contents").array
        }
        // 新着リリースなどはタブを介さず直接 sectionListRenderer が来る
        if shelves.isEmpty {
            shelves = json.path("contents", "sectionListRenderer", "contents").array
        }
        // continuation 応答
        if shelves.isEmpty {
            shelves = json["continuationContents"]["sectionListContinuation"]["contents"].array
        }
        // グリッドだけが直接返るケース (FEmusic_new_releases_albums など)。
        // この場合 sectionListRenderer を挟まず content 直下に gridRenderer が来るので、
        // content ノード自体を 1 枚の棚として扱う。
        if shelves.isEmpty {
            let content = json.path("contents", "singleColumnBrowseResultsRenderer",
                                    "tabs", "0", "tabRenderer", "content")
            if content["gridRenderer"].exists {
                shelves = [content]
            }
        }

        var result: [HomeSection] = []
        /// 対応していない棚の種類。次に何を実装すべきか分かるようログに残す。
        var unknownKinds = Set<String>()

        for shelf in shelves {
            // --- 横スクロールの棚 ---
            let carousel = shelf["musicCarouselShelfRenderer"]
            if carousel.exists {
                let header = carousel["header"]["musicCarouselShelfBasicHeaderRenderer"]
                let title = header["title"].runsText ?? ""
                let label = header["strapline"].runsText

                var items: [HomeItem] = []
                for content in carousel["contents"].array {
                    // カード形式
                    let twoRow = content["musicTwoRowItemRenderer"]
                    if twoRow.exists, let item = homeItem(fromTwoRowItem: twoRow) {
                        items.append(item)
                        continue
                    }
                    // リスト行形式 (Quick picks はこちら)
                    let listItem = content["musicResponsiveListItemRenderer"]
                    if listItem.exists, let s = song(fromResponsiveListItem: listItem) {
                        items.append(.song(s))
                    }
                }

                if !items.isEmpty {
                    result.append(HomeSection(title: title.isEmpty ? "おすすめ" : title,
                                              label: label, items: items))
                }
                continue
            }

            // --- 縦積みの棚 (新着リリースなど) ---
            let musicShelf = shelf["musicShelfRenderer"]
            if musicShelf.exists {
                let title = musicShelf["title"].runsText ?? ""
                var items: [HomeItem] = []
                for content in musicShelf["contents"].array {
                    let listItem = content["musicResponsiveListItemRenderer"]
                    if listItem.exists, let s = song(fromResponsiveListItem: listItem) {
                        items.append(.song(s))
                    }
                }
                if !items.isEmpty {
                    result.append(HomeSection(title: title.isEmpty ? "曲" : title,
                                              label: nil, items: items))
                }
                continue
            }

            // --- グリッド (アルバム一覧・新着リリースなど) ---
            let grid = shelf["gridRenderer"]
            if grid.exists {
                let title = grid["header"]["gridHeaderRenderer"]["title"].runsText ?? ""
                var items: [HomeItem] = []
                for content in grid["items"].array {
                    let twoRow = content["musicTwoRowItemRenderer"]
                    if twoRow.exists, let item = homeItem(fromTwoRowItem: twoRow) {
                        items.append(item)
                    }
                }
                // 新着リリースのグリッドはヘッダを持たないことがあるので
                // タイトルが空でも中身があれば採用する。
                if !items.isEmpty {
                    result.append(HomeSection(title: title.isEmpty ? "新着" : title,
                                              label: nil, items: items))
                }
                continue
            }

            // --- 未対応の棚 ---
            // どの renderer が来ているか分かればすぐ対応できるので記録しておく。
            // ただしヘッダ類は「棚」ではないので報告対象から外す (ノイズになる)。
            let headerKinds: Set<String> = [
                "musicResponsiveHeaderRenderer",
                "musicDetailHeaderRenderer",
                "musicImmersiveHeaderRenderer",
                "musicEditablePlaylistDetailHeaderRenderer",
            ]
            for key in shelf.dictionary.keys
            where key.hasSuffix("Renderer") && !headerKinds.contains(key) {
                unknownKinds.insert(key)
            }
        }

        if !unknownKinds.isEmpty {
            EventLog.log(.home,
                         message: "未対応の棚: \(unknownKinds.sorted().joined(separator: ", "))")
        }

        return result
    }

    // MARK: - 検索候補

    /// 検索候補レスポンスをパースする。
    /// 語句の候補 (searchSuggestionRenderer) と
    /// 曲そのものの候補 (musicResponsiveListItemRenderer) が混在して返る。
    static func searchSuggestions(_ json: JSON) -> [SearchSuggestion] {
        var result: [SearchSuggestion] = []

        for section in json["contents"].array {
            let contents = section["searchSuggestionsSectionRenderer"]["contents"].array
            for entry in contents {
                // 語句の候補
                let suggestion = entry["searchSuggestionRenderer"]
                if suggestion.exists {
                    if let text = suggestion["suggestion"].runsText, !text.isEmpty {
                        result.append(.query(text))
                    }
                    continue
                }
                // 曲の候補
                let listItem = entry["musicResponsiveListItemRenderer"]
                if listItem.exists, let s = song(fromResponsiveListItem: listItem) {
                    result.append(.song(s))
                }
            }
        }
        return result
    }

    // MARK: - 詳細ページ (アルバム / プレイリスト / アーティスト)

    /// browse レスポンスの「中身が入っている場所」を全部集める。
    ///
    /// InnerTube は同じ browse でも 2 通りの形で返してくる:
    ///   - singleColumnBrowseResultsRenderer  (1 カラム)
    ///   - twoColumnBrowseResultsRenderer     (2 カラム。曲リストは secondaryContents 側)
    /// どちらで来ても拾えるよう、候補をまとめて返す。
    private static func contentRoots(_ json: JSON) -> [JSON] {
        var roots: [JSON] = []

        let single = json.path("contents", "singleColumnBrowseResultsRenderer", "tabs", "0",
                               "tabRenderer", "content",
                               "sectionListRenderer", "contents")
        if single.exists { roots.append(contentsOf: single.array) }

        let twoPrimary = json.path("contents", "twoColumnBrowseResultsRenderer", "tabs", "0",
                                   "tabRenderer", "content",
                                   "sectionListRenderer", "contents")
        if twoPrimary.exists { roots.append(contentsOf: twoPrimary.array) }

        let twoSecondary = json.path("contents", "twoColumnBrowseResultsRenderer",
                                     "secondaryContents",
                                     "sectionListRenderer", "contents")
        if twoSecondary.exists { roots.append(contentsOf: twoSecondary.array) }

        return roots
    }

    /// 詳細ページのヘッダ (タイトル / サブタイトル / アートワーク) を取り出す。
    /// 新形式 musicResponsiveHeaderRenderer と旧形式 musicDetailHeaderRenderer の両対応。
    private static func header(_ json: JSON) -> (title: String?, subtitle: String?, thumb: String?) {
        // 新形式: sectionListRenderer の先頭に入っている
        for root in contentRoots(json) {
            let h = root["musicResponsiveHeaderRenderer"]
            guard h.exists else { continue }
            let title = h["title"].runsText
            // straplineTextOne にアーティスト名、subtitle に "アルバム • 2024" が入る
            let artist = h["straplineTextOne"].runsText
            let sub = subtitleText(h["subtitle"])
            let combined = [artist, sub].compactMap { $0 }.joined(separator: " • ")
            let thumb = h["thumbnail"]["musicThumbnailRenderer"]["thumbnail"].bestThumbnailURL
            return (title, combined.isEmpty ? nil : combined, thumb.map(upgradeThumbnail))
        }

        // 旧形式: トップレベルの header に入っている
        let detail = json["header"]["musicDetailHeaderRenderer"]
        if detail.exists {
            let thumb = detail["thumbnail"]["croppedSquareThumbnailRenderer"]["thumbnail"].bestThumbnailURL
            return (detail["title"].runsText,
                    subtitleText(detail["subtitle"]),
                    thumb.map(upgradeThumbnail))
        }

        // アーティストページは immersiveHeader
        let immersive = json["header"]["musicImmersiveHeaderRenderer"]
        if immersive.exists {
            let thumb = immersive["thumbnail"]["musicThumbnailRenderer"]["thumbnail"].bestThumbnailURL
            return (immersive["title"].runsText,
                    immersive["description"].runsText,
                    thumb.map(upgradeThumbnail))
        }

        return (nil, nil, nil)
    }

    /// 詳細ページ全体をパースする。
    /// - Parameters:
    ///   - kind: アルバム / プレイリスト / アーティストのどれか (UI の出し分けに使う)
    ///   - fallback: ヘッダが取れなかった場合に使うタイトル・サムネ
    static func browsePage(_ json: JSON,
                           kind: BrowsePage.Kind,
                           fallbackTitle: String,
                           fallbackThumbnail: String?) -> BrowsePage {
        let h = header(json)
        let roots = contentRoots(json)

        // --- 収録曲を集める ---
        var songs: [Song] = []
        var seen = Set<String>()

        for root in roots {
            // 曲リストは musicShelfRenderer か musicPlaylistShelfRenderer に入る
            for shelfKey in ["musicShelfRenderer", "musicPlaylistShelfRenderer"] {
                let shelf = root[shelfKey]
                guard shelf.exists else { continue }
                for content in shelf["contents"].array {
                    let item = content["musicResponsiveListItemRenderer"]
                    guard item.exists, var s = song(fromResponsiveListItem: item) else { continue }
                    guard !seen.contains(s.id) else { continue }
                    seen.insert(s.id)

                    // アルバムの行はアーティスト名やアートワークが省略されることがあるので
                    // ヘッダの情報で補う。
                    if kind == .album {
                        if s.thumbnailURL == nil { s.thumbnailURL = h.thumb ?? fallbackThumbnail }
                        if s.album == nil { s.album = h.title ?? fallbackTitle }
                    }
                    songs.append(s)
                }
            }
        }

        // --- 棚 (アーティストページの「人気の曲」「アルバム」など) ---
        // 既存の sections() をそのまま使えるので流用する。
        // ただし曲リストと重複する棚は落とす。
        var sections = self.sections(json)
        if !songs.isEmpty {
            sections = sections.filter { section in
                let ids = Set(section.items.compactMap { $0.song?.id })
                // 収録曲とほぼ同じ内容の棚は除外
                return ids.isEmpty || ids.subtracting(seen).count > ids.count / 2
            }
        }

        return BrowsePage(
            kind: kind,
            title: h.title ?? fallbackTitle,
            subtitle: h.subtitle,
            thumbnailURL: h.thumb ?? fallbackThumbnail,
            songs: songs,
            sections: sections
        )
    }

    // MARK: - 再生ストリーム

    /// `player` レスポンスから音声のみの最良ストリームを選ぶ。
    static func bestAudioStream(_ json: JSON, videoID: String) throws -> StreamInfo {
        // まず再生可否を確認する。年齢制限などはここで弾かれる。
        let status = json["playabilityStatus"]["status"].string ?? ""
        if status != "OK" {
            let reason = json["playabilityStatus"]["reason"].string
                ?? json["playabilityStatus"]["messages"][0].string
                ?? status
            throw InnerTubeError.playabilityBlocked(reason: reason)
        }

        let formats = json["streamingData"]["adaptiveFormats"].array
        let audioFormats = formats.filter {
            ($0["mimeType"].string ?? "").hasPrefix("audio/")
        }

        // -------------------------------------------------------------------
        // 重要: iOS の AVPlayer は WebM コンテナと Opus コーデックを再生できない。
        // YouTube は高音質側として opus (itag 249/250/251) を返してくるため、
        // 単純に「ビットレート最大」で選ぶとほぼ全曲が
        //   AVPlayerItem.status = failed | Cannot Open
        // で落ちる。AAC (audio/mp4, itag 139/140/141) だけに絞る必要がある。
        // -------------------------------------------------------------------
        let playable = audioFormats.filter {
            ($0["mimeType"].string ?? "").hasPrefix("audio/mp4")
        }
        let rejected = audioFormats.count - playable.count
        if rejected > 0 {
            EventLog.log(.resolveOK, videoID: videoID,
                         message: "iOS 非対応の音声形式を \(rejected) 件除外 (webm/opus)")
        }

        // 再生可能なものの中で最高ビットレートを選ぶ
        let chosen = playable.max { a, b in
            (a["bitrate"].int ?? 0) < (b["bitrate"].int ?? 0)
        }

        // 音声のみが無ければ muxed (formats) にフォールバック。
        // こちらも mp4 に限定する。
        let muxed = json["streamingData"]["formats"].array.filter {
            ($0["mimeType"].string ?? "").contains("mp4")
        }
        let fallback = muxed.max { a, b in
            (a["bitrate"].int ?? 0) < (b["bitrate"].int ?? 0)
        }

        guard let format = chosen ?? fallback,
              let url = format["url"].string else {
            // 何が来ていたのかを残しておくと次の調査が早い
            let seen = audioFormats
                .compactMap { $0["mimeType"].string?.split(separator: ";").first.map(String.init) }
                .joined(separator: ", ")
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "再生可能な形式なし。返ってきた形式: [\(seen)]")
            throw InnerTubeError.noStream(videoID: videoID)
        }

        // URL の c= パラメータから解決元クライアント名を取る
        let clientName = clientNameFromURL(url)

        return StreamInfo(
            url: url,
            contentLength: format["contentLength"].int ?? 0,
            mimeType: format["mimeType"].string ?? "audio/mp4",
            bitrate: format["bitrate"].int ?? 0,
            clientName: clientName
        )
    }

    /// 再生 URL に埋め込まれた `c=IOS` などのクライアント名を取り出す。
    static func clientNameFromURL(_ url: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "[?&]c=([A-Z0-9_]+)") else { return "" }
        let range = NSRange(url.startIndex..., in: url)
        guard let match = regex.firstMatch(in: url, range: range),
              let r = Range(match.range(at: 1), in: url) else { return "" }
        return String(url[r])
    }

    /// `player` レスポンスの videoDetails から Song を作る。
    static func song(fromPlayerResponse json: JSON, fallbackID: String) -> Song {
        let details = json["videoDetails"]
        return Song(
            id: details["videoId"].string ?? fallbackID,
            title: details["title"].string ?? "Unknown",
            artist: details["author"].string ?? "Unknown",
            album: nil,
            albumID: nil,
            durationSeconds: details["lengthSeconds"].int,
            thumbnailURL: details["thumbnail"].bestThumbnailURL,
            artistID: details["channelId"].string
        )
    }

    // MARK: - 関連曲

    /// `next` レスポンスからキュー継続用の曲リストを取り出す。
    static func relatedSongs(_ json: JSON) -> [Song] {
        let contents = json.path("contents", "singleColumnMusicWatchNextResultsRenderer",
                                 "tabbedRenderer", "watchNextTabbedResultsRenderer",
                                 "tabs", "0", "tabRenderer", "content",
                                 "musicQueueRenderer", "content",
                                 "playlistPanelRenderer", "contents").array

        var songs: [Song] = []
        for content in contents {
            let item = content["playlistPanelVideoRenderer"]
            guard item.exists, let videoID = item["videoId"].string else { continue }
            guard let title = item["title"].runsText else { continue }

            let runs = meaningfulRuns(item["longBylineText"])
            let artist = runs.first?["text"].string ?? "Unknown"
            let seconds = parseDuration(item["lengthText"].runsText)

            songs.append(Song(
                id: videoID,
                title: title,
                artist: artist,
                album: nil,
                albumID: nil,
                durationSeconds: seconds,
                thumbnailURL: item["thumbnail"].bestThumbnailURL
                    .map(upgradeThumbnail),
                artistID: nil
            ))
        }
        return songs
    }
}
