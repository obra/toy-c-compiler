import CCommon
import Foundation

// MARK: - Assembly Text → IR Parser

/// Parse ARM64 assembly text (as produced by the existing Codegen) into a list
/// of IR instructions. This is the bridge that lets us run IR-level optimizations
/// on the output of the existing single-pass codegen without modifying it.
///
/// The parser handles the instruction patterns emitted by Codegen.swift:
/// - Arithmetic: add, sub, mul, sdiv, udiv, madd, msub
/// - Logical: and, orr, eor, mvn
/// - Shifts: lsl, lsr, asr
/// - Memory: ldr, ldrb, ldrh, ldrsb, ldrsh, ldrsw, str, strb, strh
/// - Pairs: stp, ldp
/// - Branches: b, b.eq, b.ne, b.lt, b.le, b.gt, b.ge, b.lo, b.ls, b.hi, b.hs, etc.
/// - CBZ/CBNZ/TBZ/TBNZ
/// - Calls: bl, blr
/// - Data movement: mov, movz, movk, movn, fmov
/// - Sign/zero extend: sxtw, sxtb, sxth, uxtb, uxth
/// - FP: fadd, fsub, fmul, fdiv, fneg, fcvt, fcmp, scvtf, ucvtf, fcvtzs, fcvtzu
/// - Address: adrp, add (with @PAGE/@PAGEOFF), adr
/// - Other: cmp, cset, csetm, neg, clz, rbit, rev, rev16, sbfx, ret, dmb
/// - Int128: umulh, smulh, adds, subs, adc, sbc
/// - Labels: "L_name:"
/// - Directives: .text, .globl, .p2align, .section, .quad, .byte, .short, .long, .zero, .ascii, .asciz
///
/// Directives are preserved as comment instructions (they don't affect optimization).
/// Labels are preserved as .label instructions.

public func parseAssembly(_ lines: [String]) -> [IRInst] {
    var insts: [IRInst] = []
    var vregCounter = 0

    func newVReg(kind: VReg.RegKind = .gp) -> VReg {
        let v = VReg(id: vregCounter, kind: kind)
        vregCounter += 1
        return v
    }

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }

        // Directives: .text, .globl, .p2align, .section, .quad, etc.
        // Preserve as raw pass-through lines
        if trimmed.hasPrefix(".") {
            insts.append(.raw(trimmed))
            continue
        }

        // Label: "L_func_N:"
        if trimmed.hasSuffix(":") && !trimmed.contains(" ") {
            let label = String(trimmed.dropLast())
            insts.append(.label(label))
            continue
        }

        // Parse instruction
        let parts = tokenize(trimmed)
        guard let mnemonic = parts.first else { continue }
        let args = Array(parts.dropFirst())

        let inst = parseInstruction(mnemonic, args, &vregCounter, newVReg)
        if let inst = inst {
            insts.append(inst)
        } else {
            // Unknown instruction — preserve as comment
            insts.append(.comment(trimmed))
        }
    }

    return insts
}

// MARK: - Tokenizer

/// Split an assembly line into tokens, handling commas, brackets, and @ suffixes.
/// Example: "str w9, [x29, #-16]" → ["str", "w9", "[x29", "#-16]"]
/// Example: "b.ge L_sum_3" → ["b.ge", "L_sum_3"]
/// Example: "adrp x9, _name@PAGE" → ["adrp", "x9", "_name@PAGE"]
func tokenize(_ line: String) -> [String] {
    // Handle conditional branches: "b.eq", "b.ne", etc. → single token
    // These have a dot in the mnemonic.
    let working = line

    // Special case: "b.cond label" — keep "b.cond" as one token
    if working.hasPrefix("b.") {
        let afterB = working.dropFirst(2)
        if let spaceIdx = afterB.firstIndex(of: " ") {
            let cond = afterB[..<spaceIdx]
            let rest = afterB[afterB.index(after: spaceIdx)...]
            return ["b.\(cond)"] + tokenizeRest(String(rest))
        }
    }

    return tokenizeRest(working)
}

func tokenizeRest(_ s: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var inBrackets = false

    for ch in s {
        if ch == "[" {
            inBrackets = true
            current.append(ch)
        } else if ch == "]" {
            inBrackets = false
            current.append(ch)
        } else if ch == "," && !inBrackets {
            let t = current.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { tokens.append(t) }
            current = ""
        } else if ch == " " && !inBrackets {
            let t = current.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { tokens.append(t) }
            current = ""
        } else {
            current.append(ch)
        }
    }
    let t = current.trimmingCharacters(in: .whitespaces)
    if !t.isEmpty { tokens.append(t) }
    return tokens
}

// MARK: - Register Parsing

/// Parse a register string like "x9", "w9", "s3", "d5" into a VReg.
/// Since we're parsing existing assembly, each register reference creates a new VReg.
/// The optimizer will later coalesce these.
func parseReg(_ s: String, counter: inout Int) -> VReg? {
    // Clean up the string (remove brackets if present)
    let cleaned = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    
    if cleaned.hasPrefix("x") {
        let numStr = cleaned.dropFirst()
        if let num = Int(numStr) {
            return VReg(id: num, kind: .gp, isWord: false)
        }
    }
    if cleaned.hasPrefix("w") {
        let numStr = cleaned.dropFirst()
        if let num = Int(numStr) {
            return VReg(id: num, kind: .gp, isWord: true)
        }
    }
    if cleaned.hasPrefix("s") {
        let numStr = cleaned.dropFirst()
        if let num = Int(numStr) {
            return VReg(id: num, kind: .fp)
        }
    }
    if cleaned.hasPrefix("d") {
        let numStr = cleaned.dropFirst()
        if let num = Int(numStr) {
            return VReg(id: num, kind: .fp)
        }
    }
    if cleaned == "sp" {
        return VReg(id: 31, kind: .gp, isWord: false)
    }
    if cleaned == "xzr" {
        return VReg(id: 32, kind: .gp, isWord: false)
    }
    if cleaned == "wzr" {
        return VReg(id: 32, kind: .gp, isWord: true)
    }
    return nil
}

/// Parse an operand that could be a register or an immediate.
func parseOperand(_ s: String, counter: inout Int) -> Operand {
    let cleaned = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    
    // Immediate: #123 or #-16
    if cleaned.hasPrefix("#") {
        let immStr = cleaned.dropFirst()
        if let imm = Int64(immStr) {
            return .imm(imm)
        }
        // Could be #0x... hex
        if immStr.hasPrefix("0x") {
            if let imm = Int64(immStr.dropFirst(2), radix: 16) {
                return .imm(imm)
            }
        }
    }

    // Register
    if let vreg = parseReg(cleaned, counter: &counter) {
        return .vreg(vreg)
    }

    // Label/symbol reference
    return .label(cleaned)
}

// MARK: - Memory Operand Parsing

/// Parse a memory operand like "[x29, #-16]" or "[x29]" or "[sp, #16]" or "[reg, reg, lsl #3]"
/// Returns (base, offset, isPreIndexed, isPostIndexed)
struct MemOperand {
    let base: Operand
    let offset: Int          // 0 if no offset or register offset
    let regOffset: Operand?  // register offset (e.g., lsl #3)
    let preIndexed: Bool
    let postIndexed: Bool
}

func parseMemOperand(_ s: String, counter: inout Int) -> MemOperand? {
    // Remove brackets
    var inner = s.trimmingCharacters(in: .whitespaces)
    if inner.hasPrefix("[") { inner = String(inner.dropFirst()) }
    if inner.hasSuffix("]") { inner = String(inner.dropLast()) }
    if inner.hasSuffix("]!") { inner = String(inner.dropLast(2)) }  // pre-indexed: [x, #N]!

    // Split by comma
    let parts = inner.split(separator: ",", omittingEmptySubsequences: true).map {
        $0.trimmingCharacters(in: .whitespaces)
    }

    guard let first = parts.first else { return nil }
    let base = parseOperand(first, counter: &counter)

    var offset = 0
    var regOffset: Operand? = nil

    if parts.count >= 2 {
        let second = parts[1]
        if second.hasPrefix("#") {
            let offStr = second.dropFirst()
            offset = Int(offStr) ?? 0
        } else {
            // Register offset (possibly with shift: "x10, lsl #3")
            regOffset = parseOperand(second, counter: &counter)
        }
    }

    return MemOperand(
        base: base,
        offset: offset,
        regOffset: regOffset,
        preIndexed: s.hasSuffix("!"),
        postIndexed: false  // handled separately for post-index
    )
}

// MARK: - Instruction Parser

func parseInstruction(
    _ mnemonic: String,
    _ args: [String],
    _ counter: inout Int,
    _ newVReg: (VReg.RegKind) -> VReg
) -> IRInst? {
    let m = mnemonic

    switch m {
    // --- Arithmetic (integer) ---
    case "add":
        // Check for shifted register: "add x0, x1, x2, lsl #3"
        if args.count >= 5 && (args[3] == "lsl" || args[3] == "lsr" || args[3] == "asr") {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            let shiftType = args[3]
            let amountStr = args[4].hasPrefix("#") ? String(args[4].dropFirst()) : args[4]
            let amount = Int(amountStr) ?? 0
            return .addShifted(dst: dst, src1: src1, src2: src2, shift: shiftType, amount: amount)
        }
        if args.count >= 3 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            return .add(dst: dst, src1: src1, src2: src2)
        }
    case "sub":
        if args.count >= 3 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            return .sub(dst: dst, src1: src1, src2: src2)
        }
    case "mul":
        if args.count >= 3 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            return .mul(dst: dst, src1: src1, src2: src2)
        }
    case "sdiv":
        if args.count >= 3 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            return .sdiv(dst: dst, src1: src1, src2: src2)
        }
    case "udiv":
        if args.count >= 3 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            return .udiv(dst: dst, src1: src1, src2: src2)
        }
    case "madd":
        if args.count >= 4 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            let src3 = parseOperand(args[3], counter: &counter)
            return .madd(dst: dst, src1: src1, src2: src2, src3: src3)
        }
    case "msub":
        if args.count >= 4 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            let src3 = parseOperand(args[3], counter: &counter)
            return .msub(dst: dst, src1: src1, src2: src2, src3: src3)
        }

    // --- Arithmetic (floating-point) ---
    case "fadd", "fsub", "fmul", "fdiv":
        if args.count >= 3 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            switch m {
            case "fadd": return .fadd(dst: dst, src1: src1, src2: src2)
            case "fsub": return .fsub(dst: dst, src1: src1, src2: src2)
            case "fmul": return .fmul(dst: dst, src1: src1, src2: src2)
            case "fdiv": return .fdiv(dst: dst, src1: src1, src2: src2)
            default: break
            }
        }
    case "fneg":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            return .fneg(dst: dst, src: src)
        }

    // --- Logical ---
    case "and":
        if args.count >= 3 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            return .and(dst: dst, src1: src1, src2: src2)
        }
    case "orr":
        if args.count >= 3 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            return .orr(dst: dst, src1: src1, src2: src2)
        }
    case "eor":
        if args.count >= 3 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            return .eor(dst: dst, src1: src1, src2: src2)
        }
    case "mvn":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            return .mvn(dst: dst, src: src)
        }

    // --- Shifts ---
    case "lsl", "lsr", "asr":
        if args.count >= 3 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            switch m {
            case "lsl": return .lsl(dst: dst, src1: src1, src2: src2)
            case "lsr": return .lsr(dst: dst, src1: src1, src2: src2)
            case "asr": return .asr(dst: dst, src1: src1, src2: src2)
            default: break
            }
        }

    // --- Comparison ---
    case "cmp":
        if args.count >= 2 {
            let src1 = parseOperand(args[0], counter: &counter)
            let src2 = parseOperand(args[1], counter: &counter)
            return .cmp(src1: src1, src2: src2)
        }
    case "fcmp":
        if args.count >= 2 {
            let src1 = parseOperand(args[0], counter: &counter)
            let src2 = parseOperand(args[1], counter: &counter)
            return .fcmp(src1: src1, src2: src2)
        }

    // --- Conditional set ---
    case "cset":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let cond = parseCond(args[1])
            return .cset(dst: dst, cond: cond)
        }
    case "csetm":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let cond = parseCond(args[1])
            return .csetm(dst: dst, cond: cond)
        }

    // --- Data movement ---
    case "mov", "movz":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            return .mov(dst: dst, src: src)
        }
    case "movk":
        // movk is part of immediate loading — preserve as comment for now
        // (the loadImm case handles the full sequence)
        return .comment("movk \(args.joined(separator: ", "))")
    case "movn":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            return .mov(dst: dst, src: src)
        }
    case "fmov":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            return .fmov(dst: dst, src: src)
        }
    case "neg":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            return .neg(dst: dst, src: src)
        }

    // --- Sign/zero extension ---
    case "sxtw", "sxtb", "sxth", "uxtb", "uxth":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            switch m {
            case "sxtw": return .sxtw(dst: dst, src: src)
            case "sxtb": return .sxtb(dst: dst, src: src)
            case "sxth": return .sxth(dst: dst, src: src)
            case "uxtb": return .uxtb(dst: dst, src: src)
            case "uxth": return .uxth(dst: dst, src: src)
            default: break
            }
        }

    // --- Memory: load ---
    case "ldr", "ldrb", "ldrh", "ldrsb", "ldrsh", "ldrsw":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let (width, signed) = loadWidth(m)
            // Check for post-indexed: "ldr x9, [sp], #16"
            // Tokenized as: ["x9", "[sp]", "#16"] or ["x9", "[sp, #-16]"]
            if args.count >= 3 && args[1].hasPrefix("[") && args[1].hasSuffix("]") && args[2].hasPrefix("#") {
                // Post-indexed: [reg], #offset
                let base = parseOperand(args[1].trimmingCharacters(in: CharacterSet(charactersIn: "[]")), counter: &counter)
                let offStr = args[2].dropFirst()
                let offset = Int(offStr) ?? 0
                return .loadPost(src: dst, addr: base, offset: offset, width: width)
            }
            let memStr = args.dropFirst().joined(separator: ", ")
            if let mem = parseMemOperand(memStr, counter: &counter) {
                if mem.preIndexed {
                    return .loadPre(src: dst, addr: mem.base, offset: mem.offset, width: width)
                }
                return .load(dst: dst, addr: mem.base, offset: mem.offset, width: width, signed: signed)
            }
        }

    // --- Memory: store ---
    case "str", "strb", "strh":
        if args.count >= 2 {
            let src = parseOperand(args[0], counter: &counter)
            let width = storeWidth(m)
            // Check for post-indexed: "str x9, [sp], #16"
            if args.count >= 3 && args[1].hasPrefix("[") && args[1].hasSuffix("]") && args[2].hasPrefix("#") {
                let base = parseOperand(args[1].trimmingCharacters(in: CharacterSet(charactersIn: "[]")), counter: &counter)
                let offStr = args[2].dropFirst()
                let offset = Int(offStr) ?? 0
                return .storePost(src: src, addr: base, offset: offset, width: width)
            }
            let memStr = args.dropFirst().joined(separator: ", ")
            if let mem = parseMemOperand(memStr, counter: &counter) {
                if mem.preIndexed {
                    return .storePre(src: src, addr: mem.base, offset: mem.offset, width: width)
                }
                return .store(src: src, addr: mem.base, offset: mem.offset, width: width)
            }
        }

    // --- Load/store pair ---
    case "ldp":
        if args.count >= 2 {
            let dst1 = parseReg(args[0], counter: &counter)!
            let dst2 = parseReg(args[1], counter: &counter)!
            // Check for post-indexed: "ldp x29, x30, [sp], #16"
            // Tokenized as: ["x29", "x30", "[sp]", "#16"]
            if args.count >= 4 && args[2].hasPrefix("[") && args[2].hasSuffix("]") && args[3].hasPrefix("#") {
                let base = parseOperand(args[2].trimmingCharacters(in: CharacterSet(charactersIn: "[]")), counter: &counter)
                let offStr = args[3].dropFirst()
                let offset = Int(offStr) ?? 0
                return .ldpPost(dst1: dst1, dst2: dst2, addr: base, offset: offset)
            }
            let memStr = args.dropFirst(2).joined(separator: ", ")
            if let mem = parseMemOperand(memStr, counter: &counter) {
                if mem.preIndexed {
                    return .ldpPre(dst1: dst1, dst2: dst2, addr: mem.base, offset: mem.offset)
                }
                return .ldp(dst1: dst1, dst2: dst2, addr: mem.base, offset: mem.offset)
            }
        }
    case "stp":
        if args.count >= 2 {
            let src1 = parseOperand(args[0], counter: &counter)
            let src2 = parseOperand(args[1], counter: &counter)
            // Check for post-indexed: "stp x29, x30, [sp], #16"
            if args.count >= 4 && args[2].hasPrefix("[") && args[2].hasSuffix("]") && args[3].hasPrefix("#") {
                let base = parseOperand(args[2].trimmingCharacters(in: CharacterSet(charactersIn: "[]")), counter: &counter)
                let offStr = args[3].dropFirst()
                let offset = Int(offStr) ?? 0
                return .stpPost(src1: src1, src2: src2, addr: base, offset: offset)
            }
            let memStr = args.dropFirst(2).joined(separator: ", ")
            if let mem = parseMemOperand(memStr, counter: &counter) {
                if mem.preIndexed {
                    return .stpPre(src1: src1, src2: src2, addr: mem.base, offset: mem.offset)
                }
                return .stp(src1: src1, src2: src2, addr: mem.base, offset: mem.offset)
            }
        }

    // --- Address computation ---
    case "adr":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            return .adr(dst: dst, symbol: args[1])
        }
    case "adrp":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            // Strip @PAGE suffix
            let symbol = args[1].replacingOccurrences(of: "@PAGE", with: "")
            return .adrp(dst: dst, symbol: symbol)
        }

    // --- Branch ---
    case "b":
        if args.count >= 1 {
            return .b(label: args[0])
        }
    case "cbz":
        if args.count >= 2 {
            let src = parseOperand(args[0], counter: &counter)
            return .cbz(src: src, label: args[1])
        }
    case "cbnz":
        if args.count >= 2 {
            let src = parseOperand(args[0], counter: &counter)
            return .cbnz(src: src, label: args[1])
        }
    case "tbz":
        if args.count >= 3 {
            let src = parseOperand(args[0], counter: &counter)
            let bitStr = args[1].hasPrefix("#") ? String(args[1].dropFirst()) : args[1]
            let bit = Int(bitStr) ?? 0
            return .tbz(src: src, bit: bit, label: args[2])
        }
    case "tbnz":
        if args.count >= 3 {
            let src = parseOperand(args[0], counter: &counter)
            let bitStr = args[1].hasPrefix("#") ? String(args[1].dropFirst()) : args[1]
            let bit = Int(bitStr) ?? 0
            return .tbnz(src: src, bit: bit, label: args[2])
        }

    // --- Function call ---
    case "bl":
        if args.count >= 1 {
            return .call(target: args[0], args: [])
        }
    case "blr":
        if args.count >= 1 {
            let target = parseOperand(args[0], counter: &counter)
            return .callIndirect(target: target, args: [])
        }

    // --- Return ---
    case "ret":
        return .ret

    // --- Type conversions ---
    case "scvtf":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            let toFloat = args[0].hasPrefix("s")
            return .scvtf(dst: dst, src: src, toFloat: toFloat)
        }
    case "ucvtf":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            let toFloat = args[0].hasPrefix("s")
            return .ucvtf(dst: dst, src: src, toFloat: toFloat)
        }
    case "fcvtzs":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            let fromDouble = args[1].hasPrefix("d")
            return .fcvtzs(dst: dst, src: src, fromDouble: fromDouble, width: .dword)
        }
    case "fcvtzu":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            let fromDouble = args[1].hasPrefix("d")
            return .fcvtzu(dst: dst, src: src, fromDouble: fromDouble, width: .dword)
        }
    case "fcvt":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            let fromDouble = args[1].hasPrefix("d")
            return .fcvt(dst: dst, src: src, fromDouble: fromDouble)
        }

    // --- Int128 arithmetic ---
    case "adds":
        if args.count >= 3 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            return .adds(dst: dst, src1: src1, src2: src2)
        }
    case "subs":
        if args.count >= 3 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            return .subs(dst: dst, src1: src1, src2: src2)
        }
    case "adc":
        if args.count >= 3 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            return .adc(dst: dst, src1: src1, src2: src2)
        }
    case "sbc":
        if args.count >= 3 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            return .sbc(dst: dst, src1: src1, src2: src2)
        }
    case "umulh":
        if args.count >= 3 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            return .umulh(dst: dst, src1: src1, src2: src2)
        }
    case "smulh":
        if args.count >= 3 {
            let dst = parseReg(args[0], counter: &counter)!
            let src1 = parseOperand(args[1], counter: &counter)
            let src2 = parseOperand(args[2], counter: &counter)
            return .smulh(dst: dst, src1: src1, src2: src2)
        }

    // --- Miscellaneous ---
    case "clz":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            return .clz(dst: dst, src: src)
        }
    case "rbit":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            return .rbit(dst: dst, src: src)
        }
    case "rev":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            return .rev(dst: dst, src: src)
        }
    case "rev16":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            return .rev16(dst: dst, src: src)
        }
    case "sbfx":
        if args.count >= 4 {
            let dst = parseReg(args[0], counter: &counter)!
            let src = parseOperand(args[1], counter: &counter)
            let lsbStr = args[2].hasPrefix("#") ? String(args[2].dropFirst()) : args[2]
            let widthStr = args[3].hasPrefix("#") ? String(args[3].dropFirst()) : args[3]
            return .sbfx(dst: dst, src: src, lsb: Int(lsbStr) ?? 0, width: Int(widthStr) ?? 0)
        }
    case "dmb":
        return .dmb
    case "mrs":
        if args.count >= 2 {
            let dst = parseReg(args[0], counter: &counter)!
            return .mrs(dst: dst, reg: args[1])
        }

    // --- Conditional branch: b.eq, b.ne, etc. ---
    default:
        if m.hasPrefix("b.") {
            let condStr = String(m.dropFirst(2))
            let cond = parseCond(condStr)
            if args.count >= 1 {
                return .bcond(cond: cond, label: args[0])
            }
        }

    }

    // Handle "add" with @PAGEOFF (symbol address)
    if m == "add" && args.count >= 3 && args[2].contains("@PAGEOFF") {
        let dst = parseReg(args[0], counter: &counter)!
        let base = parseOperand(args[1], counter: &counter)
        let symbol = args[2].replacingOccurrences(of: "@PAGEOFF", with: "")
        return .addSymbol(dst: dst, base: base, symbol: symbol)
    }

    // Handle "sub sp, sp, #N" as subSP
    if m == "sub" && args.count >= 3 && args[0] == "sp" {
        if case .imm(let val) = parseOperand(args[2], counter: &counter) {
            return .subSP(dst: VReg(id: 31, kind: .gp), value: Int(val))
        }
    }

    // Handle "add sp, sp, #N" as addSP
    if m == "add" && args.count >= 3 && args[0] == "sp" {
        if case .imm(let val) = parseOperand(args[2], counter: &counter) {
            return .addSP(dst: VReg(id: 31, kind: .gp), value: Int(val))
        }
    }

    return nil
}

// MARK: - Condition Code Parsing

func parseCond(_ s: String) -> Cond {
    switch s {
    case "eq": return .eq
    case "ne": return .ne
    case "lt": return .lt
    case "le": return .le
    case "gt": return .gt
    case "ge": return .ge
    case "lo": return .lo
    case "ls": return .ls
    case "hi": return .hi
    case "hs": return .hs
    case "mi": return .mi
    case "pl": return .pl
    case "vs": return .vs
    case "vc": return .vc
    default: return .eq
    }
}

// MARK: - Width Helpers

func loadWidth(_ mnemonic: String) -> (Width, Bool) {
    switch mnemonic {
    case "ldr": return (.dword, false)      // default: 64-bit unsigned (may be overridden)
    case "ldrb": return (.byte, false)
    case "ldrh": return (.halfword, false)
    case "ldrsb": return (.byte, true)
    case "ldrsh": return (.halfword, true)
    case "ldrsw": return (.word, true)
    default: return (.dword, false)
    }
}

func storeWidth(_ mnemonic: String) -> Width {
    switch mnemonic {
    case "str": return .dword
    case "strb": return .byte
    case "strh": return .halfword
    default: return .dword
    }
}
