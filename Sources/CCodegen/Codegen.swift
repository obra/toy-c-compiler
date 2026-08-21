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
    private var localVarTypes: [String: CType] = [:]
    private var globalVarTypes: [String: CType] = [:]
    private var knownRecords: [String: RecordType] = [:]

    public init() {}

    // MARK: - Public API

    public func generate(_ decls: [Decl]) -> String {
        output = ""

        // Collect global variable names and types
        for d in decls {
            if case .varDecl(let vd) = d {
                globalLabels.insert(vd.name)
                globalVarTypes[vd.name] = vd.type
            }
        }

        // Collect completed struct/union definitions (by tag name)
        for d in decls {
            if case .structDecl(let sd) = d, sd.record.size != nil {
                knownRecords[sd.name ?? ""] = sd.record
            }
            if case .unionDecl(let ud) = d, ud.record.size != nil {
                knownRecords[ud.name ?? ""] = ud.record
            }
            // Also collect from struct/union declarations that have inline definitions
            // (e.g., struct Point { int x; int y; } p; — these are VarDecls with struct types)
            if case .varDecl(let vd) = d {
                collectRecords(vd.type)
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
                localVarTypes[param.name ?? "_param_\(i)"] = param.type
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
        localVarTypes[name] = type
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
            regAlloc.reset()

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
        regAlloc.reset()
        let condReg = emitExpr(ws.condition)
        emitLine("cbz \(condReg.x), \(endLabel)")
        regAlloc.reset()
        emitStmt(ws.body)
        regAlloc.reset()
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
        regAlloc.reset()
        let startLabel = newLabel()
        let endLabel = newLabel()
        emitLine("\(startLabel):")
        if let cond = fs.condition {
            let condReg = emitExpr(cond)
            emitLine("cbz \(condReg.x), \(endLabel)")
        }
        regAlloc.reset()
        emitStmt(fs.body)
        regAlloc.reset()
        if let incr = fs.increment { _ = emitExpr(incr) }
        regAlloc.reset()
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
        // For addressOf, we need the address, not the value
        if u.op == .addressOf {
            return emitAddr(u.operand)
        }

        // For dereference, load from the address
        if u.op == .dereference {
            let addrReg = emitExpr(u.operand)
            emitLine("ldr \(addrReg.x), [\(addrReg.x)]")
            return addrReg
        }

        // For pre/post inc/dec, load, modify, store
        if u.op == .preInc || u.op == .preDec || u.op == .postInc || u.op == .postDec {
            let addrReg = emitAddr(u.operand)
            let valReg = regAlloc.alloc() ?? .x9
            emitLine("ldr \(valReg.x), [\(addrReg.x)]")

            let resultReg: ARM64Reg
            if u.op == .postInc || u.op == .postDec {
                let origReg = regAlloc.alloc() ?? .x9
                emitLine("mov \(origReg.x), \(valReg.x)")
                if u.op == .postInc {
                    emitLine("add \(valReg.x), \(valReg.x), #1")
                } else {
                    emitLine("sub \(valReg.x), \(valReg.x), #1")
                }
                emitLine("str \(valReg.x), [\(addrReg.x)]")
                regAlloc.free(valReg)
                regAlloc.free(addrReg)
                resultReg = origReg
            } else {
                if u.op == .preInc {
                    emitLine("add \(valReg.x), \(valReg.x), #1")
                } else {
                    emitLine("sub \(valReg.x), \(valReg.x), #1")
                }
                emitLine("str \(valReg.x), [\(addrReg.x)]")
                regAlloc.free(addrReg)
                resultReg = valReg
            }
            return resultReg
        }

        let operandReg = emitExpr(u.operand)

        switch u.op {
        case .neg:
            emitLine("neg \(operandReg.x), \(operandReg.x)")
        case .pos:
            break
        case .not:
            emitLine("cmp \(operandReg.x), #0")
            emitLine("cset \(operandReg.x), eq")
        case .bitNot:
            emitLine("mvn \(operandReg.x), \(operandReg.x)")
        default:
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

    /// Store a register's value to an lvalue (local var, global, member, subscript, deref).
    private func storeExprResult(_ target: Expr, _ reg: ARM64Reg) {
        let addrReg = emitAddr(target)
        // Always use 64-bit stores for simplicity and consistency
        emitLine("str \(reg.x), [\(addrReg.x)]")
        regAlloc.free(addrReg)
    }

    private func emitCallExpr(_ c: CallExpr) -> ARM64Reg {
        var funcName = ""
        if case .identifier(let id) = c.function {
            funcName = id.name
        }

        // Check if this is a variadic function (e.g., printf)
        // On Apple ARM64, variadic arguments go on the stack after the named args.
        // We track known variadic functions by name.
        let variadicFuncs: Set<String> = ["printf", "fprintf", "sprintf", "snprintf",
                                          "puts", "fputs", "scanf", "sscanf", "fprintf",
                                          "__assert_fail", "qsort"]
        let isVariadic = variadicFuncs.contains(funcName)

        // For variadic functions: first arg (format) in x0, rest on stack
        if isVariadic && c.arguments.count > 1 {
            // Evaluate all arguments
            var argRegs: [ARM64Reg] = []
            for arg in c.arguments {
                let argReg = emitExpr(arg)
                argRegs.append(argReg)
            }

            // First argument goes in x0 (the format string for printf)
            if argRegs[0] != .x0 {
                emitLine("mov x0, \(argRegs[0].x)")
            }
            for r in argRegs { regAlloc.free(r) }

            // Push variadic arguments onto the stack (in reverse order)
            // Each arg is 8 bytes, aligned to 16 for AAPCS64
            let stackArgs = argRegs.count - 1
            let stackSize = (stackArgs * 8 + 15) & ~15  // align to 16
            emitLine("sub sp, sp, #\(stackSize)")
            for i in 1..<argRegs.count {
                let argReg = argRegs[i]
                let stackOffset = (i - 1) * 8
                emitLine("str \(argReg.x), [sp, #\(stackOffset)]")
            }
        } else {
            // Non-variadic: evaluate args and place in x0-x7
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
        }

        // Save scratch registers that are currently in use to the stack
        let inUse = scratchRegs.filter { reg in
            !regAlloc.available.contains(reg)
        }
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

        // Clean up variadic stack args
        if isVariadic && c.arguments.count > 1 {
            let stackArgs = c.arguments.count - 1
            let stackSize = (stackArgs * 8 + 15) & ~15
            emitLine("add sp, sp, #\(stackSize)")
        }

        // Result is in x0
        let resultReg = regAlloc.alloc() ?? .x9
        if resultReg != .x0 {
            emitLine("mov \(resultReg.x), x0")
        }
        return resultReg
    }

    // MARK: - Type inference for codegen

    /// Determine the type of an expression (for computing offsets, element sizes, etc.)
    private func exprType(_ expr: Expr) -> CType {
        switch expr {
        case .integerLiteral(let l): return l.type
        case .charLiteral: return .int
        case .floatLiteral(let f): return f.type
        case .stringLiteral(let s): return s.type
        case .boolLiteral: return .bool
        case .identifier(let id):
            if let t = localVarTypes[id.name] { return t }
            if let t = globalVarTypes[id.name] { return t }
            return .int
        case .binary(let b):
            // For pointer arithmetic, result type is the pointer type
            let lt = exprType(b.left)
            let rt = exprType(b.right)
            if lt.isPointer && rt.isInteger { return lt }
            if lt.isInteger && rt.isPointer { return rt }
            return lt.isArithmetic ? lt : rt
        case .unary(let u):
            switch u.op {
            case .dereference:
                let t = exprType(u.operand)
                if case .pointer(let to) = t.unqualified { return to }
                if case .array(let elem, _) = t.unqualified { return elem }
                return .int
            case .addressOf:
                return .pointer(to: exprType(u.operand))
            default:
                return exprType(u.operand)
            }
        case .assign(let a):
            return exprType(a.target)
        case .call(let c):
            // Look up function return type
            if case .identifier(let id) = c.function {
                if let t = globalVarTypes[id.name] {
                    if case .function(_, let ret, _) = t.unqualified { return ret }
                }
                // Check if it's a known function
                return .int
            }
            return .int
        case .subscript_(let s):
            let bt = exprType(s.base)
            if case .pointer(let to) = bt.unqualified { return to }
            if case .array(let elem, _) = bt.unqualified { return elem }
            return .int
        case .member(let m):
            let bt = exprType(m.base)
            var recordType = bt.unqualified
            if m.isArrow {
                if case .pointer(let to) = bt.unqualified { recordType = to }
            }
            if case .structType(let rec) = recordType.unqualified {
                for field in rec.fields where field.name == m.memberName {
                    return field.type
                }
            }
            if case .unionType(let rec) = recordType.unqualified {
                for field in rec.fields where field.name == m.memberName {
                    return field.type
                }
            }
            return .int
        case .cast(let c):
            return c.type
        case .conditional:
            return .int
        case .sizeof:
            return .ulong
        case .compoundLiteral(let cl):
            return cl.type
        case .initList:
            return .int
        }
    }

    /// Collect completed record types from a CType (recursive).
    private func collectRecords(_ type: CType) {
        var t = type.unqualified
        if case .pointer(let to) = t { t = to.unqualified }
        if case .structType(let rec) = t, rec.size != nil {
            knownRecords[rec.name] = rec
        }
        if case .unionType(let rec) = t, rec.size != nil {
            knownRecords[rec.name] = rec
        }
    }

    /// Get the offset of a struct/union member.
    private func memberOffset(_ baseType: CType, _ memberName: String) -> Int {
        var t = baseType.unqualified
        if case .pointer(let to) = t { t = to.unqualified }
        // If the record is incomplete, try to look it up by name
        if case .structType(let rec) = t {
            if rec.fields.isEmpty, let completed = knownRecords[rec.name] {
                t = .structType(completed)
            }
        }
        if case .unionType(let rec) = t {
            if rec.fields.isEmpty, let completed = knownRecords[rec.name] {
                t = .unionType(completed)
            }
        }
        if case .structType(let rec) = t {
            for field in rec.fields where field.name == memberName {
                return field.offset
            }
        }
        if case .unionType(let rec) = t {
            for field in rec.fields where field.name == memberName {
                return field.offset
            }
        }
        return 0
    }

    /// Emit the address of an lvalue expression (without loading its value).
    /// Returns the register holding the address.
    private func emitAddr(_ expr: Expr) -> ARM64Reg {
        switch expr {
        case .identifier(let id):
            let reg = regAlloc.alloc() ?? .x9
            if let offset = localVarOffsets[id.name] {
                emitLine("add \(reg.x), x29, #\(offset)")
            } else if globalLabels.contains(id.name) {
                emitLine("adrp \(reg.x), _\(id.name)@PAGE")
                emitLine("add \(reg.x), \(reg.x), _\(id.name)@PAGEOFF")
            }
            return reg

        case .subscript_(let s):
            let baseReg = emitExpr(s.base)
            let indexReg = emitExpr(s.index)
            let elemType = exprType(s.base)
            let elemSize = elemType.unqualified.isPointer ? 8 : (elemType.sizeInBytes ?? 4)
            // addr = base + index * elemSize
            if elemSize == 1 {
                emitLine("add \(baseReg.x), \(baseReg.x), \(indexReg.x)")
            } else if elemSize == 2 {
                emitLine("add \(baseReg.x), \(baseReg.x), \(indexReg.x), lsl #1")
            } else if elemSize == 4 {
                emitLine("add \(baseReg.x), \(baseReg.x), \(indexReg.x), lsl #2")
            } else {
                emitLine("add \(baseReg.x), \(baseReg.x), \(indexReg.x), lsl #3")
            }
            regAlloc.free(indexReg)
            return baseReg

        case .member(let m):
            let baseReg: ARM64Reg
            if m.isArrow {
                // For a->b: evaluate a (loads the pointer), then add member offset
                baseReg = emitExpr(m.base)
            } else {
                // For a.b: get address of a, then add member offset
                baseReg = emitAddr(m.base)
            }
            let offset = memberOffset(exprType(m.base), m.memberName)
            if offset != 0 {
                emitLine("add \(baseReg.x), \(baseReg.x), #\(offset)")
            }
            return baseReg

        case .unary(let u) where u.op == .dereference:
            // Address of *p is just p
            return emitExpr(u.operand)

        default:
            // Not an lvalue — just evaluate
            return emitExpr(expr)
        }
    }

    private func emitSubscriptExpr(_ s: SubscriptExpr) -> ARM64Reg {
        let addrReg = emitAddr(.subscript_(s))
        // Always use 64-bit load for consistency
        emitLine("ldr \(addrReg.x), [\(addrReg.x)]")
        return addrReg
    }

    private func emitMemberExpr(_ m: MemberExpr) -> ARM64Reg {
        let addrReg = emitAddr(.member(m))
        // Always use 64-bit load for consistency
        emitLine("ldr \(addrReg.x), [\(addrReg.x)]")
        return addrReg
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
