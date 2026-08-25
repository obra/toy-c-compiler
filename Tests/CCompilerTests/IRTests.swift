import XCTest
@testable import CIR

/// Round-trip tests: assembly text → IR → lower back to assembly.
/// Verifies the parser and lowering pass produce valid output.
final class IRRoundTripTests: XCTestCase {

    /// Build a register map that maps VReg IDs to physical register names.
    /// ID 0-30 → x0-x30, ID 31 → sp, ID 32 → xzr, FP IDs → s/d registers.
    private func identityRegMap(_ insts: [IRInst]) -> [VReg: String] {
        var map: [VReg: String] = [:]
        for inst in insts {
            for v in allVRegs(in: inst) {
                if v.kind == .gp {
                    switch v.id {
                    case 0...30: map[v] = "x\(v.id)"
                    case 31: map[v] = "sp"
                    case 32: map[v] = "xzr"
                    default: map[v] = "x\(v.id)"
                    }
                } else if v.kind == .fp {
                    map[v] = "d\(v.id)"
                }
            }
        }
        return map
    }

    /// Extract all VRegs referenced in an IRInst.
    private func allVRegs(in inst: IRInst) -> [VReg] {
        switch inst {
        case .add(let d, let s1, let s2): return [d] + vregs(s1) + vregs(s2)
        case .sub(let d, let s1, let s2): return [d] + vregs(s1) + vregs(s2)
        case .mul(let d, let s1, let s2): return [d] + vregs(s1) + vregs(s2)
        case .sdiv(let d, let s1, let s2): return [d] + vregs(s1) + vregs(s2)
        case .udiv(let d, let s1, let s2): return [d] + vregs(s1) + vregs(s2)
        case .mov(let d, let s): return [d] + vregs(s)
        case .cmp(let s1, let s2): return vregs(s1) + vregs(s2)
        case .load(let d, let a, _, _, _): return [d] + vregs(a)
        case .store(let s, let a, _, _): return vregs(s) + vregs(a)
        case .ret: return []
        case .label: return []
        case .comment: return []
        default: return []
        }
    }

    private func vregs(_ op: Operand) -> [VReg] {
        if case .vreg(let v) = op { return [v] }
        return []
    }

    func testSimpleArithmetic() {
        let asm = [
            "stp x29, x30, [sp, #-16]!",
            "mov x29, sp",
            "sub sp, sp, #32",
            "str x0, [x29, #-8]",
            "ldr w9, [x29, #-8]",
            "add w9, w9, w10",
            "str w9, [x29, #-24]",
            "mov w0, w9",
            "ret"
        ]
        let ir = parseAssembly(asm)
        // Should have parsed most instructions (some directives may be comments)
        XCTAssertGreaterThan(ir.count, 5)

        // Lower back
        let regMap = identityRegMap(ir)
        let lowered = lowerIR(ir, regMap: regMap)
        XCTAssertGreaterThan(lowered.count, 5)

        // Verify the lowered output contains "ret"
        XCTAssertTrue(lowered.contains("ret"))
    }

    func testBranches() {
        let asm = [
            "cmp w9, w10",
            "b.ge L_sum_3",
            "ldr w9, [x29, #-16]",
            "b L_sum_1",
            "L_sum_3:",
            "ret"
        ]
        let ir = parseAssembly(asm)
        XCTAssertGreaterThan(ir.count, 4)

        // Check we have a comparison and conditional branch
        let hasCmp = ir.contains { inst in
            if case .cmp = inst { return true }
            return false
        }
        XCTAssertTrue(hasCmp)

        let hasBcond = ir.contains { inst in
            if case .bcond = inst { return true }
            return false
        }
        XCTAssertTrue(hasBcond)

        let hasLabel = ir.contains { inst in
            if case .label(let name) = inst, name == "L_sum_3" { return true }
            return false
        }
        XCTAssertTrue(hasLabel)
    }

    func testFunctionCall() {
        let asm = [
            "mov x0, #3",
            "bl _add",
            "mov w9, w0",
            "ret"
        ]
        let ir = parseAssembly(asm)

        let hasCall = ir.contains { inst in
            if case .call(let target, _) = inst, target == "_add" { return true }
            return false
        }
        XCTAssertTrue(hasCall)
    }

    func testMemoryOps() {
        let asm = [
            "str x0, [x29, #-8]",
            "ldr w9, [x29, #-8]",
            "strb w9, [x29, #-16]",
            "ldrb w10, [x29, #-16]"
        ]
        let ir = parseAssembly(asm)

        let storeCount = ir.filter { if case .store = $0 { return true }; return false }.count
        XCTAssertEqual(storeCount, 2)

        let loadCount = ir.filter { if case .load = $0 { return true }; return false }.count
        XCTAssertEqual(loadCount, 2)
    }

    func testRoundTripPreservesInstructions() {
        let asm = [
            "add w9, w9, w10",
            "sub x9, x9, x10",
            "mul w9, w9, w10",
            "and x9, x9, x10",
            "orr x9, x9, x10",
            "eor x9, x9, x10"
        ]
        let ir = parseAssembly(asm)
        let regMap = identityRegMap(ir)
        let lowered = lowerIR(ir, regMap: regMap)

        // Each instruction should produce one line of assembly
        XCTAssertEqual(lowered.count, 6)

        // Verify the mnemonics are preserved
        XCTAssertTrue(lowered[0].hasPrefix("add"))
        XCTAssertTrue(lowered[1].hasPrefix("sub"))
        XCTAssertTrue(lowered[2].hasPrefix("mul"))
        XCTAssertTrue(lowered[3].hasPrefix("and"))
        XCTAssertTrue(lowered[4].hasPrefix("orr"))
        XCTAssertTrue(lowered[5].hasPrefix("eor"))
    }
}
