import CCommon

// MARK: - Push-Pop Elimination

/// Eliminate push-then-load patterns where a value is pushed to the stack
/// and immediately loaded back into a different register.
///
/// Pattern: str x9, [sp, #-16]! followed by ldr x0, [sp, #0]
/// The push writes x9 to [sp-16] and updates sp. The load reads from [sp+0]
/// which is the same address. Replace the load with: mov x0, x9
/// KEEP the store (it's needed for stack alignment and potential variadic args).
///
/// This handles the argument-passing pattern where the codegen pushes
/// values to the stack and then loads them into argument registers.
public func pushPopElimination(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result: [IRInst] = []
    var changed = false

    var i = 0
    while i < insts.count {
        let inst = insts[i]

        // Look for: storePre(src: .vreg(r1), addr: sp, offset: -16, width: .dword)
        // followed by: load(dst: r2, addr: sp, offset: 0, width: .dword, signed: false)
        if case .storePre(let src, let addr, let offset, _) = inst,
           isSPRef(addr), offset == -16,
           case .vreg(let srcReg) = src,
           i + 1 < insts.count,
           case .load(let dst, let loadAddr, let loadOffset, _, _) = insts[i + 1],
           isSPRef(loadAddr), loadOffset == 0 {
            // Keep the store (needed for stack alignment), replace the load with mov
            // But only if the register banks match (both GP)
            if srcReg.kind == .gp && dst.kind == .gp {
                result.append(inst)  // keep the store
                result.append(.mov(dst: dst, src: .vreg(srcReg)))  // replace load with mov
                changed = true
                i += 2  // skip both the store and the load
                continue
            }
        }

        result.append(inst)
        i += 1
    }

    return (result, changed)
}
