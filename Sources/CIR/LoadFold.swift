import CCommon

// MARK: - Load-Target Folding

/// Fold `ldr wN, [addr]` + `mov xP, xN` into `ldr wP, [addr]` when xN is
/// not used after the mov. This eliminates the mov by loading directly
/// into the final destination register.
///
/// Also handles: `ldr xN, [addr]` + `mov xP, xN` → `ldr xP, [addr]`
public func loadTargetFolding(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result: [IRInst] = []
    var changed = false

    var i = 0
    while i < insts.count {
        let inst = insts[i]

        // Look for: load dst, addr, offset, width, signed followed by mov dst2, dst
        if case .load(let dst, let addr, let offset, let width, let signed) = inst,
           i + 1 < insts.count,
           case .mov(let dst2, let src) = insts[i + 1],
           case .vreg(let srcVReg) = src, NormalizedReg(srcVReg) == NormalizedReg(dst) {
            // Check if dst is not used between the load and the mov (it's the immediate next instruction)
            // and dst is not used after the mov before being reassigned
            if !usedAfter(insts, after: i + 1, reg: dst) {
                // Fold: load directly into dst2
                // Keep the width of the original load (w stays w, x stays x)
                result.append(.load(dst: dst2, addr: addr, offset: offset, width: width, signed: signed))
                changed = true
                i += 2  // skip both load and mov
                continue
            }
        }

        result.append(inst)
        i += 1
    }

    return (result, changed)
}

/// Check if a register is used after the given index (as a source in any instruction)
/// before being reassigned. Returns true if used, false if dead.
func usedAfter(_ insts: [IRInst], after idx: Int, reg: VReg) -> Bool {
    let regNorm = NormalizedReg(reg)

    for j in (idx+1)..<min(idx+30, insts.count) {
        let inst = insts[j]

        // If reg is reassigned, it's dead (not used before reassignment)
        if let dst = destVReg(inst), NormalizedReg(dst) == regNorm {
            return false
        }

        // If reg is used as a source, it's live
        for src in sourceVRegs(inst) {
            if NormalizedReg(src) == regNorm {
                return true
            }
        }

        // Stop at control flow (register might be used in other blocks)
        switch inst {
        case .b, .bcond, .cbz, .cbnz, .tbz, .tbnz, .ret, .label:
            return true
        case .call, .callIndirect:
            return true
        default:
            break
        }
    }

    return true  // Conservative
}
