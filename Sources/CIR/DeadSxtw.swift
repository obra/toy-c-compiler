import CCommon

// MARK: - Dead Sign Extension Elimination

/// Eliminate sign/zero extension instructions when the result is only used
/// in a narrower form. Handles sxtw, sxtb, sxth, uxtb, uxth.
///
/// Pattern: sxtw x9, w9 followed by instructions using w9 (never x9)
/// → remove the sxtw
///
/// Only removes when the extended form is not used before being reassigned.
public func deadSignExtensionElimination(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result: [IRInst] = []
    var changed = false

    var i = 0
    while i < insts.count {
        let inst = insts[i]

        // Check all sign/zero extension instructions where dst and src have same reg number
        let extDst: VReg? = {
            switch inst {
            case .sxtw(let d, _): return d
            case .sxtb(let d, _): return d
            case .sxth(let d, _): return d
            case .uxtb(let d, _): return d
            case .uxth(let d, _): return d
            default: return nil
            }
        }()

        let extSrc: VReg? = {
            switch inst {
            case .sxtw(_, let s): return s.asVReg
            case .sxtb(_, let s): return s.asVReg
            case .sxth(_, let s): return s.asVReg
            case .uxtb(_, let s): return s.asVReg
            case .uxth(_, let s): return s.asVReg
            default: return nil
            }
        }()

        if let dst = extDst, let src = extSrc, NormalizedReg(dst) == NormalizedReg(src) {
            // Check if dst is used in 64-bit form before being reassigned
            if !usedIn64BitForm(insts, after: i, reg: dst) {
                // Extension is dead — skip it
                changed = true
                i += 1
                continue
            }
        }

        result.append(inst)
        i += 1
    }

    return (result, changed)
}

/// Check if a register is used in 64-bit (x) form before being reassigned.
/// Returns true if the 64-bit form is used, false if only 32-bit (w) form
/// is used (or the register is reassigned without any use).
func usedIn64BitForm(_ insts: [IRInst], after idx: Int, reg: VReg) -> Bool {
    let regNorm = NormalizedReg(reg)

    for j in (idx+1)..<min(idx+30, insts.count) {
        let inst = insts[j]

        // If reg is reassigned (written to), stop
        if let dst = destVReg(inst), NormalizedReg(dst) == regNorm {
            // Check if it's written in 64-bit form (x) — if so, the old value
            // including sxtw is overwritten, so sxtw was dead
            if !dst.isWord {
                return false  // Reassigned in 64-bit form — sxtw was dead
            }
            // Written in 32-bit form (w) — the sxtw result is partially overwritten
            // but the upper 32 bits survive. This is complex — be conservative.
            return true  // Can't prove it's dead
        }

        // Check if reg is used as a source
        for src in sourceVRegs(inst) {
            if NormalizedReg(src) == regNorm {
                // If used in 64-bit (x) form, sxtw is needed
                if !src.isWord {
                    return true
                }
                // If used in 32-bit (w) form, sxtw is not needed for this use
                // but we need to keep checking for 64-bit uses
            }
        }

        // Stop at control flow (register might be used in other blocks)
        switch inst {
        case .b, .bcond, .cbz, .cbnz, .tbz, .tbnz, .ret, .label:
            // At control flow boundary, be conservative — assume 64-bit use possible
            return true
        case .call, .callIndirect:
            return true
        default:
            break
        }
    }

    // Reached end of window — be conservative
    return true
}
