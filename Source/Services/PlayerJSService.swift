//
//  PlayerJSService.swift
//  ViviMusic
//
//  YouTube の player JS (base.js) を取得し、そこから
//    1. signatureTimestamp (STS)
//    2. 署名復号関数        (signatureCipher の s= を復号する)
//    3. n 変換関数          (再生 URL の n= を変換する)
//  を取り出して使えるようにする。
//
//  ── なぜ必要か ────────────────────────────────────────────────
//  ログイン済みの再生は TVHTML5 でしか通せない (bot 判定を回避できる
//  唯一のクライアント)。ところが TVHTML5 は 3 段構えになっている。
//
//    (1) STS を送らないと再生情報自体を返さない
//        → playabilityStatus.reason = "ページを再読み込みする必要があります。"
//    (2) 再生情報を返しても、音声のみの形式には url も signatureCipher も
//        入っていない (SABR 専用)。署名付き URL を持つのは muxed の
//        itag 18 だけで、そこは `signatureCipher` で来る。
//    (3) 署名を復号しただけの URL は googlevideo に 403 で拒否される。
//        URL の `n` パラメータを base.js の関数で変換する必要がある。
//
//  実測 (2026-08-12):
//    署名復号のみ        → HTTP 403
//    署名復号 + n 変換   → HTTP 302 → 206  ← 再生可能
//
//  ANDROID_VR / IOS は復号済み URL をそのまま返し、その URL の n は
//  変換不要でそのまま 206 が返る。よって **n 変換は
//  signatureCipher から組み立てた URL にだけ適用する**。
//  素の url をいじると、今動いている経路を壊す。
//
//  ── 実装方針 ────────────────────────────────────────────────
//  base.js 全体を実行するのは無理 (DOM 前提の 2.8MB の JS)。
//  yt-dlp / NewPipe と同じく、**必要な関数だけを切り出して**
//  JavaScriptCore (iOS 標準搭載) で評価する。
//
//    var <外部依存の定数>;                  ← n 関数が typeof で存在確認する
//    var <ヘルパオブジェクト> = { ... };     ← 反転/スワップ/切り詰めの実体
//    var <署名復号関数> = function(a){ ... };
//    var <n 変換関数>   = function(a){ ... };
//    function __viviSig(s){ ... }
//    function __viviN(s){ ... }
//
//  ── どの base.js を使うか (重要) ────────────────────────────
//  同じ player ID でも base.js には複数のビルドがあり、
//  **復号関数が入っているのは player_ias_tce だけ** (2026-08 実測)。
//
//    /s/player/<id>/player_ias_tce.vflset/en_US/base.js  … STS + 復号 + n
//    /s/player/<id>/player_ias.vflset/en_US/base.js      … STS のみ
//    /s/player/<id>/player_es6.vflset/en_US/base.js      … STS のみ
//
//  ── 外部依存の定数について ──────────────────────────────────
//  n 変換関数の先頭には
//      if(typeof nna==="undefined")return a;
//  のような番人がいる。`nna` は base.js の別の場所で
//      var nna=-676135113;
//  と定義されている。これを一緒に切り出さないと、関数は例外も出さずに
//  **引数をそのまま返す** (=変換されず 403 のまま)。
//  静かに失敗するので、準備時に「入力と出力が変わるか」まで確認する。
//
//  ── 既知の限界 ──────────────────────────────────────────────
//  base.js は YouTube 側の都合で書き換わるため、切り出しの正規表現は
//  いつか合わなくなる。合わなくなったらログの「署名復号 可/不可」
//  「n 変換 可/不可」に出るので、そこを手がかりに追随する。
//  取り出せなかった場合も STS だけは使える形にして、他クライアントへの
//  フォールバックを妨げない。
//

import Foundation
import JavaScriptCore

actor PlayerJSService {
    static let shared = PlayerJSService()

    /// base.js の取り直し間隔。player JS はそう頻繁には変わらない。
    private static let ttl: TimeInterval = 12 * 60 * 60

    /// 取得に失敗した直後に何度も叩きに行かないための間隔。
    private static let failureBackoff: TimeInterval = 5 * 60

    /// n 関数の候補を探す範囲。関数本体は 5KB 前後なので十分な余裕を取る。
    private static let functionSearchWindow = 60_000

    /// 準備できた player JS 一式。
    private struct Prepared {
        let playerID: String
        /// 採用した base.js のビルド名 (player_ias_tce など)。ログ用。
        let variant: String
        let signatureTimestamp: Int
        /// 署名復号が使えるか。
        let canDecipher: Bool
        /// n 変換が使えるか。使えないと復号できても 403 になる。
        let canTransformN: Bool
        let context: JSContext
    }

    private var prepared: Prepared?
    private var preparedAt: Date?
    private var lastFailureAt: Date?

    /// 同時要求をまとめるための進行中タスク。
    private var inFlight: Task<Prepared?, Never>?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - 公開 API

    /// `player` 要求に入れる signatureTimestamp。取得できなければ nil。
    func signatureTimestamp() async -> Int? {
        await ensurePrepared()?.signatureTimestamp
    }

    /// 起動時に温めておくための入口。
    /// base.js は 2.8MB 前後あるので、最初の再生で待たされないよう先に取る。
    func warmUp() async {
        _ = await ensurePrepared()
    }

    /// player 応答の `streamingData` を走査し、`signatureCipher` しか
    /// 持たない形式に「復号 + n 変換」済みの `url` を埋めた JSON を返す。
    ///
    /// - `signatureCipher` が 1 つも無ければ **何もせず元の JSON を返す**
    ///   (ANDROID_VR / IOS はここを素通りする)。
    /// - 復号できなかった形式はそのまま残す。呼び出し側の
    ///   「再生可能な形式なし」判定に任せ、次のクライアントへ落ちる。
    func resolveStreamingURLs(in json: JSON, videoID: String) async -> JSON {
        guard var root = json.raw as? [String: Any],
              var streaming = root["streamingData"] as? [String: Any] else {
            return json
        }

        let keys = ["adaptiveFormats", "formats"]

        var needsWork = false
        for key in keys {
            guard let formats = streaming[key] as? [Any] else { continue }
            for element in formats {
                guard let format = element as? [String: Any] else { continue }
                if format["url"] == nil,
                   format["signatureCipher"] != nil || format["cipher"] != nil {
                    needsWork = true
                    break
                }
            }
            if needsWork { break }
        }
        guard needsWork else { return json }

        guard let prepared = await ensurePrepared(), prepared.canDecipher else {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "署名付き URL を復号できません (player JS 未準備)")
            return json
        }

        var deciphered = 0
        var failed = 0

        for key in keys {
            guard let formats = streaming[key] as? [Any] else { continue }
            let rewritten: [Any] = formats.map { element in
                guard var format = element as? [String: Any],
                      format["url"] == nil else {
                    return element
                }
                let cipher = (format["signatureCipher"] as? String)
                    ?? (format["cipher"] as? String)
                guard let cipher else { return element }

                if let url = resolvedURL(fromCipher: cipher, using: prepared) {
                    format["url"] = url
                    deciphered += 1
                    return format
                }
                failed += 1
                return element
            }
            streaming[key] = rewritten
        }

        root["streamingData"] = streaming

        let note = prepared.canTransformN ? "" : " / n 変換なし (403 の可能性)"
        if failed > 0 {
            EventLog.log(.resolveNG, videoID: videoID,
                         message: "署名復号: 成功 \(deciphered) / 失敗 \(failed)\(note)")
        } else {
            EventLog.log(.resolveOK, videoID: videoID,
                         message: "署名復号: \(deciphered) 形式\(note)")
        }

        return JSON(root)
    }

    /// base.js が差し替わったと疑われるときに捨てる。
    func invalidate() {
        prepared = nil
        preparedAt = nil
    }

    /// 既に組み上がっている URL に対して `n` 変換だけを施す。
    ///
    /// SABR の `serverAbrStreamingUrl` は署名撹拌 (`s=`) を含まず、
    /// **`n=` だけが変換前**の状態で降ってくる。
    /// そのまま POST すると googlevideo に 403 で拒否される。
    ///
    /// googlevideo (LuanRT) の公式サンプルでも
    ///   `await innertube.session.player?.decipher(server_abr_streaming_url)`
    /// と、必ず復号処理を通してから使っている。
    ///
    /// - Returns: 変換後の URL。JS を用意できなければ入力をそのまま返す。
    func decipher(_ urlString: String) async -> String {
        guard let prepared = await ensurePrepared(), prepared.canTransformN else {
            EventLog.log(.network, message: "n 変換を適用できない (JS 未準備)")
            return urlString
        }
        let result = transformingN(in: urlString, using: prepared.context)
        if result != urlString {
            EventLog.log(.network, message: "SABR URL に n 変換を適用")
        }
        return result
    }

    // MARK: - URL の組み立て

    /// `s=…&sp=…&url=…` を、復号済み署名 + 変換済み n を持つ URL に組み立てる。
    private func resolvedURL(fromCipher cipher: String,
                             using prepared: Prepared) -> String? {
        // cipher はクエリ文字列そのもの。URLComponents に食わせて分解する。
        guard let components = URLComponents(string: "?" + cipher),
              let items = components.queryItems else {
            return nil
        }

        var scrambled: String?
        var paramName = "signature"
        var base: String?

        for item in items {
            switch item.name {
            case "s":   scrambled = item.value
            case "sp":  paramName = item.value ?? paramName
            case "url": base = item.value
            default:    break
            }
        }

        guard var url = base else { return nil }

        // n を変換する。ここを飛ばすと googlevideo が 403 を返す。
        if prepared.canTransformN {
            url = transformingN(in: url, using: prepared.context)
        }

        // s が無ければ復号不要 (そのまま使える形で入っていることがある)
        guard let scrambled else { return url }

        guard let function = prepared.context.objectForKeyedSubscript("__viviSig"),
              !function.isUndefined,
              let result = function.call(withArguments: [scrambled]),
              !result.isUndefined,
              let signature = result.toString(),
              !signature.isEmpty else {
            return nil
        }

        let separator = url.contains("?") ? "&" : "?"
        let escaped = signature.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) ?? signature
        return "\(url)\(separator)\(paramName)=\(escaped)"
    }

    /// URL のクエリから `n=` だけを差し替える。
    ///
    /// URLComponents で組み直すと他のパラメータの
    /// パーセントエンコードが変わってしまい、`sparams` の署名検証に
    /// 落ちることがある。そこでクエリ文字列を文字列のまま分解し、
    /// 該当する要素だけを置き換える。
    private func transformingN(in url: String, using context: JSContext) -> String {
        guard let separatorIndex = url.firstIndex(of: "?") else { return url }

        let head = String(url[url.startIndex..<separatorIndex])
        let query = String(url[url.index(after: separatorIndex)...])

        var replaced = false
        let rebuilt = query.split(separator: "&", omittingEmptySubsequences: false)
            .map { pair -> String in
                let text = String(pair)
                guard !replaced, text.hasPrefix("n=") else { return text }
                let value = String(text.dropFirst(2))
                guard !value.isEmpty,
                      let function = context.objectForKeyedSubscript("__viviN"),
                      !function.isUndefined,
                      let output = function.call(withArguments: [value])?.toString(),
                      !output.isEmpty else {
                    return text
                }
                replaced = true
                return "n=" + output
            }
            .joined(separator: "&")

        return head + "?" + rebuilt
    }

    // MARK: - 準備

    private func ensurePrepared() async -> Prepared? {
        if let prepared, let preparedAt,
           Date().timeIntervalSince(preparedAt) < Self.ttl {
            return prepared
        }

        // 直前に失敗しているならしばらく諦める。
        // 再生のたびに 2.8MB を取りに行って待たされるのを防ぐ。
        if let lastFailureAt,
           Date().timeIntervalSince(lastFailureAt) < Self.failureBackoff {
            return nil
        }

        if let inFlight {
            return await inFlight.value
        }

        let task = Task<Prepared?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.prepare()
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func prepare() async -> Prepared? {
        let started = Date()

        guard let playerID = await currentPlayerID() else {
            lastFailureAt = Date()
            EventLog.log(.network, message: "player ID を特定できませんでした")
            return nil
        }

        // 復号関数が入っているのは player_ias_tce だけ (2026-08 実測)。
        // 将来 tce が消えたときのために順に試す。
        let variants = ["player_ias_tce", "player_ias", "player_es6"]

        var fallbackTimestamp: Int?
        var fallbackVariant: String?

        for variant in variants {
            guard let url = URL(string: "https://www.youtube.com/s/player/\(playerID)"
                                + "/\(variant).vflset/en_US/base.js") else {
                continue
            }
            guard let source = await fetchText(url: url) else { continue }
            guard let sts = extractSignatureTimestamp(from: source) else { continue }

            if fallbackTimestamp == nil {
                fallbackTimestamp = sts
                fallbackVariant = variant
            }

            guard let snippet = buildPlayerSnippet(from: source),
                  let context = makeContext(evaluating: snippet) else {
                continue
            }

            let canTransformN = verifyNTransform(in: context)
            let result = Prepared(
                playerID: playerID,
                variant: variant,
                signatureTimestamp: sts,
                canDecipher: true,
                canTransformN: canTransformN,
                context: context
            )
            prepared = result
            preparedAt = Date()
            lastFailureAt = nil

            EventLog.logDuration(
                .network, start: started,
                message: "player JS 準備完了 (\(playerID)/\(variant) / STS \(sts)"
                    + " / 署名復号 可 / n 変換 \(canTransformN ? "可" : "不可"))"
            )
            return result
        }

        // 復号関数はどのビルドからも取れなかった。
        // STS だけでも TVHTML5 の再生情報は取れるので、そこまでは通す。
        guard let sts = fallbackTimestamp, let variant = fallbackVariant,
              let context = JSContext() else {
            lastFailureAt = Date()
            EventLog.log(.network,
                         message: "player JS を準備できませんでした (\(playerID))")
            return nil
        }

        let result = Prepared(
            playerID: playerID,
            variant: variant,
            signatureTimestamp: sts,
            canDecipher: false,
            canTransformN: false,
            context: context
        )
        prepared = result
        preparedAt = Date()
        lastFailureAt = nil

        EventLog.logDuration(
            .network, start: started,
            message: "player JS 準備完了 (\(playerID)/\(variant) / STS \(sts)"
                + " / 署名復号 不可)"
        )
        return result
    }

    /// 切り出した JS を評価し、`__viviSig` が実際に動く JSContext を返す。
    /// 動かなければ nil (切り出しがずれている)。
    private func makeContext(evaluating snippet: String) -> JSContext? {
        guard let context = JSContext() else { return nil }
        context.exceptionHandler = { _, exception in
            let text = exception?.toString() ?? "不明"
            EventLog.log(.network, message: "player JS 例外: \(text)")
        }
        context.evaluateScript(snippet)

        guard let function = context.objectForKeyedSubscript("__viviSig"),
              !function.isUndefined else {
            return nil
        }

        // 実際に呼べるところまで確認する。
        // 撹拌は「入れ替え・切り詰め・反転」の組み合わせなので、
        // 出力は入力より短くなることはあっても空にはならない。
        let probe = "abcdefghijklmnopqrstuvwxyz0123456789ABCD"
        guard let output = function.call(withArguments: [probe])?.toString(),
              !output.isEmpty else {
            return nil
        }
        return context
    }

    /// n 変換が本当に働くかを確認する。
    ///
    /// n 関数は先頭で外部定数の存在を `typeof` で確認しており、
    /// それが無いと **例外も出さずに引数をそのまま返す**。
    /// 「入力と違う値が返ること」まで見ないと、使えないことに気づけない。
    private func verifyNTransform(in context: JSContext) -> Bool {
        guard let function = context.objectForKeyedSubscript("__viviN"),
              !function.isUndefined else {
            return false
        }
        let probe = "h-5C9emA_DjG-qkyE"
        guard let output = function.call(withArguments: [probe])?.toString(),
              !output.isEmpty else {
            return false
        }
        return output != probe
    }

    // MARK: - base.js の場所を特定する

    /// 現行 player の ID を返す。
    private func currentPlayerID() async -> String? {
        // 1) iframe_api の中に
        //    "\/s\/player\/<playerId>\/www-widgetapi.vflset\/www-widgetapi.js"
        //    という形で現行 player ID が入っている。
        if let url = URL(string: "https://www.youtube.com/iframe_api"),
           let text = await fetchText(url: url) {
            let unescaped = text.replacingOccurrences(of: "\\/", with: "/")
            if let playerID = firstMatch(in: unescaped,
                                         pattern: "/s/player/([0-9a-zA-Z_-]{4,})/") {
                return playerID
            }
        }

        // 2) 保険: 埋め込みページの "jsUrl" から拾い直す。
        if let url = URL(string: "https://www.youtube.com/embed/dQw4w9WgXcQ"),
           let text = await fetchText(url: url) {
            let unescaped = text.replacingOccurrences(of: "\\/", with: "/")
            if let playerID = firstMatch(in: unescaped,
                                         pattern: "/s/player/([0-9a-zA-Z_-]{4,})/") {
                return playerID
            }
        }

        return nil
    }

    // MARK: - base.js からの切り出し

    private func extractSignatureTimestamp(from js: String) -> Int? {
        let patterns = ["signatureTimestamp:(\\d{4,})", "\\bsts:(\\d{4,})"]
        for pattern in patterns {
            if let digits = firstMatch(in: js, pattern: pattern),
               let value = Int(digits) {
                return value
            }
        }
        return nil
    }

    /// 署名復号と n 変換に必要な JS を組み立てる。
    /// 署名復号が取れなければ nil (n だけあっても意味がない)。
    private func buildPlayerSnippet(from js: String) -> String? {
        guard let signature = findSignatureFunction(in: js),
              let helperName = helperObjectName(inFunctionBody: signature.body),
              let helperSource = findObjectLiteral(named: helperName, in: js) else {
            return nil
        }

        let nFunction = findNFunction(in: js)

        // 関数が `typeof X==="undefined"` で存在確認している外部定数を集める。
        // これが無いと n 関数は黙って引数をそのまま返す。
        var dependencySource = signature.declaration
        if let nFunction {
            dependencySource += nFunction.declaration
        }
        let dependencies = globalDependencies(in: js, referencedBy: dependencySource)

        var lines: [String] = dependencies
        lines.append("var \(helperSource);")
        lines.append(statement(for: signature.declaration))
        lines.append("function __viviSig(s){ return \(signature.name)(s); }")

        if let nFunction {
            lines.append(statement(for: nFunction.declaration))
            lines.append("function __viviN(s){ return \(nFunction.name)(s); }")
        }

        return lines.joined(separator: "\n")
    }

    /// `function 名前(a){…}` 形式ならそのまま文として置ける。
    /// `名前=function(a){…}` 形式は `var` を足して宣言にする。
    private func statement(for declaration: String) -> String {
        (declaration.hasPrefix("function") ? declaration : "var " + declaration) + ";"
    }

    /// `名前=function(引数){…}` 形式の署名復号関数を探す。
    /// 目印は「引数を split して、最後に join して返す」こと。
    private func findSignatureFunction(
        in js: String
    ) -> (name: String, declaration: String, body: String)? {
        // \\2 は 1 つ目の引数名への後方参照。
        // split の引数は "" のこともあれば定数配列参照のこともある。
        let splitArgument = "(?:\"\"|[a-zA-Z0-9$_]+\\[\\d+\\])"
        let patterns = [
            "\\b([a-zA-Z0-9$_]{2,})\\s*=\\s*function\\s*\\(\\s*([a-zA-Z0-9$_]+)\\s*\\)\\s*\\{"
                + "\\s*\\2\\s*=\\s*\\2\\.split\\(\\s*\(splitArgument)\\s*\\)",
            "\\bfunction\\s+([a-zA-Z0-9$_]{2,})\\s*\\(\\s*([a-zA-Z0-9$_]+)\\s*\\)\\s*\\{"
                + "\\s*\\2\\s*=\\s*\\2\\.split\\(\\s*\(splitArgument)\\s*\\)"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(js.startIndex..<js.endIndex, in: js)
            guard let match = regex.firstMatch(in: js, range: range),
                  match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: js),
                  let whole = Range(match.range, in: js) else {
                continue
            }
            // マッチ内の最初の `{` が関数本体の開始。
            guard let brace = js[whole].firstIndex(of: "{"),
                  let bodyRange = braceMatchedRange(in: js, openingAt: brace) else {
                continue
            }

            let body = String(js[bodyRange])
            // join で終わっていることを確認する (別の split 関数を掴まないため)
            guard body.contains(".join(") else { continue }

            // \b は幅ゼロなので whole の先頭が宣言の先頭になる。
            let declaration = String(js[whole.lowerBound..<bodyRange.upperBound])
            return (String(js[nameRange]), declaration, body)
        }
        return nil
    }

    /// n 変換関数を探す。
    ///
    /// この関数は名前も中身も毎回変わるが、末尾だけは特徴的で、
    ///
    ///     …catch(d){return "〜"+a}return b.join("")}
    ///
    /// という形で終わる (変換に失敗したら目印付きの文字列を返す)。
    /// そこを起点に、その `}` で閉じる関数宣言を逆向きに探す。
    private func findNFunction(
        in js: String
    ) -> (name: String, declaration: String)? {
        let tailPattern = "catch\\s*\\(\\s*[a-zA-Z0-9$_]+\\s*\\)\\s*\\{\\s*return\\s*"
            + "\"[^\"]*\"\\s*\\+\\s*[a-zA-Z0-9$_]+\\s*\\}\\s*return\\s+"
            + "[a-zA-Z0-9$_]+\\.join\\(\\s*\"\"\\s*\\)\\s*\\}"
        guard let tailRegex = try? NSRegularExpression(pattern: tailPattern) else {
            return nil
        }
        let full = NSRange(js.startIndex..<js.endIndex, in: js)
        guard let tail = tailRegex.firstMatch(in: js, range: full),
              let tailRange = Range(tail.range, in: js) else {
            return nil
        }

        // 終端の手前だけを候補探索の対象にする (全文を走査すると重い)。
        let windowStart = max(0, tail.range.location - Self.functionSearchWindow)
        let windowLength = tail.range.location + tail.range.length - windowStart
        let window = NSRange(location: windowStart, length: windowLength)

        let headPattern = "(?:var\\s+)?([a-zA-Z0-9$_]{2,})\\s*=\\s*function\\s*"
            + "\\(\\s*[a-zA-Z0-9$_]+\\s*\\)\\s*\\{"
        guard let headRegex = try? NSRegularExpression(pattern: headPattern) else {
            return nil
        }

        // 終端に近い候補から順に、本体がその終端で閉じるものを探す。
        let candidates = headRegex.matches(in: js, range: window)
        for match in candidates.reversed() {
            guard match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: js),
                  let whole = Range(match.range, in: js),
                  let brace = js[whole].firstIndex(of: "{"),
                  let bodyRange = braceMatchedRange(in: js, openingAt: brace),
                  bodyRange.upperBound == tailRange.upperBound else {
                continue
            }
            let declaration = String(js[nameRange.lowerBound..<bodyRange.upperBound])
            return (String(js[nameRange]), declaration)
        }
        return nil
    }

    /// 切り出した関数が `typeof X === "undefined"` で存在確認している
    /// 外部定数の宣言を base.js から集める。
    private func globalDependencies(in js: String,
                                    referencedBy snippet: String) -> [String] {
        let pattern = "typeof\\s+([a-zA-Z0-9$_]{2,})\\s*===?\\s*\"undefined\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(snippet.startIndex..<snippet.endIndex, in: snippet)

        var seen = Set<String>()
        var result: [String] = []

        for match in regex.matches(in: snippet, range: range) {
            guard match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: snippet) else {
                continue
            }
            let name = String(snippet[nameRange])
            guard seen.insert(name).inserted else { continue }

            let escaped = NSRegularExpression.escapedPattern(for: name)
            guard let declaration = firstMatchRange(
                in: js, pattern: "\\bvar\\s+\(escaped)\\s*="
            ) else {
                continue
            }
            guard let end = endOfExpression(in: js, from: declaration.upperBound) else {
                continue
            }
            result.append("var \(name)=\(String(js[declaration.upperBound..<end]));")
        }
        return result
    }

    // MARK: - JS を意識した走査

    /// `{` の位置から対応する `}` の次までの範囲を返す。
    /// 文字列・テンプレート・コメント・正規表現リテラルの中身は数えない。
    private func braceMatchedRange(
        in text: String,
        openingAt open: String.Index
    ) -> Range<String.Index>? {
        var depth = 0
        var index = open
        var previous: Character?

        while index < text.endIndex {
            let character = text[index]

            if let skipped = skipNonCode(in: text, at: index, previous: previous) {
                index = skipped.next
                previous = skipped.marker
                continue
            }

            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return open..<text.index(after: index)
                }
            }

            if !character.isWhitespace { previous = character }
            index = text.index(after: index)
        }
        return nil
    }

    /// `var X=` の右辺の終わり (深さ 0 の `;` または `,`) を返す。
    private func endOfExpression(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var index = start
        var previous: Character?

        while index < text.endIndex {
            let character = text[index]

            if let skipped = skipNonCode(in: text, at: index, previous: previous) {
                index = skipped.next
                previous = skipped.marker
                continue
            }

            switch character {
            case "(", "[", "{":
                depth += 1
            case ")", "]", "}":
                depth -= 1
            case ";", ",":
                if depth == 0 { return index }
            default:
                break
            }

            if !character.isWhitespace { previous = character }
            index = text.index(after: index)
        }
        return nil
    }

    /// コメント・文字列・正規表現リテラルなら、その次の位置まで飛ばす。
    /// コードとして扱ってよい位置なら nil。
    private func skipNonCode(
        in text: String,
        at index: String.Index,
        previous: Character?
    ) -> (next: String.Index, marker: Character)? {
        let character = text[index]
        let following = text.index(after: index)
        let next = following < text.endIndex ? text[following] : nil

        // 行コメント
        if character == "/", next == "/" {
            var cursor = following
            while cursor < text.endIndex, text[cursor] != "\n" {
                cursor = text.index(after: cursor)
            }
            return (cursor, "/")
        }

        // ブロックコメント
        if character == "/", next == "*" {
            var cursor = text.index(after: following)
            while cursor < text.endIndex {
                if text[cursor] == "*",
                   text.index(after: cursor) < text.endIndex,
                   text[text.index(after: cursor)] == "/" {
                    return (text.index(cursor, offsetBy: 2), "/")
                }
                cursor = text.index(after: cursor)
            }
            return (text.endIndex, "/")
        }

        // 正規表現リテラル。
        // 除算との区別は直前の意味のある文字で判断する
        // (演算子や開き括弧の直後なら正規表現)。
        if character == "/", isRegexPosition(previous) {
            var cursor = following
            var inCharacterClass = false
            while cursor < text.endIndex {
                let current = text[cursor]
                if current == "\\" {
                    cursor = text.index(cursor, offsetBy: 2, limitedBy: text.endIndex)
                        ?? text.endIndex
                    continue
                }
                if current == "\n" { return nil }   // 正規表現ではなかった
                if inCharacterClass {
                    if current == "]" { inCharacterClass = false }
                } else if current == "[" {
                    inCharacterClass = true
                } else if current == "/" {
                    return (text.index(after: cursor), "/")
                }
                cursor = text.index(after: cursor)
            }
            return nil
        }

        // 文字列 / テンプレート
        if character == "\"" || character == "'" || character == "`" {
            var cursor = following
            while cursor < text.endIndex {
                let current = text[cursor]
                if current == "\\" {
                    cursor = text.index(cursor, offsetBy: 2, limitedBy: text.endIndex)
                        ?? text.endIndex
                    continue
                }
                if current == character {
                    return (text.index(after: cursor), character)
                }
                cursor = text.index(after: cursor)
            }
            return (text.endIndex, character)
        }

        return nil
    }

    private func isRegexPosition(_ previous: Character?) -> Bool {
        guard let previous else { return true }
        return "(,=:[!&|?{};~+-*%^<>".contains(previous)
    }

    /// 関数本体で呼ばれているヘルパオブジェクトの名前を拾う。
    /// 本体は `a=a.split("");Xh.wS(a,3);…` の形なので、
    /// `名前.メソッド(` の最初の出現を取ればよい。
    private func helperObjectName(inFunctionBody body: String) -> String? {
        firstMatch(in: body,
                   pattern: "[;{]\\s*([a-zA-Z0-9$_]{2,})\\s*\\.\\s*[a-zA-Z0-9$_]+\\s*\\(")
    }

    /// `名前={ … }` を丸ごと切り出す (先頭の `var` は含めない)。
    private func findObjectLiteral(named name: String, in js: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "\\b\(escaped)\\s*=\\s*\\{"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(js.startIndex..<js.endIndex, in: js)

        // 同名の代入が複数あることがあるので、
        // 「中身に function を含む」最初のものを採用する。
        for match in regex.matches(in: js, range: range) {
            guard let whole = Range(match.range, in: js),
                  let brace = js[whole].firstIndex(of: "{"),
                  let bodyRange = braceMatchedRange(in: js, openingAt: brace) else {
                continue
            }
            let body = js[bodyRange]
            guard body.contains("function") else { continue }
            return name + "=" + String(body)
        }
        return nil
    }

    // MARK: - 下請け

    private func fetchText(url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        // 応答を安定させるため en 固定で取りに行く。
        req.setValue(YouTubeClient.userAgentWeb, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                EventLog.log(.network,
                             message: "player JS 取得 \(url.lastPathComponent) → HTTP \(status)")
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            if (error as? URLError)?.code != .cancelled {
                EventLog.logError(.network, error: error,
                                  context: "player JS 取得 \(url.lastPathComponent)")
            }
            return nil
        }
    }

    /// 正規表現の 1 番目のキャプチャを返す。
    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captured])
    }

    /// マッチ全体の範囲を返す。
    private func firstMatchRange(in text: String, pattern: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }
        return Range(match.range, in: text)
    }
}
