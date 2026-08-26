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
