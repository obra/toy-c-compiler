import CCommon

// MARK: - Redundant SP Restore Elimination

/// Eliminate `mov sp, x29` in function epilogues when sp was not modified
/// after the prologue. If no `sub sp`, `str [sp]`, or other sp-modifying
/// instruction exists between the prologue and epilogue, sp already equals
/// x29 and the `mov sp, x29` is redundant.
///
/// This is a function-level optimization: it processes the instruction list
/// function by function (delimited by labels starting with `_`).
public func redundantSPRestoreElimination(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result: [IRInst] = []
    var changed = false

    // Track function boundaries and sp modifications
    var inFunction = false
    var spModified = false

    for inst in insts {
        switch inst {
        case .label(let name):
            // Function start: labels starting with "_" and ending with ":"
            if name.hasPrefix("_") && !name.contains(".") {
                inFunction = true
                spModified = false
            }
            result.append(inst)

        case .subSP, .addSP:
            spModified = true
            result.append(inst)

        case .storePre(let src, let addr, _, _):
            if isSPRef(addr) { spModified = true }
            result.append(inst)

        case .storePost(let src, let addr, _, _):
            if isSPRef(addr) { spModified = true }
            result.append(inst)

        case .loadPre(_, let addr, _, _):
            if isSPRef(addr) { spModified = true }
            result.append(inst)

        case .loadPost(_, let addr, _, _):
            if isSPRef(addr) { spModified = true }
            result.append(inst)

        case .stpPre(_, _, let addr, _), .stpPost(_, _, let addr, _):
            if isSPRef(addr) { spModified = true }
            result.append(inst)

        case .ldpPre(_, _, let addr, _), .ldpPost(_, _, let addr, _):
            if isSPRef(addr) { spModified = true }
            result.append(inst)

        case .mov(let dst, let src):
            // mov sp, x29 — eliminate if sp not modified
            if dst.id == 31, case .vreg(let srcV) = src, srcV.id == 29, !spModified {
                changed = true
                continue  // skip this instruction
            }
            // mov x29, sp — reset sp modified flag (this is the prologue)
            if dst.id == 29, case .vreg(let srcV) = src, srcV.id == 31 {
                spModified = false
            }
            result.append(inst)

        case .ret:
            inFunction = false
            result.append(inst)

        default:
            result.append(inst)
        }
    }

    return (result, changed)
}
