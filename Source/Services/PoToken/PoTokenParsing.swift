//
//  PoTokenParsing.swift
//  ViviMusic
//
//  BotGuard のチャレンジ応答を JavaScript に渡せる形に整える処理。
//  本家 VIVI Music の `potoken/JavaScriptUtil.kt` の移植。
//
//  YouTube の /api/jnn/v1/Create は、JSON 配列の中に
//  「base64 風に符号化され、各バイトに 97 を足してずらされた」文字列を返す。
//  これを元に戻すと、実際のチャレンジ内容 (インタプリタの JS 本体を含む) が出てくる。
//

import Foundation

enum PoTokenParsingError: LocalizedError {
    case badBase64
    case unexpectedShape(String)

    var errorDescription: String? {
        switch self {
        case .badBase64:
            return "base64 を復号できませんでした"
        case .unexpectedShape(let detail):
            return "チャレンジの形式が想定と違います (\(detail))"
        }
    }
}

enum PoTokenParsing {

    // MARK: - チャレンジ

    /// `/api/jnn/v1/Create` の応答を、JS の `runBotGuard()` に渡せる
    /// JSON 文字列に整形する。
    static func challengeData(from raw: String) throws -> String {
        guard let data = raw.data(using: .utf8) else {
            throw PoTokenParsingError.unexpectedShape("UTF-8 として読めない")
        }
        let scrambled = JSON(data: data)

        // 2 要素目が文字列なら、それがずらされたチャレンジ本体。
        // そうでなければ 1 要素目がそのままチャレンジ。
        let challenge: JSON
        if let encoded = scrambled[1].string {
            let descrambled = try descramble(encoded)
            guard let descrambledData = descrambled.data(using: .utf8) else {
                throw PoTokenParsingError.unexpectedShape("ずらし解除後が UTF-8 でない")
            }
            challenge = JSON(data: descrambledData)
        } else {
            challenge = scrambled[0]
        }

        guard let messageID = challenge[0].string,
              let interpreterHash = challenge[3].string,
              let program = challenge[4].string,
              let globalName = challenge[5].string else {
            throw PoTokenParsingError.unexpectedShape("必須項目が欠けている")
        }
        let experimentsBlob = challenge[7].string ?? ""

        // challenge[1] / challenge[2] は配列で、その中の文字列要素が
        // インタプリタの JS 本体 (または取得先 URL)。
        let safeScript = challenge[1].array.compactMap { $0.string }.first
        let trustedURL = challenge[2].array.compactMap { $0.string }.first

        var interpreter: [String: Any] = [:]
        interpreter["privateDoNotAccessOrElseSafeScriptWrappedValue"] =
            safeScript ?? NSNull()
        interpreter["privateDoNotAccessOrElseTrustedResourceUrlWrappedValue"] =
            trustedURL ?? NSNull()

        let payload: [String: Any] = [
            "messageId": messageID,
            "interpreterJavascript": interpreter,
            "interpreterHash": interpreterHash,
            "program": program,
            "globalName": globalName,
            "clientExperimentsStateBlob": experimentsBlob,
        ]

        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let json = String(data: encoded, encoding: .utf8) else {
            throw PoTokenParsingError.unexpectedShape("再符号化に失敗")
        }
        return json
    }

    // MARK: - integrityToken

    /// `/api/jnn/v1/GenerateIT` の応答から、
    /// JS に埋め込める `new Uint8Array([...])` と有効秒数を取り出す。
    static func integrityToken(from raw: String) throws -> (js: String, expiresIn: TimeInterval) {
        guard let data = raw.data(using: .utf8) else {
            throw PoTokenParsingError.unexpectedShape("UTF-8 として読めない")
        }
        let array = JSON(data: data)
        guard let tokenBase64 = array[0].string else {
            throw PoTokenParsingError.unexpectedShape("integrityToken がない")
        }
        let expiresIn = array[1].double ?? 3600
        let bytes = try decodeYouTubeBase64(tokenBase64)
        return (uint8ArrayLiteral(bytes), TimeInterval(expiresIn))
    }

    // MARK: - 変換ヘルパ

    /// 文字列を JS の `new Uint8Array([...])` リテラルにする。
    static func uint8ArrayLiteral(_ string: String) -> String {
        uint8ArrayLiteral(Array(string.utf8))
    }

    static func uint8ArrayLiteral(_ bytes: [UInt8]) -> String {
        "new Uint8Array([" + bytes.map(String.init).joined(separator: ",") + "])"
    }

    /// JS の `Uint8Array::toString()` 出力 ("97,98,99") を
    /// poToken 用の base64 (URL-safe) に変換する。
    static func base64FromByteList(_ list: String) -> String {
        let bytes = list.split(separator: ",").compactMap { UInt8($0.trimmingCharacters(in: .whitespaces)) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    /// YouTube 独自の base64 (`-` `_` `.` を使う) を復号する。
    static func decodeYouTubeBase64(_ input: String) throws -> [UInt8] {
        var normalized = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: ".", with: "=")

        // Swift の Data(base64Encoded:) はパディングに厳格なので補う
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: normalized) else {
            throw PoTokenParsingError.badBase64
        }
        return [UInt8](data)
    }

    /// base64 を復号し、各バイトに 97 を足して元の文字列に戻す。
    private static func descramble(_ scrambled: String) throws -> String {
        let bytes = try decodeYouTubeBase64(scrambled)
        // Kotlin 版は Byte (符号付き) に 97 を足しているので、
        // 同じ結果になるよう符号付きで計算してから戻す。
        let shifted = bytes.map { byte -> UInt8 in
            let signed = Int8(bitPattern: byte)
            return UInt8(bitPattern: signed &+ 97)
        }
        guard let text = String(bytes: shifted, encoding: .utf8) else {
            throw PoTokenParsingError.unexpectedShape("ずらし解除後が UTF-8 でない")
        }
        return text
    }
}
