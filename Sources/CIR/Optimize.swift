import CCommon

// MARK: - IR Optimizations

/// Run a series of IR-level optimizations on the instruction list.
/// Returns the optimized instruction list.
public func optimizeIR(_ insts: [IRInst]) -> [IRInst] {
    var result = insts

    // Run multiple passes until no more changes
    var changed = true
    var iterations = 0
    while changed && iterations < 10 {
        changed = false

        // Pass 1: Copy propagation (safe — doesn't remove instructions)
        let (copyResult, copyChanged) = copyPropagation(result)
        if copyChanged {
            result = copyResult
            changed = true
        }

        // Pass 2: Constant folding
        let (foldResult, foldChanged) = constantFolding(result)
        if foldChanged {
            result = foldResult
            changed = true
        }

        // Pass 3: Dead code elimination (conservative — only removes pure insts
        // whose results are never used, accounting for ABI implicit uses)
        let (dceResult, dceChanged) = deadCodeElimination(result)
        if dceChanged {
            result = dceResult
            changed = true
        }

        iterations += 1
    }

    return result
}

// MARK: - Dead Code Elimination

/// Remove instructions whose destination register is never used.
/// Only removes "pure" instructions (no side effects): arithmetic, logical,
/// shifts, sign/zero extension, moves, comparisons, cset.
/// Does NOT remove: stores, calls, branches, ret, labels, directives.
public func deadCodeElimination(_ insts: [IRInst]) -> ([IRInst], Bool) {
    // Collect all registers that are used as source operands
    // Use a normalized key (id, kind) ignoring isWord, since x9 and w9 are the same physical register
    var usedRegs = Set<NormalizedReg>()

    for inst in insts {
        for vreg in sourceVRegs(inst) {
            usedRegs.insert(NormalizedReg(vreg))
        }
        // Implicit uses: calls use x0-x7, ret uses x0
        for implicitReg in implicitlyUsedRegs(inst) {
            usedRegs.insert(NormalizedReg(implicitReg))
        }
    }

    var result: [IRInst] = []
    var changed = false

    for inst in insts {
        if isDead(inst, usedRegs: usedRegs) {
            changed = true
            continue
        }
        // Also remove movk comment lines (leftover from loadImm folding)
        if case .comment(let text) = inst, text.hasPrefix("movk ") {
            changed = true
            continue
        }
        result.append(inst)
    }

    return (result, changed)
}

/// Normalized register identity — ignores isWord, so x9 and w9 are the same.
struct NormalizedReg: Hashable {
    let id: Int
    let kind: VReg.RegKind
    init(_ v: VReg) {
        self.id = v.id
        self.kind = v.kind
    }
}

func isDead(_ inst: IRInst, usedRegs: Set<NormalizedReg>) -> Bool {
    guard let dst = destVReg(inst) else { return false }
    guard isPure(inst) else { return false }
    return !usedRegs.contains(NormalizedReg(dst))
}

/// Get registers implicitly used by an instruction (ABI constraints).
/// Calls use x0-x7 (argument registers), ret uses x0 (return value).
/// These must be kept alive even though no IRInst explicitly reads them.
func implicitlyUsedRegs(_ inst: IRInst) -> [VReg] {
    switch inst {
    case .call, .callIndirect:
        // x0-x7 are argument registers (both w and x forms)
        return (0...7).flatMap { n in
            [VReg(id: n, kind: .gp, isWord: false), VReg(id: n, kind: .gp, isWord: true)]
        }
    case .ret:
        // x0 is the return value register (both w and x forms)
        return [VReg(id: 0, kind: .gp, isWord: false), VReg(id: 0, kind: .gp, isWord: true)]
    default:
        return []
    }
}

/// Check if an instruction is pure (has no side effects beyond writing its destination).
func isPure(_ inst: IRInst) -> Bool {
    switch inst {
    case .add, .sub, .mul, .sdiv, .udiv, .madd, .msub,
         .fadd, .fsub, .fmul, .fdiv, .fneg,
         .and, .orr, .eor, .mvn,
         .lsl, .lsr, .asr,
         .cmp, .fcmp,
         .cset, .csetm,
         .mov, .fmov,
         .sxtw, .sxtb, .sxth, .uxtb, .uxth,
         .neg, .clz, .rbit, .rev, .rev16,
         .scvtf, .ucvtf, .fcvtzs, .fcvtzu, .fcvt,
         .adds, .subs, .adc, .sbc, .umulh, .smulh,
         .addShifted, .loadImm, .loadFImm:
        return true
    case .load, .loadPre, .loadPost:
        // Loads are pure (reading memory is a side effect in general, but for
        // stack-relative loads from our own frame, it's safe to DCE if unused)
        // Be conservative: don't DCE loads for now
        return false
    default:
        return false
    }
}

/// Get the destination VReg of an instruction (if it has one).
func destVReg(_ inst: IRInst) -> VReg? {
    switch inst {
    case .add(let d, _, _): return d
    case .addShifted(let d, _, _, _, _): return d
    case .sub(let d, _, _): return d
    case .mul(let d, _, _): return d
    case .sdiv(let d, _, _): return d
    case .udiv(let d, _, _): return d
    case .madd(let d, _, _, _): return d
    case .msub(let d, _, _, _): return d
    case .fadd(let d, _, _): return d
    case .fsub(let d, _, _): return d
    case .fmul(let d, _, _): return d
    case .fdiv(let d, _, _): return d
    case .fneg(let d, _): return d
    case .and(let d, _, _): return d
    case .orr(let d, _, _): return d
    case .eor(let d, _, _): return d
    case .mvn(let d, _): return d
    case .lsl(let d, _, _): return d
    case .lsr(let d, _, _): return d
    case .asr(let d, _, _): return d
    case .cset(let d, _): return d
    case .csetm(let d, _): return d
    case .mov(let d, _): return d
    case .fmov(let d, _): return d
    case .sxtw(let d, _): return d
    case .sxtb(let d, _): return d
    case .sxth(let d, _): return d
    case .uxtb(let d, _): return d
    case .uxth(let d, _): return d
    case .neg(let d, _): return d
    case .clz(let d, _): return d
    case .rbit(let d, _): return d
    case .rev(let d, _): return d
    case .rev16(let d, _): return d
    case .sbfx(let d, _, _, _): return d
    case .fcvt(let d, _, _): return d
    case .mrs(let d, _): return d
    case .scvtf(let d, _, _): return d
    case .ucvtf(let d, _, _): return d
    case .fcvtzs(let d, _, _, _): return d
    case .fcvtzu(let d, _, _, _): return d
    case .fmovFromInt(let d, _, _): return d
    case .fmovToInt(let d, _, _): return d
    case .adds(let d, _, _): return d
    case .subs(let d, _, _): return d
    case .adc(let d, _, _): return d
    case .sbc(let d, _, _): return d
    case .umulh(let d, _, _): return d
    case .smulh(let d, _, _): return d
    case .loadImm(let d, _): return d
    case .loadFImm(let d, _, _): return d
    case .load(let d, _, _, _, _): return d
    case .loadReg(let d, _, _, _, _): return d
    case .loadPre(let d, _, _, _): return d
    case .loadPost(let d, _, _, _): return d
    case .addrr(let d, _, _): return d
    case .adr(let d, _): return d
    case .adrp(let d, _): return d
    case .addSymbol(let d, _, _): return d
    default: return nil
    }
}

/// Get all source VRegs that an instruction reads.
func sourceVRegs(_ inst: IRInst) -> [VReg] {
    switch inst {
    case .add(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .addShifted(_, let s1, let s2, _, _): return vregsIn(s1) + vregsIn(s2)
    case .sub(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .mul(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .sdiv(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .udiv(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .madd(_, let s1, let s2, let s3): return vregsIn(s1) + vregsIn(s2) + vregsIn(s3)
    case .msub(_, let s1, let s2, let s3): return vregsIn(s1) + vregsIn(s2) + vregsIn(s3)
    case .fadd(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .fsub(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .fmul(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .fdiv(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .fneg(_, let s): return vregsIn(s)
    case .and(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .orr(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .eor(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .mvn(_, let s): return vregsIn(s)
    case .lsl(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .lsr(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .asr(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .cmp(let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .fcmp(let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .cset: return []
    case .csetm: return []
    case .mov(_, let s): return vregsIn(s)
    case .fmov(_, let s): return vregsIn(s)
    case .sxtw(_, let s): return vregsIn(s)
    case .sxtb(_, let s): return vregsIn(s)
    case .sxth(_, let s): return vregsIn(s)
    case .uxtb(_, let s): return vregsIn(s)
    case .uxth(_, let s): return vregsIn(s)
    case .neg(_, let s): return vregsIn(s)
    case .clz(_, let s): return vregsIn(s)
    case .rbit(_, let s): return vregsIn(s)
    case .rev(_, let s): return vregsIn(s)
    case .rev16(_, let s): return vregsIn(s)
    case .sbfx(_, let s, _, _): return vregsIn(s)
    case .fcvt(_, let s, _): return vregsIn(s)
    case .mrs: return []
    case .scvtf(_, let s, _): return vregsIn(s)
    case .ucvtf(_, let s, _): return vregsIn(s)
    case .fcvtzs(_, let s, _, _): return vregsIn(s)
    case .fcvtzu(_, let s, _, _): return vregsIn(s)
    case .fmovFromInt(_, let s, _): return vregsIn(s)
    case .fmovToInt(_, let s, _): return vregsIn(s)
    case .adds(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .subs(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .adc(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .sbc(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .umulh(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .smulh(_, let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .store(let s, let a, _, _): return vregsIn(s) + vregsIn(a)
    case .storeReg(let s, let a, let i, _): return vregsIn(s) + vregsIn(a) + vregsIn(i)
    case .storePre(let s, let a, _, _): return vregsIn(s) + vregsIn(a)
    case .storePost(let s, let a, _, _): return vregsIn(s) + vregsIn(a)
    case .load(_, let a, _, _, _): return vregsIn(a)
    case .loadReg(_, let a, let i, _, _): return vregsIn(a) + vregsIn(i)
    case .loadPre(_, let a, _, _): return vregsIn(a)
    case .loadPost(_, let a, _, _): return vregsIn(a)
    case .stp(let s1, let s2, let a, _): return vregsIn(s1) + vregsIn(s2) + vregsIn(a)
    case .stpPre(let s1, let s2, let a, _): return vregsIn(s1) + vregsIn(s2) + vregsIn(a)
    case .stpPost(let s1, let s2, let a, _): return vregsIn(s1) + vregsIn(s2) + vregsIn(a)
    case .ldp(_, _, let a, _): return vregsIn(a)
    case .ldpPre(_, _, let a, _): return vregsIn(a)
    case .ldpPost(_, _, let a, _): return vregsIn(a)
    case .addrr(_, let b, _): return vregsIn(b)
    case .addSymbol(_, let b, _): return vregsIn(b)
    case .cbz(let s, _): return vregsIn(s)
    case .cbnz(let s, _): return vregsIn(s)
    case .tbz(let s, _, _): return vregsIn(s)
    case .tbnz(let s, _, _): return vregsIn(s)
    case .callIndirect(let t, _): return vregsIn(t)
    case .loadImm: return []
    case .loadFImm: return []
    case .adr: return []
    case .adrp: return []
    case .b: return []
    case .bcond: return []
    case .call: return []
    case .ret: return []
    case .label: return []
    case .comment: return []
    case .raw: return []
    case .dmb: return []
    case .addSP: return []
    case .subSP: return []
    }
}

func vregsIn(_ op: Operand) -> [VReg] {
    if case .vreg(let v) = op { return [v] }
    return []
}

// MARK: - Copy Propagation

/// Replace uses of `mov dst, src` with uses of `src` directly, when `dst` is
/// not modified between the mov and its use.
public func copyPropagation(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result = insts
    var changed = false

    // Build a map: for each mov dst, src instruction, remember the mapping
    // Then for subsequent uses of dst, replace with src (if dst is not reassigned)

    // Simple single-pass: for each mov, if the source is another mov's destination,
    // replace the source with the original source.
    var copyMap: [VReg: Operand] = [:]

    for i in 0..<result.count {
        let inst = result[i]

        // Check if this is a mov
        if case .mov(let dst, let src) = inst {
            // If src is a vreg that was the dst of a previous mov, use the original src
            if case .vreg(let srcVReg) = src, let originalSrc = copyMap[srcVReg] {
                // Don't create a self-mov (mov x, x) — keep the original
                if case .vreg(let origVReg) = originalSrc, origVReg == dst {
                    // This would be mov dst, dst — skip the propagation
                } else {
                    result[i] = .mov(dst: dst, src: originalSrc)
                    changed = true
                }
            }
            // Record this copy
            copyMap[dst] = src
            // If dst is reassigned, remove any entries that map to dst
            copyMap = copyMap.filter { _, v in
                if case .vreg(let v2) = v, v2 == dst { return false }
                return true
            }
        } else {
            // For non-mov instructions, check if any source operands can be replaced
            // For now, we only propagate through movs (conservative)
            // If this instruction writes to a register that's in copyMap as a destination,
            // invalidate that entry
            if let dst = destVReg(inst) {
                copyMap.removeValue(forKey: dst)
                // Also remove entries where dst appears as a source in the copy map
                copyMap = copyMap.filter { _, v in
                    if case .vreg(let v2) = v, v2 == dst { return false }
                    return true
                }
            }
        }
    }

    return (result, changed)
}

// MARK: - Constant Folding

/// Fold simple constant computations.
/// Example: loadImm x9, #3 → loadImm x9, #3 (no change)
/// Example: add x9, x8, #1 where x8 = loadImm #3 → loadImm x9, #4
public func constantFolding(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result = insts
    var changed = false

    // Track register constant values
    var constValues: [VReg: Int64] = [:]

    for i in 0..<result.count {
        let inst = result[i]

        switch inst {
        case .loadImm(let dst, let val):
            constValues[dst] = val

        case .add(let dst, let s1, let s2):
            let v1 = getConst(s1, constValues)
            let v2 = getConst(s2, constValues)
            if let v1 = v1, let v2 = v2 {
                result[i] = .loadImm(dst: dst, value: v1 &+ v2)
                constValues[dst] = v1 &+ v2
                changed = true
            } else {
                constValues.removeValue(forKey: dst)
            }

        case .sub(let dst, let s1, let s2):
            let v1 = getConst(s1, constValues)
            let v2 = getConst(s2, constValues)
            if let v1 = v1, let v2 = v2 {
                result[i] = .loadImm(dst: dst, value: v1 &- v2)
                constValues[dst] = v1 &- v2
                changed = true
            } else {
                constValues.removeValue(forKey: dst)
            }

        case .mul(let dst, let s1, let s2):
            let v1 = getConst(s1, constValues)
            let v2 = getConst(s2, constValues)
            if let v1 = v1, let v2 = v2 {
                result[i] = .loadImm(dst: dst, value: v1 &* v2)
                constValues[dst] = v1 &* v2
                changed = true
            } else {
                constValues.removeValue(forKey: dst)
            }

        case .mov(let dst, let src):
            if let val = getConst(src, constValues) {
                constValues[dst] = val
            } else {
                constValues.removeValue(forKey: dst)
            }

        default:
            if let dst = destVReg(inst) {
                constValues.removeValue(forKey: dst)
            }
        }
    }

    return (result, changed)
}

func getConst(_ op: Operand, _ map: [VReg: Int64]) -> Int64? {
    switch op {
    case .imm(let i): return i
    case .vreg(let v): return map[v]
    default: return nil
    }
}
