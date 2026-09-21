//
//  EEL2Bytecode.swift
//  ViviMusic
//
//  Phase 3-4: EEL2 AST → Bytecode コンパイラ + Stack-based VM。
//  期待効果: @sample per-sample コストが 2-5 倍高速化。
//
//  Bytecode 化する構文 (Phase 3-4-1):
//    - 定数、変数、引数、算術、比較、論理、ビット演算、代入
//    - if/else、while、loop、三項演算子
//    - メモリアクセス (mem[i], x[i])
//    - 標準数学関数 (sin, cos, sqrt, exp, log, ...)
//    - JamesDSP built-in DSP 関数 (IIRBandSplitter, memset, memcpy, rms)
//
//  AST フォールバック (Phase 3-4-2 で bytecode 化予定):
//    - ユーザー定義関数呼び出し (userFuncCall) 参照引数の扱いが複雑なため
//    - argAssign (関数内引数代入)
//
//  VM の設計:
//    - Stack: UnsafeMutablePointer<Double> の固定サイズ (1024)
//    - PC: 命令インデックス
//    - 命令は EEL2Instruction (opcode + intOp + doubleOp) の固定サイズ struct
//

import Foundation

// MARK: - Opcode

enum EEL2Opcode: UInt8 {
    case halt = 0

    // スタック操作
    case pushConst = 1      // doubleOp を push
    case pushVar = 2        // intOp = var index
    case pushArg = 3        // intOp = arg index
    case pushPi = 4
    case pushE = 5
    case pop = 6
    case dup = 7

    // 代入
    case storeVar = 10      // stack top を variables[intOp] に、stack top はそのまま残す
    case loadMem = 11       // stack: [.., offset, index] → [.., value]
    case storeMem = 12      // stack: [.., offset, index, value] → [.., value]
    case storeArg = 13      // stack top を argFrame の intOp インデックスに書く (Phase 4-2)

    // 算術
    case add = 20
    case sub = 21
    case mul = 22
    case div = 23
    case mod = 24
    case powOp = 25
    case neg = 26

    // 比較
    case eq = 30
    case neq = 31
    case lt = 32
    case le = 33
    case gt = 34
    case ge = 35

    // 論理
    case land = 40
    case lor = 41
    case lnot = 42

    // ビット
    case bitAnd = 50
    case bitOr = 51
    case bitXor = 52
    case shl = 53
    case shr = 54
    case bitNot = 55

    // 制御フロー (intOp = 命令アドレス)
    case jump = 60
    case jumpIfZero = 61      // stack top を pop してチェック
    case jumpIfNotZero = 62

    // 標準数学関数 (組み込み関数)
    // intOp = EEL2Function の serial (0-21)
    case callFunc = 70

    // JamesDSP built-in DSP 関数
    // intOp = EEL2Builtin の serial (0-4)
    // doubleOp: 参照引数を含むもの用に、事前に AST を保存しておく必要があるが、
    // ここでは AST インデックス (astTable のインデックス) を intOp2 として持ちたい。
    // ただし固定サイズ struct なので、ワークアラウンド:
    //   ・EEL2Builtin の case を全部インラインで扱う
    //   ・参照引数の書き戻し先変数 index は事前計算して operand として保存
    // → 別に callBuiltinDsp 命令を用意し、
    //   intOp = builtin serial、doubleOp のビット表現に refArgVarIndices を packing
    // ただし複雑なので、シンプルに evalAST fallback で処理する。
    // Phase 3-4-1 では JamesDSP built-in も AST fallback とする。

    // AST インタプリタへのフォールバック (ユーザー関数、JamesDSP built-in、argAssign)
    // intOp = astTable の index
    case evalAST = 80
}

// MARK: - Instruction

/// 固定サイズ命令。全命令共通のレイアウトで、UnsafeMutablePointer で高速アクセス。
struct EEL2Instruction {
    var opcode: UInt8         // EEL2Opcode.rawValue
    var _padding: UInt8 = 0
    var _padding2: UInt16 = 0
    var intOp: Int32          // 汎用整数オペランド (変数 index、ジャンプ先、arg count など)
    var doubleOp: Double      // 汎用倍精度オペランド (定数値)

    init(op: EEL2Opcode, intOp: Int32 = 0, doubleOp: Double = 0) {
        self.opcode = op.rawValue
        self.intOp = intOp
        self.doubleOp = doubleOp
    }
}

// MARK: - コンパイル済みプログラム (セクション毎)

struct EEL2CompiledSection {
    /// 命令列 (連続配列)
    var instructions: [EEL2Instruction]
    /// AST フォールバック用: 命令列から参照される元の AST ノード
    var astTable: [EEL2Expr]
    /// halt 到達時にスタックトップを残すか (ユーザー関数 body 用: 戻り値取得)
    var keepLastValue: Bool
}

// MARK: - コンパイラ

/// AST を bytecode に変換するコンパイラ。EEL2 の各セクション (init/slider/sample) 毎に呼ぶ。
final class EEL2Compiler {

    private var instructions: [EEL2Instruction] = []
    private var astTable: [EEL2Expr] = []

    /// AST リスト (statement 列) を bytecode 化。
    /// - Parameter keepLastValue: true の場合、最後の値をスタックに残す (ユーザー関数の戻り値用)。
    ///                           false の場合、値を全て捨てる (通常のセクション: @init/@sample)。
    static func compile(_ stmts: [EEL2Expr], keepLastValue: Bool = false) -> EEL2CompiledSection {
        let c = EEL2Compiler()
        if stmts.isEmpty {
            if keepLastValue {
                c.emit(.pushConst, doubleOp: 0)  // 空のセクションは 0 を返す
            }
        } else {
            for (i, stmt) in stmts.enumerated() {
                c.compileExpr(stmt)
                if i < stmts.count - 1 {
                    c.emit(.pop)  // 中間 statement の値を捨てる
                }
            }
            // 最後の値: keepLastValue なら残す、そうでなければ捨てる
            if !keepLastValue {
                c.emit(.pop)
            }
        }
        c.emit(.halt)
        return EEL2CompiledSection(
            instructions: c.instructions,
            astTable: c.astTable,
            keepLastValue: keepLastValue
        )
    }

    private init() {}

    // MARK: emit

    @inline(__always)
    private func emit(_ op: EEL2Opcode, intOp: Int32 = 0, doubleOp: Double = 0) {
        instructions.append(EEL2Instruction(op: op, intOp: intOp, doubleOp: doubleOp))
    }

    @inline(__always)
    private func addAST(_ expr: EEL2Expr) -> Int32 {
        astTable.append(expr)
        return Int32(astTable.count - 1)
    }

    // MARK: - 式のコンパイル (常にスタックに値を残す)

    private func compileExpr(_ expr: EEL2Expr) {
        switch expr {
        case .number(let n):
            emit(.pushConst, doubleOp: n)

        case .constant(let c):
            switch c {
            case .pi: emit(.pushPi)
            case .e:  emit(.pushE)
            }

        case .varRead(let idx):
            emit(.pushVar, intOp: Int32(idx))

        case .argRead(let idx):
            emit(.pushArg, intOp: Int32(idx))

        case .assign(let idx, let rhs):
            compileExpr(rhs)
            emit(.storeVar, intOp: Int32(idx))
            // storeVar は stack top を保持したまま (代入結果を残す)

        case .argAssign(let idx, let rhs):
            // Phase 4-2: 関数内引数への代入も bytecode 化
            compileExpr(rhs)
            emit(.storeArg, intOp: Int32(idx))

        case .memoryRead(let offsetE, let indexE):
            compileExpr(offsetE)
            compileExpr(indexE)
            emit(.loadMem)

        case .memoryWrite(let offsetE, let indexE, let valueE):
            compileExpr(offsetE)
            compileExpr(indexE)
            compileExpr(valueE)
            emit(.storeMem)

        case .binOp(let op, let l, let r):
            compileExpr(l)
            compileExpr(r)
            emit(opcodeForBinOp(op))

        case .unaryOp(let op, let e):
            compileExpr(e)
            switch op {
            case .negate: emit(.neg)
            case .not:    emit(.lnot)
            case .bitNot: emit(.bitNot)
            }

        case .ternary(let cond, let thenE, let elseE):
            // cond ? thenE : elseE
            compileExpr(cond)
            let jzIdx = instructions.count
            emit(.jumpIfZero)  // placeholder
            compileExpr(thenE)
            let jmpIdx = instructions.count
            emit(.jump)        // placeholder
            let elseAddr = instructions.count
            compileExpr(elseE)
            let endAddr = instructions.count
            instructions[jzIdx].intOp = Int32(elseAddr)
            instructions[jmpIdx].intOp = Int32(endAddr)

        case .funcCall(let fn, let args):
            // すべての引数を評価してスタックに乗せる
            for a in args {
                compileExpr(a)
            }
            // 引数数を intOp[16bit] に、function を intOp[16bit] に pack
            // 簡素化: intOp = function serial だけ、arg count は固定 (function 定義で決まる)
            let serial = Self.funcSerial(fn)
            let argCount = Int32(args.count)
            // 上位 16bit = argCount、下位 16bit = function serial
            let packed = (argCount << 16) | (serial & 0xFFFF)
            emit(.callFunc, intOp: packed)

        case .builtinDspCall:
            // JamesDSP built-in は参照引数を含むため AST fallback
            let astIdx = addAST(expr)
            emit(.evalAST, intOp: astIdx)

        case .userFuncCall:
            // ユーザー関数呼び出しは AST fallback (Phase 3-4-2 で bytecode 化予定)
            let astIdx = addAST(expr)
            emit(.evalAST, intOp: astIdx)

        case .ifElse(let cond, let thenStmts, let elseStmts):
            // if (cond) then_body else else_body として値も返す
            // then/else の最後の値がスタックに残る
            compileExpr(cond)
            let jzIdx = instructions.count
            emit(.jumpIfZero)  // placeholder → else へ

            // then
            if thenStmts.isEmpty {
                emit(.pushConst, doubleOp: 0)
            } else {
                for (i, s) in thenStmts.enumerated() {
                    compileExpr(s)
                    if i < thenStmts.count - 1 {
                        emit(.pop)
                    }
                }
            }
            let jmpIdx = instructions.count
            emit(.jump)  // placeholder → end へ

            // else
            let elseAddr = instructions.count
            if elseStmts.isEmpty {
                emit(.pushConst, doubleOp: 0)
            } else {
                for (i, s) in elseStmts.enumerated() {
                    compileExpr(s)
                    if i < elseStmts.count - 1 {
                        emit(.pop)
                    }
                }
            }
            let endAddr = instructions.count
            instructions[jzIdx].intOp = Int32(elseAddr)
            instructions[jmpIdx].intOp = Int32(endAddr)

        case .whileLoop(let cond, let body):
            // while (cond) body
            let loopStart = instructions.count
            compileExpr(cond)
            let jzIdx = instructions.count
            emit(.jumpIfZero)  // placeholder → end へ
            for s in body {
                compileExpr(s)
                emit(.pop)  // body の値は捨てる
            }
            emit(.jump, intOp: Int32(loopStart))
            let endAddr = instructions.count
            instructions[jzIdx].intOp = Int32(endAddr)
            // while 全体としては 0 を残す (loop 値)
            emit(.pushConst, doubleOp: 0)

        case .loopN(let countExpr, let body):
            // loop(n, body) を n 回繰り返す
            // 一時変数を使わないアプローチ:
            //   [compile countExpr]  → stack: [n]
            // loopStart:
            //   dup                  → stack: [n, n]
            //   pushConst 0          → stack: [n, n, 0]
            //   gt                   → stack: [n, (n>0 ? 1 : 0)]
            //   jumpIfZero endAddr
            //   [compile body]
            //   pop (body の値を捨てる)
            //   pushConst 1
            //   sub                  → stack: [n - 1]
            //   jump loopStart
            // endAddr:
            //   pop (残った 0)
            //   pushConst 0          → whole loop の結果値
            compileExpr(countExpr)
            let loopStart = instructions.count
            emit(.dup)
            emit(.pushConst, doubleOp: 0)
            emit(.gt)
            let jzIdx = instructions.count
            emit(.jumpIfZero)
            for s in body {
                compileExpr(s)
                emit(.pop)
            }
            emit(.pushConst, doubleOp: 1)
            emit(.sub)
            emit(.jump, intOp: Int32(loopStart))
            let endAddr = instructions.count
            instructions[jzIdx].intOp = Int32(endAddr)
            emit(.pop)  // 残った count (0)
            emit(.pushConst, doubleOp: 0)
        }
    }

    // MARK: BinOp → Opcode

    private func opcodeForBinOp(_ op: BinOp) -> EEL2Opcode {
        switch op {
        case .add: return .add
        case .sub: return .sub
        case .mul: return .mul
        case .div: return .div
        case .mod: return .mod
        case .pow: return .powOp
        case .eq:  return .eq
        case .neq: return .neq
        case .lt:  return .lt
        case .le:  return .le
        case .gt:  return .gt
        case .ge:  return .ge
        case .and: return .land
        case .or:  return .lor
        case .bitAnd: return .bitAnd
        case .bitOr:  return .bitOr
        case .bitXor: return .bitXor
        case .shl:    return .shl
        case .shr:    return .shr
        }
    }

    // MARK: Function serial

    /// EEL2Function を Int32 に serial 化 (VM 側でこれを使って function を呼び出す)
    static func funcSerial(_ fn: EEL2Function) -> Int32 {
        switch fn {
        case .sin:     return 0
        case .cos:     return 1
        case .tan:     return 2
        case .asin:    return 3
        case .acos:    return 4
        case .atan:    return 5
        case .atan2:   return 6
        case .sqrt:    return 7
        case .exp:     return 8
        case .log:     return 9
        case .log10:   return 10
        case .pow:     return 11
        case .abs:     return 12
        case .floor:   return 13
        case .ceil:    return 14
        case .min:     return 15
        case .max:     return 16
        case .sign:    return 17
        case .sinh:    return 18
        case .cosh:    return 19
        case .tanh:    return 20
        case .sqr:     return 21
        case .invsqrt: return 22
        }
    }

    static func funcFromSerial(_ s: Int32) -> EEL2Function? {
        switch s {
        case 0:  return .sin
        case 1:  return .cos
        case 2:  return .tan
        case 3:  return .asin
        case 4:  return .acos
        case 5:  return .atan
        case 6:  return .atan2
        case 7:  return .sqrt
        case 8:  return .exp
        case 9:  return .log
        case 10: return .log10
        case 11: return .pow
        case 12: return .abs
        case 13: return .floor
        case 14: return .ceil
        case 15: return .min
        case 16: return .max
        case 17: return .sign
        case 18: return .sinh
        case 19: return .cosh
        case 20: return .tanh
        case 21: return .sqr
        case 22: return .invsqrt
        default: return nil
        }
    }
}
