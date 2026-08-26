import CCommon

// MARK: - Basic Block Construction

/// Build basic blocks from a flat IR instruction list.
/// Basic blocks are maximal sequences of instructions with:
/// - No branches in (except at the entry)
/// - No branches out (except at the terminator)
///
/// Block boundaries are:
/// - Labels (start a new block)
/// - Branch instructions (end a block: b, bcond, cbz, cbnz, tbz, tbnz, ret, call)
/// - Instructions after branches (start a new block)
public func buildBasicBlocks(_ insts: [IRInst]) -> [BasicBlock] {
    var blocks: [BasicBlock] = []
    var currentBlock = BasicBlock(label: "entry")
    var labelToBlockIdx: [String: Int] = [:]
    var blockIdx = 0

    for inst in insts {
        switch inst {
        case .label(let name):
            // Label starts a new block. Save the current block.
            // Always save, even if empty — empty blocks represent labels that
            // fall through to the next block (e.g., L_fallthrough: L_target:).
            // But skip the initial empty entry block.
            if !currentBlock.insts.isEmpty || currentBlock.label != "entry" {
                blocks.append(currentBlock)
                blockIdx += 1
            }
            currentBlock = BasicBlock(label: name)
            labelToBlockIdx[name] = blockIdx

        case .b, .bcond, .cbz, .cbnz, .tbz, .tbnz, .ret:
            // Terminator: add to current block, then start a new block
            currentBlock.insts.append(inst)
            if !currentBlock.insts.isEmpty {
                blocks.append(currentBlock)
                blockIdx += 1
            }
            currentBlock = BasicBlock(label: "bb\(blockIdx)")

        case .call, .callIndirect:
            // Calls are not terminators (execution continues after), but
            // they clobber caller-saved registers, so it's useful to note them.
            currentBlock.insts.append(inst)

        default:
            currentBlock.insts.append(inst)
        }
    }

    // Don't forget the last block
    if !currentBlock.insts.isEmpty {
        blocks.append(currentBlock)
    }

    // Now build successor/predecessor edges
    for i in 0..<blocks.count {
        let block = blocks[i]
        guard let terminator = block.terminator else {
            // No terminator: falls through to next block
            if i + 1 < blocks.count {
                blocks[i].succs.append(i + 1)
                blocks[i + 1].preds.append(i)
            }
            continue
        }

        switch terminator {
        case .b(let label):
            if let target = findBlock(label: label, blocks: blocks, labelMap: labelToBlockIdx) {
                blocks[i].succs.append(target)
                blocks[target].preds.append(i)
            }
        case .bcond(_, let label), .cbz(_, let label), .cbnz(_, let label), .tbz(_, _, let label), .tbnz(_, _, let label):
            // Conditional branch: two successors — the branch target and fall-through
            if let target = findBlock(label: label, blocks: blocks, labelMap: labelToBlockIdx) {
                blocks[i].succs.append(target)
                blocks[target].preds.append(i)
            }
            // Fall-through to next block
            if i + 1 < blocks.count {
                blocks[i].succs.append(i + 1)
                blocks[i + 1].preds.append(i)
            }
        case .ret:
            // No successors
            break
        default:
            // Not a terminator — fall through
            if i + 1 < blocks.count {
                blocks[i].succs.append(i + 1)
                blocks[i + 1].preds.append(i)
            }
        }
    }

    return blocks
}

/// Find the block index for a label.
func findBlock(label: String, blocks: [BasicBlock], labelMap: [String: Int]) -> Int? {
    if let idx = labelMap[label] { return idx }
    // Search by block label
    for (i, block) in blocks.enumerated() {
        if block.label == label { return i }
    }
    return nil
}

// MARK: - Liveness Analysis

/// Compute live-in and live-out register sets for each basic block.
/// A register is live-in if it's used before being defined in the block,
/// or if it's live-out from a predecessor.
/// A register is live-out if it's live-in for any successor.
public func computeLiveness(_ blocks: [BasicBlock]) -> [(liveIn: Set<NormalizedReg>, liveOut: Set<NormalizedReg>)] {
    var liveIn = Array(repeating: Set<NormalizedReg>(), count: blocks.count)
    var liveOut = Array(repeating: Set<NormalizedReg>(), count: blocks.count)

    // Iterate until fixpoint
    var changed = true
    while changed {
        changed = false

        for i in (0..<blocks.count).reversed() {
            let block = blocks[i]

            // liveOut = union of liveIn of all successors
            var newLiveOut = Set<NormalizedReg>()
            for succ in block.succs {
                newLiveOut.formUnion(liveIn[succ])
            }

            // liveIn = (liveOut - defined regs) | used-before-defined regs
            var newLiveIn = newLiveOut
            var defined = Set<NormalizedReg>()

            // Walk instructions in reverse
            for inst in block.insts.reversed() {
                // Remove destination from live set (it's defined here)
                if let dst = destVReg(inst) {
                    newLiveIn.remove(NormalizedReg(dst))
                    defined.insert(NormalizedReg(dst))
                }
                // Add sources to live set (they're used here)
                for src in sourceVRegs(inst) {
                    newLiveIn.insert(NormalizedReg(src))
                }
                // Also add implicit uses
                for implicitReg in implicitlyUsedRegs(inst) {
                    newLiveIn.insert(NormalizedReg(implicitReg))
                }
            }

            if newLiveIn != liveIn[i] || newLiveOut != liveOut[i] {
                liveIn[i] = newLiveIn
                liveOut[i] = newLiveOut
                changed = true
            }
        }
    }

    return Array(zip(liveIn, liveOut))
}

// MARK: - Cross-Block Dead Code Elimination

/// Remove dead instructions using cross-block liveness analysis.
/// This is more powerful than the simple DCE — it can remove instructions
/// whose results are used in a different block but are actually dead
/// because the use is itself dead.
public func crossBlockDCE(_ insts: [IRInst]) -> [IRInst] {
    let blocks = buildBasicBlocks(insts)
    let liveness = computeLiveness(blocks)

    // For each block, remove pure instructions whose destination is not in liveOut
    // and not used by any subsequent instruction in the same block.
    var result: [IRInst] = []

    for (blockIdx, block) in blocks.enumerated() {
        let blockInsts = block.insts
        let liveOut = liveness[blockIdx].liveOut

        // Walk in reverse, tracking what's live at each point
        var live = liveOut
        var deadIndices = Set<Int>()

        for i in (0..<blockInsts.count).reversed() {
            let inst = blockInsts[i]
            let dstNorm = destVReg(inst).map { NormalizedReg($0) }

            // Check if this instruction is dead
            if let dst = dstNorm, isPure(inst), !live.contains(dst) {
                deadIndices.insert(i)
                continue
            }

            // Update live set: remove destination, add sources
            if let dst = dstNorm {
                live.remove(dst)
            }
            for src in sourceVRegs(inst) {
                live.insert(NormalizedReg(src))
            }
            for implicitReg in implicitlyUsedRegs(inst) {
                live.insert(NormalizedReg(implicitReg))
            }
        }

        // Also mark movk comments for removal
        for i in 0..<blockInsts.count {
            if case .comment(let text) = blockInsts[i], text.hasPrefix("movk ") {
                deadIndices.insert(i)
            }
        }

        // Emit non-dead instructions, prefixed with the block label if it's a real label
        // Only emit labels for blocks that came from actual .label instructions
        // (not synthetic blocks created after terminators)
        if block.label != "entry" && !block.label.hasPrefix("bb") {
            result.append(.label(block.label))
        }
        for (i, inst) in blockInsts.enumerated() {
            if !deadIndices.contains(i) {
                result.append(inst)
            }
        }
    }

    return result
}

// MARK: - Enhanced Optimizer

/// Enhanced optimizer with cross-block analysis.
public func optimizeIR2(_ insts: [IRInst]) -> [IRInst] {
    var result = insts

    var changed = true
    var iterations = 0
    while changed && iterations < 10 {
        changed = false

        // Pass 1: Push-pop elimination (str [sp,#-16]! → ldr [sp,#0] → mov)
        let (pushPopResult, pushPopChanged) = pushPopElimination(result)
        if pushPopChanged {
            result = pushPopResult
            changed = true
        }

        // Pass 2: Load forwarding (eliminate redundant loads)
        let (loadResult, loadChanged) = loadForwarding(result)
        if loadChanged {
            result = loadResult
            changed = true
        }

        // Pass 3: Stack adjustment merging
        let (stackResult, stackChanged) = stackAdjustmentMerge(result)
        if stackChanged {
            result = stackResult
            changed = true
        }

        // Pass 4: Redundant branch elimination
        let (branchResult, branchChanged) = redundantBranchElimination(result)
        if branchChanged {
            result = branchResult
            changed = true
        }

        // Pass 5: Cross-block DCE (remove dead instructions)
        let crossBlockResult = crossBlockDCE(result)
        if crossBlockResult.count != result.count {
            result = crossBlockResult
            changed = true
        }

        // Pass 6: Copy propagation
        let (copyResult, copyChanged) = copyPropagation(result)
        if copyChanged {
            result = copyResult
            changed = true
        }

        // Pass 7: Constant folding
        let (foldResult, foldChanged) = constantFolding(result)
        if foldChanged {
            result = foldResult
            changed = true
        }

        // Pass 8: Add chain folding (must run BEFORE address folding to catch chains)
        let (addFoldResult, addFoldChanged) = addChainFolding(result)
        if addFoldChanged {
            result = addFoldResult
            changed = true
        }

        // Pass 9: Address folding (fold addrr xN,x29,#N into load/store [x29, #N])
        let (addrResult, addrChanged) = addressFolding(result)
        if addrChanged {
            result = addrResult
            changed = true
        }

        // Pass 10: Zero store elimination (mov reg,#0 + str reg → str wzr)
        let (zeroResult, zeroChanged) = zeroStoreElimination(result)
        if zeroChanged {
            result = zeroResult
            changed = true
        }

        // Pass 11: Compare-to-branch folding (cmp #0 + b.eq/ne → cbz/cbnz)
        let (cmpResult, cmpChanged) = cmpToBranchFolding(result)
        if cmpChanged {
            result = cmpResult
            changed = true
        }

        // Pass 12: Dead sign extension elimination (sxtw only used in 32-bit → remove)
        let (sxtwResult, sxtwChanged) = deadSignExtensionElimination(result)
        if sxtwChanged {
            result = sxtwResult
            changed = true
        }

        iterations += 1
    }

    return result
}
