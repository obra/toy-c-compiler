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
            return regForm(v)
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

    /// Resolve a GP vreg to its physical register string, choosing w/x form
    /// based on the vreg's isWord flag. For FP registers, use d/s form.
    func regForm(_ v: VReg) -> String {
        if let s = regMap[v] {
            // Override the map's register form based on isWord
            if v.kind == .gp {
                let num = v.id
                if v.id == 31 { return "sp" }
                if v.id == 32 { return v.isWord ? "wzr" : "xzr" }
                return v.isWord ? "w\(num)" : "x\(num)"
            }
            // FP registers: use isWord to choose s (single) vs d (double) form
            if v.kind == .fp {
                if v.id == 32 { return v.isWord ? "wzr" : "xzr" }
                return v.isWord ? "s\(v.id)" : "d\(v.id)"
            }
            return s
        }
        // Spilled: reference as a frame slot.
        return "[x29, #\(v.id * 8)]"
    }

    /// Render an operand as a register in the correct width for a store instruction.
    /// strb/strh require w-form (32-bit) registers; str (dword) uses x-form (64-bit).
    func storeRegForm(_ op: Operand, width: Width) -> String {
        if case .vreg(let v) = op, v.kind == .gp {
            // For byte/halfword/word stores, use w-form
            // For dword stores, use x-form
            let useWord = width != .dword
            if v.id == 31 { return "sp" }
            if v.id == 32 { return useWord ? "wzr" : "xzr" }
            return useWord ? "w\(v.id)" : "x\(v.id)"
        }
        return operand(op)
    }

    /// Render a load destination register in the correct width.
    /// ldrb/ldrh require w-form; ldrsw/ldrsb/ldrsh can use x-form (sign-extends);
    /// ldr (dword) uses x-form; ldr (word unsigned) uses w-form.
    func loadRegForm(_ v: VReg, width: Width, signed: Bool) -> String {
        if v.kind == .gp {
            // Signed loads (ldrsb, ldrsh, ldrsw) can target x-form (sign-extends)
            // Unsigned byte/halfword loads (ldrb, ldrh) require w-form
            // Unsigned word load (ldr wN) uses w-form
            // Dword load (ldr xN) uses x-form
            let useWord: Bool
            if signed {
                // Signed loads can use either w or x form — use the register's own form
                useWord = v.isWord
            } else {
                // Unsigned: byte/halfword/word → w-form, dword → x-form
                useWord = width != .dword
            }
            if v.id == 31 { return "sp" }
            if v.id == 32 { return useWord ? "wzr" : "xzr" }
            return useWord ? "w\(v.id)" : "x\(v.id)"
        }
        return regForm(v)
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
            emit("add \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .addShifted(let dst, let s1, let s2, let shift, let amount):
            emit("add \(regForm(dst)), \(operand(s1)), \(operand(s2)), \(shift) #\(amount)", into: &out)
        case .sub(let dst, let s1, let s2):
            emit("sub \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .mul(let dst, let s1, let s2):
            emit("mul \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .sdiv(let dst, let s1, let s2):
            emit("sdiv \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .udiv(let dst, let s1, let s2):
            emit("udiv \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .madd(let dst, let s1, let s2, let s3):
            emit("madd \(regForm(dst)), \(operand(s1)), \(operand(s2)), \(operand(s3))", into: &out)
        case .msub(let dst, let s1, let s2, let s3):
            emit("msub \(regForm(dst)), \(operand(s1)), \(operand(s2)), \(operand(s3))", into: &out)

        // --- Arithmetic (floating-point) ---
        case .fadd(let dst, let s1, let s2):
            emit("fadd \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .fsub(let dst, let s1, let s2):
            emit("fsub \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .fmul(let dst, let s1, let s2):
            emit("fmul \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .fdiv(let dst, let s1, let s2):
            emit("fdiv \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .fneg(let dst, let src):
            emit("fneg \(regForm(dst)), \(operand(src))", into: &out)

        // --- Logical ---
        case .and(let dst, let s1, let s2):
            emit("and \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .orr(let dst, let s1, let s2):
            emit("orr \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .eor(let dst, let s1, let s2):
            emit("eor \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .mvn(let dst, let src):
            emit("mvn \(regForm(dst)), \(operand(src))", into: &out)

        // --- Shifts ---
        case .lsl(let dst, let s1, let s2):
            emit("lsl \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .lsr(let dst, let s1, let s2):
            emit("lsr \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .asr(let dst, let s1, let s2):
            emit("asr \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)

        // --- Comparison ---
        case .cmp(let s1, let s2):
            emit("cmp \(operand(s1)), \(operand(s2))", into: &out)
        case .fcmp(let s1, let s2):
            emit("fcmp \(operand(s1)), \(operand(s2))", into: &out)

        // --- Conditional set ---
        case .cset(let dst, let cond):
            emit("cset \(regForm(dst)), \(condString(cond))", into: &out)
        case .csetm(let dst, let cond):
            emit("csetm \(regForm(dst)), \(condString(cond))", into: &out)

        // --- Data movement ---
        case .mov(let dst, let src):
            // Use fmov for FP register copies
            if dst.kind == .fp {
                // fmov dN, dM is valid (FP→FP)
                // fmov dN, xM is valid (GP→FP, 64-bit)
                // fmov dN, wM is INVALID — must use x-form for GP source
                if case .vreg(let srcV) = src, srcV.kind == .gp, srcV.isWord {
                    // Force 64-bit x-form for GP source
                    emit("fmov \(regForm(dst)), x\(srcV.id)", into: &out)
                } else {
                    emit("fmov \(regForm(dst)), \(operand(src))", into: &out)
                }
            } else {
                emit("mov \(regForm(dst)), \(operand(src))", into: &out)
            }
        case .fmov(let dst, let src):
            emit("fmov \(regForm(dst)), \(operand(src))", into: &out)

        // --- Sign/zero extension ---
        case .sxtb(let dst, let src):
            emit("sxtb \(regForm(dst)), \(operand(src))", into: &out)
        case .sxth(let dst, let src):
            emit("sxth \(regForm(dst)), \(operand(src))", into: &out)
        case .sxtw(let dst, let src):
            emit("sxtw \(regForm(dst)), \(operand(src))", into: &out)
        case .uxtb(let dst, let src):
            emit("uxtb \(regForm(dst)), \(operand(src))", into: &out)
        case .uxth(let dst, let src):
            emit("uxth \(regForm(dst)), \(operand(src))", into: &out)

        // --- Memory: load/store ---
        case .load(let dst, let addr, let offset, let width, let signed):
            let mnem = signed ? width.loadSignedMnemonic : width.loadMnemonic
            let dstReg = loadRegForm(dst, width: width, signed: signed)
            emit("\(mnem) \(dstReg), [\(operand(addr)), #\(offset)]", into: &out)
        case .store(let src, let addr, let offset, let width):
            let srcReg = storeRegForm(src, width: width)
            emit("\(width.storeMnemonic) \(srcReg), [\(operand(addr)), #\(offset)]", into: &out)
        case .loadReg(let dst, let addr, let index, let width, let signed):
            let mnem = signed ? width.loadSignedMnemonic : width.loadMnemonic
            emit("\(mnem) \(regForm(dst)), [\(operand(addr)), \(operand(index))]", into: &out)
        case .storeReg(let src, let addr, let index, let width):
            emit("\(width.storeMnemonic) \(operand(src)), [\(operand(addr)), \(operand(index))]", into: &out)

        // --- Load/store pair ---
        case .ldp(let d1, let d2, let addr, let offset):
            emit("ldp \(regForm(d1)), \(regForm(d2)), [\(operand(addr)), #\(offset)]", into: &out)
        case .stp(let s1, let s2, let addr, let offset):
            emit("stp \(operand(s1)), \(operand(s2)), [\(operand(addr)), #\(offset)]", into: &out)
        case .ldpPre(let d1, let d2, let addr, let offset):
            emit("ldp \(regForm(d1)), \(regForm(d2)), [\(operand(addr)), #\(offset)]!", into: &out)
        case .stpPre(let s1, let s2, let addr, let offset):
            emit("stp \(operand(s1)), \(operand(s2)), [\(operand(addr)), #\(offset)]!", into: &out)
        case .ldpPost(let d1, let d2, let addr, let offset):
            emit("ldp \(regForm(d1)), \(regForm(d2)), [\(operand(addr))], #\(offset)", into: &out)
        case .stpPost(let s1, let s2, let addr, let offset):
            emit("stp \(operand(s1)), \(operand(s2)), [\(operand(addr))], #\(offset)", into: &out)

        // --- Address computation ---
        case .addrr(let dst, let base, let offset):
            emit("add \(regForm(dst)), \(operand(base)), #\(offset)", into: &out)
        case .adr(let dst, let symbol):
            emit("adr \(regForm(dst)), \(symbol)", into: &out)
        case .adrp(let dst, let symbol):
            // Don't add @PAGE if the symbol already has a relocation suffix (e.g., @GOTPAGE)
            if symbol.contains("@") {
                emit("adrp \(regForm(dst)), \(symbol)", into: &out)
            } else {
                emit("adrp \(regForm(dst)), \(symbol)@PAGE", into: &out)
            }
        case .addSymbol(let dst, let base, let symbol):
            emit("add \(regForm(dst)), \(operand(base)), \(symbol)@PAGEOFF", into: &out)

        // --- Immediate load ---
        case .loadImm(let dst, let value):
            emitLoadImm(regForm(dst), value, into: &out)

        // --- FP immediate load ---
        case .loadFImm(let dst, let value, let isFloat):
            emitLoadFImm(regForm(dst), value, isFloat: isFloat, into: &out)

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
            emit("clz \(regForm(dst)), \(operand(src))", into: &out)
        case .rbit(let dst, let src):
            emit("rbit \(regForm(dst)), \(operand(src))", into: &out)
        case .rev(let dst, let src):
            emit("rev \(regForm(dst)), \(operand(src))", into: &out)
        case .rev16(let dst, let src):
            emit("rev16 \(regForm(dst)), \(operand(src))", into: &out)
        case .sbfx(let dst, let src, let lsb, let width):
            emit("sbfx \(regForm(dst)), \(operand(src)), #\(lsb), #\(width)", into: &out)
        case .fcvt(let dst, let src, let fromDouble):
            if fromDouble {
                // double → float: fcvt sN, dN
                emit("fcvt \(sForm(regForm(dst))), \(operand(src))", into: &out)
            } else {
                // float → double: fcvt dN, sN
                emit("fcvt \(dForm(regForm(dst))), \(operand(src))", into: &out)
            }
        case .dmb:
            emit("dmb ish", into: &out)
        case .mrs(let dst, let regName):
            emit("mrs \(regForm(dst)), \(regName)", into: &out)

        // --- Type conversions ---
        case .neg(let dst, let src):
            emit("neg \(regForm(dst)), \(operand(src))", into: &out)
        case .scvtf(let dst, let src, let toFloat):
            let form = toFloat ? "s" : "d"
            emit("scvtf \(form)\(dst.id), \(operand(src))", into: &out)
        case .ucvtf(let dst, let src, let toFloat):
            let form = toFloat ? "s" : "d"
            emit("ucvtf \(form)\(dst.id), \(operand(src))", into: &out)
        case .fcvtzs(let dst, let src, let fromDouble, let width):
            let srcForm = fromDouble ? "d" : "s"
            let dstForm: String
            switch width {
            case .byte: dstForm = "w"; case .halfword: dstForm = "w"
            case .word: dstForm = "w"; case .dword: dstForm = "x"
            }
            emit("fcvtzs \(dstForm)\(dst.id), \(srcForm)\(src.asVReg?.id ?? 0)", into: &out)
        case .fcvtzu(let dst, let src, let fromDouble, let width):
            let srcForm = fromDouble ? "d" : "s"
            let dstForm: String
            switch width {
            case .byte: dstForm = "w"; case .halfword: dstForm = "w"
            case .word: dstForm = "w"; case .dword: dstForm = "x"
            }
            emit("fcvtzu \(dstForm)\(dst.id), \(srcForm)\(src.asVReg?.id ?? 0)", into: &out)
        case .fmovFromInt(let dst, let src, let isFloat):
            let form = isFloat ? "s" : "d"
            emit("fmov \(form)\(dst.id), \(operand(src))", into: &out)
        case .fmovToInt(let dst, let src, let isFloat):
            let srcForm = isFloat ? "s" : "d"
            emit("fmov \(regForm(dst)), \(srcForm)\(src.asVReg?.id ?? 0)", into: &out)

        // --- Multi-word arithmetic (for __int128) ---
        case .adds(let dst, let s1, let s2):
            emit("adds \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .subs(let dst, let s1, let s2):
            emit("subs \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .adc(let dst, let s1, let s2):
            emit("adc \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .sbc(let dst, let s1, let s2):
            emit("sbc \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .umulh(let dst, let s1, let s2):
            emit("umulh \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)
        case .smulh(let dst, let s1, let s2):
            emit("smulh \(regForm(dst)), \(operand(s1)), \(operand(s2))", into: &out)

        // --- Stack pointer operations ---
        case .addSP(let dst, let value):
            if value >= -4095 && value <= 4095 {
                emit("add \(regForm(dst)), sp, #\(value)", into: &out)
            } else {
                emitLoadImm("x16", Int64(value), into: &out)
                emit("add \(regForm(dst)), sp, x16", into: &out)
            }
        case .subSP(let dst, let value):
            if value >= -4095 && value <= 4095 {
                emit("sub \(regForm(dst)), sp, #\(value)", into: &out)
            } else {
                emitLoadImm("x16", Int64(value), into: &out)
                emit("sub \(regForm(dst)), sp, x16", into: &out)
            }

        // --- Pre/post-indexed load/store ---
        case .loadPre(let dst, let addr, let offset, let width):
            emit("\(width.loadMnemonic) \(regForm(dst)), [\(operand(addr)), #\(offset)]!", into: &out)
        case .storePre(let src, let addr, let offset, let width):
            emit("\(width.storeMnemonic) \(operand(src)), [\(operand(addr)), #\(offset)]!", into: &out)
        case .loadPost(let dst, let addr, let offset, let width):
            emit("\(width.loadMnemonic) \(regForm(dst)), [\(operand(addr))], #\(offset)", into: &out)
        case .storePost(let src, let addr, let offset, let width):
            emit("\(width.storeMnemonic) \(operand(src)), [\(operand(addr))], #\(offset)", into: &out)

        // --- Label ---
        case .label(let name):
            emit("\(name):", into: &out)

        // --- Comment ---
        case .comment(let text):
            emit("// \(text)", into: &out)

        // --- Raw pass-through (directives, etc.) ---
        case .raw(let text):
            emit(text, into: &out)
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
