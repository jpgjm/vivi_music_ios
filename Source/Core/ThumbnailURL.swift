//
//  ThumbnailURL.swift
//  ViviMusic
//
//  サムネイル URL を、表示サイズに見合った解像度へ差し替える。
//
//  YouTube のサムネイルには 2 系統ある。書き換え方が違うので分けて扱う。
//
//  (1) lh3.googleusercontent.com / yt3.ggpht.com — YouTube Music のジャケット
//      末尾に `=w60-h60-l90-rj` のようなサイズ指定が付く。
//      ここを差し替えれば任意の大きさで取れる。
//      `-c` を付けなければ切り取られず、指定は「収まる枠」として働く。
//
//  (2) i.ytimg.com/vi/<videoId>/<名前>.jpg — 動画のサムネイル
//      ファイル名で解像度が決まる。
//        mqdefault      320x180
//        hqdefault      480x360  (4:3。上下に黒帯が入る)
//        sddefault      640x480  (同上)
//        maxresdefault  1280x720 (16:9。黒帯なし)
//      `?sqp=...` が付いていると加工済みの小さい画像になるので、
//      名前を差し替えるときは query ごと落とす。
//
//  参考: Opaline の `Core/Common/ThumbnailURLPolicy.swift`
//        (https://github.com/verback2308/Opaline)
//
//  注意: maxresdefault は **存在しない動画がある**。
//        404 になったときに備えて、呼び出し側で元の URL に戻せるよう
//        `fallback` を用意しておくこと。
//

import Foundation

enum ThumbnailURL {

    /// 一覧・棚・ミニプレイヤー向けの大きさ。
    /// iPad でも 1 枚あたり 200pt 程度なので、これで十分足りる。
    static let listSize = 544

    /// プレイヤー画面向けの大きさ。
    /// iPad の全画面表示だと 1000pt を超えるため、それに見合う値にする。
    static let playerSize = 1280

    /// 指定した大きさに見合う URL へ差し替える。
    /// 書き換えられない形式の URL はそのまま返す。
    static func upgrade(_ url: String, size: Int) -> String {
        if let upgraded = upgradeGoogleImage(url, size: size) { return upgraded }
        if let upgraded = upgradeYTImage(url, size: size) { return upgraded }
        return url
    }

    /// プレイヤー用の高解像度 URL。取れなければ nil。
    static func highResolution(_ url: String?) -> String? {
        guard let url else { return nil }
        return upgrade(url, size: playerSize)
    }

    // MARK: - (1) Google の画像配信

    private static func upgradeGoogleImage(_ url: String, size: Int) -> String? {
        guard let range = url.range(of: "=w") else { return nil }
        // `-c` を付けないので切り取りは起きない。
        // 縦横比は元のまま、この枠に収まる大きさで返ってくる。
        return String(url[..<range.lowerBound]) + "=w\(size)-h\(size)-l90-rj"
    }

    // MARK: - (2) i.ytimg.com

    /// 大きさに見合うファイル名を選ぶ。
    ///
    /// 常に maxresdefault を要求しないのは、
    ///   - 一覧では 5〜10 倍の転送量になる
    ///   - maxres を持たない動画では 404 を挟むぶん表示が遅れる
    /// ため。Opaline も同じ理由で段階を分けている。
    private static func stem(forSize size: Int) -> String {
        switch size {
        case ..<321:  return "mqdefault"
        case ..<481:  return "hqdefault"
        case ..<641:  return "sddefault"
        default:      return "maxresdefault"
        }
    }

    private static func upgradeYTImage(_ url: String, size: Int) -> String? {
        guard var components = URLComponents(string: url),
              components.host?.hasSuffix("ytimg.com") == true else {
            return nil
        }

        // /vi/<videoId>/<名前>.jpg  または  /vi_webp/<videoId>/<名前>.webp
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 3,
              parts[0] == "vi" || parts[0] == "vi_webp" else {
            return nil
        }
        let videoID = parts[1]
        guard !videoID.isEmpty else { return nil }

        // webp 版は maxres が用意されていないことが多いので jpg に寄せる。
        components.path = "/vi/\(videoID)/\(stem(forSize: size)).jpg"
        // sqp が残っていると加工済みの小さい画像が返るため落とす。
        components.query = nil

        return components.url?.absoluteString
    }
}
