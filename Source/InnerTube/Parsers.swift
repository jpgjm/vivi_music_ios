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

    /// 2 列目の先頭に入る「種別ラベル」。
    ///
    /// 検索結果の行は、2 列目が "曲 • アーティスト名 • 3:45" のように
    /// **何であるか**から始まることがある。とくに上位の結果カードに
    /// ぶら下がる行は "曲 • 3:53" だけで、演者名がまったく入らない。
    /// これをそのまま演者として扱うと、一覧に「曲」と並んでしまう。
    ///
    /// 本家 Android 版は `Runs.clean()` で先頭の 1 組を落としている。
    /// こちらは語で判定する (誤って人名を落とさないため)。
    private static let typeLabels: Set<String> = [
        "曲", "動画", "アルバム", "シングル", "EP", "プレイリスト",
        "アーティスト", "エピソード", "ポッドキャスト",
        "Song", "Video", "Album", "Single", "Playlist",
        "Artist", "Episode", "Podcast",
    ]

    private static func isTypeLabel(_ text: String) -> Bool {
        typeLabels.contains(text.trimmingCharacters(in: .whitespaces))
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

    /// 一覧・棚に出すサムネイルの解像度を上げる。
    ///
    /// 以前は `=w` 形式 (YouTube Music のジャケット) しか扱えず、
    /// `i.ytimg.com/vi/...` 形式 (動画のサムネイル) は API が返した
    /// ままだった。そちらは mqdefault (320x180) のことが多く、
    /// iPad で見ると明らかに粗い。ThumbnailURL 側で両方扱う。
    static func upgradeThumbnail(_ url: String) -> String {
        ThumbnailURL.upgrade(url, size: ThumbnailURL.listSize)
    }

    // MARK: - 曲 (musicResponsiveListItemRenderer)

    /// 行に付いている `menu` から「アーティストを表示」「アルバムを表示」の
    /// browseId を拾う。
    ///
    /// プレイリストの曲では、2 列目のアーティスト名やアルバム名が
    /// **ただのテキストで、navigationEndpoint を持たない**ことがある。
    /// (声優名が並ぶキャラソンのプレイリストなどが典型)
    /// その場合でも menu 側には遷移先が入っているので、そちらから補う。
    ///
    /// 本家 Android 版が、一覧に出ていないアルバム名まで
    /// 曲メニューに出せているのはこの経路によるもの。
    private static func menuBrowseIDs(_ renderer: JSON) -> (artist: String?, album: String?) {
        var artist: String?
        var album: String?

        for item in renderer.path("menu", "menuRenderer", "items").array {
            let nav = item["menuNavigationItemRenderer"]
            guard nav.exists else { continue }

            let endpoint = nav.path("navigationEndpoint", "browseEndpoint")
            guard let browseID = endpoint["browseId"].string, !browseID.isEmpty else { continue }

            let icon = nav.path("icon", "iconType").string ?? ""
            let pageType = endpoint.path("browseEndpointContextSupportedConfigs",
                                         "browseEndpointContextMusicConfig",
                                         "pageType").string ?? ""

            // アイコン種別が最も確実。無い場合に備えて pageType と
            // browseId の接頭辞でも判定する。
            let isArtist = icon == "ARTIST"
                || pageType == "MUSIC_PAGE_TYPE_ARTIST"
                || (icon.isEmpty && pageType.isEmpty && browseID.hasPrefix("UC"))
            let isAlbum = icon == "ALBUM"
                || pageType == "MUSIC_PAGE_TYPE_ALBUM"
                || (icon.isEmpty && pageType.isEmpty && browseID.hasPrefix("MPREb"))

            if isArtist, artist == nil { artist = browseID }
            if isAlbum, album == nil { album = browseID }
        }

        return (artist, album)
    }

    /// 検索結果や Quick picks の 1 行を Song に変換する。
    ///
    /// - Parameter implicitArtist: 行に演者名が書かれていないときに使う演者。
    ///   上位の結果がアーティストのカードなら、ぶら下がる曲はそのアーティストの
    ///   曲なので、呼び出し側から渡してもらう。本家 Android 版と同じ考え方。
    static func song(fromResponsiveListItem renderer: JSON,
                     implicitArtist: (name: String, id: String?)? = nil) -> Song? {
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

        // 演者名の決め方。
        //   1. 呼び出し側が演者を知っているならそれ (アーティストカードの中身)
        //   2. アーティストへのリンクを持つ run
        //   3. 種別ラベル・再生時間を除いた最初の run
        let artistName: String
        if let implicitArtist {
            artistName = implicitArtist.name
        } else if let text = artistRun?["text"].string {
            artistName = text
        } else {
            artistName = runs.compactMap { $0["text"].string }
                .first { !isTypeLabel($0) && parseDuration($0) == nil }
                ?? "Unknown"
        }

        let artistID = artistRun?["navigationEndpoint"]["browseEndpoint"]["browseId"].string
            ?? implicitArtist?.id

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

        // flexColumns にリンクが無い行のために menu 側からも拾う。
        // 一覧の見た目は変わらないが、曲メニューからアルバム / アーティストへ
        // 飛べるようになる。
        let fromMenu = menuBrowseIDs(renderer)

        return Song(
            id: videoID,
            title: title,
            artist: artistName,
            album: albumName,
            albumID: albumID ?? fromMenu.album,
            durationSeconds: seconds,
            thumbnailURL: thumbnail(renderer),
            artistID: artistID ?? fromMenu.artist
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
    ///   上位の結果 / 曲 / 動画 / アルバム / アーティスト / プレイリスト
    /// のように分けて返す。それぞれ見出しを保ったまま取り出す。
    ///
    /// 棚の形は 3 通りある。
    ///   - `musicCardShelfRenderer`  : 上位の結果 (大きなカード + ぶら下がる行)
    ///   - `musicShelfRenderer`      : 見出しつきの一覧
    ///   - `itemSectionRenderer`     : **見出しの無い、素の行の並び**
    ///
    /// 3 つ目を捨てていたのが rev.80 までの取りこぼし。
    /// 上位の結果カードだけが出て、その下の「曲」が丸ごと消えていた。
    /// 本家 Android 版 (`YouTube.searchSummary`) と同じく、
    /// 素の行は種別ごとにまとめ直して見出しを付ける。
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
        // 見出しの無い並びに入っていた項目。最後に種別ごとにまとめる。
        var looseItems: [HomeItem] = []
        // どの形の棚が来たかの記録。取りこぼしを追えるようにログへ残す。
        var shelfKinds: [String] = []

        for shelf in shelves {
            // --- 上位の結果 (大きなカード 1 枚) ---
            let card = shelf["musicCardShelfRenderer"]
            if card.exists {
                shelfKinds.append("カード")
                let top = homeItem(fromCardShelf: card)

                // カードがアーティストなら、ぶら下がる曲はそのアーティストの曲。
                // 行には演者名が書かれていない ("曲 • 3:53" だけ) ので補う。
                var implicitArtist: (name: String, id: String?)?
                if case .artist(let artist)? = top {
                    implicitArtist = (artist.title, artist.id)
                }

                var items: [HomeItem] = []
                if let top { items.append(top) }
                for content in card["contents"].array {
                    let listItem = content["musicResponsiveListItemRenderer"]
                    if listItem.exists,
                       let item = homeItem(fromResponsiveListItem: listItem,
                                           implicitArtist: implicitArtist) {
                        items.append(item)
                    }
                }
                if !items.isEmpty {
                    let title = card["header"]["musicCardShelfHeaderBasicRenderer"]["title"]
                        .runsText ?? "上位の結果"
                    sections.append(SearchSection(title: title, items: deduplicated(items)))
                }
                continue
            }

            // --- 見出しつきの一覧 (曲 / 動画 / アルバム / アーティスト / プレイリスト) ---
            let musicShelf = shelf["musicShelfRenderer"]
            if musicShelf.exists {
                shelfKinds.append("一覧")
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
                        items: deduplicated(items)
                    ))
                }
                continue
            }

            // --- 見出しの無い、素の行の並び ---
            //
            // ここに「曲」がまとめて入ってくることがある。
            // 見出しが無いので、種別ごとに分けて後でまとめる。
            let itemSection = shelf["itemSectionRenderer"]
            if itemSection.exists {
                shelfKinds.append("素の並び")
                for content in itemSection["contents"].array {
                    let listItem = content["musicResponsiveListItemRenderer"]
                    if listItem.exists, let item = homeItem(fromResponsiveListItem: listItem) {
                        looseItems.append(item)
                    }
                }
                continue
            }

            // --- 横スクロールの棚 (関連アーティストなど) ---
            let carousel = shelf["musicCarouselShelfRenderer"]
            if carousel.exists {
                shelfKinds.append("横スクロール")
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
                        items: deduplicated(items)
                    ))
                }
                continue
            }

            // どれにも当てはまらない棚。取りこぼしを追えるよう鍵の名前を残す。
            let keys = shelf.dictionary.keys.sorted().joined(separator: ",")
            shelfKinds.append("不明(\(keys.isEmpty ? "-" : keys))")
        }

        // 見出しの無かった項目を種別ごとにまとめて後ろに足す。
        sections.append(contentsOf: groupedSections(from: looseItems))

        if !shelfKinds.isEmpty {
            EventLog.log(.search,
                         message: "棚の内訳: " + shelfKinds.joined(separator: " / ")
                             + (looseItems.isEmpty ? "" : " → 素の並び \(looseItems.count) 件を分類"))
        }

        return sections
    }

    /// 同じ項目が二重に並ばないようにする (id で判定)。
    private static func deduplicated(_ items: [HomeItem]) -> [HomeItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// 検索の 1 ページ目から「続き」のトークンを取り出す。
    ///
    /// 検索の続きは **musicShelfRenderer に付く**。
    /// ホームのように sectionListRenderer に付くのではないので、
    /// `continuationToken(_:)` とは別に用意する。
    static func searchContinuationToken(_ json: JSON) -> String? {
        var shelves = json.path("contents", "tabbedSearchResultsRenderer", "tabs", "0",
                                "tabRenderer", "content",
                                "sectionListRenderer", "contents").array
        if shelves.isEmpty {
            shelves = json.path("contents", "sectionListRenderer", "contents").array
        }

        for shelf in shelves {
            let musicShelf = shelf["musicShelfRenderer"]
            if musicShelf.exists, let token = continuation(in: musicShelf) {
                return token
            }
        }
        return nil
    }

    /// 検索の続き (2 ページ目以降) の応答を読む。
    ///
    /// 応答の形は 2 通りある。
    ///   旧形式: `continuationContents.musicShelfContinuation.contents`
    ///   新形式: `onResponseReceivedActions[].appendContinuationItemsAction
    ///            .continuationItems`
    /// どちらでも読めるようにしておく。
    ///
    /// さらに次のページがあれば、そのトークンも一緒に返す。
    /// 終端に達するとトークンが消えるので nil になる。
    static func searchContinuation(_ json: JSON) -> (items: [HomeItem], continuation: String?) {
        let shelf = json.path("continuationContents", "musicShelfContinuation")
        var rows: [JSON] = shelf.exists ? shelf["contents"].array : []

        if rows.isEmpty {
            for action in json["onResponseReceivedActions"].array {
                let appended = action.path("appendContinuationItemsAction",
                                           "continuationItems").array
                rows.append(contentsOf: appended)
            }
        }

        var items: [HomeItem] = []
        var token: String?

        for row in rows {
            let listItem = row["musicResponsiveListItemRenderer"]
            if listItem.exists, let item = homeItem(fromResponsiveListItem: listItem) {
                items.append(item)
                continue
            }
            // 並びの最後に「さらに続きがある」印が入る
            if let next = row.path("continuationItemRenderer",
                                   "continuationEndpoint",
                                   "continuationCommand", "token").string,
               !next.isEmpty {
                token = next
            }
        }

        // 旧形式では棚そのものに次のトークンが付く
        if token == nil, shelf.exists {
            token = continuation(in: shelf)
        }

        return (deduplicated(items), token)
    }

    /// 見出しの無い項目を、曲 / アルバム / アーティスト / プレイリストに分けて
    /// 見出しつきの区画にする。並び順は本家 Android 版に合わせる。
    private static func groupedSections(from items: [HomeItem]) -> [SearchSection] {
        guard !items.isEmpty else { return [] }
        let unique = deduplicated(items)

        var result: [SearchSection] = []

        func add(_ title: String, _ picked: [HomeItem]) {
            guard !picked.isEmpty else { return }
            result.append(SearchSection(title: title, items: picked))
        }

        add("曲", unique.filter { if case .song = $0 { return true } else { return false } })
        add("アルバム", unique.filter { if case .album = $0 { return true } else { return false } })
        add("アーティスト", unique.filter { if case .artist = $0 { return true } else { return false } })
        add("プレイリスト", unique.filter { if case .playlist = $0 { return true } else { return false } })

        return result
    }

    /// リスト行を種別つきの項目に変換する。
    ///
    /// 検索結果の行は曲とは限らず、アルバム・アーティスト・プレイリストも
    /// 同じ `musicResponsiveListItemRenderer` で来る。
    /// `watchEndpoint` があれば曲、無ければ `browseEndpoint` の種別で振り分ける。
    static func homeItem(fromResponsiveListItem renderer: JSON,
                         implicitArtist: (name: String, id: String?)? = nil) -> HomeItem? {
        // 曲 (再生できるもの) を先に判定する
        if let s = song(fromResponsiveListItem: renderer, implicitArtist: implicitArtist) {
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

    // MARK: - continuation トークン

    /// browse レスポンスから「次のページ」のトークンを取り出す。
    ///
    /// ホーム (FEmusic_home) は初回応答に先頭の数棚しか含まれず、
    /// 残りはこのトークンを使った追加リクエストで返ってくる。
    /// 本家 VIVI Music の `YouTube.home()` / `homeContinuation()` と同じ考え方。
    ///
    /// 応答の形が数通りあるので、候補を順に見て最初に見つかったものを返す。
    /// 終端に達するとトークン自体が消えるので nil が返る。
    static func continuationToken(_ json: JSON) -> String? {
        // 初回応答 (1 カラム)
        let single = json.path("contents", "singleColumnBrowseResultsRenderer", "tabs", "0",
                               "tabRenderer", "content", "sectionListRenderer")
        if let token = continuation(in: single) { return token }

        // 初回応答 (2 カラム / デスクトップ形式)
        let two = json.path("contents", "twoColumnBrowseResultsRenderer", "tabs", "0",
                            "tabRenderer", "content", "sectionListRenderer")
        if let token = continuation(in: two) { return token }

        // タブを介さず直接 sectionListRenderer が来るケース
        let direct = json.path("contents", "sectionListRenderer")
        if let token = continuation(in: direct) { return token }

        // continuation 応答 (2 ページ目以降)
        let cont = json.path("continuationContents", "sectionListContinuation")
        if let token = continuation(in: cont) { return token }

        return nil
    }

    /// sectionListRenderer 相当のノードから continuation トークンを抜く。
    ///
    /// 2 通りの置き場所がある:
    ///   旧形式: `continuations[].nextContinuationData.continuation`
    ///   新形式: `contents[].continuationItemRenderer
    ///            .continuationEndpoint.continuationCommand.token`
    /// YouTube 側が段階的に移行しているため両方見る。
    private static func continuation(in node: JSON) -> String? {
        guard node.exists else { return nil }

        // 旧形式
        for entry in node["continuations"].array {
            if let token = entry.path("nextContinuationData", "continuation").string,
               !token.isEmpty {
                return token
            }
            if let token = entry.path("nextRadioContinuationData", "continuation").string,
               !token.isEmpty {
                return token
            }
        }

        // 新形式
        // ※ `reloadContinuationData` は「同じページの再取得」用なので採用しない。
        //   採用すると同じ内容を延々と読み続ける無限ループになる。
        for entry in node["contents"].array {
            if let token = entry.path("continuationItemRenderer",
                                      "continuationEndpoint",
                                      "continuationCommand", "token").string,
               !token.isEmpty {
                return token
            }
        }

        return nil
    }

    // MARK: - アカウント

    /// `account/account_menu` の応答からログイン中のアカウント名を取り出す。
    ///
    /// 未認証だと `activeAccountHeaderRenderer` 自体が返らないので、
    /// nil が返ること自体が「Cookie が効いていない」証拠になる。
    static func accountName(_ json: JSON) -> String? {
        for action in json["actions"].array {
            let header = action.path("openPopupAction", "popup",
                                     "multiPageMenuRenderer", "header",
                                     "activeAccountHeaderRenderer")
            guard header.exists else { continue }
            if let name = header["accountName"].runsText, !name.isEmpty {
                return name
            }
        }
        return nil
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
        // 重要 1: iOS の AVPlayer は WebM コンテナと Opus コーデックを再生できない。
        // YouTube は高音質側として opus (itag 249/250/251) を返してくるため、
        // 単純に「ビットレート最大」で選ぶとほぼ全曲が
        //   AVPlayerItem.status = failed | Cannot Open
        // で落ちる。AAC (audio/mp4, itag 139/140/141) だけに絞る必要がある。
        //
        // 重要 2: **URL を持たない形式は候補にできない。**
        // TVHTML5 の応答は adaptiveFormats に url も signatureCipher も持たず、
        // streamingData.serverAbrStreamingUrl 経由でしか取れない (SABR)。
        // ここで弾いておかないと「一番音質の良い形式」として SABR 専用の
        // itag 140 を掴んでしまい、URL が無いまま失敗して
        // muxed へのフォールバックにも進めない。
        // -------------------------------------------------------------------
        let mp4Audio = audioFormats.filter {
            ($0["mimeType"].string ?? "").hasPrefix("audio/mp4")
        }
        let rejected = audioFormats.count - mp4Audio.count
        if rejected > 0 {
            EventLog.log(.resolveOK, videoID: videoID,
                         message: "iOS 非対応の音声形式を \(rejected) 件除外 (webm/opus)")
        }

        let playable = mp4Audio.filter { $0["url"].string != nil }
        let sabrOnly = mp4Audio.count - playable.count
        if sabrOnly > 0 {
            EventLog.log(.resolveOK, videoID: videoID,
                         message: "URL を持たない音声形式を \(sabrOnly) 件除外 (SABR 専用)")
        }

        // 再生可能なものの中で最高ビットレートを選ぶ
        let chosen = playable.max { a, b in
            (a["bitrate"].int ?? 0) < (b["bitrate"].int ?? 0)
        }

        // 音声のみが無ければ muxed (formats) にフォールバック。
        // こちらも mp4 かつ URL を持つものに限定する。
        // TVHTML5 で再生できるのは実質この経路 (itag 18) だけになる。
        let muxed = json["streamingData"]["formats"].array.filter {
            ($0["mimeType"].string ?? "").contains("mp4") && $0["url"].string != nil
        }
        let fallback = muxed.max { a, b in
            (a["bitrate"].int ?? 0) < (b["bitrate"].int ?? 0)
        }

        if chosen == nil, fallback != nil {
            EventLog.log(.resolveOK, videoID: videoID,
                         message: "音声のみの形式が使えないため muxed で再生します"
                             + " (音質は下がります)")
        }

        guard let format = chosen ?? fallback,
              let url = format["url"].string else {
            // 何が来ていたのかを残しておくと次の調査が早い
            let seen = audioFormats
                .compactMap { $0["mimeType"].string?.split(separator: ";").first.map(String.init) }
                .joined(separator: ", ")
            let hasSABR = json["streamingData"]["serverAbrStreamingUrl"].string != nil
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "再生可能な形式なし。返ってきた形式: [\(seen)]"
                             + (hasSABR ? " / SABR 専用応答" : ""))
            throw InnerTubeError.noStream(videoID: videoID)
        }

        // URL の c= パラメータから解決元クライアント名を取る
        let clientName = clientNameFromURL(url)

        return StreamInfo(
            url: url,
            contentLength: format["contentLength"].int ?? 0,
            mimeType: format["mimeType"].string ?? "audio/mp4",
            bitrate: format["bitrate"].int ?? 0,
            clientName: clientName,
            durationSeconds: json["videoDetails"]["lengthSeconds"].int
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
