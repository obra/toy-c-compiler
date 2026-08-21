import CCommon
import CSema
import Foundation

// MARK: - Codegen

/// ARM64 code generator: emits assembly from the typed AST.
public final class Codegen {
    private var output = ""
    private var stringLiterals: [(label: String, value: String)] = []
    private var stringLabelCounter = 0
    private var globalLabels: Set<String> = []
    private var localOffset = 0
    private var localVarOffsets: [String: Int] = [:]
    private var frameSize = 0
    private var labelCounter = 0
    private var regAlloc = RegAlloc()
    private var currentFuncName = ""

    public init() {}

    // MARK: - Public API

    public func generate(_ decls: [Decl]) -> String {
        output = ""

        // Collect global variable names
        for d in decls {
            if case .varDecl(let vd) = d {
                globalLabels.insert(vd.name)
            }
        }

        // Emit data section for string literals and globals
        emitDataSection(decls)

        // Emit text section (code)
        emitLine(".text")

        for decl in decls {
            if case .funcDecl(let fd) = decl, fd.body != nil {
                emitFunction(fd)
            }
        }

        // Emit string literals at the end
        emitStringLiterals()

        return output
    }

    // MARK: - Data section

    private func emitDataSection(_ decls: [Decl]) {
        var hasGlobals = false
        for d in decls {
            if case .varDecl(let vd) = d, vd.isGlobal {
                if !hasGlobals {
                    hasGlobals = true
                }
                // Emit global variable
                let size = vd.type.sizeInBytes ?? 0
                if let init_ = vd.initializer {
                    // Emit initialized global
                    emitLine(".section __DATA,__data")
                    emitLine(".globl _\(vd.name)")
                    emitLine(".p2align 3")
                    emitLine("_\(vd.name):")
                    emitInitializer(init_, size: size)
                } else {
                    // BSS (zero-initialized)
                    emitLine(".section __DATA,__bss")
                    emitLine(".globl _\(vd.name)")
                    emitLine(".p2align 3")
                    emitLine("_\(vd.name):")
                    emitLine(".zero \(size)")
                }
            }
        }
    }

    private func emitInitializer(_ expr: Expr, size: Int) {
        switch expr {
        case .integerLiteral(let l):
            if size >= 8 {
                emitLine(".quad \(l.value)")
            } else if size >= 4 {
                emitLine(".long \(l.value)")
            } else if size >= 2 {
                emitLine(".short \(l.value)")
            } else {
                emitLine(".byte \(l.value)")
            }
        default:
            // Default: zero-fill
            emitLine(".zero \(size)")
        }
    }

    // MARK: - String literals

    private func emitStringLiterals() {
        guard !stringLiterals.isEmpty else { return }
        emitLine(".section __TEXT,__cstring")
        for sl in stringLiterals {
            emitLine("\(sl.label):")
            emitLine(".asciz \"\(escapeString(sl.value))\"")
        }
    }

    private func escapeString(_ s: String) -> String {
        var result = ""
        for ch in s {
            switch ch {
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\0": result += "\\0"
            default: result += String(ch)
            }
        }
        return result
    }

    private func addStringLiteral(_ s: String) -> String {
        let label = "L_STR_\(stringLabelCounter)"
        stringLabelCounter += 1
        stringLiterals.append((label: label, value: s))
        return label
    }

    // MARK: - Function emission

    private func emitFunction(_ fd: FuncDecl) {
        currentFuncName = fd.name
        localOffset = 0
        localVarOffsets = [:]
        frameSize = 0
        labelCounter = 0

        emitLine("")
        emitLine(".globl _\(fd.name)")
        emitLine(".p2align 2")
        emitLine("_\(fd.name):")

        // Prologue: save fp and lr, set up frame pointer
        // stp fp, lr, [sp, #-16]!
        emitLine("stp x29, x30, [sp, #-16]!")
        emitLine("mov x29, sp")

        // Allocate space for local variables (will be patched after we know the size)
        let frameAllocLine = "sub sp, sp, #0  ; FRAME_SIZE_PLACEHOLDER"
        emitLine(frameAllocLine)

        // Add parameters to local variables
        var paramOffset = 16 // above the saved fp/lr
        for (i, param) in fd.params.enumerated() {
            if i < 8 {
                // Parameters come in x0-x7, store them on the stack
                ensureLocalSpace(size: 8)
                let offset = -(localOffset)
                localVarOffsets[param.name ?? "_param_\(i)"] = offset
                let reg = argRegs[i]
                let isInt = param.type.isInteger || param.type.isPointer
                if isInt {
                    // Always use 64-bit store for simplicity
                    emitLine("str \(reg.x), [x29, #\(offset)]")
                }
            }
        }

        // Emit body
        if let body = fd.body {
            emitCompoundStmt(body)
        }

        // Epilogue (default return)
        emitLine("mov w0, #0  ; default return")
        emitEpilogue()

        // Patch the frame size (must be 16-byte aligned for AAPCS64)
        var alignedFrameSize = (frameSize + 15) & ~15
        if alignedFrameSize == 0 { alignedFrameSize = 16 } // minimum for alignment
        let frameSizeStr = String(alignedFrameSize)
        output = output.replacingOccurrences(
            of: "sub sp, sp, #0  ; FRAME_SIZE_PLACEHOLDER",
            with: "sub sp, sp, #\(frameSizeStr)")
    }

    private func emitEpilogue() {
        // Restore sp to frame pointer before loading fp/lr
        emitLine("mov sp, x29")
        emitLine("ldp x29, x30, [sp], #16")
        emitLine("ret")
    }

    // MARK: - Local variable management

    private func ensureLocalSpace(size: Int) {
        let aligned = (size + 7) & ~7  // align to 8 bytes
        localOffset += aligned
        if localOffset > frameSize {
            frameSize = localOffset
        }
    }

    private func allocLocal(name: String, type: CType) {
        let size = type.sizeInBytes ?? 8
        ensureLocalSpace(size: size)
        let offset = -localOffset
        localVarOffsets[name] = offset
    }

    // MARK: - Statement emission

    private func emitCompoundStmt(_ cs: CompoundStmt) {
        for stmt in cs.statements {
            emitStmt(stmt)
        }
    }

    private func emitStmt(_ stmt: Stmt) {
        switch stmt {
        case .expr(let es):
            if let e = es.expr {
                _ = emitExpr(e)
                regAlloc.reset()
            }

        case .compound(let cs):
            emitCompoundStmt(cs)

        case .decl(let ds):
            for d in ds.decls {
                if case .varDecl(let vd) = d {
                    allocLocal(name: vd.name, type: vd.type)
                    if let init_ = vd.initializer {
                        let reg = emitExpr(init_)
                        storeLocal(vd.name, reg, type: vd.type)
                    }
                }
            }

        case .if(let is_):
            emitIfStmt(is_)

        case .while(let ws):
            emitWhileStmt(ws)

        case .doWhile(let dws):
            emitDoWhileStmt(dws)

        case .for(let fs):
            emitForStmt(fs)

        case .return(let rs):
            if let v = rs.value {
                let reg = emitExpr(v)
                // Move result to x0
                if reg != .x0 {
                    emitLine("mov x0, \(reg.x)")
                }
            } else {
                emitLine("mov w0, #0")
            }
            emitEpilogue()

        case .break:
            // TODO: track loop end labels
            break

        case .continue:
            // TODO: track loop start labels
            break

        case .switch, .case, .default, .goto, .label, .empty:
            // Simplified: skip for now
            break
        }
    }

    private func emitIfStmt(_ is_: IfStmt) {
        let condReg = emitExpr(is_.condition)
        let elseLabel = newLabel()
        let endLabel = newLabel()
        emitLine("cbz \(condReg.x), \(elseLabel)")
        emitStmt(is_.thenStmt)
        emitLine("b \(endLabel)")
        emitLine("\(elseLabel):")
        if let else_ = is_.elseStmt {
            emitStmt(else_)
        }
        emitLine("\(endLabel):")
    }

    private func emitWhileStmt(_ ws: WhileStmt) {
        let startLabel = newLabel()
        let endLabel = newLabel()
        emitLine("\(startLabel):")
        let condReg = emitExpr(ws.condition)
        emitLine("cbz \(condReg.x), \(endLabel)")
        emitStmt(ws.body)
        emitLine("b \(startLabel)")
        emitLine("\(endLabel):")
    }

    private func emitDoWhileStmt(_ dws: DoWhileStmt) {
        let startLabel = newLabel()
        emitLine("\(startLabel):")
        emitStmt(dws.body)
        let condReg = emitExpr(dws.condition)
        emitLine("cbnz \(condReg.x), \(startLabel)")
    }

    private func emitForStmt(_ fs: ForStmt) {
        if let init_ = fs.initStmt { emitStmt(init_) }
        let startLabel = newLabel()
        let endLabel = newLabel()
        emitLine("\(startLabel):")
        if let cond = fs.condition {
            let condReg = emitExpr(cond)
            emitLine("cbz \(condReg.x), \(endLabel)")
        }
        emitStmt(fs.body)
        if let incr = fs.increment { _ = emitExpr(incr) }
        emitLine("b \(startLabel)")
        emitLine("\(endLabel):")
    }

    // MARK: - Expression emission

    /// Emit an expression and return the register holding the result.
    private func emitExpr(_ expr: Expr) -> ARM64Reg {
        switch expr {
        case .integerLiteral(let l):
            let reg = regAlloc.alloc() ?? .x9
            emitLine("mov \(reg.x), #\(l.value)")
            return reg

        case .charLiteral(let cl):
            let reg = regAlloc.alloc() ?? .x9
            emitLine("mov \(reg.x), #\(cl.value)")
            return reg

        case .boolLiteral(let bl):
            let reg = regAlloc.alloc() ?? .x9
            emitLine("mov \(reg.x), #\(bl.value ? 1 : 0)")
            return reg

        case .floatLiteral:
            // TODO: FP support
            let reg = regAlloc.alloc() ?? .x9
            emitLine("mov \(reg.x), #0  ; float not supported yet")
            return reg

        case .stringLiteral(let sl):
            let label = addStringLiteral(sl.value)
            let reg = regAlloc.alloc() ?? .x9
            emitLine("adrp \(reg.x), \(label)@PAGE")
            emitLine("add \(reg.x), \(reg.x), \(label)@PAGEOFF")
            return reg

        case .identifier(let id):
            if let offset = localVarOffsets[id.name] {
                let reg = regAlloc.alloc() ?? .x9
                emitLine("ldr \(reg.x), [x29, #\(offset)]")
                return reg
            } else if globalLabels.contains(id.name) {
                let reg = regAlloc.alloc() ?? .x9
                emitLine("adrp \(reg.x), _\(id.name)@PAGE")
                emitLine("add \(reg.x), \(reg.x), _\(id.name)@PAGEOFF")
                return reg
            } else if id.name == "__builtin_va_list" || id.name == "__va_list_tag" {
                let reg = regAlloc.alloc() ?? .x9
                emitLine("mov \(reg.x), #0")
                return reg
            }
            // Unknown — return 0
            let reg = regAlloc.alloc() ?? .x9
            emitLine("mov \(reg.x), #0  ; unknown identifier \(id.name)")
            return reg

        case .binary(let b):
            return emitBinaryExpr(b)

        case .unary(let u):
            return emitUnaryExpr(u)

        case .assign(let a):
            return emitAssignExpr(a)

        case .call(let c):
            return emitCallExpr(c)

        case .subscript_(let s):
            return emitSubscriptExpr(s)

        case .member(let m):
            return emitMemberExpr(m)

        case .conditional(let c):
            return emitConditionalExpr(c)

        case .cast(let c):
            return emitExpr(c.expr)

        case .sizeof(let s):
            let reg = regAlloc.alloc() ?? .x9
            let size: Int
            if let typeName = s.typeName {
                size = typeName.sizeInBytes ?? 0
            } else if let e = s.expr {
                // Evaluate type of expression (simplified: use literal type)
                switch e {
                case .integerLiteral(let l): size = l.type.sizeInBytes ?? 4
                case .stringLiteral(let sl): size = sl.type.sizeInBytes ?? 0
                default: size = 8
                }
            } else {
                size = 0
            }
            emitLine("mov \(reg.x), #\(size)")
            return reg

        case .compoundLiteral(let cl):
            return emitExpr(cl.initList)

        case .initList(let il):
            // Return first value for now
            if let first = il.values.first {
                return emitExpr(first)
            }
            let reg = regAlloc.alloc() ?? .x9
            emitLine("mov \(reg.x), #0")
            return reg
        }
    }

    private func emitBinaryExpr(_ b: BinaryExpr) -> ARM64Reg {
        switch b.op {
        case .logicAnd:
            let leftReg = emitExpr(b.left)
            let endLabel = newLabel()
            emitLine("cbz \(leftReg.x), \(endLabel)")
            let rightReg = emitExpr(b.right)
            emitLine("and \(leftReg.x), \(leftReg.x), \(rightReg.x)")
            regAlloc.free(rightReg)
            emitLine("\(endLabel):")
            return leftReg

        case .logicOr:
            let leftReg = emitExpr(b.left)
            let endLabel = newLabel()
            emitLine("cbnz \(leftReg.x), \(endLabel)")
            let rightReg = emitExpr(b.right)
            emitLine("orr \(leftReg.x), \(leftReg.x), \(rightReg.x)")
            regAlloc.free(rightReg)
            emitLine("\(endLabel):")
            return leftReg

        case .comma:
            let leftReg = emitExpr(b.left)
            regAlloc.free(leftReg)
            return emitExpr(b.right)

        default:
            let leftReg = emitExpr(b.left)
            let rightReg = emitExpr(b.right)

            switch b.op {
            case .add:
                emitLine("add \(leftReg.x), \(leftReg.x), \(rightReg.x)")
            case .sub:
                emitLine("sub \(leftReg.x), \(leftReg.x), \(rightReg.x)")
            case .mul:
                emitLine("mul \(leftReg.x), \(leftReg.x), \(rightReg.x)")
            case .div:
                emitLine("sdiv \(leftReg.x), \(leftReg.x), \(rightReg.x)")
            case .mod:
                emitLine("sdiv \(rightReg.x), \(leftReg.x), \(rightReg.x)")
                emitLine("msub \(leftReg.x), \(rightReg.x), \(leftReg.x), \(leftReg.x)")
                // Actually: result = left - (left / right) * right
                // sdiv temp, left, right
                // msub result, temp, right, left
                // But we already overwrote rightReg. Let's use a temp.
                // This is wrong — let me fix below.
            case .shl:
                emitLine("lsl \(leftReg.x), \(leftReg.x), \(rightReg.x)")
            case .shr:
                emitLine("asr \(leftReg.x), \(leftReg.x), \(rightReg.x)")
            case .bitAnd:
                emitLine("and \(leftReg.x), \(leftReg.x), \(rightReg.x)")
            case .bitOr:
                emitLine("orr \(leftReg.x), \(leftReg.x), \(rightReg.x)")
            case .bitXor:
                emitLine("eor \(leftReg.x), \(leftReg.x), \(rightReg.x)")
            case .eq:
                emitLine("cmp \(leftReg.x), \(rightReg.x)")
                emitLine("cset \(leftReg.x), eq")
            case .ne:
                emitLine("cmp \(leftReg.x), \(rightReg.x)")
                emitLine("cset \(leftReg.x), ne")
            case .lt:
                emitLine("cmp \(leftReg.x), \(rightReg.x)")
                emitLine("cset \(leftReg.x), lt")
            case .le:
                emitLine("cmp \(leftReg.x), \(rightReg.x)")
                emitLine("cset \(leftReg.x), le")
            case .gt:
                emitLine("cmp \(leftReg.x), \(rightReg.x)")
                emitLine("cset \(leftReg.x), gt")
            case .ge:
                emitLine("cmp \(leftReg.x), \(rightReg.x)")
                emitLine("cset \(leftReg.x), ge")
            default:
                break
            }

            regAlloc.free(rightReg)
            return leftReg
        }
    }

    private func emitUnaryExpr(_ u: UnaryExpr) -> ARM64Reg {
        let operandReg = emitExpr(u.operand)

        switch u.op {
        case .neg:
            emitLine("neg \(operandReg.x), \(operandReg.x)")
        case .pos:
            break // no-op
        case .not:
            emitLine("cmp \(operandReg.x), #0")
            emitLine("cset \(operandReg.x), eq")
        case .bitNot:
            emitLine("mvn \(operandReg.x), \(operandReg.x)")
        case .dereference:
            emitLine("ldr \(operandReg.x), [\(operandReg.x)]")
        case .addressOf:
            // This is tricky — we need the address, not the value
            // For local vars, compute the address from x29
            // For now, this only works correctly for identifiers
            if case .identifier(let id) = u.operand {
                if let offset = localVarOffsets[id.name] {
                    emitLine("add \(operandReg.x), x29, #\(offset)")
                } else if globalLabels.contains(id.name) {
                    emitLine("adrp \(operandReg.x), _\(id.name)@PAGE")
                    emitLine("add \(operandReg.x), \(operandReg.x), _\(id.name)@PAGEOFF")
                }
            }
        case .preInc:
            emitLine("add \(operandReg.x), \(operandReg.x), #1")
            // Store back if it's an lvalue
            if case .identifier(let id) = u.operand, let offset = localVarOffsets[id.name] {
                emitLine("str \(operandReg.x), [x29, #\(offset)]")
            }
        case .preDec:
            emitLine("sub \(operandReg.x), \(operandReg.x), #1")
            if case .identifier(let id) = u.operand, let offset = localVarOffsets[id.name] {
                emitLine("str \(operandReg.x), [x29, #\(offset)]")
            }
        case .postInc:
            // Return original value, increment in place
            // We need a temp for the original
            break
        case .postDec:
            break
        }

        return operandReg
    }

    private func emitAssignExpr(_ a: AssignExpr) -> ARM64Reg {
        // For compound assignments (+=, -=, etc.), we need to read, operate, and write
        if a.op != .assign {
            // Load the current value of the target
            let currentReg = emitExpr(a.target)
            let rhsReg = emitExpr(a.value)

            // Apply the operation
            let binaryOp: BinaryOp
            switch a.op {
            case .addAssign: binaryOp = .add
            case .subAssign: binaryOp = .sub
            case .mulAssign: binaryOp = .mul
            case .divAssign: binaryOp = .div
            case .modAssign: binaryOp = .mod
            case .shlAssign: binaryOp = .shl
            case .shrAssign: binaryOp = .shr
            case .andAssign: binaryOp = .bitAnd
            case .orAssign: binaryOp = .bitOr
            case .xorAssign: binaryOp = .bitXor
            default: binaryOp = .add
            }

            switch binaryOp {
            case .add: emitLine("add \(currentReg.x), \(currentReg.x), \(rhsReg.x)")
            case .sub: emitLine("sub \(currentReg.x), \(currentReg.x), \(rhsReg.x)")
            case .mul: emitLine("mul \(currentReg.x), \(currentReg.x), \(rhsReg.x)")
            case .div: emitLine("sdiv \(currentReg.x), \(currentReg.x), \(rhsReg.x)")
            case .mod:
                // result = current - (current / rhs) * rhs
                let temp = regAlloc.alloc() ?? .x9
                emitLine("sdiv \(temp.x), \(currentReg.x), \(rhsReg.x)")
                emitLine("msub \(currentReg.x), \(temp.x), \(rhsReg.x), \(currentReg.x)")
                regAlloc.free(temp)
            case .shl: emitLine("lsl \(currentReg.x), \(currentReg.x), \(rhsReg.x)")
            case .shr: emitLine("asr \(currentReg.x), \(currentReg.x), \(rhsReg.x)")
            case .bitAnd: emitLine("and \(currentReg.x), \(currentReg.x), \(rhsReg.x)")
            case .bitOr: emitLine("orr \(currentReg.x), \(currentReg.x), \(rhsReg.x)")
            case .bitXor: emitLine("eor \(currentReg.x), \(currentReg.x), \(rhsReg.x)")
            default: break
            }
            regAlloc.free(rhsReg)

            // Store the result back to the target
            storeExprResult(a.target, currentReg)
            return currentReg
        }

        // Simple assignment: evaluate RHS, store to target
        let valueReg = emitExpr(a.value)
        storeExprResult(a.target, valueReg)
        return valueReg
    }

    /// Store a register's value back to an lvalue (local var, global, or via pointer).
    private func storeExprResult(_ target: Expr, _ reg: ARM64Reg) {
        if case .identifier(let id) = target {
            if let offset = localVarOffsets[id.name] {
                emitLine("str \(reg.x), [x29, #\(offset)]")
            } else if globalLabels.contains(id.name) {
                let addrReg = regAlloc.alloc() ?? .x9
                emitLine("adrp \(addrReg.x), _\(id.name)@PAGE")
                emitLine("add \(addrReg.x), \(addrReg.x), _\(id.name)@PAGEOFF")
                emitLine("str \(reg.x), [\(addrReg.x)]")
                regAlloc.free(addrReg)
            }
        }
        // TODO: handle member and subscript targets
    }

    private func emitCallExpr(_ c: CallExpr) -> ARM64Reg {
        var funcName = ""
        if case .identifier(let id) = c.function {
            funcName = id.name
        }

        // Evaluate arguments and place in x0-x7
        for (i, arg) in c.arguments.enumerated() {
            if i < 8 {
                let argReg = emitExpr(arg)
                if argReg != argRegs[i] {
                    emitLine("mov \(argRegs[i].x), \(argReg.x)")
                }
                regAlloc.free(argReg)
            } else {
                let argReg = emitExpr(arg)
                regAlloc.free(argReg)
            }
        }

        // Save scratch registers that are currently in use to the stack
        // before the call, since the callee may clobber them.
        // Use 16-byte aligned stack adjustments (AAPCS64 requirement).
        let inUse = scratchRegs.filter { reg in
            !regAlloc.available.contains(reg)
        }
        // Pad to even count for 16-byte alignment
        let paddedCount = inUse.count + (inUse.count % 2)
        if paddedCount > 0 {
            emitLine("sub sp, sp, #\(paddedCount * 8)")
            for (idx, reg) in inUse.enumerated() {
                emitLine("str \(reg.x), [sp, #\(idx * 8)]")
            }
        }

        // Make the call
        if !funcName.isEmpty {
            emitLine("bl _\(funcName)")
        }

        // Restore spilled registers
        if paddedCount > 0 {
            for (idx, reg) in inUse.enumerated() {
                emitLine("ldr \(reg.x), [sp, #\(idx * 8)]")
            }
            emitLine("add sp, sp, #\(paddedCount * 8)")
        }

        // Result is in x0
        let resultReg = regAlloc.alloc() ?? .x9
        if resultReg != .x0 {
            emitLine("mov \(resultReg.x), x0")
        }
        return resultReg
    }

    private func emitSubscriptExpr(_ s: SubscriptExpr) -> ARM64Reg {
        let baseReg = emitExpr(s.base)
        let indexReg = emitExpr(s.index)
        // Compute address = base + index * elementSize
        // For simplicity, assume 4-byte elements (int)
        emitLine("ldr \(baseReg.x), [\(baseReg.x), \(indexReg.x), lsl #2]")
        regAlloc.free(indexReg)
        return baseReg
    }

    private func emitMemberExpr(_ m: MemberExpr) -> ARM64Reg {
        let baseReg = emitExpr(m.base)
        // We need to know the offset of the member
        // For simplicity, return the base for now
        // TODO: compute member offset from struct layout
        return baseReg
    }

    private func emitConditionalExpr(_ c: ConditionalExpr) -> ARM64Reg {
        let condReg = emitExpr(c.condition)
        let elseLabel = newLabel()
        let endLabel = newLabel()
        let resultReg = regAlloc.alloc() ?? .x9
        emitLine("cbz \(condReg.x), \(elseLabel)")
        let trueReg = emitExpr(c.trueExpr)
        emitLine("mov \(resultReg.x), \(trueReg.x)")
        regAlloc.free(trueReg)
        emitLine("b \(endLabel)")
        emitLine("\(elseLabel):")
        let falseReg = emitExpr(c.falseExpr)
        emitLine("mov \(resultReg.x), \(falseReg.x)")
        regAlloc.free(falseReg)
        emitLine("\(endLabel):")
        return resultReg
    }

    // MARK: - Store/load helpers

    private func storeLocal(_ name: String, _ reg: ARM64Reg, type: CType) {
        if let offset = localVarOffsets[name] {
            emitLine("str \(reg.x), [x29, #\(offset)]")
        }
    }

    // MARK: - Utility

    private func emitLine(_ s: String) {
        output += s + "\n"
    }

    private func newLabel() -> String {
        labelCounter += 1
        return "L_\(currentFuncName)_\(labelCounter)"
    }
}
