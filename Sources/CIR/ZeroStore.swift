import CCommon

// MARK: - Zero Store Elimination

/// Replace `mov reg, #0` + `str reg, [addr]` with `str wzr, [addr]`.
/// Also handles `strb`, `strh` variants.
/// Eliminates the mov instruction entirely by using the zero register (wzr/xzr).
public func zeroStoreElimination(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result: [IRInst] = []
    var changed = false

    var i = 0
    while i < insts.count {
        let inst = insts[i]

        // Look for: mov dst, .imm(0) followed by str dst, [addr]
        if case .mov(let dst, let src) = inst,
           case .imm(let val) = src, val == 0,
           i + 1 < insts.count {
            // Check if next instruction is a store of dst
            if case .store(let storeSrc, let addr, let offset, let width) = insts[i + 1],
               case .vreg(let storeReg) = storeSrc, NormalizedReg(storeReg) == NormalizedReg(dst) {
                // Replace with: store wzr, [addr]
                let wzr = VReg(id: 32, kind: .gp, isWord: dst.isWord)
                result.append(.store(src: .vreg(wzr), addr: addr, offset: offset, width: width))
                changed = true
                i += 2  // skip both mov and store
                continue
            }
        }

        result.append(inst)
        i += 1
    }

    return (result, changed)
}
