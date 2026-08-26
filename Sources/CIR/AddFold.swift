import CCommon

// MARK: - Add Chain Folding

/// Fold `add xN, x29, #A` + `add xM, xN, #B` into `add xM, x29, #(A+B)`.
/// Eliminates one add instruction by combining two frame offset additions.
public func addChainFolding(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result: [IRInst] = []
    var changed = false

    var i = 0
    while i < insts.count {
        let inst = insts[i]

        // Look for: addrr xN, x29(x29), #A
        if case .addrr(let dst, let base, let offset1) = inst,
           case .vreg(let baseVReg) = base, baseVReg.id == 29,
           i + 1 < insts.count {
            // Check if next is: addrr xM, xN, #B (or add xM, xN, #B)
            let next = insts[i + 1]
            if case .addrr(let dst2, let base2, let offset2) = next,
               case .vreg(let base2VReg) = base2, NormalizedReg(base2VReg) == NormalizedReg(dst) {
                // Fold: addrr xM, x29, #(offset1 + offset2)
                let combinedOffset = offset1 + offset2
                result.append(.addrr(dst: dst2, base: .vreg(baseVReg), offset: combinedOffset))
                changed = true
                i += 2
                continue
            }
            // Also check for .add with immediate
            if case .add(let dst2, let src1, let src2) = next,
               case .vreg(let src1VReg) = src1, NormalizedReg(src1VReg) == NormalizedReg(dst),
               case .imm(let offset2) = src2 {
                // Fold: addrr xM, x29, #(offset1 + Int(offset2))
                let combinedOffset = offset1 + Int(offset2)
                result.append(.addrr(dst: dst2, base: .vreg(baseVReg), offset: combinedOffset))
                changed = true
                i += 2
                continue
            }
        }

        result.append(inst)
        i += 1
    }

    return (result, changed)
}

/// Fold consecutive `add xN, xN, #A` + `add xN, xN, #B` into `add xN, xN, #(A+B)`.
/// These come from sequential offset computations (e.g., array index walks).
public func addSelfChainFolding(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result: [IRInst] = []
    var changed = false

    var i = 0
    while i < insts.count {
        // Look for: add xN, xN, #A followed by add xN, xN, #B
        if case .add(let dst1, let src1a, let src1b) = insts[i],
           case .vreg(let s1a) = src1a, NormalizedReg(s1a) == NormalizedReg(dst1),
           case .imm(let off1) = src1b,
           i + 1 < insts.count,
           case .add(let dst2, let src2a, let src2b) = insts[i + 1],
           case .vreg(let s2a) = src2a, NormalizedReg(s2a) == NormalizedReg(dst1),
           case .imm(let off2) = src2b,
           NormalizedReg(dst2) == NormalizedReg(dst1) {
            // Fold: add xN, xN, #(off1 + off2)
            let combined = Int(off1) + Int(off2)
            // ARM64 add immediate: 12-bit unsigned (0-4095) or shifted (multiples of 4096)
            if combined >= 0 && (combined <= 0xFFF || (combined % 0x1000 == 0 && combined <= 0xFFF000)) {
                result.append(.add(dst: dst2, src1: src2a, src2: .imm(Int64(combined))))
                changed = true
                i += 2
                continue
            }
        }

        result.append(insts[i])
        i += 1
    }

    return (result, changed)
}
