import CCommon

// MARK: - Zero Store Elimination

/// Replace `mov reg, #0` + optional `sxtw reg, wreg` + `str reg, [addr]` with `str wzr, [addr]`.
/// Also handles `strb`, `strh` variants.
/// Eliminates the mov (and sxtw) by using the zero register (wzr/xzr).
public func zeroStoreElimination(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result: [IRInst] = []
    var changed = false

    var i = 0
    while i < insts.count {
        let inst = insts[i]

        // Look for: mov dst, .imm(0) followed by optional sxtw, then str dst, [addr]
        if case .mov(let dst, let src) = inst,
           case .imm(let val) = src, val == 0 {
            // Check for immediate store or sxtw + store pattern
            let nextIdx = i + 1
            if nextIdx < insts.count {
                // Case 1: direct store of dst
                if case .store(let storeSrc, let addr, let offset, let width) = insts[nextIdx],
                   case .vreg(let storeReg) = storeSrc, NormalizedReg(storeReg) == NormalizedReg(dst) {
                    // Replace store source with zero register, but KEEP the mov.
                    // The mov may be needed if the register was forwarded by load forwarding.
                    let wzr = VReg(id: 32, kind: .gp, isWord: dst.isWord)
                    result.append(inst)  // keep mov dst, #0
                    result.append(.store(src: .vreg(wzr), addr: addr, offset: offset, width: width))
                    changed = true
                    i += 2
                    continue
                }
                // Case 2: sxtw dst, wdst followed by store dst
                if case .sxtw(let extDst, let extSrc) = insts[nextIdx],
                   NormalizedReg(extDst) == NormalizedReg(dst),
                   case .vreg(let extSrcReg) = extSrc, NormalizedReg(extSrcReg) == NormalizedReg(dst),
                   nextIdx + 1 < insts.count,
                   case .store(let storeSrc, let addr, let offset, let width) = insts[nextIdx + 1],
                   case .vreg(let storeReg) = storeSrc, NormalizedReg(storeReg) == NormalizedReg(dst) {
                    // mov #0 + sxtw (of zero) + str → str wzr (keep mov, skip sxtw)
                    let wzr = VReg(id: 32, kind: .gp, isWord: false)
                    result.append(inst)  // keep mov dst, #0
                    result.append(.store(src: .vreg(wzr), addr: addr, offset: offset, width: width))
                    changed = true
                    i += 3  // skip mov, sxtw, and store
                    continue
                }
                // Case 3: storePre of dst (str dst, [sp, #-16]!)
                if case .storePre(let storeSrc, let addr, let offset, let width) = insts[nextIdx],
                   case .vreg(let storeReg) = storeSrc, NormalizedReg(storeReg) == NormalizedReg(dst) {
                    // Replace store source with zero register, but KEEP the mov.
                    let wzr = VReg(id: 32, kind: .gp, isWord: dst.isWord)
                    result.append(inst)  // keep mov dst, #0
                    result.append(.storePre(src: .vreg(wzr), addr: addr, offset: offset, width: width))
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
