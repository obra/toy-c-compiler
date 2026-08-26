import CCommon

// MARK: - Load Forwarding (Local Value Numbering)

/// Eliminate redundant loads by tracking what's in each frame slot.
/// If a load from [x29, #N] is followed by another load from the same address
/// without an intervening store, the second load can use the value already
/// in the register from the first load.
///
/// This is a local (within-basic-block) optimization. It also forwards
/// stored values: if `str x9, [x29, #N]` is followed by `ldr x10, [x29, #N]`,
/// replace the load with `mov x10, x9`.
public func loadForwarding(_ insts: [IRInst]) -> ([IRInst], Bool) {
    var result: [IRInst] = []
    var changed = false

    // Track what register holds the value at each frame offset.
    // Key: (base register id, offset) → Value: register that holds it
    // When we see a load from that offset, replace with a mov from the tracked register.
    var frameValues: [FrameSlot: VReg] = [:]

    for inst in insts {
        switch inst {
        // --- Load from frame: check if we already have the value ---
        case .load(let dst, let addr, let offset, let width, let signed):
            // First, invalidate any frame values that reference the dest register
            // (the load overwrites it, making any cached pointer to it stale)
            let dstNorm = NormalizedReg(dst)
            frameValues = frameValues.filter { _, reg in
                NormalizedReg(reg) != dstNorm
            }
            if let slot = frameSlot(addr, offset) {
                if let cachedReg = frameValues[slot] {
                    // Forward: replace load with mov
                    // Only forward if widths match exactly. Forwarding a 32-bit
                    // value to a 64-bit destination without sign extension is
                    // incorrect — it produces invalid mov xN, wM instructions.
                    if cachedReg.isWord == dst.isWord {
                        result.append(.mov(dst: dst, src: .vreg(cachedReg)))
                        changed = true
                        continue
                    }
                }
                // Record what register holds this value
                frameValues[slot] = dst
            }
            result.append(inst)

        // --- Store to frame: record what register holds the value ---
        case .store(let src, let addr, let offset, _):
            if let slot = frameSlot(addr, offset) {
                if case .vreg(let srcReg) = src {
                    frameValues[slot] = srcReg
                } else {
                    // Storing an immediate — invalidate cached value
                    frameValues.removeValue(forKey: slot)
                }
            }
            result.append(inst)

        // --- Store to frame with register offset ---
        case .storeReg:
            // Can't track register-offset stores
            frameValues.removeAll(keepingCapacity: true)
            result.append(inst)

        // --- Calls clobber all cached values ---
        case .call, .callIndirect:
            frameValues.removeAll(keepingCapacity: true)
            result.append(inst)

        // --- Branches start a new block — clear cache ---
        case .b, .bcond, .cbz, .cbnz, .tbz, .tbnz, .ret:
            frameValues.removeAll(keepingCapacity: true)
            result.append(inst)

        // --- Labels start a new block — clear cache ---
        case .label:
            frameValues.removeAll(keepingCapacity: true)
            result.append(inst)

        // --- Pre/post-indexed stores/loads — be conservative ---
        case .storePre, .storePost, .loadPre, .loadPost:
            frameValues.removeAll(keepingCapacity: true)
            result.append(inst)

        // --- Pairs are complex — just invalidate ---
        case .stp, .stpPre, .stpPost, .ldp, .ldpPre, .ldpPost:
            frameValues.removeAll(keepingCapacity: true)
            result.append(inst)

        // --- Default: invalidate any frame values that reference the dest register ---
        default:
            // If this instruction writes to a register that was previously stored
            // to the frame, the cached value is now stale (the register has been
            // reassigned). Remove all frameValues entries pointing to this register.
            if let dst = destVReg(inst) {
                let dstNorm = NormalizedReg(dst)
                frameValues = frameValues.filter { _, reg in
                    NormalizedReg(reg) != dstNorm
                }
            }
            result.append(inst)
        }
    }

    return (result, changed)
}

/// A frame slot identified by the base register and offset.
struct FrameSlot: Hashable {
    let baseRegId: Int  // VReg id of the base register (e.g., 29 for x29)
    let offset: Int
}

/// Extract a FrameSlot from a load/store address+offset, if it's a frame reference.
func frameSlot(_ addr: Operand, _ offset: Int) -> FrameSlot? {
    if case .vreg(let v) = addr, v.kind == .gp, v.id == 29 || v.id == 31 {
        return FrameSlot(baseRegId: v.id, offset: offset)
    }
    return nil
}
