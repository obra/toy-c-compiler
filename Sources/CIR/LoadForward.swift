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
    // Key: (base register id, offset) → Value: (register that holds it, instruction index)
    // When we see a load from that offset, replace with a mov from the tracked register.
    var frameValues: [FrameSlot: VReg] = [:]

    // Track what register was loaded from each frame slot
    // Key: (base, offset) → register that was loaded into

    for inst in insts {
        switch inst {
        // --- Load from frame: check if we already have the value ---
        case .load(let dst, let addr, let offset, let width, let signed):
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
            // Store also invalidates any cached load to a different-width slot
            // at the same offset (e.g., storing w9 to #N invalidates ldr x from #N)
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

        // --- Pre/post-indexed stores modify the base register — be conservative ---
        case .storePre, .storePost:
            frameValues.removeAll(keepingCapacity: true)
            result.append(inst)

        case .loadPre, .loadPost:
            frameValues.removeAll(keepingCapacity: true)
            result.append(inst)

        // --- str/ldr to sp-relative addresses: track separately ---
        case .stp, .stpPre, .stpPost:
            // Pairs are complex — just invalidate
            frameValues.removeAll(keepingCapacity: true)
            result.append(inst)

        case .ldp, .ldpPre, .ldpPost:
            frameValues.removeAll(keepingCapacity: true)
            result.append(inst)

        // --- Everything else passes through ---
        default:
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

/// Try to extract a frame slot from a load/store address.
/// Only handles constant-offset addressing (base register + immediate offset).
func frameSlot(_ addr: Operand, _ offset: Int) -> FrameSlot? {
    if case .vreg(let v) = addr {
        return FrameSlot(baseRegId: v.id, offset: offset)
    }
    return nil
}
