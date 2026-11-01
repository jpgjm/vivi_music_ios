//
//  EEL2Program.swift
//  ViviMusic
//
//  Phase 3-4: Bytecode コンパイル + Stack-based VM を導入。
//    - AST → Bytecode に変換して @init/@slider/@sample を実行
//    - 単純な算術・比較・論理・ビット演算・if/else/while/loop/三項演算子・
//      メモリアクセス・標準数学関数呼び出しは完全 bytecode 化
//    - ユーザー関数呼び出しと JamesDSP built-in DSP 関数は AST fallback
//      (Phase 3-4-2 で bytecode 化予定)
//    - AST インタプリタは fallback として残す (evaluate 関数)
//
//  Phase 3-3 で実装済み:
//    - 三項演算子 cond ? a : b
//    - 参照渡し function 引数 (function foo(*ref, val))
//    - JamesDSP 独自 built-in DSP 関数:
//        IIRBandSplitterInit(offset, srate, f1, f2) → 必要メモリセル数
//        IIRBandSplitterProcess(offset, in, *low, *mid, *high) → 0
//        memset(offset, count, value), memcpy(dst, src, count)
//        rms(offset, count)  RMS 計算
//    - 追加数学関数: sqr, invsqrt, sinh, cosh, tanh
//
//  Phase 3-2 で実装済み:
//    - @slider セクション、loop(n, body)、mem[]/x[]、ビット演算、簡易 function 定義
//  Phase 3-1 で実装済み:
//    - Tokenizer / Parser / AST インタプリタ
//    - @init / @sample セクション、算術・比較・論理、if/else、while
//    - 標準数学関数、$pi/$e
//
//  Phase 3-4 予定:
//    - Bytecode コンパイル (パフォーマンス改善)
//    - 他の JamesDSP DSP 関数 (FIRProcess, Compressor など)
//

import Foundation

// MARK: - スライダー宣言

struct EEL2Slider: Identifiable, Hashable {
    let id = UUID()
    let variableName: String
    var defaultValue: Double
    var minValue: Double
    var maxValue: Double
    var step: Double
    var label: String
}

// MARK: - AST

indirect enum EEL2Expr {
    case number(Double)
    case constant(EEL2Constant)
    case varRead(Int)
    case argRead(Int)
    case assign(Int, EEL2Expr)
    case argAssign(Int, EEL2Expr)
    case memoryRead(EEL2Expr, EEL2Expr)
    case memoryWrite(EEL2Expr, EEL2Expr, EEL2Expr)
    case binOp(BinOp, EEL2Expr, EEL2Expr)
    case unaryOp(UnaryOp, EEL2Expr)
    case ternary(EEL2Expr, EEL2Expr, EEL2Expr)   // cond ? then : else
    case funcCall(EEL2Function, [EEL2Expr])
    case builtinDspCall(EEL2Builtin, [EEL2Expr]) // JamesDSP 独自関数 (参照引数を含む)
    case userFuncCall(Int, [EEL2Expr])
    case ifElse(EEL2Expr, [EEL2Expr], [EEL2Expr])
    case whileLoop(EEL2Expr, [EEL2Expr])
    case loopN(EEL2Expr, [EEL2Expr])
}

enum BinOp {
    case add, sub, mul, div, mod, pow
    case eq, neq, lt, le, gt, ge
    case and, or
    case bitAnd, bitOr, bitXor, shl, shr
}

enum UnaryOp { case negate, not, bitNot }

enum EEL2Constant { case pi, e }

/// 標準数学関数 (値渡しのみ)
enum EEL2Function: String {
    case sin, cos, tan, asin, acos, atan, atan2
    case sqrt, exp, log, log10, pow
    case abs, floor, ceil, min, max, sign
    case sinh, cosh, tanh                      // Phase 3-3
    case sqr, invsqrt                          // Phase 3-3
}

/// JamesDSP 独自 built-in DSP 関数 (参照引数を含むもの)
/// 実装内で "参照引数" は AST の .varRead / .argRead を検出して対応する変数に直接書き込む。
enum EEL2Builtin: String {
    case iirBandSplitterInit    // (offset, srate, f1, f2) → reqSize
    case iirBandSplitterProcess // (offset, in, *low, *mid, *high) → 0
    case memset                 // (offset, count, value) → 0
    case memcpy                 // (dst, src, count) → 0
    case rms                    // (offset, count) → RMS 値
}

/// ユーザー定義関数
struct EEL2UserFunction {
    let name: String
    let argNames: [String]
    let argIsRef: [Bool]
    let body: [EEL2Expr]
}

// MARK: - パースエラー

enum EEL2ParseError: LocalizedError {
    case unexpectedCharacter(Character, line: Int)
    case unexpectedToken(String, line: Int)
    case unexpectedEndOfFile
    case unknownFunction(String, line: Int)
    case undefinedVariable(String)
    case tooManyVariables
    case invalidSliderDeclaration(String)
    case invalidLoopArguments(line: Int)
    case functionRedefinition(String, line: Int)
    case missingColonInTernary(line: Int)

    var errorDescription: String? {
        switch self {
        case .unexpectedCharacter(let c, let line):    return "予期しない文字 '\(c)' (行 \(line))"
        case .unexpectedToken(let s, let line):        return "予期しないトークン '\(s)' (行 \(line))"
        case .unexpectedEndOfFile:                     return "スクリプトが途中で終わっています"
        case .unknownFunction(let n, let line):        return "未知の関数 '\(n)' (行 \(line))"
        case .undefinedVariable(let n):                return "未定義の変数 '\(n)'"
        case .tooManyVariables:                        return "変数が多すぎます (最大 512)"
        case .invalidSliderDeclaration(let l):         return "無効なスライダー宣言: \(l)"
        case .invalidLoopArguments(let line):          return "loop() の引数が不正です (行 \(line))"
        case .functionRedefinition(let n, let line):   return "関数 '\(n)' が重複定義されています (行 \(line))"
        case .missingColonInTernary(let line):         return "三項演算子に ':' がありません (行 \(line))"
        }
    }
}

// MARK: - Tokenizer

enum EEL2Token: Equatable {
    case number(Double)
    case identifier(String)
    case sectionMarker(String)
    case op(String)
    case leftParen, rightParen
    case leftBrace, rightBrace
    case leftBracket, rightBracket
    case comma, semicolon, colon
    case question               // Phase 3-3: 三項演算子 ?
    case dollarIdent(String)
    case eof
}

final class EEL2Tokenizer {
    private let source: [Character]
    private var pos: Int = 0
    private var line: Int = 1

    init(_ source: String) {
        self.source = Array(source)
    }

    func tokenize() throws -> [(EEL2Token, Int)] {
        var tokens: [(EEL2Token, Int)] = []
        while pos < source.count {
            skipWhitespaceAndComments()
            if pos >= source.count { break }
            let c = source[pos]
            let tokLine = line
            if c.isNumber || (c == "." && pos + 1 < source.count && source[pos + 1].isNumber) {
                let n = try readNumber()
                tokens.append((.number(n), tokLine))
            } else if c.isLetter || c == "_" {
                let ident = readIdentifier()
                tokens.append((.identifier(ident), tokLine))
            } else if c == "$" {
                pos += 1
                let ident = readIdentifier()
                tokens.append((.dollarIdent(ident), tokLine))
            } else if c == "@" {
                pos += 1
                let ident = readIdentifier()
                tokens.append((.sectionMarker("@" + ident), tokLine))
            } else if let op = readOperator() {
                tokens.append((.op(op), tokLine))
            } else if c == "(" { pos += 1; tokens.append((.leftParen, tokLine))
            } else if c == ")" { pos += 1; tokens.append((.rightParen, tokLine))
            } else if c == "{" { pos += 1; tokens.append((.leftBrace, tokLine))
            } else if c == "}" { pos += 1; tokens.append((.rightBrace, tokLine))
            } else if c == "[" { pos += 1; tokens.append((.leftBracket, tokLine))
            } else if c == "]" { pos += 1; tokens.append((.rightBracket, tokLine))
            } else if c == "," { pos += 1; tokens.append((.comma, tokLine))
            } else if c == ";" { pos += 1; tokens.append((.semicolon, tokLine))
            } else if c == ":" { pos += 1; tokens.append((.colon, tokLine))
            } else if c == "?" { pos += 1; tokens.append((.question, tokLine))
            } else {
                throw EEL2ParseError.unexpectedCharacter(c, line: tokLine)
            }
        }
        tokens.append((.eof, line))
        return tokens
    }

    private func skipWhitespaceAndComments() {
        while pos < source.count {
            let c = source[pos]
            if c == "\n" { line += 1; pos += 1 }
            else if c.isWhitespace { pos += 1 }
            else if c == "/" && pos + 1 < source.count && source[pos + 1] == "/" {
                while pos < source.count && source[pos] != "\n" { pos += 1 }
            }
            else if c == "/" && pos + 1 < source.count && source[pos + 1] == "*" {
                pos += 2
                while pos + 1 < source.count && !(source[pos] == "*" && source[pos + 1] == "/") {
                    if source[pos] == "\n" { line += 1 }
                    pos += 1
                }
                if pos + 1 < source.count { pos += 2 }
            }
            else { break }
        }
    }

    private func readNumber() throws -> Double {
        let start = pos
        while pos < source.count && (source[pos].isNumber || source[pos] == ".") { pos += 1 }
        if pos < source.count && (source[pos] == "e" || source[pos] == "E") {
            pos += 1
            if pos < source.count && (source[pos] == "+" || source[pos] == "-") { pos += 1 }
            while pos < source.count && source[pos].isNumber { pos += 1 }
        }
        let str = String(source[start ..< pos])
        guard let value = Double(str) else {
            throw EEL2ParseError.unexpectedCharacter(source[start], line: line)
        }
        return value
    }

    private func readIdentifier() -> String {
        let start = pos
        while pos < source.count && (source[pos].isLetter || source[pos].isNumber || source[pos] == "_") {
            pos += 1
        }
        return String(source[start ..< pos])
    }

    private func readOperator() -> String? {
        if pos + 1 < source.count {
            let two = String([source[pos], source[pos + 1]])
            let twoOps: Set<String> = ["==", "!=", "<=", ">=", "&&", "||",
                                       "+=", "-=", "*=", "/=", "<<", ">>"]
            if twoOps.contains(two) { pos += 2; return two }
        }
        let one = source[pos]
        let oneOps: Set<Character> = ["+", "-", "*", "/", "%", "^", "=",
                                     "<", ">", "!", "&", "|", "~"]
        if oneOps.contains(one) { pos += 1; return String(one) }
        return nil
    }
}

// MARK: - Parser

final class EEL2Parser {

    struct Program {
        var desc: String
        var sliders: [EEL2Slider]
        var initSection: [EEL2Expr]
        var sliderSection: [EEL2Expr]
        var sampleSection: [EEL2Expr]
        var variableCount: Int
        var variableNames: [String]
        var variableIndices: [String: Int]
        var spl0Index: Int
        var spl1Index: Int
        var srateIndex: Int
        var sliderVarIndices: [Int]
        var userFunctions: [EEL2UserFunction]
    }

    private let tokens: [(EEL2Token, Int)]
    private var pos: Int = 0
    private var variableIndices: [String: Int] = [:]
    private var variableNames: [String] = []
    private var userFunctions: [EEL2UserFunction] = []
    private var userFunctionNameToIndex: [String: Int] = [:]
    private var currentFunctionArgMap: [String: Int]?

    static let maxVariables = 512

    static func parse(_ source: String) throws -> Program {
        let (cleanedSource, desc, sliders) = preprocess(source)
        let tokenizer = EEL2Tokenizer(cleanedSource)
        let tokens = try tokenizer.tokenize()
        let parser = EEL2Parser(tokens: tokens)

        let spl0Index = parser.getOrCreateVariable("spl0")
        let spl1Index = parser.getOrCreateVariable("spl1")
        let srateIndex = parser.getOrCreateVariable("srate")

        var sliderVarIndices: [Int] = []
        for s in sliders {
            let idx = parser.getOrCreateVariable(s.variableName)
            sliderVarIndices.append(idx)
        }

        var initSection: [EEL2Expr] = []
        var sliderSection: [EEL2Expr] = []
        var sampleSection: [EEL2Expr] = []

        while parser.pos < parser.tokens.count {
            if case .eof = parser.currentToken.0 { break }
            if case .identifier(let name) = parser.currentToken.0, name == "function" {
                try parser.parseFunctionDefinition()
                continue
            }
            if case .sectionMarker(let name) = parser.currentToken.0 {
                parser.advance()
                let body = try parser.parseSectionBody()
                switch name {
                case "@init":   initSection = body
                case "@slider": sliderSection = body
                case "@sample": sampleSection = body
                default:        break
                }
                continue
            }
            throw EEL2ParseError.unexpectedToken(parser.currentDescription, line: parser.currentToken.1)
        }

        return Program(
            desc: desc,
            sliders: sliders,
            initSection: initSection,
            sliderSection: sliderSection,
            sampleSection: sampleSection,
            variableCount: parser.variableNames.count,
            variableNames: parser.variableNames,
            variableIndices: parser.variableIndices,
            spl0Index: spl0Index,
            spl1Index: spl1Index,
            srateIndex: srateIndex,
            sliderVarIndices: sliderVarIndices,
            userFunctions: parser.userFunctions
        )
    }

    private init(tokens: [(EEL2Token, Int)]) {
        self.tokens = tokens
    }

    // MARK: 前処理

    static func preprocess(_ source: String) -> (String, String, [EEL2Slider]) {
        var desc = ""
        var sliders: [EEL2Slider] = []
        var cleanedLines: [String] = []

        let sliderRegex = try! NSRegularExpression(
            pattern: #"^\s*([A-Za-z_][A-Za-z_0-9]*)\s*:\s*(-?\d+(?:\.\d+)?)\s*<\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*>\s*(.*)$"#
        )
        let descRegex = try! NSRegularExpression(pattern: #"^\s*desc\s*:\s*(.*)$"#)

        for line in source.split(whereSeparator: { $0.isNewline }) {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { cleanedLines.append(raw); continue }

            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let m = descRegex.firstMatch(in: trimmed, range: range),
               let r = Range(m.range(at: 1), in: trimmed) {
                desc = String(trimmed[r]).trimmingCharacters(in: .whitespaces)
                cleanedLines.append("")
                continue
            }
            if let m = sliderRegex.firstMatch(in: trimmed, range: range) {
                func cap(_ i: Int) -> String? {
                    guard let r = Range(m.range(at: i), in: trimmed) else { return nil }
                    return String(trimmed[r])
                }
                if let name = cap(1),
                   let defVal = cap(2).flatMap(Double.init),
                   let minVal = cap(3).flatMap(Double.init),
                   let maxVal = cap(4).flatMap(Double.init),
                   let step = cap(5).flatMap(Double.init) {
                    let label = cap(6)?.trimmingCharacters(in: .whitespaces) ?? name
                    sliders.append(EEL2Slider(
                        variableName: name,
                        defaultValue: defVal,
                        minValue: minVal,
                        maxValue: maxVal,
                        step: max(0.0001, step),
                        label: label
                    ))
                    cleanedLines.append("")
                    continue
                }
            }
            cleanedLines.append(raw)
        }
        return (cleanedLines.joined(separator: "\n"), desc, sliders)
    }

    // MARK: トークン操作

    private var currentToken: (EEL2Token, Int) { tokens[pos] }
    private var currentDescription: String {
        switch currentToken.0 {
        case .number(let n):        return String(n)
        case .identifier(let s):    return s
        case .sectionMarker(let s): return s
        case .op(let s):            return s
        case .dollarIdent(let s):   return "$" + s
        case .leftParen:            return "("
        case .rightParen:           return ")"
        case .leftBrace:            return "{"
        case .rightBrace:           return "}"
        case .leftBracket:          return "["
        case .rightBracket:         return "]"
        case .comma:                return ","
        case .semicolon:            return ";"
        case .colon:                return ":"
        case .question:             return "?"
        case .eof:                  return "<EOF>"
        }
    }
    private var currentLine: Int { currentToken.1 }

    private func advance() { if pos < tokens.count - 1 { pos += 1 } }

    private func expect(_ token: EEL2Token) throws {
        if currentToken.0 == token { advance() }
        else { throw EEL2ParseError.unexpectedToken(currentDescription, line: currentLine) }
    }

    private func matchOp(_ op: String) -> Bool {
        if case .op(let s) = currentToken.0, s == op { advance(); return true }
        return false
    }

    // MARK: 変数管理

    private func getOrCreateVariable(_ name: String) -> Int {
        if let idx = variableIndices[name] { return idx }
        let idx = variableNames.count
        variableIndices[name] = idx
        variableNames.append(name)
        return idx
    }

    // MARK: - function 定義

    private func parseFunctionDefinition() throws {
        advance()  // 'function'
        guard case .identifier(let name) = currentToken.0 else {
            throw EEL2ParseError.unexpectedToken(currentDescription, line: currentLine)
        }
        let defLine = currentLine
        if userFunctionNameToIndex[name] != nil {
            throw EEL2ParseError.functionRedefinition(name, line: defLine)
        }
        advance()

        try expect(.leftParen)
        var argNames: [String] = []
        var argIsRef: [Bool] = []
        if case .rightParen = currentToken.0 {
            // 引数なし
        } else {
            let (n, isRef) = try parseFunctionArgDecl()
            argNames.append(n)
            argIsRef.append(isRef)
            while case .comma = currentToken.0 {
                advance()
                let (n2, isRef2) = try parseFunctionArgDecl()
                argNames.append(n2)
                argIsRef.append(isRef2)
            }
        }
        try expect(.rightParen)
        try expect(.leftParen)

        var argMap: [String: Int] = [:]
        for (i, a) in argNames.enumerated() { argMap[a] = i }
        currentFunctionArgMap = argMap
        defer { currentFunctionArgMap = nil }

        var body: [EEL2Expr] = []
        while true {
            if case .rightParen = currentToken.0 { break }
            if case .eof = currentToken.0 { throw EEL2ParseError.unexpectedEndOfFile }
            let s = try parseStatement()
            body.append(s)
            while case .semicolon = currentToken.0 { advance() }
        }
        try expect(.rightParen)
        while case .semicolon = currentToken.0 { advance() }

        let fn = EEL2UserFunction(name: name, argNames: argNames, argIsRef: argIsRef, body: body)
        userFunctionNameToIndex[name] = userFunctions.count
        userFunctions.append(fn)
    }

    /// 引数宣言のパース: `*name` (参照) または `name` (値渡し)
    private func parseFunctionArgDecl() throws -> (String, Bool) {
        var isRef = false
        if matchOp("*") { isRef = true }
        guard case .identifier(let name) = currentToken.0 else {
            throw EEL2ParseError.unexpectedToken(currentDescription, line: currentLine)
        }
        advance()
        return (name, isRef)
    }

    // MARK: セクション

    private func parseSectionBody() throws -> [EEL2Expr] {
        var stmts: [EEL2Expr] = []
        while true {
            if case .sectionMarker = currentToken.0 { break }
            if case .eof = currentToken.0 { break }
            if case .identifier(let n) = currentToken.0, n == "function" { break }
            let stmt = try parseStatement()
            stmts.append(stmt)
            while case .semicolon = currentToken.0 { advance() }
        }
        return stmts
    }

    private func parseStatement() throws -> EEL2Expr {
        if case .identifier(let name) = currentToken.0 {
            if name == "if" { return try parseIf() }
            if name == "while" { return try parseWhile() }
            if name == "loop" && peekIsLeftParen() { return try parseLoop() }
        }
        if case .leftBrace = currentToken.0 { return try parseBlock() }
        return try parseExpression()
    }

    private func peekIsLeftParen() -> Bool {
        if pos + 1 < tokens.count, case .leftParen = tokens[pos + 1].0 { return true }
        return false
    }

    private func parseBlock() throws -> EEL2Expr {
        try expect(.leftBrace)
        var stmts: [EEL2Expr] = []
        while true {
            if case .rightBrace = currentToken.0 { break }
            if case .eof = currentToken.0 { throw EEL2ParseError.unexpectedEndOfFile }
            let s = try parseStatement()
            stmts.append(s)
            while case .semicolon = currentToken.0 { advance() }
        }
        try expect(.rightBrace)
        return .ifElse(.number(1), stmts, [])
    }

    private func parseIf() throws -> EEL2Expr {
        advance()
        try expect(.leftParen)
        let cond = try parseExpression()
        try expect(.rightParen)
        let thenStmts = try parseThenOrElse()
        var elseStmts: [EEL2Expr] = []
        if case .identifier(let n) = currentToken.0, n == "else" {
            advance()
            elseStmts = try parseThenOrElse()
        }
        return .ifElse(cond, thenStmts, elseStmts)
    }

    private func parseThenOrElse() throws -> [EEL2Expr] {
        if case .leftBrace = currentToken.0 {
            try expect(.leftBrace)
            var stmts: [EEL2Expr] = []
            while true {
                if case .rightBrace = currentToken.0 { break }
                if case .eof = currentToken.0 { throw EEL2ParseError.unexpectedEndOfFile }
                let s = try parseStatement()
                stmts.append(s)
                while case .semicolon = currentToken.0 { advance() }
            }
            try expect(.rightBrace)
            return stmts
        } else {
            let s = try parseStatement()
            while case .semicolon = currentToken.0 { advance() }
            return [s]
        }
    }

    private func parseWhile() throws -> EEL2Expr {
        advance()
        try expect(.leftParen)
        let cond = try parseExpression()
        try expect(.rightParen)
        let body = try parseThenOrElse()
        return .whileLoop(cond, body)
    }

    private func parseLoop() throws -> EEL2Expr {
        let startLine = currentLine
        advance()
        try expect(.leftParen)
        let count = try parseExpression()
        var body: [EEL2Expr] = []
        if case .comma = currentToken.0 {
            advance()
            while true {
                if case .rightParen = currentToken.0 { break }
                if case .eof = currentToken.0 { throw EEL2ParseError.unexpectedEndOfFile }
                let s = try parseStatement()
                body.append(s)
                if case .semicolon = currentToken.0 {
                    while case .semicolon = currentToken.0 { advance() }
                } else if case .rightParen = currentToken.0 {
                    break
                } else if case .comma = currentToken.0 {
                    advance()
                }
            }
        } else {
            throw EEL2ParseError.invalidLoopArguments(line: startLine)
        }
        try expect(.rightParen)
        return .loopN(count, body)
    }

    // MARK: 式

    /// 代入 (右結合)。 代入の右辺は三項演算子から。
    private func parseExpression() throws -> EEL2Expr {
        let left = try parseTernary()

        if case .op(let opStr) = currentToken.0, ["=", "+=", "-=", "*=", "/="].contains(opStr) {
            switch left {
            case .varRead(let idx):
                advance()
                let right = try parseExpression()
                switch opStr {
                case "=":  return .assign(idx, right)
                case "+=": return .assign(idx, .binOp(.add, .varRead(idx), right))
                case "-=": return .assign(idx, .binOp(.sub, .varRead(idx), right))
                case "*=": return .assign(idx, .binOp(.mul, .varRead(idx), right))
                case "/=": return .assign(idx, .binOp(.div, .varRead(idx), right))
                default:   break
                }
            case .argRead(let idx):
                advance()
                let right = try parseExpression()
                switch opStr {
                case "=":  return .argAssign(idx, right)
                case "+=": return .argAssign(idx, .binOp(.add, .argRead(idx), right))
                case "-=": return .argAssign(idx, .binOp(.sub, .argRead(idx), right))
                case "*=": return .argAssign(idx, .binOp(.mul, .argRead(idx), right))
                case "/=": return .argAssign(idx, .binOp(.div, .argRead(idx), right))
                default:   break
                }
            case .memoryRead(let offset, let index):
                advance()
                let right = try parseExpression()
                switch opStr {
                case "=":  return .memoryWrite(offset, index, right)
                case "+=": return .memoryWrite(offset, index, .binOp(.add, .memoryRead(offset, index), right))
                case "-=": return .memoryWrite(offset, index, .binOp(.sub, .memoryRead(offset, index), right))
                case "*=": return .memoryWrite(offset, index, .binOp(.mul, .memoryRead(offset, index), right))
                case "/=": return .memoryWrite(offset, index, .binOp(.div, .memoryRead(offset, index), right))
                default:   break
                }
            default:
                throw EEL2ParseError.unexpectedToken(opStr, line: currentLine)
            }
        }
        return left
    }

    /// 三項演算子 cond ? then : else (右結合)
    private func parseTernary() throws -> EEL2Expr {
        let cond = try parseLogicalOr()
        if case .question = currentToken.0 {
            advance()
            let thenExpr = try parseExpression()  // 右結合、代入も可
            guard case .colon = currentToken.0 else {
                throw EEL2ParseError.missingColonInTernary(line: currentLine)
            }
            advance()
            let elseExpr = try parseExpression()
            return .ternary(cond, thenExpr, elseExpr)
        }
        return cond
    }

    private func parseLogicalOr() throws -> EEL2Expr {
        var left = try parseLogicalAnd()
        while matchOp("||") { left = .binOp(.or, left, try parseLogicalAnd()) }
        return left
    }

    private func parseLogicalAnd() throws -> EEL2Expr {
        var left = try parseBitOr()
        while matchOp("&&") { left = .binOp(.and, left, try parseBitOr()) }
        return left
    }

    private func parseBitOr() throws -> EEL2Expr {
        var left = try parseBitAnd()
        while case .op(let s) = currentToken.0, s == "|" {
            advance()
            left = .binOp(.bitOr, left, try parseBitAnd())
        }
        return left
    }

    private func parseBitAnd() throws -> EEL2Expr {
        var left = try parseEquality()
        while case .op(let s) = currentToken.0, s == "&" {
            advance()
            left = .binOp(.bitAnd, left, try parseEquality())
        }
        return left
    }

    private func parseEquality() throws -> EEL2Expr {
        var left = try parseComparison()
        while true {
            if matchOp("==") { left = .binOp(.eq, left, try parseComparison()) }
            else if matchOp("!=") { left = .binOp(.neq, left, try parseComparison()) }
            else { break }
        }
        return left
    }

    private func parseComparison() throws -> EEL2Expr {
        var left = try parseShift()
        while true {
            if matchOp("<=") { left = .binOp(.le, left, try parseShift()) }
            else if matchOp(">=") { left = .binOp(.ge, left, try parseShift()) }
            else if matchOp("<") { left = .binOp(.lt, left, try parseShift()) }
            else if matchOp(">") { left = .binOp(.gt, left, try parseShift()) }
            else { break }
        }
        return left
    }

    private func parseShift() throws -> EEL2Expr {
        var left = try parseAdditive()
        while true {
            if matchOp("<<") { left = .binOp(.shl, left, try parseAdditive()) }
            else if matchOp(">>") { left = .binOp(.shr, left, try parseAdditive()) }
            else { break }
        }
        return left
    }

    private func parseAdditive() throws -> EEL2Expr {
        var left = try parseMultiplicative()
        while true {
            if matchOp("+") { left = .binOp(.add, left, try parseMultiplicative()) }
            else if matchOp("-") { left = .binOp(.sub, left, try parseMultiplicative()) }
            else { break }
        }
        return left
    }

    private func parseMultiplicative() throws -> EEL2Expr {
        var left = try parsePower()
        while true {
            if matchOp("*") { left = .binOp(.mul, left, try parsePower()) }
            else if matchOp("/") { left = .binOp(.div, left, try parsePower()) }
            else if matchOp("%") { left = .binOp(.mod, left, try parsePower()) }
            else { break }
        }
        return left
    }

    private func parsePower() throws -> EEL2Expr {
        let base = try parseUnary()
        if matchOp("^") {
            let exponent = try parsePower()
            return .binOp(.pow, base, exponent)
        }
        return base
    }

    private func parseUnary() throws -> EEL2Expr {
        if matchOp("-") { return .unaryOp(.negate, try parseUnary()) }
        if matchOp("+") { return try parseUnary() }
        if matchOp("!") { return .unaryOp(.not, try parseUnary()) }
        if matchOp("~") { return .unaryOp(.bitNot, try parseUnary()) }
        return try parsePostfix()
    }

    private func parsePostfix() throws -> EEL2Expr {
        var expr = try parsePrimary()
        while case .leftBracket = currentToken.0 {
            advance()
            let indexExpr = try parseExpression()
            try expect(.rightBracket)
            expr = .memoryRead(expr, indexExpr)
        }
        return expr
    }

    private func parsePrimary() throws -> EEL2Expr {
        switch currentToken.0 {
        case .number(let n):
            advance()
            return .number(n)
        case .dollarIdent(let name):
            advance()
            switch name.lowercased() {
            case "pi": return .constant(.pi)
            case "e":  return .constant(.e)
            default:
                throw EEL2ParseError.undefinedVariable("$" + name)
            }
        case .leftParen:
            advance()
            let e = try parseExpression()
            try expect(.rightParen)
            return e
        case .identifier(let name):
            advance()
            if case .leftParen = currentToken.0 {
                advance()
                var args: [EEL2Expr] = []
                if case .rightParen = currentToken.0 {
                    // 引数なし
                } else {
                    args.append(try parseExpression())
                    while case .comma = currentToken.0 {
                        advance()
                        args.append(try parseExpression())
                    }
                }
                try expect(.rightParen)
                return try makeFunctionCall(name: name, args: args)
            }
            if let argMap = currentFunctionArgMap, let argIdx = argMap[name] {
                return .argRead(argIdx)
            }
            let idx = getOrCreateVariable(name)
            return .varRead(idx)
        default:
            throw EEL2ParseError.unexpectedToken(currentDescription, line: currentLine)
        }
    }

    private func makeFunctionCall(name: String, args: [EEL2Expr]) throws -> EEL2Expr {
        // ユーザー定義関数優先
        if let fnIdx = userFunctionNameToIndex[name] {
            return .userFuncCall(fnIdx, args)
        }

        // JamesDSP 独自 built-in
        if let builtin = Self.mapBuiltin(name: name) {
            return .builtinDspCall(builtin, args)
        }

        // 標準数学関数
        let key = name.lowercased()
        let fn: EEL2Function
        switch key {
        case "sin":     fn = .sin
        case "cos":     fn = .cos
        case "tan":     fn = .tan
        case "asin":    fn = .asin
        case "acos":    fn = .acos
        case "atan":    fn = .atan
        case "atan2":   fn = .atan2
        case "sqrt":    fn = .sqrt
        case "exp":     fn = .exp
        case "log":     fn = .log
        case "log10":   fn = .log10
        case "pow":     fn = .pow
        case "abs":     fn = .abs
        case "floor":   fn = .floor
        case "ceil":    fn = .ceil
        case "min":     fn = .min
        case "max":     fn = .max
        case "sign":    fn = .sign
        case "sinh":    fn = .sinh
        case "cosh":    fn = .cosh
        case "tanh":    fn = .tanh
        case "sqr":     fn = .sqr
        case "invsqrt": fn = .invsqrt
        default:
            throw EEL2ParseError.unknownFunction(name, line: currentLine)
        }
        return .funcCall(fn, args)
    }

    /// JamesDSP 独自 built-in の名前解決 (case-insensitive)
    private static func mapBuiltin(name: String) -> EEL2Builtin? {
        switch name {
        case "IIRBandSplitterInit":    return .iirBandSplitterInit
        case "IIRBandSplitterProcess": return .iirBandSplitterProcess
        case "memset":                 return .memset
        case "memcpy":                 return .memcpy
        case "rms":                    return .rms
        default:                       return nil
        }
    }
}

// MARK: - Evaluator (AST インタプリタ)

/// 引数スタックのスロット。参照引数の場合はグローバル変数 index を保持。
enum EEL2StackSlot {
    case value(Double)
    case reference(Int)  // グローバル変数の index
}

final class EEL2Executor {

    let program: EEL2Parser.Program
    let variables: UnsafeMutablePointer<Double>
    let variableCount: Int
    let memory: UnsafeMutablePointer<Double>
    static let memorySize: Int = 100_000

    private var argStack: [[EEL2StackSlot]] = []
    var maxIterationsPerLoop: Int = 100000

    // MARK: - Bytecode 化されたセクション

    private let compiledInit: EEL2CompiledSection
    private let compiledSlider: EEL2CompiledSection
    private let compiledSample: EEL2CompiledSection
    /// Phase 4-2: ユーザー関数 body を bytecode 化したもの (fnIdx でアクセス、keepLastValue=true)
    private let userFunctionBodies: [EEL2CompiledSection]

    // MARK: - VM スタック (Bytecode 実行時に使用)

    /// VM の値スタック (固定サイズで確保)
    private let vmStack: UnsafeMutablePointer<Double>
    private static let vmStackSize: Int = 1024
    /// 現在のスタックトップ (execute 再帰時のフレーム境界)
    private var vmStackTop: Int = 0

    // MARK: - パフォーマンス統計 (Phase 4-1)

    /// 直前の runSample() で実行された命令数
    private(set) var lastSampleInstructionCount: Int = 0
    /// リセット以降に累積した命令数 (@sample のみ)
    private(set) var cumulativeSampleInstructions: UInt64 = 0
    /// リセット以降の @sample 呼び出し回数
    private(set) var cumulativeSampleCalls: UInt64 = 0

    /// 統計をリセット
    func resetStatistics() {
        lastSampleInstructionCount = 0
        cumulativeSampleInstructions = 0
        cumulativeSampleCalls = 0
    }

    init(program: EEL2Parser.Program) {
        self.program = program
        self.variableCount = program.variableCount
        self.variables = UnsafeMutablePointer<Double>.allocate(capacity: max(1, variableCount))
        self.variables.initialize(repeating: 0, count: max(1, variableCount))
        self.memory = UnsafeMutablePointer<Double>.allocate(capacity: Self.memorySize)
        self.memory.initialize(repeating: 0, count: Self.memorySize)

        self.vmStack = UnsafeMutablePointer<Double>.allocate(capacity: Self.vmStackSize)
        self.vmStack.initialize(repeating: 0, count: Self.vmStackSize)

        // 各セクションを Bytecode 化
        self.compiledInit   = EEL2Compiler.compile(program.initSection)
        self.compiledSlider = EEL2Compiler.compile(program.sliderSection)
        self.compiledSample = EEL2Compiler.compile(program.sampleSection)
        // Phase 4-2: ユーザー関数 body も bytecode 化 (戻り値を残すため keepLastValue=true)
        self.userFunctionBodies = program.userFunctions.map {
            EEL2Compiler.compile($0.body, keepLastValue: true)
        }
    }

    deinit {
        variables.deinitialize(count: max(1, variableCount))
        variables.deallocate()
        memory.deinitialize(count: Self.memorySize)
        memory.deallocate()
        vmStack.deinitialize(count: Self.vmStackSize)
        vmStack.deallocate()
    }

    func applySliderValue(sliderIndex: Int, value: Double) {
        guard sliderIndex >= 0 && sliderIndex < program.sliderVarIndices.count else { return }
        variables[program.sliderVarIndices[sliderIndex]] = value
    }

    func resetSlidersToDefaults() {
        for (i, s) in program.sliders.enumerated() {
            applySliderValue(sliderIndex: i, value: s.defaultValue)
        }
    }

    func setSampleRate(_ sr: Double) {
        variables[program.srateIndex] = sr
    }

    // MARK: - Bytecode 実行 (Phase 3-4)

    func runInit()   { _ = execute(section: compiledInit) }
    func runSlider() { _ = execute(section: compiledSlider) }

    @inline(__always)
    func runSample() {
        let result = execute(section: compiledSample)
        lastSampleInstructionCount = result.instructions
        cumulativeSampleInstructions &+= UInt64(result.instructions)
        cumulativeSampleCalls &+= 1
    }

    // MARK: - 評価器

    @inline(__always)
    func evaluate(_ expr: EEL2Expr) -> Double {
        switch expr {
        case .number(let n):
            return n
        case .constant(let c):
            switch c {
            case .pi: return .pi
            case .e:  return M_E
            }
        case .varRead(let idx):
            return idx < variableCount ? variables[idx] : 0
        case .argRead(let idx):
            if let top = argStack.last, idx < top.count {
                switch top[idx] {
                case .value(let v):          return v
                case .reference(let varIdx): return varIdx < variableCount ? variables[varIdx] : 0
                }
            }
            return 0
        case .assign(let idx, let rhs):
            let v = evaluate(rhs)
            if idx < variableCount { variables[idx] = v }
            return v
        case .argAssign(let idx, let rhs):
            let v = evaluate(rhs)
            if var top = argStack.last, idx < top.count {
                switch top[idx] {
                case .value:
                    top[idx] = .value(v)
                    argStack[argStack.count - 1] = top
                case .reference(let varIdx):
                    if varIdx < variableCount { variables[varIdx] = v }
                }
            }
            return v
        case .memoryRead(let offsetExpr, let indexExpr):
            let addr = Int(evaluate(offsetExpr) + evaluate(indexExpr))
            return (addr >= 0 && addr < Self.memorySize) ? memory[addr] : 0
        case .memoryWrite(let offsetExpr, let indexExpr, let valueExpr):
            let addr = Int(evaluate(offsetExpr) + evaluate(indexExpr))
            let v = evaluate(valueExpr)
            if addr >= 0 && addr < Self.memorySize { memory[addr] = v }
            return v
        case .binOp(let op, let l, let r):
            return evaluateBinOp(op, evaluate(l), evaluate(r))
        case .unaryOp(let op, let e):
            let v = evaluate(e)
            switch op {
            case .negate: return -v
            case .not:    return v == 0 ? 1 : 0
            case .bitNot: return Double(~Int64(v))
            }
        case .ternary(let cond, let thenE, let elseE):
            return evaluate(cond) != 0 ? evaluate(thenE) : evaluate(elseE)
        case .funcCall(let fn, let args):
            return evaluateFunc(fn, args)
        case .builtinDspCall(let fn, let args):
            return evaluateBuiltinDsp(fn, args)
        case .userFuncCall(let fnIdx, let args):
            return evaluateUserFunc(fnIdx, args)
        case .ifElse(let cond, let thenStmts, let elseStmts):
            let branch = evaluate(cond) != 0 ? thenStmts : elseStmts
            var last: Double = 0
            for s in branch { last = evaluate(s) }
            return last
        case .whileLoop(let cond, let body):
            var iters = 0
            var last: Double = 0
            while evaluate(cond) != 0 {
                for s in body { last = evaluate(s) }
                iters += 1
                if iters >= maxIterationsPerLoop { break }
            }
            return last
        case .loopN(let countExpr, let body):
            let n = Int(evaluate(countExpr))
            let cap = min(n, maxIterationsPerLoop)
            var last: Double = 0
            var i = 0
            while i < cap {
                for s in body { last = evaluate(s) }
                i += 1
            }
            return last
        }
    }

    @inline(__always)
    private func evaluateBinOp(_ op: BinOp, _ a: Double, _ b: Double) -> Double {
        switch op {
        case .add: return a + b
        case .sub: return a - b
        case .mul: return a * b
        case .div: return b == 0 ? 0 : a / b
        case .mod: return b == 0 ? 0 : a.truncatingRemainder(dividingBy: b)
        case .pow: return Foundation.pow(a, b)
        case .eq:  return a == b ? 1 : 0
        case .neq: return a != b ? 1 : 0
        case .lt:  return a < b ? 1 : 0
        case .le:  return a <= b ? 1 : 0
        case .gt:  return a > b ? 1 : 0
        case .ge:  return a >= b ? 1 : 0
        case .and: return (a != 0 && b != 0) ? 1 : 0
        case .or:  return (a != 0 || b != 0) ? 1 : 0
        case .bitAnd: return Double(Int64(a) & Int64(b))
        case .bitOr:  return Double(Int64(a) | Int64(b))
        case .bitXor: return Double(Int64(a) ^ Int64(b))
        case .shl:    return Double(Int64(a) << Int64(b))
        case .shr:    return Double(Int64(a) >> Int64(b))
        }
    }

    private func evaluateFunc(_ fn: EEL2Function, _ args: [EEL2Expr]) -> Double {
        func arg(_ i: Int) -> Double { i < args.count ? evaluate(args[i]) : 0 }
        switch fn {
        case .sin:     return Foundation.sin(arg(0))
        case .cos:     return Foundation.cos(arg(0))
        case .tan:     return Foundation.tan(arg(0))
        case .asin:    return Foundation.asin(arg(0))
        case .acos:    return Foundation.acos(arg(0))
        case .atan:    return Foundation.atan(arg(0))
        case .atan2:   return Foundation.atan2(arg(0), arg(1))
        case .sqrt:    return Foundation.sqrt(arg(0))
        case .exp:     return Foundation.exp(arg(0))
        case .log:     return Foundation.log(arg(0))
        case .log10:   return Foundation.log10(arg(0))
        case .pow:     return Foundation.pow(arg(0), arg(1))
        case .abs:     return Swift.abs(arg(0))
        case .floor:   return Foundation.floor(arg(0))
        case .ceil:    return Foundation.ceil(arg(0))
        case .min:     return Swift.min(arg(0), arg(1))
        case .max:     return Swift.max(arg(0), arg(1))
        case .sign:    let v = arg(0); return v > 0 ? 1 : (v < 0 ? -1 : 0)
        case .sinh:    return Foundation.sinh(arg(0))
        case .cosh:    return Foundation.cosh(arg(0))
        case .tanh:    return Foundation.tanh(arg(0))
        case .sqr:     let v = arg(0); return v * v
        case .invsqrt: let v = arg(0); return v > 0 ? 1.0 / Foundation.sqrt(v) : 0
        }
    }

    // MARK: - Bytecode VM 実行 (Phase 3-4)

    /// コンパイル済みセクションを VM で実行する。
    /// 戻り値: (実行された命令数, halt 時のスタックトップ)。
    /// keepLastValue=true の場合、halt 時の stack top が戻り値。false の場合は 0。
    ///
    /// 再帰安全: 実行中に evaluate() → evaluateUserFunc() → execute() の再入があっても
    ///          スタック領域が競合しないよう vmStackTop で境界を管理する。
    @discardableResult
    @inline(__always)
    private func execute(section: EEL2CompiledSection) -> (instructions: Int, returnValue: Double) {
        // このフレームのスタック開始位置 (再帰呼び出し時、外側のスタックを保護)
        let spBase = vmStackTop
        var pc = 0
        var sp = spBase

        let insts = section.instructions
        let astTable = section.astTable
        let stackCap = Self.vmStackSize
        let vs = vmStack
        let vars = variables
        let varCount = variableCount
        let mem = memory
        let memCap = Self.memorySize

        let maxInstructions = 10_000_000
        var executed = 0

        while pc < insts.count {
            let inst = insts[pc]
            executed += 1
            if executed >= maxInstructions { break }

            switch EEL2Opcode(rawValue: inst.opcode) ?? .halt {

            case .halt:
                let rv = sp > spBase ? vs[sp - 1] : 0
                vmStackTop = spBase  // このフレームのスタックを解放
                return (executed, rv)

            // MARK: スタック操作
            case .pushConst:
                if sp < stackCap { vs[sp] = inst.doubleOp; sp += 1 }
                pc += 1

            case .pushVar:
                let idx = Int(inst.intOp)
                let v = (idx >= 0 && idx < varCount) ? vars[idx] : 0
                if sp < stackCap { vs[sp] = v; sp += 1 }
                pc += 1

            case .pushArg:
                let idx = Int(inst.intOp)
                var v: Double = 0
                if let top = argStack.last, idx >= 0 && idx < top.count {
                    switch top[idx] {
                    case .value(let x):        v = x
                    case .reference(let vIdx): v = (vIdx >= 0 && vIdx < varCount) ? vars[vIdx] : 0
                    }
                }
                if sp < stackCap { vs[sp] = v; sp += 1 }
                pc += 1

            case .pushPi:
                if sp < stackCap { vs[sp] = .pi; sp += 1 }
                pc += 1

            case .pushE:
                if sp < stackCap { vs[sp] = M_E; sp += 1 }
                pc += 1

            case .pop:
                if sp > 0 { sp -= 1 }
                pc += 1

            case .dup:
                if sp > 0 && sp < stackCap { vs[sp] = vs[sp - 1]; sp += 1 }
                pc += 1

            // MARK: 代入
            case .storeVar:
                // storeVar は stack top を変数に書き、stack top はそのまま残す (代入式の値)
                let idx = Int(inst.intOp)
                if sp > 0 && idx >= 0 && idx < varCount {
                    vars[idx] = vs[sp - 1]
                }
                pc += 1

            case .storeArg:
                // Phase 4-2: 関数内引数への代入 (bytecode 化)
                // スタックトップを argFrame の指定インデックスに書く。stack top はそのまま残す。
                let idx = Int(inst.intOp)
                if sp > 0 {
                    let v = vs[sp - 1]
                    if var top = argStack.last, idx >= 0 && idx < top.count {
                        switch top[idx] {
                        case .value:
                            top[idx] = .value(v)
                            argStack[argStack.count - 1] = top
                        case .reference(let vIdx):
                            if vIdx >= 0 && vIdx < varCount { vars[vIdx] = v }
                        }
                    }
                }
                pc += 1

            case .loadMem:
                // stack: [.., offset, index] → [.., value]
                if sp >= 2 {
                    let index = vs[sp - 1]
                    let offset = vs[sp - 2]
                    let addr = Int(offset + index)
                    let v = (addr >= 0 && addr < memCap) ? mem[addr] : 0
                    sp -= 2
                    vs[sp] = v
                    sp += 1
                }
                pc += 1

            case .storeMem:
                // stack: [.., offset, index, value] → [.., value]
                if sp >= 3 {
                    let value = vs[sp - 1]
                    let index = vs[sp - 2]
                    let offset = vs[sp - 3]
                    let addr = Int(offset + index)
                    if addr >= 0 && addr < memCap { mem[addr] = value }
                    sp -= 3
                    vs[sp] = value
                    sp += 1
                }
                pc += 1

            // MARK: 算術
            case .add:
                if sp >= 2 { vs[sp - 2] += vs[sp - 1]; sp -= 1 }
                pc += 1
            case .sub:
                if sp >= 2 { vs[sp - 2] -= vs[sp - 1]; sp -= 1 }
                pc += 1
            case .mul:
                if sp >= 2 { vs[sp - 2] *= vs[sp - 1]; sp -= 1 }
                pc += 1
            case .div:
                if sp >= 2 {
                    let b = vs[sp - 1]
                    vs[sp - 2] = b == 0 ? 0 : vs[sp - 2] / b
                    sp -= 1
                }
                pc += 1
            case .mod:
                if sp >= 2 {
                    let b = vs[sp - 1]
                    vs[sp - 2] = b == 0 ? 0 : vs[sp - 2].truncatingRemainder(dividingBy: b)
                    sp -= 1
                }
                pc += 1
            case .powOp:
                if sp >= 2 {
                    vs[sp - 2] = Foundation.pow(vs[sp - 2], vs[sp - 1])
                    sp -= 1
                }
                pc += 1
            case .neg:
                if sp > 0 { vs[sp - 1] = -vs[sp - 1] }
                pc += 1

            // MARK: 比較
            case .eq:
                if sp >= 2 { vs[sp - 2] = (vs[sp - 2] == vs[sp - 1]) ? 1 : 0; sp -= 1 }
                pc += 1
            case .neq:
                if sp >= 2 { vs[sp - 2] = (vs[sp - 2] != vs[sp - 1]) ? 1 : 0; sp -= 1 }
                pc += 1
            case .lt:
                if sp >= 2 { vs[sp - 2] = (vs[sp - 2] <  vs[sp - 1]) ? 1 : 0; sp -= 1 }
                pc += 1
            case .le:
                if sp >= 2 { vs[sp - 2] = (vs[sp - 2] <= vs[sp - 1]) ? 1 : 0; sp -= 1 }
                pc += 1
            case .gt:
                if sp >= 2 { vs[sp - 2] = (vs[sp - 2] >  vs[sp - 1]) ? 1 : 0; sp -= 1 }
                pc += 1
            case .ge:
                if sp >= 2 { vs[sp - 2] = (vs[sp - 2] >= vs[sp - 1]) ? 1 : 0; sp -= 1 }
                pc += 1

            // MARK: 論理
            case .land:
                if sp >= 2 {
                    let b = vs[sp - 1] != 0, a = vs[sp - 2] != 0
                    vs[sp - 2] = (a && b) ? 1 : 0
                    sp -= 1
                }
                pc += 1
            case .lor:
                if sp >= 2 {
                    let b = vs[sp - 1] != 0, a = vs[sp - 2] != 0
                    vs[sp - 2] = (a || b) ? 1 : 0
                    sp -= 1
                }
                pc += 1
            case .lnot:
                if sp > 0 { vs[sp - 1] = vs[sp - 1] == 0 ? 1 : 0 }
                pc += 1

            // MARK: ビット
            case .bitAnd:
                if sp >= 2 { vs[sp - 2] = Double(Int64(vs[sp - 2]) & Int64(vs[sp - 1])); sp -= 1 }
                pc += 1
            case .bitOr:
                if sp >= 2 { vs[sp - 2] = Double(Int64(vs[sp - 2]) | Int64(vs[sp - 1])); sp -= 1 }
                pc += 1
            case .bitXor:
                if sp >= 2 { vs[sp - 2] = Double(Int64(vs[sp - 2]) ^ Int64(vs[sp - 1])); sp -= 1 }
                pc += 1
            case .shl:
                if sp >= 2 { vs[sp - 2] = Double(Int64(vs[sp - 2]) << Int64(vs[sp - 1])); sp -= 1 }
                pc += 1
            case .shr:
                if sp >= 2 { vs[sp - 2] = Double(Int64(vs[sp - 2]) >> Int64(vs[sp - 1])); sp -= 1 }
                pc += 1
            case .bitNot:
                if sp > 0 { vs[sp - 1] = Double(~Int64(vs[sp - 1])) }
                pc += 1

            // MARK: 制御フロー
            case .jump:
                pc = Int(inst.intOp)

            case .jumpIfZero:
                if sp > 0 {
                    let v = vs[sp - 1]
                    sp -= 1
                    if v == 0 { pc = Int(inst.intOp) } else { pc += 1 }
                } else {
                    pc = Int(inst.intOp)
                }

            case .jumpIfNotZero:
                if sp > 0 {
                    let v = vs[sp - 1]
                    sp -= 1
                    if v != 0 { pc = Int(inst.intOp) } else { pc += 1 }
                } else {
                    pc += 1
                }

            // MARK: 標準数学関数呼び出し
            case .callFunc:
                let packed = inst.intOp
                let argCount = Int((packed >> 16) & 0xFFFF)
                let serial = Int32(packed & 0xFFFF)
                if let fn = EEL2Compiler.funcFromSerial(serial) {
                    let result = callStdFunc(fn, argCount: argCount, sp: &sp)
                    if sp < stackCap { vs[sp] = result; sp += 1 }
                }
                pc += 1

            // MARK: AST フォールバック
            case .evalAST:
                let idx = Int(inst.intOp)
                if idx >= 0 && idx < astTable.count {
                    // 内側の execute から現在の sp を見えるよう、vmStackTop を更新
                    // (userFuncCall 経由で execute が再帰的に呼ばれる場合、
                    //  内側は vmStackTop から書き始めるので、外側のスタックを保護できる)
                    vmStackTop = sp
                    let v = evaluate(astTable[idx])
                    // evaluate 後、内側で execute が呼ばれていた場合でも
                    // 内側の halt で vmStackTop は spBase (=元の外側 sp) に戻っている
                    if sp < stackCap { vs[sp] = v; sp += 1 }
                }
                pc += 1
            }
        }
        let rv = sp > spBase ? vs[sp - 1] : 0
        vmStackTop = spBase
        return (executed, rv)
    }

    /// スタックから argCount 個の値を pop して標準関数を実行し、結果を返す。
    /// spは inout で更新される。
    @inline(__always)
    private func callStdFunc(_ fn: EEL2Function, argCount: Int, sp: inout Int) -> Double {
        let vs = vmStack
        // 引数を取り出す (逆順ではなく、順番通り)
        func a(_ i: Int) -> Double {
            let base = sp - argCount
            return (i >= 0 && i < argCount && base + i >= 0) ? vs[base + i] : 0
        }
        let a0 = a(0), a1 = a(1)
        // pop
        sp = max(0, sp - argCount)

        switch fn {
        case .sin:     return Foundation.sin(a0)
        case .cos:     return Foundation.cos(a0)
        case .tan:     return Foundation.tan(a0)
        case .asin:    return Foundation.asin(a0)
        case .acos:    return Foundation.acos(a0)
        case .atan:    return Foundation.atan(a0)
        case .atan2:   return Foundation.atan2(a0, a1)
        case .sqrt:    return Foundation.sqrt(a0)
        case .exp:     return Foundation.exp(a0)
        case .log:     return Foundation.log(a0)
        case .log10:   return Foundation.log10(a0)
        case .pow:     return Foundation.pow(a0, a1)
        case .abs:     return Swift.abs(a0)
        case .floor:   return Foundation.floor(a0)
        case .ceil:    return Foundation.ceil(a0)
        case .min:     return Swift.min(a0, a1)
        case .max:     return Swift.max(a0, a1)
        case .sign:    return a0 > 0 ? 1 : (a0 < 0 ? -1 : 0)
        case .sinh:    return Foundation.sinh(a0)
        case .cosh:    return Foundation.cosh(a0)
        case .tanh:    return Foundation.tanh(a0)
        case .sqr:     return a0 * a0
        case .invsqrt: return a0 > 0 ? 1.0 / Foundation.sqrt(a0) : 0
        }
    }

    // MARK: - JamesDSP 独自 built-in

    private func evaluateBuiltinDsp(_ fn: EEL2Builtin, _ args: [EEL2Expr]) -> Double {
        switch fn {
        case .iirBandSplitterInit:
            // (offset, srate, f1, f2) → reqSize
            let offset = Int(argValue(args, 0))
            let srate  = argValue(args, 1)
            let f1     = argValue(args, 2)
            let f2     = argValue(args, 3)
            return Double(iirBandSplitterInit(offset: offset, sampleRate: srate, f1: f1, f2: f2))

        case .iirBandSplitterProcess:
            // (offset, in, *low, *mid, *high)
            let offset = Int(argValue(args, 0))
            let input  = argValue(args, 1)
            var lowOut: Double = 0
            var midOut: Double = 0
            var highOut: Double = 0
            iirBandSplitterProcess(offset: offset, input: input,
                                   low: &lowOut, mid: &midOut, high: &highOut)
            // 参照引数: args[2..4] が .varRead / .argRead ならその変数に書き込む
            writeBackReference(args: args, index: 2, value: lowOut)
            writeBackReference(args: args, index: 3, value: midOut)
            writeBackReference(args: args, index: 4, value: highOut)
            return 0

        case .memset:
            // (offset, count, value)
            let offset = Int(argValue(args, 0))
            let count  = Int(argValue(args, 1))
            let value  = argValue(args, 2)
            let start = max(0, offset)
            let end = min(Self.memorySize, offset + count)
            if end > start {
                for i in start ..< end { memory[i] = value }
            }
            return 0

        case .memcpy:
            // (dst, src, count)
            let dst = Int(argValue(args, 0))
            let src = Int(argValue(args, 1))
            let count = Int(argValue(args, 2))
            let n = min(count,
                        Self.memorySize - Swift.max(0, dst),
                        Self.memorySize - Swift.max(0, src))
            if n > 0 && dst >= 0 && src >= 0 {
                // 前方向/後方向の重複判定
                if dst < src {
                    for i in 0 ..< n { memory[dst + i] = memory[src + i] }
                } else {
                    for i in stride(from: n - 1, through: 0, by: -1) {
                        memory[dst + i] = memory[src + i]
                    }
                }
            }
            return 0

        case .rms:
            // (offset, count) → sqrt(mean(sq))
            let offset = Int(argValue(args, 0))
            let count = Int(argValue(args, 1))
            let start = max(0, offset)
            let end = min(Self.memorySize, offset + count)
            if end <= start { return 0 }
            var sum: Double = 0
            for i in start ..< end {
                let v = memory[i]
                sum += v * v
            }
            return Foundation.sqrt(sum / Double(end - start))
        }
    }

    @inline(__always)
    private func argValue(_ args: [EEL2Expr], _ i: Int) -> Double {
        return i < args.count ? evaluate(args[i]) : 0
    }

    /// 参照引数: 引数 args[index] が .varRead / .argRead の場合、対応変数に書き込む。
    /// それ以外の式なら書き戻しはできない (silent noop)。
    private func writeBackReference(args: [EEL2Expr], index: Int, value: Double) {
        guard index < args.count else { return }
        switch args[index] {
        case .varRead(let vIdx):
            if vIdx < variableCount { variables[vIdx] = value }
        case .argRead(let argIdx):
            if var top = argStack.last, argIdx < top.count {
                switch top[argIdx] {
                case .value:
                    top[argIdx] = .value(value)
                    argStack[argStack.count - 1] = top
                case .reference(let vIdx):
                    if vIdx < variableCount { variables[vIdx] = value }
                }
            }
        default:
            break  // 参照じゃない式には書き戻さない
        }
    }

    // MARK: - ユーザー定義関数呼び出し

    private func evaluateUserFunc(_ fnIdx: Int, _ argExprs: [EEL2Expr]) -> Double {
        guard fnIdx < program.userFunctions.count else { return 0 }
        let fn = program.userFunctions[fnIdx]

        // 引数を評価してスタックフレームを作成
        var argFrame: [EEL2StackSlot] = []
        argFrame.reserveCapacity(fn.argNames.count)
        for i in 0 ..< fn.argNames.count {
            let expr = i < argExprs.count ? argExprs[i] : .number(0)
            let isRef = i < fn.argIsRef.count ? fn.argIsRef[i] : false
            if isRef {
                switch expr {
                case .varRead(let vIdx):
                    argFrame.append(.reference(vIdx))
                case .argRead(let argIdx):
                    // 呼び出し元のフレームで解決
                    if let top = argStack.last, argIdx < top.count {
                        switch top[argIdx] {
                        case .value(let v):          argFrame.append(.value(v))
                        case .reference(let refIdx): argFrame.append(.reference(refIdx))
                        }
                    } else {
                        argFrame.append(.value(0))
                    }
                default:
                    // 参照引数だが値渡し可能な式が来た → 値としてスタックに置く (書き戻し不能)
                    argFrame.append(.value(evaluate(expr)))
                }
            } else {
                argFrame.append(.value(evaluate(expr)))
            }
        }

        argStack.append(argFrame)
        defer { argStack.removeLast() }

        // Phase 4-2: body を bytecode 実行 (userFunctionBodies に pre-compile 済み)
        if fnIdx < userFunctionBodies.count {
            let result = execute(section: userFunctionBodies[fnIdx])
            return result.returnValue
        } else {
            // フォールバック (通常は到達しない)
            var last: Double = 0
            for stmt in fn.body { last = evaluate(stmt) }
            return last
        }
    }

    // MARK: - IIRBandSplitter (Linkwitz-Riley 4th order, 3-band)

    /// IIRBandSplitter は Linkwitz-Riley 4次 (2つのバターワース 2次カスケード)
    /// で低域-中域と中域-高域を分離する 3-band splitter。
    ///
    /// メモリレイアウト (offset から):
    ///   [0..3]:  LPF1 の 2次 biquad state (LP for split1) x1 stage の s1, s2
    ///   [4..7]:  LPF1 の 2次 biquad state x2 stage の s1, s2
    ///   [8..11]: HPF1 の 2次 biquad state x1 stage
    ///   [12..15]: HPF1 の 2次 biquad state x2 stage
    ///   [16..19]: LPF2 の state x1
    ///   [20..23]: LPF2 の state x2
    ///   [24..27]: HPF2 の state x1
    ///   [28..31]: HPF2 の state x2
    ///   [32..47]: LPF/HPF の係数 (b0, b1, b2, a1, a2 × 4 filter)
    /// 使用サイズ: 52 セル (係数 20 + state 32)
    private static let iirBandSplitterCells: Int = 52

    private func iirBandSplitterInit(offset: Int, sampleRate: Double, f1: Double, f2: Double) -> Int {
        guard offset >= 0 && offset + Self.iirBandSplitterCells <= Self.memorySize else { return 0 }

        // state を 0 に
        for i in 0 ..< 32 { memory[offset + i] = 0 }

        // Butterworth 2次 (Q = 0.7071) LPF/HPF 係数を 4 フィルタ分計算
        // Linkwitz-Riley 4th = 2 個のバターワース 2次 cascade
        writeBiquadLPF(offset: offset + 32,  sampleRate: sampleRate, frequency: f1)  // LPF1 for split1
        writeBiquadHPF(offset: offset + 32 + 5, sampleRate: sampleRate, frequency: f1)  // HPF1 for split1
        writeBiquadLPF(offset: offset + 32 + 10, sampleRate: sampleRate, frequency: f2) // LPF2 for split2
        writeBiquadHPF(offset: offset + 32 + 15, sampleRate: sampleRate, frequency: f2) // HPF2 for split2

        return Self.iirBandSplitterCells
    }

    private func iirBandSplitterProcess(offset: Int, input: Double,
                                        low: inout Double, mid: inout Double, high: inout Double) {
        guard offset >= 0 && offset + Self.iirBandSplitterCells <= Self.memorySize else {
            low = 0; mid = 0; high = 0
            return
        }

        // LPF1: 2次 cascade → low + mid + high の帯域
        let lpf1a = applyBiquad(offset: offset, coefOffset: offset + 32, input: input)
        let lpf1 = applyBiquad(offset: offset + 2, coefOffset: offset + 32, input: lpf1a)

        // HPF1: 2次 cascade → mid + high の帯域
        let hpf1a = applyBiquad(offset: offset + 8, coefOffset: offset + 37, input: input)
        let hpf1 = applyBiquad(offset: offset + 10, coefOffset: offset + 37, input: hpf1a)

        // low = LPF1(x)
        low = lpf1

        // 中域と高域は HPF1 の出力をさらに LPF2 / HPF2 で分割
        let lpf2a = applyBiquad(offset: offset + 16, coefOffset: offset + 42, input: hpf1)
        let lpf2 = applyBiquad(offset: offset + 18, coefOffset: offset + 42, input: lpf2a)
        let hpf2a = applyBiquad(offset: offset + 24, coefOffset: offset + 47, input: hpf1)
        let hpf2 = applyBiquad(offset: offset + 26, coefOffset: offset + 47, input: hpf2a)

        mid = lpf2
        high = hpf2
    }

    /// Biquad LPF (Butterworth 2次, Q = 1/√2)
    /// RBJ Audio EQ Cookbook 相当。
    private func writeBiquadLPF(offset: Int, sampleRate: Double, frequency: Double) {
        let f = max(1.0, Swift.min(frequency, sampleRate * 0.49))
        let w0 = 2.0 * Double.pi * f / sampleRate
        let cosw = Foundation.cos(w0)
        let sinw = Foundation.sin(w0)
        let Q = 1.0 / Foundation.sqrt(2.0)  // Butterworth
        let alpha = sinw / (2.0 * Q)

        let a0 = 1.0 + alpha
        let b0 = ((1.0 - cosw) / 2.0) / a0
        let b1 = (1.0 - cosw) / a0
        let b2 = ((1.0 - cosw) / 2.0) / a0
        let a1 = (-2.0 * cosw) / a0
        let a2 = (1.0 - alpha) / a0

        memory[offset + 0] = b0
        memory[offset + 1] = b1
        memory[offset + 2] = b2
        memory[offset + 3] = a1
        memory[offset + 4] = a2
    }

    private func writeBiquadHPF(offset: Int, sampleRate: Double, frequency: Double) {
        let f = max(1.0, Swift.min(frequency, sampleRate * 0.49))
        let w0 = 2.0 * Double.pi * f / sampleRate
        let cosw = Foundation.cos(w0)
        let sinw = Foundation.sin(w0)
        let Q = 1.0 / Foundation.sqrt(2.0)
        let alpha = sinw / (2.0 * Q)

        let a0 = 1.0 + alpha
        let b0 = ((1.0 + cosw) / 2.0) / a0
        let b1 = -(1.0 + cosw) / a0
        let b2 = ((1.0 + cosw) / 2.0) / a0
        let a1 = (-2.0 * cosw) / a0
        let a2 = (1.0 - alpha) / a0

        memory[offset + 0] = b0
        memory[offset + 1] = b1
        memory[offset + 2] = b2
        memory[offset + 3] = a1
        memory[offset + 4] = a2
    }

    /// Direct Form II Transposed で 1 stage の biquad を実行
    /// state: [s1, s2] の 2 セル
    /// coef: [b0, b1, b2, a1, a2] の 5 セル
    @inline(__always)
    private func applyBiquad(offset stateOffset: Int, coefOffset: Int, input x: Double) -> Double {
        let b0 = memory[coefOffset + 0]
        let b1 = memory[coefOffset + 1]
        let b2 = memory[coefOffset + 2]
        let a1 = memory[coefOffset + 3]
        let a2 = memory[coefOffset + 4]
        let s1 = memory[stateOffset + 0]
        let s2 = memory[stateOffset + 1]
        let y = b0 * x + s1
        memory[stateOffset + 0] = b1 * x - a1 * y + s2
        memory[stateOffset + 1] = b2 * x - a2 * y
        return y
    }
}
