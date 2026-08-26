import CCommon

// MARK: - Load-Sign-Extend Fusion

/// Fuses `ldr wN, [addr, #off]` + `sxtw xN, wN` into `ldrsw xN, [addr, #off]`.
/// This eliminates the separate sign-extension instruction by using the
/// ARM64 sign-extending load instruction (ldrsw).
///
/// Only applies when:
/// - The load destination (wN) is the same register as the sxtw source
/// - The sxtw destination is the 64-bit form of the same register (xN)
/// - The load is a 32-bit (word) unsigned load
/// - The load destination is not used after the sxtw (the w form is dead)
public func loadSignExtendFusion(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result: [IRInst] = []
    var changed = false

    var i = 0
    while i < insts.count {
        // Look for: load dst=wN, addr, off, width=.word, signed=false
        // followed by: sxtw dst=xN, src=wN
        if i + 1 < insts.count,
           case .load(let loadDst, let addr, let offset, let width, let signed) = insts[i],
           width == .word, !signed, loadDst.isWord,
           case .sxtw(let sxtwDst, let sxtwSrc) = insts[i + 1],
           case .vreg(let sxtwSrcReg) = sxtwSrc,
           NormalizedReg(sxtwSrcReg) == NormalizedReg(loadDst),
           !sxtwDst.isWord,
           NormalizedReg(sxtwDst) == NormalizedReg(loadDst) {
            // Fuse into: load dst=xN, addr, off, width=.word, signed=true (ldrsw)
            result.append(.load(dst: sxtwDst, addr: addr, offset: offset, width: .word, signed: true))
            changed = true
            i += 2
            continue
        }

        result.append(insts[i])
        i += 1
    }

    return (result, changed)
}
