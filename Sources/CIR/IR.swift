import CCommon

// MARK: - Virtual Register

/// A virtual register in the IR. Virtual registers are assigned to physical
/// ARM64 registers by the register allocator, or spilled to the stack.
public struct VReg: Equatable, Hashable {
    public let id: Int
    public let kind: RegKind

    public enum RegKind: Equatable, Hashable {
        case gp       // General-purpose (x0-x30, w0-w30)
        case fp       // Floating-point (d0-d31, s0-s31)
        case pflag    // Condition flags (result of cmp/cset)
    }

    public init(id: Int, kind: RegKind = .gp) {
        self.id = id
        self.kind = kind
    }

    public var description: String {
        switch kind {
        case .gp: return "%v\(id)"
        case .fp: return "%f\(id)"
        case .pflag: return "%cc\(id)"
        }
    }
}

// MARK: - Operand

/// An operand to an IR instruction: a virtual register, an immediate, a
/// stack slot reference, a global symbol, or a label.
public enum Operand: Equatable {
    case vreg(VReg)
    case imm(Int64)
    case immF(Double)        // Double-precision float immediate
    case immF32(Float)       // Single-precision float immediate
    case slot(Int)           // Stack slot offset (frame-relative)
    case global(String)     // Global symbol name
    case label(String)       // Branch target label
    case funcRef(String)     // Function name for call targets

    public var asVReg: VReg? {
        if case .vreg(let v) = self { return v } else { return nil }
    }
}

// MARK: - Width

/// Operation width: 1, 2, 4, or 8 bytes. Determines whether the lowering
/// pass uses x/w/b/h register forms and ldr/str vs ldrb/strb etc.
public enum Width: Int, Equatable {
    case byte = 1
    case halfword = 2
    case word = 4
    case dword = 8

    /// Signed variant for loads: ldrsb, ldrsh, ldrsw
    public var loadSignedMnemonic: String {
        switch self {
        case .byte: return "ldrsb"
        case .halfword: return "ldrsh"
        case .word: return "ldrsw"  // sign-extend to 64
        case .dword: return "ldr"
        }
    }

    public var loadMnemonic: String {
        switch self {
        case .byte: return "ldrb"
        case .halfword: return "ldrh"
        case .word: return "ldr"
        case .dword: return "ldr"
        }
    }

    public var storeMnemonic: String {
        switch self {
        case .byte: return "strb"
        case .halfword: return "strh"
        case .word: return "str"
        case .dword: return "str"
        }
    }
}

// MARK: - Condition Code

/// ARM64 condition codes for conditional branches and cset.
public enum Cond: Equatable {
    case eq, ne
    case lt, le, gt, ge
    case lo, ls, hi, hs  // unsigned comparisons
    case mi, pl          // negative/positive
    case vs, vc          // overflow/no-overflow

    /// Invert a condition code (for cbz→cbnz, b.eq→b.ne, etc.)
    public var inverted: Cond {
        switch self {
        case .eq: return .ne; case .ne: return .eq
        case .lt: return .ge; case .ge: return .lt
        case .le: return .gt; case .gt: return .le
        case .lo: return .hs; case .hs: return .lo
        case .ls: return .hi; case .hi: return .ls
        case .mi: return .pl; case .pl: return .mi
        case .vs: return .vc; case .vc: return .vs
        }
    }
}

// MARK: - IR Instruction

/// A single IR instruction. Each maps to at most one ARM64 instruction after
/// lowering, though some (like loadImmediate) may expand to movz+movk sequences.
public enum IRInst: Equatable {
    // --- Arithmetic (integer) ---
    case add(dst: VReg, src1: Operand, src2: Operand)           // add
    case sub(dst: VReg, src1: Operand, src2: Operand)           // sub
    case mul(dst: VReg, src1: Operand, src2: Operand)           // mul
    case sdiv(dst: VReg, src1: Operand, src2: Operand)          // sdiv
    case udiv(dst: VReg, src1: Operand, src2: Operand)          // udiv
    case madd(dst: VReg, src1: Operand, src2: Operand, src3: Operand) // madd (a*b+c)
    case msub(dst: VReg, src1: Operand, src2: Operand, src3: Operand) // msub (c-a*b)

    // --- Arithmetic (floating-point) ---
    case fadd(dst: VReg, src1: Operand, src2: Operand)          // fadd
    case fsub(dst: VReg, src1: Operand, src2: Operand)          // fsub
    case fmul(dst: VReg, src1: Operand, src2: Operand)          // fmul
    case fdiv(dst: VReg, src1: Operand, src2: Operand)          // fdiv
    case fneg(dst: VReg, src: Operand)                          // fneg

    // --- Logical ---
    case and(dst: VReg, src1: Operand, src2: Operand)
    case orr(dst: VReg, src1: Operand, src2: Operand)
    case eor(dst: VReg, src1: Operand, src2: Operand)
    case mvn(dst: VReg, src: Operand)                           // bitwise NOT

    // --- Shifts ---
    case lsl(dst: VReg, src1: Operand, src2: Operand)
    case lsr(dst: VReg, src1: Operand, src2: Operand)
    case asr(dst: VReg, src1: Operand, src2: Operand)

    // --- Comparison ---
    case cmp(src1: Operand, src2: Operand)                      // sets flags
    case fcmp(src1: Operand, src2: Operand)                     // FP compare

    // --- Conditional set ---
    case cset(dst: VReg, cond: Cond)                           // dst = (cond) ? 1 : 0
    case csetm(dst: VReg, cond: Cond)                          // dst = (cond) ? -1 : 0

    // --- Data movement ---
    case mov(dst: VReg, src: Operand)                          // register copy or imm load
    case fmov(dst: VReg, src: Operand)                         // FP register copy or imm load

    // --- Sign/zero extension ---
    case sxtb(dst: VReg, src: Operand)                         // sign-extend byte
    case sxth(dst: VReg, src: Operand)                         // sign-extend halfword
    case sxtw(dst: VReg, src: Operand)                         // sign-extend word
    case uxtb(dst: VReg, src: Operand)                         // zero-extend byte
    case uxth(dst: VReg, src: Operand)                         // zero-extend halfword

    // --- Memory: load/store ---
    case load(dst: VReg, addr: Operand, offset: Int, width: Width, signed: Bool)
    case store(src: Operand, addr: Operand, offset: Int, width: Width)

    // Load/store pair (for register save/restore)
    case ldp(dst1: VReg, dst2: VReg, addr: Operand, offset: Int)
    case stp(src1: Operand, src2: Operand, addr: Operand, offset: Int)

    // --- Address computation ---
    case addrr(dst: VReg, base: Operand, offset: Int)           // add reg, reg, #imm
    case adr(dst: VReg, symbol: String)                         // adr for PC-relative local
    case adrp(dst: VReg, symbol: String)                       // adrp + add for global
    case addSymbol(dst: VReg, base: Operand, symbol: String)   // add reg, reg, symbol@PAGEOFF

    // --- Immediate load (may expand to movz+movk) ---
    case loadImm(dst: VReg, value: Int64)

    // --- FP immediate load ---
    case loadFImm(dst: VReg, value: Double, isFloat: Bool)

    // --- Branch ---
    case b(label: String)                                       // unconditional branch
    case bcond(cond: Cond, label: String)                      // conditional branch
    case cbz(src: Operand, label: String)                      // compare and branch if zero
    case cbnz(src: Operand, label: String)                     // compare and branch if not zero
    case tbz(src: Operand, bit: Int, label: String)            // test bit and branch if zero
    case tbnz(src: Operand, bit: Int, label: String)           // test bit and branch if not zero

    // --- Function call ---
    case call(target: String, args: [Operand])                 // direct call
    case callIndirect(target: Operand, args: [Operand])        // indirect call via function pointer

    // --- Return ---
    case ret

    // --- Miscellaneous ---
    case clz(dst: VReg, src: Operand)                          // count leading zeros
    case rbit(dst: VReg, src: Operand)                         // reverse bits
    case rev(dst: VReg, src: Operand)                          // reverse bytes
    case rev16(dst: VReg, src: Operand)
    case sbfx(dst: VReg, src: Operand, lsb: Int, width: Int)   // signed bit field extract
    case fcvt(dst: VReg, src: Operand, fromDouble: Bool)       // FP convert (s→d or d→s)
    case dmb                                                   // data memory barrier
    case mrs(dst: VReg, reg: String)                           // move from system register

    // --- Label (not a real instruction, marks a basic block boundary) ---
    case label(String)

    // --- Pseudo: comment (not emitted to assembly) ---
    case comment(String)
}

// MARK: - Basic Block

/// A basic block: a maximal sequence of instructions with no branches in
/// (except at the entry) and no branches out (except at the exit).
public struct BasicBlock {
    public var label: String
    public var insts: [IRInst] = []
    public var preds: [Int] = []      // predecessor block indices
    public var succs: [Int] = []      // successor block indices

    public init(label: String) {
        self.label = label
    }

    public var terminator: IRInst? {
        insts.last
    }
}

// MARK: - IR Function

/// A function in the IR: a list of basic blocks plus metadata.
public struct IRFunction {
    public var name: String
    public var blocks: [BasicBlock] = []
    public var numVRegs: Int = 0
    public var frameSize: Int = 0
    public var args: [(VReg, Width, Bool)] = []  // (vreg, width, isFP)
    public var usedCalleeSaved: Set<ARM64Reg> = []

    public init(name: String) {
        self.name = name
    }

    /// Allocate a new virtual register.
    public mutating func newVReg(kind: VReg.RegKind = .gp) -> VReg {
        let v = VReg(id: numVRegs, kind: kind)
        numVRegs += 1
        return v
    }
}

// MARK: - Forward declaration for ARM64Reg

/// We reference ARM64Reg from the codegen module for physical register
/// assignment. This is a forward import — the actual type is defined in
/// CCodegen.ARM64Reg. For the IR module, we just need the type name.
public enum ARM64Reg: String, Equatable {
    case x0, x1, x2, x3, x4, x5, x6, x7
    case x8, x9, x10, x11, x12, x13, x14, x15
    case x16, x17, x18, x19, x20, x21, x22, x23
    case x24, x25, x26, x27, x28, x29, x30
    case sp, xzr, wzr

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
