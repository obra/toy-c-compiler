import CCommon

// MARK: - Pair Coalescing

/// Coalesces consecutive load/store pairs into ldp/stp instructions.
///
/// Pattern 1: str xN, [base, #off] + str xP, [base, #(off±8)] → stp xN, xP, [base, #min(off, off±8)]
/// Pattern 2: ldr xN, [base, #off] + ldr xP, [base, #(off±8)] → ldp xN, xP, [base, #min(off, off±8)]
///
/// Requirements:
/// - Both instructions must have the same base register
/// - Both must be the same width (dword)
/// - Offsets must differ by exactly 8 (the element size for dword)
/// - The two destination/source registers must be different
/// - No intervening instructions that could affect the base register or either value
/// - stp offset range: -512 to 504 for 64-bit
public func pairCoalescing(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result: [IRInst] = []
    var changed = false

    var i = 0
    while i < insts.count {
        // Try store pair: str xN, [base, #off1] + str xP, [base, #off2]
        if i + 1 < insts.count,
           case .store(let src1, let addr1, let off1, let width1) = insts[i],
           case .store(let src2, let addr2, let off2, let width2) = insts[i + 1],
           width1 == .dword, width2 == .dword,
           sameOperand(addr1, addr2),
           abs(off2 - off1) == 8,
           distinctOperands(src1, src2),
           sameKind(src1, src2),
           sameWidth(src1, src2) {
            // Coalesce to stp
            let minOff = min(off1, off2)
            let (s1, s2) = off1 <= off2 ? (src1, src2) : (src2, src1)
            // stp offset must be in range -512 to 504
            if minOff >= -512 && minOff <= 504 {
                // Normalize zero register width to match the other operand
                let ns1 = normalizeWidth(s1, to: s2)
                let ns2 = normalizeWidth(s2, to: s1)
                result.append(.stp(src1: ns1, src2: ns2, addr: addr1, offset: minOff))
                changed = true
                i += 2
                continue
            }
        }

        // Try load pair: ldr xN, [base, #off1] + ldr xP, [base, #off2]
        if i + 1 < insts.count,
           case .load(let dst1, let addr1, let off1, let width1, _) = insts[i],
           case .load(let dst2, let addr2, let off2, let width2, _) = insts[i + 1],
           width1 == .dword, width2 == .dword,
           sameOperand(addr1, addr2),
           abs(off2 - off1) == 8,
           NormalizedReg(dst1) != NormalizedReg(dst2),
           dst1.kind == dst2.kind,
           dst1.isWord == dst2.isWord {
            // Coalesce to ldp
            let minOff = min(off1, off2)
            let (d1, d2) = off1 <= off2 ? (dst1, dst2) : (dst2, dst1)
            // ldp offset must be in range -512 to 504
            if minOff >= -512 && minOff <= 504 {
                result.append(.ldp(dst1: d1, dst2: d2, addr: addr1, offset: minOff))
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

/// Check if two operands refer to the same register
private func sameOperand(_ a: Operand, _ b: Operand) -> Bool {
    switch (a, b) {
    case (.vreg(let va), .vreg(let vb)):
        return NormalizedReg(va) == NormalizedReg(vb)
    default:
        return a == b
    }
}

/// Check if two store sources are distinct (not the same register)
private func distinctOperands(_ a: Operand, _ b: Operand) -> Bool {
    switch (a, b) {
    case (.vreg(let va), .vreg(let vb)):
        return NormalizedReg(va) != NormalizedReg(vb)
    default:
        return a != b
    }
}

/// Check if two operands are the same register kind (GP vs FP).
/// stp/ldp require both operands to be the same kind.
private func sameKind(_ a: Operand, _ b: Operand) -> Bool {
    switch (a, b) {
    case (.vreg(let va), .vreg(let vb)):
        return va.kind == vb.kind
    default:
        return true
    }
}

/// Check if two operands have the same register width (x vs w).
/// stp requires both operands to be the same width.
private func sameWidth(_ a: Operand, _ b: Operand) -> Bool {
    switch (a, b) {
    case (.vreg(let va), .vreg(let vb)):
        return va.isWord == vb.isWord
    default:
        return true
    }
}

/// Normalize the isWord flag of a zero register (id=32) to match another operand's width.
/// stp/ldp require both register operands to use the same width (x vs w).
/// The zero register may have isWord=true (wzr) while the other is xN — fix to xzr.
private func normalizeWidth(_ op: Operand, to ref: Operand) -> Operand {
    if case .vreg(let v) = op, v.id == 32,
       case .vreg(let r) = ref, r.id != 32 {
        return .vreg(VReg(id: 32, kind: .gp, isWord: r.isWord))
    }
    return op
}
