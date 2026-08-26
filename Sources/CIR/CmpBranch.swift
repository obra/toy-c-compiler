import CCommon

// MARK: - Compare-to-Branch Folding

/// Replace `cmp reg, #0` + `b.eq label` with `cbz reg, label`.
/// Replace `cmp reg, #0` + `b.ne label` with `cbnz reg, label`.
/// Also fold `mov reg, #0` + `cbz reg` → `b label` (always taken)
/// and `mov reg, #0` + `cbnz reg` → eliminate both (never taken).
/// Eliminates the cmp instruction.
public func cmpToBranchFolding(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result: [IRInst] = []
    var changed = false

    var i = 0
    while i < insts.count {
        let inst = insts[i]

        // Look for: mov dst, #0 or loadImm dst, #0 followed by cbz/cbnz dst
        let isZeroLoadImm: Bool = {
            if case .loadImm(let dst, let val) = inst, val == 0 {
                return true
            }
            return false
        }()
        if case .mov(let dst, let src) = inst,
           case .imm(let val) = src, val == 0,
           i + 1 < insts.count {
            let nextInst = insts[i + 1]
            if case .cbz(let cbzSrc, let label) = nextInst,
               case .vreg(let cbzReg) = cbzSrc, NormalizedReg(cbzReg) == NormalizedReg(dst) {
                // mov reg, #0 + cbz reg → b label (always taken)
                result.append(.b(label: label))
                changed = true
                i += 2
                continue
            }
            if case .cbnz(let cbnzSrc, let label) = nextInst,
               case .vreg(let cbnzReg) = cbnzSrc, NormalizedReg(cbnzReg) == NormalizedReg(dst) {
                // mov reg, #0 + cbnz reg → eliminate both (never taken)
                changed = true
                i += 2
                continue
            }
        }
        if isZeroLoadImm, i + 1 < insts.count,
           case .loadImm(let dst, _) = inst {
            let nextInst = insts[i + 1]
            if case .cbz(let cbzSrc, let label) = nextInst,
               case .vreg(let cbzReg) = cbzSrc, NormalizedReg(cbzReg) == NormalizedReg(dst) {
                // loadImm reg, #0 + cbz reg → b label (always taken)
                result.append(.b(label: label))
                changed = true
                i += 2
                continue
            }
            if case .cbnz(let cbnzSrc, let label) = nextInst,
               case .vreg(let cbnzReg) = cbnzSrc, NormalizedReg(cbnzReg) == NormalizedReg(dst) {
                // loadImm reg, #0 + cbnz reg → eliminate both (never taken)
                changed = true
                i += 2
                continue
            }
        }

        // Look for: cmp src, .imm(0) followed by b.eq/b.ne
        if case .cmp(let src1, let src2) = inst,
           case .imm(let val) = src2, val == 0,
           i + 1 < insts.count {
            let nextInst = insts[i + 1]
            if case .bcond(let cond, let label) = nextInst {
                if cond == .eq {
                    // cmp reg, #0 + b.eq label → cbz reg, label
                    result.append(.cbz(src: src1, label: label))
                    changed = true
                    i += 2
                    continue
                } else if cond == .ne {
                    // cmp reg, #0 + b.ne label → cbnz reg, label
                    result.append(.cbnz(src: src1, label: label))
                    changed = true
                    i += 2
                    continue
                }
            }
        }

        result.append(inst)
        i += 1
    }

    return (result, changed)
}
