import CCommon
import Foundation

// MARK: - ARM64 Register

/// ARM64 general-purpose registers.
public enum ARM64Reg: String, Equatable {
    case x0, x1, x2, x3, x4, x5, x6, x7
    case x8, x9, x10, x11, x12, x13, x14, x15
    case x16, x17, x18, x19, x20, x21, x22, x23
    case x24, x25, x26, x27, x28, x29, x30
    case sp, xzr, wzr

    /// 32-bit (W) register name.
    public var w: String {
        switch self {
        case .x0: return "w0"; case .x1: return "w1"; case .x2: return "w2"
        case .x3: return "w3"; case .x4: return "w4"; case .x5: return "w5"
        case .x6: return "w6"; case .x7: return "w7"; case .x8: return "w8"
        case .x9: return "w9"; case .x10: return "w10"; case .x11: return "w11"
        case .x12: return "w12"; case .x13: return "w13"; case .x14: return "w14"
        case .x15: return "w15"; case .x16: return "w16"; case .x17: return "w17"
        case .x18: return "w18"; case .x19: return "w19"; case .x20: return "w20"
        case .x21: return "w21"; case .x22: return "w22"; case .x23: return "w23"
        case .x24: return "w24"; case .x25: return "w25"; case .x26: return "w26"
        case .x27: return "w27"; case .x28: return "w28"; case .x29: return "w29"
        case .x30: return "w30"
        case .sp: return "sp"; case .xzr: return "wzr"; case .wzr: return "wzr"
        }
    }

    /// 64-bit (X) register name.
    public var x: String {
        switch self {
        case .xzr: return "xzr"; case .wzr: return "wzr"
        default: return rawValue
        }
    }

    /// Register number (0-30).
    public var regNum: Int {
        switch self {
        case .x0: return 0; case .x1: return 1; case .x2: return 2
        case .x3: return 3; case .x4: return 4; case .x5: return 5
        case .x6: return 6; case .x7: return 7; case .x8: return 8
        case .x9: return 9; case .x10: return 10; case .x11: return 11
        case .x12: return 12; case .x13: return 13; case .x14: return 14
        case .x15: return 15; case .x16: return 16; case .x17: return 17
        case .x18: return 18; case .x19: return 19; case .x20: return 20
        case .x21: return 21; case .x22: return 22; case .x23: return 23
        case .x24: return 24; case .x25: return 25; case .x26: return 26
        case .x27: return 27; case .x28: return 28; case .x29: return 29
        case .x30: return 30
        default: return 0
        }
    }
}

/// Available caller-saved registers for temporary use (x9-x15 are scratch).
public nonisolated(unsafe) let scratchRegs: [ARM64Reg] = [.x9, .x10, .x11, .x12, .x13, .x14, .x15]

/// Callee-saved registers available for spillover when all scratch regs are exhausted.
/// x19 is safe (not used by our codegen). x20 is used for nested function static chains.
/// x18 is platform register (reserved). So we use x19, x21-x28.
public nonisolated(unsafe) let calleeSavedPool: [ARM64Reg] = [.x19, .x21, .x22, .x23, .x24, .x25, .x26, .x27, .x28]

/// Argument registers (AAPCS64).
public nonisolated(unsafe) let argRegs: [ARM64Reg] = [.x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7]

// MARK: - Simple Register Allocator

/// A simple register allocator that manages a pool of scratch registers.
public final class RegAlloc {
    public var available: [ARM64Reg]
    /// Callee-saved registers that have been handed out as spillover.
    /// The codegen must save/restore these in the prologue/epilogue.
    public var usedCalleeSaved: Set<ARM64Reg> = []
    private var calleeSavedIdx = 0

    public init() {
        available = scratchRegs
    }

    public func alloc() -> ARM64Reg? {
        return available.isEmpty ? nil : available.removeFirst()
    }

    /// Allocate a callee-saved register as spillover when scratch is exhausted.
    /// Returns nil if all callee-saved registers are also in use.
    public func allocCalleeSaved() -> ARM64Reg? {
        guard calleeSavedIdx < calleeSavedPool.count else { return nil }
        let reg = calleeSavedPool[calleeSavedIdx]
        calleeSavedIdx += 1
        usedCalleeSaved.insert(reg)
        return reg
    }

    public func free(_ reg: ARM64Reg) {
        // Prevent duplicate entries — if the register is already available,
        // don't add it again (duplicates cause alloc() to return the same
        // register multiple times, leading to register aliasing bugs).
        if !available.contains(reg) {
            available.insert(reg, at: 0)
        }
    }

    public func reset() {
        available = scratchRegs
        usedCalleeSaved.removeAll()
        calleeSavedIdx = 0
    }
}
