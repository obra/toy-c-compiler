import CCommon

// MARK: - Address Folding

/// Fold frame address computations into load/store instructions.
///
/// Pattern: addrr xN, x29, #offset followed by load/store [xN, #0]
/// → load/store [x29, #offset], eliminating the addrr.
///
/// Only folds when the address register (xN) is used exactly once
/// (for the load/store) and is not modified between the addrr and use.
public func addressFolding(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result: [IRInst] = []
    var changed = false

    var i = 0
    while i < insts.count {
        let inst = insts[i]

        // Look for: addrr dst, base(x29), offset
        if case .addrr(let dst, let base, let offset) = inst,
           case .vreg(let baseVReg) = base, baseVReg.id == 29 {
            // Check if dst is used exactly once in the next few instructions
            // as the base of a load/store
            if let useInfo = findSingleUse(insts, after: i, reg: dst) {
                let useIdx = useInfo.idx
                let useInst = insts[useIdx]

                // Fold the address into the load/store
                if let foldedInst = foldAddress(useInst, base: base, offset: offset) {
                    // Emit everything between addrr and the use (excluding addrr)
                    for j in (i+1)..<useIdx {
                        result.append(insts[j])
                    }
                    // Emit the folded instruction
                    result.append(foldedInst)
                    changed = true
                    i = useIdx + 1
                    continue
                }
            }
        }

        result.append(inst)
        i += 1
    }

    return (result, changed)
}

/// Find if a register is used exactly once (as a load/store base address)
/// in the next few instructions, without being modified.
/// Returns the index of the single use, or nil if not foldable.
func findSingleUse(_ insts: [IRInst], after idx: Int, reg: VReg) -> Int? {
    var useIdx: Int? = nil

    for j in (idx+1)..<min(idx+20, insts.count) {
        let inst = insts[j]

        // If reg is modified (written to), stop — can't fold past a write
        if let dst = destVReg(inst), NormalizedReg(dst) == NormalizedReg(reg) {
            return nil
        }

        // Check if reg is used as a source
        let sources = sourceVRegs(inst)
        for src in sources {
            if NormalizedReg(src) == NormalizedReg(reg) {
                // Check if it's used as an address (load/store base)
                if isAddressBase(inst, reg: reg) {
                    if useIdx != nil {
                        return nil  // Used more than once — can't fold
                    }
                    useIdx = j
                } else {
                    // Used as a non-address source — can't fold
                    return nil
                }
            }
        }

        // Stop at control flow
        switch inst {
        case .b, .bcond, .cbz, .cbnz, .tbz, .tbnz, .ret, .label:
            return useIdx
        case .call, .callIndirect:
            return useIdx
        default:
            break
        }
    }

    return useIdx
}

/// Check if a register is used as the base address of a load/store.
func isAddressBase(_ inst: IRInst, reg: VReg) -> Bool {
    switch inst {
    case .load(_, let addr, _, _, _):
        return addrIsReg(addr, reg)
    case .store(_, let addr, _, _):
        return addrIsReg(addr, reg)
    case .loadReg(_, let addr, _, _, _):
        return addrIsReg(addr, reg)
    case .storeReg(_, let addr, _, _):
        return addrIsReg(addr, reg)
    default:
        return false
    }
}

func addrIsReg(_ op: Operand, _ reg: VReg) -> Bool {
    if case .vreg(let v) = op, NormalizedReg(v) == NormalizedReg(reg) {
        return true
    }
    return false
}

/// Fold a load/store's address from [reg, #0] to [base, #offset].
func foldAddress(_ inst: IRInst, base: Operand, offset: Int) -> IRInst? {
    switch inst {
    case .load(let dst, _, let loadOff, let width, let signed):
        return .load(dst: dst, addr: base, offset: offset + loadOff, width: width, signed: signed)
    case .store(let src, _, let storeOff, let width):
        return .store(src: src, addr: base, offset: offset + storeOff, width: width)
    case .loadReg(let dst, _, let index, let width, let signed):
        // Can't fold register-offset loads — would need to add base+offset
        return nil
    case .storeReg:
        return nil
    default:
        return nil
    }
}
