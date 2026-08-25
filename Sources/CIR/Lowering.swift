import CCommon

// MARK: - IR → ARM64 Lowering

/// Convert a list of IR instructions into ARM64 assembly text lines.
///
/// `regMap` maps each virtual register to its assigned physical register string
/// (e.g. `VReg(0, .gp)` → `"x9"`, `VReg(1, .fp)` → `"d0"`). Spilled vregs (those
/// not present in the map) are treated as `[x29, #offset]` frame slots using the
/// vreg id as the offset — this mirrors how a simple spill allocator would work.
public func lowerIR(_ insts: [IRInst], regMap: [VReg: String]) -> [String] {
    var out: [String] = []
    var lower = Lowerer(regMap: regMap)
    for inst in insts {
        lower.lower(inst, into: &out)
    }
    return out
}

/// Lower an entire IR function: iterate over all basic blocks and concatenate
/// the lowered instruction lines.
public func lowerFunction(_ function: IRFunction, regMap: [VReg: String]) -> [String] {
    var out: [String] = []
    var lower = Lowerer(regMap: regMap)
    for block in function.blocks {
        out.append("\(block.label):")
        for inst in block.insts {
            lower.lower(inst, into: &out)
        }
    }
    return out
}

// MARK: - Lowerer

/// Stateful helper that resolves operands and emits assembly lines.
fileprivate struct Lowerer {
    let regMap: [VReg: String]

    /// Resolve an operand to its string representation in an operand position.
    /// - `.vreg(v)` → physical register string (or a frame slot if spilled)
    /// - `.imm(i)` → `"#\(i)"`
    /// - `.slot(off)` → `"[x29, #\(off)]"`
    /// - `.global(name)` → the symbol name
    /// - `.label(name)` → the label name
    /// - `.funcRef(name)` → the function name
    func operand(_ op: Operand) -> String {
        switch op {
        case .vreg(let v):
            return reg(v)
        case .imm(let i):
            return "#\(i)"
        case .immF(let d):
            return "#\(d)"
        case .immF32(let f):
            return "#\(f)"
        case .slot(let off):
            return "[x29, #\(off)]"
        case .global(let name):
            return name
        case .label(let name):
            return name
        case .funcRef(let name):
            return name
        }
    }

    /// Resolve a vreg to its physical register string. If the vreg is not in
    /// the map (spilled), fall back to a frame slot reference using the id as
    /// the stack offset.
    func reg(_ v: VReg) -> String {
        if let s = regMap[v] {
            return s
        }
        // Spilled: reference as a frame slot.
        return "[x29, #\(v.id * 8)]"
    }

    /// Convert an FP register string to its 64-bit (D) form.
    /// "d0" → "d0", "s0" → "d0".
    func dForm(_ s: String) -> String {
        if s.hasPrefix("s") {
            return "d" + s.dropFirst()
        }
        return s
    }

    /// Convert an FP register string to its 32-bit (S) form.
    /// "d0" → "s0", "s0" → "s0".
    func sForm(_ s: String) -> String {
        if s.hasPrefix("d") {
            return "s" + s.dropFirst()
        }
        return s
    }

    /// Emit a single assembly line.
    mutating func emit(_ s: String, into out: inout [String]) {
        out.append(s)
    }

    // MARK: - Immediate loading (copied from emitLoadImm in Codegen.swift)

    /// Load a 64-bit immediate into a GP register, expanding to movz/movk or
    /// movn sequences as needed. This mirrors `emitLoadImm` in Codegen.swift.
    mutating func emitLoadImm(_ reg: String, _ value: Int64, into out: inout [String]) {
        let v = UInt64(bitPattern: value)
        if v <= 0xFFFF {
            emit("mov \(reg), #\(value)", into: &out)
        } else if v == 0 {
            emit("mov \(reg), #0", into: &out)
        } else {
            // Check if movn can encode this in fewer instructions than movz+movk.
            // movn x, #imm, lsl #shift loads ~(imm << shift).
            // If ~v fits in a single 16-bit chunk (all other chunks are 0),
            // movn is 1 instruction instead of 2-4.
            let notV = ~v
            // Check each 16-bit position for a movn encoding
            let w0 = UInt16(truncatingIfNeeded: notV)
            let w1 = UInt16(truncatingIfNeeded: notV >> 16)
            let w2 = UInt16(truncatingIfNeeded: notV >> 32)
            let w3 = UInt16(truncatingIfNeeded: notV >> 48)
            if w1 == 0 && w2 == 0 && w3 == 0 && w0 != 0 {
                // ~v fits in low 16 bits
                emit("movn \(reg), #\(w0)", into: &out)
            } else if w0 == 0 && w2 == 0 && w3 == 0 && w1 != 0 {
                // ~v fits in bits 16-31
                emit("movn \(reg), #\(w1), lsl #16", into: &out)
            } else if w0 == 0 && w1 == 0 && w3 == 0 && w2 != 0 {
                // ~v fits in bits 32-47
                emit("movn \(reg), #\(w2), lsl #32", into: &out)
            } else if w0 == 0 && w1 == 0 && w2 == 0 && w3 != 0 {
                // ~v fits in bits 48-63
                emit("movn \(reg), #\(w3), lsl #48", into: &out)
            } else {
                // Use movz for the low 16 bits, then movk for higher 16-bit chunks
                let mw0 = UInt16(truncatingIfNeeded: v)
                let mw1 = UInt16(truncatingIfNeeded: v >> 16)
                let mw2 = UInt16(truncatingIfNeeded: v >> 32)
                let mw3 = UInt16(truncatingIfNeeded: v >> 48)
                emit("movz \(reg), #\(mw0)", into: &out)
                if mw1 != 0 { emit("movk \(reg), #\(mw1), lsl #16", into: &out) }
                if mw2 != 0 { emit("movk \(reg), #\(mw2), lsl #32", into: &out) }
                if mw3 != 0 { emit("movk \(reg), #\(mw3), lsl #48", into: &out) }
            }
        }
    }

    /// Load an FP immediate (double or float) into an FP register.
    /// Strategy: load the IEEE 754 bit pattern into an integer register via
    /// emitLoadImm, then transfer to the FP register with fmov.
    /// We use a scratch integer register (x17) as a temporary since the
    /// destination is an FP register and the caller's integer registers are
    /// not available as temporaries in this position.
    mutating func emitLoadFImm(_ fpReg: String, _ value: Double, isFloat: Bool, into out: inout [String]) {
        let bits: UInt64
        if isFloat {
            bits = UInt64(Float(value).bitPattern)
        } else {
            bits = value.bitPattern
        }
        // Use x17 as a scratch integer register to load the bit pattern.
        let scratch = "x17"
        emitLoadImm(scratch, Int64(bitPattern: bits), into: &out)
        if isFloat {
            // fmov sN, wN
            emit("fmov \(sForm(fpReg)), w17", into: &out)
        } else {
            // fmov dN, xN
            emit("fmov \(dForm(fpReg)), \(scratch)", into: &out)
        }
    }

    // MARK: - Instruction lowering

    mutating func lower(_ inst: IRInst, into out: inout [String]) {
        switch inst {
        // --- Arithmetic (integer) ---
        case .add(let dst, let s1, let s2):
            emit("add \(reg(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .sub(let dst, let s1, let s2):
            emit("sub \(reg(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .mul(let dst, let s1, let s2):
            emit("mul \(reg(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .sdiv(let dst, let s1, let s2):
            emit("sdiv \(reg(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .udiv(let dst, let s1, let s2):
            emit("udiv \(reg(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .madd(let dst, let s1, let s2, let s3):
            emit("madd \(reg(dst)), \(operand(s1)), \(operand(s2)), \(operand(s3))", into: &out)
        case .msub(let dst, let s1, let s2, let s3):
            emit("msub \(reg(dst)), \(operand(s1)), \(operand(s2)), \(operand(s3))", into: &out)

        // --- Arithmetic (floating-point) ---
        case .fadd(let dst, let s1, let s2):
            emit("fadd \(reg(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .fsub(let dst, let s1, let s2):
            emit("fsub \(reg(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .fmul(let dst, let s1, let s2):
            emit("fmul \(reg(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .fdiv(let dst, let s1, let s2):
            emit("fdiv \(reg(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .fneg(let dst, let src):
            emit("fneg \(reg(dst)), \(operand(src))", into: &out)

        // --- Logical ---
        case .and(let dst, let s1, let s2):
            emit("and \(reg(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .orr(let dst, let s1, let s2):
            emit("orr \(reg(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .eor(let dst, let s1, let s2):
            emit("eor \(reg(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .mvn(let dst, let src):
            emit("mvn \(reg(dst)), \(operand(src))", into: &out)

        // --- Shifts ---
        case .lsl(let dst, let s1, let s2):
            emit("lsl \(reg(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .lsr(let dst, let s1, let s2):
            emit("lsr \(reg(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .asr(let dst, let s1, let s2):
            emit("asr \(reg(dst)), \(operand(s1)), \(operand(s2))", into: &out)

        // --- Comparison ---
        case .cmp(let s1, let s2):
            emit("cmp \(operand(s1)), \(operand(s2))", into: &out)
        case .fcmp(let s1, let s2):
            emit("fcmp \(operand(s1)), \(operand(s2))", into: &out)

        // --- Conditional set ---
        case .cset(let dst, let cond):
            emit("cset \(reg(dst)), \(condString(cond))", into: &out)
        case .csetm(let dst, let cond):
            emit("csetm \(reg(dst)), \(condString(cond))", into: &out)

        // --- Data movement ---
        case .mov(let dst, let src):
            emit("mov \(reg(dst)), \(operand(src))", into: &out)
        case .fmov(let dst, let src):
            emit("fmov \(reg(dst)), \(operand(src))", into: &out)

        // --- Sign/zero extension ---
        case .sxtb(let dst, let src):
            emit("sxtb \(reg(dst)), \(operand(src))", into: &out)
        case .sxth(let dst, let src):
            emit("sxth \(reg(dst)), \(operand(src))", into: &out)
        case .sxtw(let dst, let src):
            emit("sxtw \(reg(dst)), \(operand(src))", into: &out)
        case .uxtb(let dst, let src):
            emit("uxtb \(reg(dst)), \(operand(src))", into: &out)
        case .uxth(let dst, let src):
            emit("uxth \(reg(dst)), \(operand(src))", into: &out)

        // --- Memory: load/store ---
        case .load(let dst, let addr, let offset, let width, let signed):
            let mnem = signed ? width.loadSignedMnemonic : width.loadMnemonic
            emit("\(mnem) \(reg(dst)), [\(operand(addr)), #\(offset)]", into: &out)
        case .store(let src, let addr, let offset, let width):
            emit("\(width.storeMnemonic) \(operand(src)), [\(operand(addr)), #\(offset)]", into: &out)

        // --- Load/store pair ---
        case .ldp(let d1, let d2, let addr, let offset):
            emit("ldp \(reg(d1)), \(reg(d2)), [\(operand(addr)), #\(offset)]", into: &out)
        case .stp(let s1, let s2, let addr, let offset):
            emit("stp \(operand(s1)), \(operand(s2)), [\(operand(addr)), #\(offset)]", into: &out)

        // --- Address computation ---
        case .addrr(let dst, let base, let offset):
            emit("add \(reg(dst)), \(operand(base)), #\(offset)", into: &out)
        case .adr(let dst, let symbol):
            emit("adr \(reg(dst)), \(symbol)", into: &out)
        case .adrp(let dst, let symbol):
            emit("adrp \(reg(dst)), \(symbol)@PAGE", into: &out)
        case .addSymbol(let dst, let base, let symbol):
            emit("add \(reg(dst)), \(operand(base)), \(symbol)@PAGEOFF", into: &out)

        // --- Immediate load ---
        case .loadImm(let dst, let value):
            emitLoadImm(reg(dst), value, into: &out)

        // --- FP immediate load ---
        case .loadFImm(let dst, let value, let isFloat):
            emitLoadFImm(reg(dst), value, isFloat: isFloat, into: &out)

        // --- Branch ---
        case .b(let label):
            emit("b \(label)", into: &out)
        case .bcond(let cond, let label):
            emit("b.\(condString(cond)) \(label)", into: &out)
        case .cbz(let src, let label):
            emit("cbz \(operand(src)), \(label)", into: &out)
        case .cbnz(let src, let label):
            emit("cbnz \(operand(src)), \(label)", into: &out)
        case .tbz(let src, let bit, let label):
            emit("tbz \(operand(src)), #\(bit), \(label)", into: &out)
        case .tbnz(let src, let bit, let label):
            emit("tbnz \(operand(src)), #\(bit), \(label)", into: &out)

        // --- Function call ---
        case .call(let target, _):
            // Direct call: bl target
            emit("bl \(target)", into: &out)
        case .callIndirect(let target, _):
            emit("blr \(operand(target))", into: &out)

        // --- Return ---
        case .ret:
            emit("ret", into: &out)

        // --- Miscellaneous ---
        case .clz(let dst, let src):
            emit("clz \(reg(dst)), \(operand(src))", into: &out)
        case .rbit(let dst, let src):
            emit("rbit \(reg(dst)), \(operand(src))", into: &out)
        case .rev(let dst, let src):
            emit("rev \(reg(dst)), \(operand(src))", into: &out)
        case .rev16(let dst, let src):
            emit("rev16 \(reg(dst)), \(operand(src))", into: &out)
        case .sbfx(let dst, let src, let lsb, let width):
            emit("sbfx \(reg(dst)), \(operand(src)), #\(lsb), #\(width)", into: &out)
        case .fcvt(let dst, let src, let fromDouble):
            if fromDouble {
                // double → float: fcvt sN, dN
                emit("fcvt \(sForm(reg(dst))), \(operand(src))", into: &out)
            } else {
                // float → double: fcvt dN, sN
                emit("fcvt \(dForm(reg(dst))), \(operand(src))", into: &out)
            }
        case .dmb:
            emit("dmb ish", into: &out)
        case .mrs(let dst, let regName):
            emit("mrs \(reg(dst)), \(regName)", into: &out)

        // --- Label ---
        case .label(let name):
            emit("\(name):", into: &out)

        // --- Comment ---
        case .comment(let text):
            emit("// \(text)", into: &out)
        }
    }

    /// Convert a Cond enum to its ARM64 mnemonic suffix string.
    func condString(_ cond: Cond) -> String {
        switch cond {
        case .eq: return "eq"
        case .ne: return "ne"
        case .lt: return "lt"
        case .le: return "le"
        case .gt: return "gt"
        case .ge: return "ge"
        case .lo: return "lo"
        case .ls: return "ls"
        case .hi: return "hi"
        case .hs: return "hs"
        case .mi: return "mi"
        case .pl: return "pl"
        case .vs: return "vs"
        case .vc: return "vc"
        }
    }
}
