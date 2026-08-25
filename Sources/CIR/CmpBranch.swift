import CCommon

// MARK: - Compare-to-Branch Folding

/// Replace `cmp reg, #0` + `b.eq label` with `cbz reg, label`.
/// Replace `cmp reg, #0` + `b.ne label` with `cbnz reg, label`.
/// Eliminates the cmp instruction.
public func cmpToBranchFolding(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result: [IRInst] = []
    var changed = false

    var i = 0
    while i < insts.count {
        let inst = insts[i]

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
