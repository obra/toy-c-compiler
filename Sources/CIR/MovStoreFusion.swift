import CCommon

// MARK: - Mov-Store Fusion

/// Fuse `mov xN, xM` + `str xN, [addr]` into `str xM, [addr]` when xN is
/// dead after the store. This eliminates the mov by storing the source
/// register directly.
///
/// Only applies when:
/// 1. xN is not used after the store (dead)
/// 2. xM is a register (not an immediate — handled by zero store elim)
/// 3. xM is not sp (VReg 31) or xzr (VReg 32)
public func movStoreFusion(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result: [IRInst] = []
    var changed = false

    var i = 0
    while i < insts.count {
        let inst = insts[i]

        // Look for: mov dst, src(vreg) followed by str dst, [addr]
        if case .mov(let dst, let src) = inst,
           case .vreg(let srcReg) = src, srcReg.id != 31, srcReg.id != 32,
           i + 1 < insts.count,
           case .store(let storeSrc, let addr, let offset, let width) = insts[i + 1],
           case .vreg(let storeReg) = storeSrc, NormalizedReg(storeReg) == NormalizedReg(dst) {
            // Check if dst is dead after the store
            if !usedAfter(insts, after: i + 1, reg: dst) {
                // Replace mov + str with str srcReg
                result.append(.store(src: .vreg(srcReg), addr: addr, offset: offset, width: width))
                changed = true
                i += 2
                continue
            }
        }

        // Also handle: mov dst, src(vreg) + storePre dst, [sp, #-16]!
        if case .mov(let dst, let src) = inst,
           case .vreg(let srcReg) = src, srcReg.id != 31, srcReg.id != 32,
           i + 1 < insts.count,
           case .storePre(let storeSrc, let addr, let offset, let width) = insts[i + 1],
           case .vreg(let storeReg) = storeSrc, NormalizedReg(storeReg) == NormalizedReg(dst) {
            if !usedAfter(insts, after: i + 1, reg: dst) {
                result.append(.storePre(src: .vreg(srcReg), addr: addr, offset: offset, width: width))
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
