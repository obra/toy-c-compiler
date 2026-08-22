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
    private var externGlobals: Set<String> = []  // extern globals — accessed via GOT
    private var localOffset = 0
    private var localVarOffsets: [String: Int] = [:]
    private var frameSize = 0
    private var labelCounter = 0
    private var regAlloc = RegAlloc()
    private var currentFuncName = ""
    private var localVarTypes: [String: CType] = [:]
    private var globalVarTypes: [String: CType] = [:]
    private var knownRecords: [String: RecordType] = [:]
    private var functionNames: Set<String> = []   // names of all declared functions
    private var definedFunctions: Set<String> = []  // functions with bodies (locally defined)
    private var functionReturnTypes: [String: CType] = [:]  // function name → return type
    private var variadicFunctions: Set<String> = []  // functions with variadic params (...)
    private var functionParamCounts: [String: Int] = [:]  // function name → number of named params
    private var staticLocalGlobals: [String: String] = [:]  // local name → mangled global name
    private var staticLocalInits: [(name: String, type: CType, init_: Expr)] = []  // pending static initializers
    private var breakLabels: [String] = []      // stack of break targets
    private var continueLabels: [String] = []   // stack of continue targets
    private var gotoLabels: [String: String] = [:]  // C label name → assembly label
    private var vaSaveAreaOffset: Int = 0  // offset from x29 to va register save area (0 = no va)
    private var enumConstants: [String: Int64] = [:]  // enum constant name → value
    private var compoundLiterals: [(label: String, type: CType, init_: Expr)] = []
    private var compoundLiteralCounter = 0

    public init(enumConstants: [String: Int64] = [:]) {
        self.enumConstants = enumConstants
    }

    // MARK: - Public API

    public func generate(_ decls: [Decl]) -> String {
        output = ""

        // Collect global variable names and types, and function names
        for d in decls {
            if case .varDecl(let vd) = d {
                globalLabels.insert(vd.name)
                globalVarTypes[vd.name] = vd.type
                if vd.storageClass == .extern && vd.initializer == nil {
                    externGlobals.insert(vd.name)
                } else {
                    // A non-extern declaration (or one with an initializer) defines
                    // the variable locally — remove from extern set if it was there.
                    externGlobals.remove(vd.name)
                }
            }
            if case .funcDecl(let fd) = d {
                // Collect all function declarations (with or without bodies)
                functionNames.insert(fd.name)
                functionReturnTypes[fd.name] = fd.returnType
                if fd.body != nil {
                    definedFunctions.insert(fd.name)
                }
                if fd.variadic {
                    variadicFunctions.insert(fd.name)
                }
                functionParamCounts[fd.name] = fd.params.count
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

        // Emit static local variable data (discovered during function emission)
        emitStaticLocalData()

        // Emit compound literals (discovered during initialization)
        emitCompoundLiterals()

        // Emit string literals at the end
        emitStringLiterals()

        return output
    }

    // MARK: - Data section

    private func emitDataSection(_ decls: [Decl]) {
        var hasGlobals = false
        var emittedLabels: Set<String> = []
        // First pass: collect names that have initializers (actual definitions)
        var definedGlobals: Set<String> = []
        // Also track which globals have a non-extern definition (tentative or real)
        var nonExternDefs: Set<String> = []
        for d in decls {
            if case .varDecl(let vd) = d, vd.isGlobal {
                if vd.initializer != nil {
                    definedGlobals.insert(vd.name)
                }
                if vd.storageClass != .extern {
                    nonExternDefs.insert(vd.name)
                }
            }
        }
        for d in decls {
            if case .varDecl(let vd) = d, vd.isGlobal {
                // Skip pure extern declarations (no storage emitted)
                if vd.storageClass == .extern && !nonExternDefs.contains(vd.name) {
                    continue
                }
                // Only emit storage once per variable — prefer the definition with initializer
                if emittedLabels.contains(vd.name) {
                    continue
                }
                // Skip tentative definitions (no initializer) if there's a real definition later
                if vd.initializer == nil && definedGlobals.contains(vd.name) {
                    continue
                }
                // If this is an extern declaration but there's a non-extern one, skip
                if vd.storageClass == .extern && nonExternDefs.contains(vd.name) {
                    continue
                }
                emittedLabels.insert(vd.name)
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
                    emitInitializer(init_, size: size, type: vd.type)
                } else if vd.storageClass == .extern {
                    // extern declaration — don't emit storage, the linker resolves it
                } else {
                    // BSS (zero-initialized)
                    emitLine(".section __DATA,__bss")
                    emitLine(".globl _\(vd.name)")
                    emitLine(".p2align 3")
                    emitLine("_\(vd.name):")
                    // Use at least 8 bytes for scalar types, actual size for aggregates
                    let bssSize = vd.type.isScalar ? max(size, 8) : max(size, 1)
                    emitLine(".zero \(bssSize)")
                }
            }
        }
    }

    private func emitInitializer(_ expr: Expr, size: Int, type: CType? = nil) {
        switch expr {
        case .integerLiteral(let l):
            // Emit the correct number of bytes based on the type
            if let type = type {
                let t = type.unqualified
                switch t {
                case .bool, .char, .schar, .uchar:
                    emitLine(".byte \(l.value & 0xFF)")
                case .short, .ushort:
                    emitLine(".short \(l.value & 0xFFFF)")
                case .int, .uint:
                    emitLine(".long \(l.value & 0xFFFFFFFF)")
                case .long, .ulong, .longLong, .ulongLong:
                    emitLine(".quad \(l.value)")
                case .pointer, .function:
                    emitLine(".quad \(l.value)")
                case .qualified(let base, _, _, _):
                    emitInitializer(expr, size: size, type: base)
                case .typedef(_, let base):
                    emitInitializer(expr, size: size, type: base)
                default:
                    emitLine(".quad \(l.value)")
                }
            } else {
                emitLine(".quad \(l.value)")
            }
        case .floatLiteral(let f):
            // Emit IEEE 754 bits for float/double
            if let type = type, type.unqualified == .float {
                let bits = Float(f.value).bitPattern
                emitLine(".long \(bits)")
            } else {
                let bits = f.value.bitPattern
                emitLine(".quad \(bits)")
            }
        case .initList(let il):
            // Emit each element with the correct type/size from the struct fields or array element type
            if let type = type {
                let t = type.unqualified
                if case .structType(let rec) = t {
                    // Struct initializer: emit each value at its field's offset,
                    // filling gaps with .zero. When a field is an array, consume
                    // multiple values from the flat init list.
                    let fields = rec.fields
                    var currentOffset = 0
                    var valueIdx = 0
                    for field in fields {
                        let fieldOffset = field.offset
                        // Emit padding before this field if needed
                        if fieldOffset > currentOffset {
                            emitLine(".zero \(fieldOffset - currentOffset)")
                        }
                        let fieldType = field.type.unqualified
                        if case .array(let elemType, let count) = fieldType {
                            // Array field: consume values for array elements
                            for _ in 0..<count {
                                if valueIdx < il.values.count {
                                    emitInitializer(il.values[valueIdx], size: elemType.sizeInBytes ?? 8, type: elemType)
                                    valueIdx += 1
                                } else {
                                    emitLine(".zero \(elemType.sizeInBytes ?? 8)")
                                }
                            }
                            currentOffset = fieldOffset + (field.type.sizeInBytes ?? count * (elemType.sizeInBytes ?? 8))
                        } else {
                            // Scalar or struct field: consume one value
                            if valueIdx < il.values.count {
                                emitInitializer(il.values[valueIdx], size: field.type.sizeInBytes ?? 8, type: field.type)
                                valueIdx += 1
                            } else {
                                emitLine(".zero \(field.type.sizeInBytes ?? 8)")
                            }
                            currentOffset = fieldOffset + (field.type.sizeInBytes ?? 8)
                        }
                    }
                    // Emit trailing padding to reach full struct size
                    let totalSize = rec.size ?? currentOffset
                    if totalSize > currentOffset {
                        emitLine(".zero \(totalSize - currentOffset)")
                    }
                } else if case .array(let elemType, let count) = t {
                    // Array initializer: use element type
                    var emitted = 0
                    for v in il.values {
                        emitInitializer(v, size: elemType.sizeInBytes ?? 8, type: elemType)
                        emitted += 1
                    }
                    // Fill remaining elements with zero
                    if emitted < count {
                        let remaining = count - emitted
                        emitLine(".zero \(remaining * (elemType.sizeInBytes ?? 8))")
                    }
                } else {
                    for v in il.values {
                        emitInitializer(v, size: 8)
                    }
                }
            } else {
                for v in il.values {
                    emitInitializer(v, size: 8)
                }
            }
        case .stringLiteral(let sl):
            // String literal in initializer
            if let type = type, case .array(let elemType, let count) = type.unqualified,
               elemType.isChar {
                // Initializing a char array — emit string bytes inline
                let bytes = sl.value
                if bytes.count <= count {
                    // Emit as .ascii with null padding
                    emitLine(".asciz \"\(escapeStringLiteral(bytes))\"")
                    // Pad remaining bytes
                    // .asciz already adds 1 null byte; total emitted = bytes.count + 1
                    let emitted = bytes.count + 1
                    if count > emitted {
                        emitLine(".zero \(count - emitted)")
                    }
                } else {
                    // String too long — truncate
                    emitLine(".ascii \"\(escapeStringLiteral(String(bytes.prefix(count))))\"")
                }
            } else {
                // Not a char array — emit address of string
                let label = addStringLiteral(sl.value)
                emitLine(".quad \(label)")
            }
        case .unary(let u) where u.op == .addressOf:
            // Address of string literal, global, or static local
            if case .stringLiteral(let sl) = u.operand {
                let label = addStringLiteral(sl.value)
                emitLine(".quad \(label)")
            } else if case .integerLiteral(let l) = u.operand, l.value == 0 {
                emitLine(".quad 0")
            } else if case .identifier(let id) = u.operand {
                // &globalVar or &staticLocal — emit address of the symbol
                if globalLabels.contains(id.name) {
                    emitLine(".quad _\(id.name)")
                } else if let mangled = staticLocalGlobals[id.name] {
                    emitLine(".quad \(mangled)")
                } else if functionNames.contains(id.name) {
                    emitLine(".quad _\(id.name)")
                } else {
                    // External symbol
                    emitLine(".quad _\(id.name)")
                }
            } else if case .compoundLiteral(let cl) = u.operand {
                // &(type) { init-list } — emit as unnamed global, return address
                let label = "L_COMPLIT_\(compoundLiteralCounter)"
                compoundLiteralCounter += 1
                compoundLiterals.append((label: label, type: cl.type, init_: cl.initList))
                emitLine(".quad \(label)")
            } else if case .subscript_(let sub) = u.operand {
                // &array[constant] — emit symbol + offset
                if let (sym, offset) = resolveAddressOfSubscript(sub) {
                    emitSymbolOffset(sym, offset)
                } else {
                    emitLine(".quad 0")
                }
            } else if case .member(let m) = u.operand {
                // &struct.member — emit symbol + field offset
                if let (sym, offset) = resolveAddressOfMember(m) {
                    emitSymbolOffset(sym, offset)
                } else {
                    emitLine(".quad 0")
                }
            } else if case .binary(let b) = u.operand, b.op == .add || b.op == .sub {
                // &(base + offset) or &(base - offset) — pointer arithmetic in initializer
                if let (sym, offset) = resolvePointerArith(b) {
                    emitSymbolOffset(sym, offset)
                } else {
                    emitLine(".quad 0")
                }
            } else {
                emitLine(".quad 0")
            }
        case .cast(let c):
            // Cast in initializer — just emit the underlying value
            emitInitializer(c.expr, size: size, type: type)
        case .identifier(let id):
            // Function name, global/static variable, or external symbol in initializer
            if functionNames.contains(id.name) {
                emitLine(".quad _\(id.name)")
            } else if globalLabels.contains(id.name) {
                emitLine(".quad _\(id.name)")
            } else if let mangled = staticLocalGlobals[id.name] {
                emitLine(".quad \(mangled)")
            } else {
                // External symbol (e.g., library function like getcwd, close, etc.)
                // Emit as a symbol reference for the linker to resolve
                emitLine(".quad _\(id.name)")
            }
        default:
            // Try to resolve as symbol + offset (e.g., array + 10 in a pointer initializer)
            if let (sym, offset) = resolveSymbolAndOffset(expr) {
                if offset == 0 {
                    emitLine(".quad \(sym)")
                } else if offset > 0 {
                    emitLine(".quad \(sym)+\(offset)")
                } else {
                    emitLine(".quad \(sym)-\(-offset)")
                }
            } else if let val = evalConstExpr(expr) {
                emitInitializer(.integerLiteral(IntegerLiteral(value: val, type: type ?? .int, loc: SourceLoc.unknown)), size: size, type: type)
            } else {
                // Default: zero-fill
                emitLine(".zero \(max(size, 8))")
            }
        }
    }

    /// Emit .quad with symbol + offset (handles positive, negative, and zero offsets)
    private func emitSymbolOffset(_ sym: String, _ offset: Int64) {
        if offset == 0 {
            emitLine(".quad \(sym)")
        } else if offset > 0 {
            emitLine(".quad \(sym)+\(offset)")
        } else {
            emitLine(".quad \(sym)-\(-offset)")
        }
    }

    /// Resolve a symbol name and its total byte offset for address-of expressions in initializers.
    /// Returns (symbol, offset) where symbol is like "_arr" and offset is a byte offset.
    private func resolveSymbolAndOffset(_ expr: Expr) -> (String, Int64)? {
        switch expr {
        case .identifier(let id):
            if globalLabels.contains(id.name) {
                return ("_\(id.name)", 0)
            } else if let mangled = staticLocalGlobals[id.name] {
                return (mangled, 0)
            } else if functionNames.contains(id.name) {
                return ("_\(id.name)", 0)
            } else {
                // External symbol — assume it's a global
                return ("_\(id.name)", 0)
            }
        case .subscript_(let sub):
            // array[index] = *(array + index)
            if let (sym, baseOff) = resolveSymbolAndOffset(sub.base),
               let idx = evalConstExpr(sub.index) {
                let elemSize: Int = {
                    let baseType = exprType(sub.base).unqualified
                    if case .pointer(let to) = baseType {
                        return to.unqualified.sizeInBytes ?? 1
                    }
                    if case .array(let elemType, _) = baseType {
                        return elemType.sizeInBytes ?? 1
                    }
                    return 1
                }()
                return (sym, baseOff + idx * Int64(elemSize))
            }
            return nil
        case .member(let m):
            // struct.member
            if let (sym, baseOff) = resolveSymbolAndOffset(m.base) {
                let baseType = exprType(m.base).unqualified
                if case .structType(let rec) = baseType,
                   let field = rec.fields.first(where: { $0.name == m.memberName }) {
                    return (sym, baseOff + Int64(field.offset))
                }
            }
            return nil
        case .cast(let c):
            return resolveSymbolAndOffset(c.expr)
        case .binary(let b) where b.op == .add || b.op == .sub:
            // base + offset or base - offset (pointer arithmetic)
            // Try both orderings: symbol + const, const + symbol
            if let (sym, off) = resolveSymbolAndOffset(b.left), let constVal = evalConstExpr(b.right) {
                let pointeeSize: Int = {
                    if case .pointer(let to) = exprType(b.left).unqualified {
                        return to.unqualified.sizeInBytes ?? 1
                    }
                    return 1
                }()
                let delta = constVal * Int64(pointeeSize)
                return (sym, off + (b.op == .add ? delta : -delta))
            }
            if let (sym, off) = resolveSymbolAndOffset(b.right), let constVal = evalConstExpr(b.left) {
                let pointeeSize: Int = {
                    if case .pointer(let to) = exprType(b.right).unqualified {
                        return to.unqualified.sizeInBytes ?? 1
                    }
                    return 1
                }()
                let delta = constVal * Int64(pointeeSize)
                return (sym, off + (b.op == .add ? delta : -delta))
            }
            return nil
        default:
            return nil
        }
    }

    /// Resolve &array[constant] for initializers
    private func resolveAddressOfSubscript(_ sub: SubscriptExpr) -> (String, Int64)? {
        return resolveSymbolAndOffset(.subscript_(sub))
    }

    /// Resolve &struct.member for initializers
    private func resolveAddressOfMember(_ m: MemberExpr) -> (String, Int64)? {
        return resolveSymbolAndOffset(.member(m))
    }

    /// Resolve pointer arithmetic (base +/- offset) for initializers
    private func resolvePointerArith(_ b: BinaryExpr) -> (String, Int64)? {
        return resolveSymbolAndOffset(.binary(b))
    }

    /// Best-effort constant expression evaluation for initializers.
    private func evalConstExpr(_ expr: Expr) -> Int64? {
        switch expr {
        case .integerLiteral(let l):
            return l.value
        case .charLiteral(let cl):
            return Int64(cl.value)
        case .identifier(let id):
            // Enum constants are compile-time integer values
            return enumConstants[id.name]
        case .binary(let b):
            guard let lhs = evalConstExpr(b.left), let rhs = evalConstExpr(b.right) else { return nil }
            switch b.op {
            case .add: return lhs + rhs
            case .sub: return lhs - rhs
            case .mul: return lhs * rhs
            case .div: return rhs != 0 ? lhs / rhs : nil
            case .mod: return rhs != 0 ? lhs % rhs : nil
            case .shl: return lhs << rhs
            case .shr: return lhs >> rhs
            case .bitAnd: return lhs & rhs
            case .bitOr: return lhs | rhs
            case .bitXor: return lhs ^ rhs
            case .lt: return lhs < rhs ? 1 : 0
            case .gt: return lhs > rhs ? 1 : 0
            case .le: return lhs <= rhs ? 1 : 0
            case .ge: return lhs >= rhs ? 1 : 0
            case .eq: return lhs == rhs ? 1 : 0
            case .ne: return lhs != rhs ? 1 : 0
            case .logicAnd: return (lhs != 0 && rhs != 0) ? 1 : 0
            case .logicOr: return (lhs != 0 || rhs != 0) ? 1 : 0
            default: return nil
            }
        case .unary(let u):
            guard let val = evalConstExpr(u.operand) else { return nil }
            switch u.op {
            case .neg: return -val
            case .bitNot: return ~val
            case .not: return val == 0 ? 1 : 0
            default: return val
            }
        case .cast(let c):
            return evalConstExpr(c.expr)
        case .conditional(let c):
            guard let cond = evalConstExpr(c.condition) else { return nil }
            return cond != 0 ? evalConstExpr(c.trueExpr) : evalConstExpr(c.falseExpr)
        case .sizeof(let s):
            if let typeName = s.typeName {
                // sizeof(type) — resolve type size
                return Int64(typeName.sizeInBytes ?? 0)
            }
            // sizeof(expr) — get type of expr and return its size
            if let e = s.expr {
                return Int64(exprType(e).sizeInBytes ?? 0)
            }
            return 0
        default:
            return nil
        }
    }

    // MARK: - Static local data

    private func emitStaticLocalData() {
        guard !staticLocalInits.isEmpty else { return }
        var emitted: Set<String> = []
        emitLine(".section __DATA,__data")
        for item in staticLocalInits {
            if emitted.contains(item.name) { continue }
            emitted.insert(item.name)
            let size = item.type.sizeInBytes ?? 8
            emitLine(".globl \(item.name)")
            emitLine(".p2align 3")
            emitLine("\(item.name):")
            emitInitializer(item.init_, size: size, type: item.type)
        }
    }

    // MARK: - String literals

    private func emitCompoundLiterals() {
        guard !compoundLiterals.isEmpty else { return }
        emitLine(".section __DATA,__data")
        for cl in compoundLiterals {
            let size = cl.type.sizeInBytes ?? 0
            emitLine(".p2align 3")
            emitLine("\(cl.label):")
            emitInitializer(cl.init_, size: size, type: cl.type)
        }
    }

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
        let bytes = Array(s.utf8)
        var idx = 0
        while idx < bytes.count {
            let byte = bytes[idx]
            // Check for passthrough escape sequences (stored by parser for bytes >= 128)
            if byte == 0x5C && idx + 3 < bytes.count
               && bytes[idx+1] >= 0x30 && bytes[idx+1] <= 0x37
               && bytes[idx+2] >= 0x30 && bytes[idx+2] <= 0x37
               && bytes[idx+3] >= 0x30 && bytes[idx+3] <= 0x37 {
                // Pass through \OOO octal escape as-is
                result += "\\"
                result += String(UnicodeScalar(bytes[idx+1]))
                result += String(UnicodeScalar(bytes[idx+2]))
                result += String(UnicodeScalar(bytes[idx+3]))
                idx += 4
                continue
            }
            switch byte {
            case 0x0A: result += "\\n"
            case 0x09: result += "\\t"
            case 0x0D: result += "\\r"
            case 0x5C: result += "\\\\"
            case 0x22: result += "\\\""
            case 0x00: result += "\\0"
            case 0x20...0x7E: result += String(UnicodeScalar(byte))
            default: result += String(format: "\\%03o", byte)
            }
            idx += 1
        }
        return result
    }

    private func addStringLiteral(_ s: String) -> String {
        let label = "L_STR_\(stringLabelCounter)"
        stringLabelCounter += 1
        stringLiterals.append((label: label, value: s))
        return label
    }

    /// Escape a string for use in .ascii/.asciz directives
    private func escapeStringLiteral(_ s: String) -> String {
        var result = ""
        for c in s.unicodeScalars {
            switch c {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case "\0": result += "\\0"
            default:
                if c.value >= 32 && c.value < 127 {
                    result += String(c)
                } else {
                    result += String(format: "\\%03o", c.value)
                }
            }
        }
        return result
    }

    // MARK: - Function emission

    private func emitFunction(_ fd: FuncDecl) {
        currentFuncName = fd.name
        localOffset = 0
        localVarOffsets = [:]
        gotoLabels = [:]
        frameSize = 0
        labelCounter = 0
        // Save static local map so function-specific statics don't leak to other functions
        let savedStaticLocals = staticLocalGlobals

        emitLine("")
        emitLine(".globl _\(fd.name)")
        emitLine(".p2align 2")
        emitLine("_\(fd.name):")

        // Prologue: save fp and lr, set up frame pointer
        emitLine("stp x29, x30, [sp, #-16]!")
        emitLine("mov x29, sp")

        // For variadic functions: the caller pushes variadic args on the stack
        // (macOS ARM64 ABI). The args are above the saved fp/lr, at x29 + 16.
        // We don't need to save x1-x7 — just point va_start to x29+16.
        if fd.variadic {
            vaSaveAreaOffset = 16  // x29 + 16 = where caller pushed variadic args
        } else {
            vaSaveAreaOffset = 0
        }

        // Allocate space for local variables (will be patched after we know the size)
        let frameAllocLine = "sub sp, sp, #0  ; FRAME_SIZE_PLACEHOLDER"
        emitLine(frameAllocLine)

        // Add parameters to local variables
        // Track how many registers each parameter consumes (1 for most types, 2 for 9-16 byte structs)
        var regIndex = 0  // current register index (x0, x1, ...)
        for (i, param) in fd.params.enumerated() {
            let pt = param.type.unqualified
            let paramSize = pt.sizeInBytes ?? 8
            let regWidth: Int
            if case .structType = pt, paramSize > 8, paramSize <= 16 {
                regWidth = 2
            } else {
                regWidth = 1
            }

            if regIndex < 8 {
                // Parameters come in x0-x7, store them on the stack
                ensureLocalSpace(size: regWidth * 8)
                let offset = -(localOffset)
                localVarOffsets[param.name ?? "_param_\(i)"] = offset
                let isInt = pt.isInteger || pt.isPointer || pt.isFunction
                if isInt {
                    // Always use 64-bit store for simplicity
                    emitStoreFP(argRegs[regIndex].x, offset)
                } else if regWidth == 2 {
                    // Struct parameter: store 2 registers
                    emitStoreFP(argRegs[regIndex].x, offset)
                    if regIndex + 1 < 8 {
                        emitStoreFP(argRegs[regIndex + 1].x, offset + 8)
                    }
                }
                localVarTypes[param.name ?? "_param_\(i)"] = param.type
                regIndex += regWidth
            } else {
                // Parameters beyond x0-x7 are passed on the stack by the caller.
                // They are at [x29, #16 + (regIndex-8)*8] (above saved fp/lr).
                let stackSrcOffset = 16 + (regIndex - 8) * 8
                ensureLocalSpace(size: regWidth * 8)
                let localOff = -(localOffset)
                localVarOffsets[param.name ?? "_param_\(i)"] = localOff
                // Load from caller's stack and store to our local frame
                emitLoadFP("x9", stackSrcOffset)
                emitStoreFP("x9", localOff)
                if regWidth == 2 {
                    emitLoadFP("x9", stackSrcOffset + 8)
                    emitStoreFP("x9", localOff + 8)
                }
                localVarTypes[param.name ?? "_param_\(i)"] = param.type
                regIndex += regWidth
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
        let frameInstr: String
        if alignedFrameSize <= 4095 {
            frameInstr = "sub sp, sp, #\(frameSizeStr)"
        } else {
            // Large frame: use scratch register (x16 is safe in prologue)
            let lo = alignedFrameSize & 0xFFFF
            let hi = (alignedFrameSize >> 16) & 0xFFFF
            frameInstr = "mov x16, #\(lo)\n" +
                         "movk x16, #\(hi), lsl #16\n" +
                         "sub sp, sp, x16"
        }
        output = output.replacingOccurrences(
            of: "sub sp, sp, #0  ; FRAME_SIZE_PLACEHOLDER",
            with: frameInstr)

        // Restore static local map so function-specific statics don't leak
        staticLocalGlobals = savedStaticLocals
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
                    if vd.storageClass == .static {
                        // Static local: hoist to global scope with a mangled name
                        let globalName = "_\(currentFuncName)__\(vd.name)"
                        let isFirstTime = !staticLocalGlobals.values.contains(globalName)
                        staticLocalGlobals[vd.name] = globalName
                        if isFirstTime {
                            globalLabels.insert(globalName)
                            if let init_ = vd.initializer {
                                staticLocalInits.append((name: globalName, type: vd.type, init_: init_))
                            } else {
                                // BSS
                                staticLocalInits.append((name: globalName, type: vd.type, init_: .integerLiteral(IntegerLiteral(value: 0, type: .int, loc: SourceLoc.unknown))))
                            }
                            // Don't add to localVarOffsets — static locals are resolved
                            // via staticLocalGlobals in emitExpr/emitAddr
                            localVarTypes[vd.name] = vd.type
                        }
                    } else {
                        allocLocal(name: vd.name, type: vd.type)
                        if let init_ = vd.initializer {
                            if case .stringLiteral(let sl) = init_,
                               case .array(let elemType, let count) = vd.type.unqualified,
                               elemType.isChar {
                                // char arr[] = "string" — copy bytes to local array
                                let addrReg = regAlloc.alloc() ?? .x9
                                if let offset = localVarOffsets[vd.name] {
                                    if offset >= -256 && offset <= 255 {
                                        emitLine("add \(addrReg.x), x29, #\(offset)")
                                    } else {
                                        emitLoadImm("x16", Int64(offset))
                                        emitLine("add \(addrReg.x), x29, x16")
                                    }
                                    let label = addStringLiteral(sl.value)
                                    let srcReg = regAlloc.alloc() ?? .x9
                                    emitLine("adrp \(srcReg.x), \(label)@PAGE")
                                    emitLine("add \(srcReg.x), \(srcReg.x), \(label)@PAGEOFF")
                                    // Copy up to count bytes (string + null terminator)
                                    let bytes = Array(sl.value.utf8)
                                    for i in 0..<min(count, bytes.count + 1) {
                                        if i > 0 {
                                            emitLine("ldrb w16, [\(srcReg.x), #\(i)]")
                                            emitLine("strb w16, [\(addrReg.x), #\(i)]")
                                        } else {
                                            emitLine("ldrb w16, [\(srcReg.x)]")
                                            emitLine("strb w16, [\(addrReg.x)]")
                                        }
                                    }
                                    regAlloc.free(srcReg)
                                }
                                regAlloc.free(addrReg)
                            } else if case .initList = init_ {
                                // Aggregate initializer: emit each field/element at its offset
                                let addrReg = regAlloc.alloc() ?? .x9
                                if let offset = localVarOffsets[vd.name] {
                                    if offset >= -256 && offset <= 255 {
                                        emitLine("add \(addrReg.x), x29, #\(offset)")
                                    } else {
                                        emitLoadImm("x16", Int64(offset))
                                        emitLine("add \(addrReg.x), x29, x16")
                                    }
                                    emitLocalInit(addrReg, init_, type: vd.type)
                                }
                                regAlloc.free(addrReg)
                            } else {
                                let reg = emitExpr(init_)
                                storeLocal(vd.name, reg, type: vd.type)
                            }
                        }
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
            if let label = breakLabels.last {
                emitLine("b \(label)")
            }

        case .continue:
            if let label = continueLabels.last {
                emitLine("b \(label)")
            }

        case .switch(let ss):
            emitSwitchStmt(ss)

        case .case, .default:
            // Case/default labels are handled inside emitSwitchStmt
            break

        case .goto(let g):
            // Get or create the assembly label for this C label
            let asmLabel: String
            if let existing = gotoLabels[g.label] {
                asmLabel = existing
            } else {
                asmLabel = newLabel()
                gotoLabels[g.label] = asmLabel
            }
            emitLine("b \(asmLabel)")

        case .label(let l):
            // Use existing label if goto already created one, else create new
            let asmLabel: String
            if let existing = gotoLabels[l.name] {
                asmLabel = existing
            } else {
                asmLabel = newLabel()
                gotoLabels[l.name] = asmLabel
            }
            emitLine("\(asmLabel):")
            emitStmt(l.stmt)

        case .empty:
            break
        }
    }

    private func emitIfStmt(_ is_: IfStmt) {
        let condReg = emitExpr(is_.condition)
        regAlloc.reset()
        let elseLabel = newLabel()
        let endLabel = newLabel()
        emitLine("cbz \(condReg.x), \(elseLabel)")
        emitStmt(is_.thenStmt)
        regAlloc.reset()
        emitLine("b \(endLabel)")
        emitLine("\(elseLabel):")
        if let else_ = is_.elseStmt {
            emitStmt(else_)
            regAlloc.reset()
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
        breakLabels.append(endLabel)
        continueLabels.append(startLabel)
        emitStmt(ws.body)
        breakLabels.removeLast()
        continueLabels.removeLast()
        regAlloc.reset()
        emitLine("b \(startLabel)")
        emitLine("\(endLabel):")
    }

    private func emitDoWhileStmt(_ dws: DoWhileStmt) {
        let startLabel = newLabel()
        let continueLabel = newLabel()
        let endLabel = newLabel()
        emitLine("\(startLabel):")
        breakLabels.append(endLabel)
        continueLabels.append(continueLabel)
        emitStmt(dws.body)
        breakLabels.removeLast()
        continueLabels.removeLast()
        emitLine("\(continueLabel):")
        regAlloc.reset()
        let condReg = emitExpr(dws.condition)
        emitLine("cbnz \(condReg.x), \(startLabel)")
        emitLine("\(endLabel):")
    }

    private func emitForStmt(_ fs: ForStmt) {
        if let init_ = fs.initStmt { emitStmt(init_) }
        regAlloc.reset()
        let startLabel = newLabel()
        let continueLabel = newLabel()
        let endLabel = newLabel()
        emitLine("\(startLabel):")
        if let cond = fs.condition {
            let condReg = emitExpr(cond)
            emitLine("cbz \(condReg.x), \(endLabel)")
        }
        regAlloc.reset()
        breakLabels.append(endLabel)
        continueLabels.append(continueLabel)
        emitStmt(fs.body)
        breakLabels.removeLast()
        continueLabels.removeLast()
        emitLine("\(continueLabel):")
        regAlloc.reset()
        if let incr = fs.increment { _ = emitExpr(incr) }
        regAlloc.reset()
        emitLine("b \(startLabel)")
        emitLine("\(endLabel):")
    }

    private func emitSwitchStmt(_ ss: SwitchStmt) {
        let endLabel = newLabel()
        let valueReg = emitExpr(ss.value)
        regAlloc.reset()

        // Spill the switch value to a stack slot so case comparisons don't clobber it
        ensureLocalSpace(size: 8)
        let switchOffset = -localOffset
        emitStoreFP(valueReg.x, switchOffset)
        regAlloc.reset()

        // Use string keys to avoid collisions between top-level and nested case labels
        var caseLabelMap: [String: String] = [:]
        var defaultLabel: String? = nil

        // Helper: emit a comparison and branch for a case value
        func emitCaseComparison(_ caseVal: Expr) -> String {
            let label = newLabel()
            let val = emitExpr(caseVal)
            let switchTemp = regAlloc.alloc() ?? .x10
            emitLoadFP(switchTemp.x, switchOffset)
            emitLine("cmp \(switchTemp.x), \(val.x)")
            emitLine("b.eq \(label)")
            regAlloc.free(switchTemp)
            regAlloc.free(val)
            regAlloc.reset()
            return label
        }

        // First pass: emit comparisons for all case labels (including nested ones inside compound statements)
        for (idx, stmt) in ss.cases.enumerated() {
            if case .case(let cs) = stmt {
                caseLabelMap["\(idx)"] = emitCaseComparison(cs.value)
                // If the case body is a compound statement, scan for nested case labels (Duff's device)
                if case .compound(let comp) = cs.stmt {
                    for (innerIdx, innerStmt) in comp.statements.enumerated() {
                        if case .case(let innerCs) = innerStmt {
                            caseLabelMap["\(idx).\(innerIdx)"] = emitCaseComparison(innerCs.value)
                        } else if case .default = innerStmt {
                            defaultLabel = newLabel()
                        }
                    }
                }
            } else if case .compound(let comp) = stmt {
                for (innerIdx, innerStmt) in comp.statements.enumerated() {
                    if case .case = innerStmt {
                        if case .case(let cs) = innerStmt {
                            caseLabelMap["\(idx).\(innerIdx)"] = emitCaseComparison(cs.value)
                        }
                    } else if case .default = innerStmt {
                        defaultLabel = newLabel()
                    }
                }
            } else if case .default = stmt {
                defaultLabel = newLabel()
            }
        }

        // Jump to default or end
        if let dl = defaultLabel {
            emitLine("b \(dl)")
        } else {
            emitLine("b \(endLabel)")
        }

        // Second pass: emit the body with case/default labels
        breakLabels.append(endLabel)

        // Helper: emit a compound statement with nested case labels injected at their positions
        func emitCompoundWithCases(_ comp: CompoundStmt, keyPrefix: String) {
            for (innerIdx, innerStmt) in comp.statements.enumerated() {
                let key = "\(keyPrefix).\(innerIdx)"
                if let label = caseLabelMap[key] {
                    emitLine("\(label):")
                } else if case .default = innerStmt, let dl = defaultLabel {
                    emitLine("\(dl):")
                }
                // For nested .case/.default inside compound statements, emit the body directly
                // (emitStmt skips them since they're "handled inside emitSwitchStmt")
                if case .case(let cs) = innerStmt {
                    if let s = cs.stmt { emitStmt(s) }
                } else if case .default(let ds) = innerStmt {
                    if let s = ds.stmt { emitStmt(s) }
                } else {
                    emitStmt(innerStmt)
                }
            }
        }

        for (idx, stmt) in ss.cases.enumerated() {
            if let label = caseLabelMap["\(idx)"] {
                emitLine("\(label):")
            } else if case .default = stmt, let dl = defaultLabel {
                emitLine("\(dl):")
            }
            // Emit the statement (case stmt or regular stmt)
            switch stmt {
            case .case(let cs):
                if let s = cs.stmt {
                    if case .compound(let comp) = s {
                        emitCompoundWithCases(comp, keyPrefix: "\(idx)")
                    } else {
                        emitStmt(s)
                    }
                }
            case .default(let ds):
                if let s = ds.stmt { emitStmt(s) }
            case .compound(let comp):
                emitCompoundWithCases(comp, keyPrefix: "\(idx)")
            default:
                emitStmt(stmt)
            }
        }

        breakLabels.removeLast()
        emitLine("\(endLabel):")
    }

    // MARK: - Expression emission

    /// Emit an expression and return the register holding the result.
    private func emitExpr(_ expr: Expr) -> ARM64Reg {
        switch expr {
        case .integerLiteral(let l):
            let reg = regAlloc.alloc() ?? .x9
            emitLoadImm(reg.x, l.value)
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
            // Check enum constants first — they are compile-time integer values
            if let val = enumConstants[id.name] {
                let reg = regAlloc.alloc() ?? .x9
                emitLoadImm(reg.x, val)
                return reg
            }
            if let offset = localVarOffsets[id.name] {
                let reg = regAlloc.alloc() ?? .x9
                // If the local is an array, return the address (array decays to pointer)
                if let t = localVarTypes[id.name], case .array = t.unqualified {
                    if offset >= -256 && offset <= 255 {
                        emitLine("add \(reg.x), x29, #\(offset)")
                    } else {
                        emitLoadImm("x16", Int64(offset))
                        emitLine("add \(reg.x), x29, x16")
                    }
                    return reg
                }
                // Type-aware load for local variables
                if let t = localVarTypes[id.name] {
                    // Get address first, then use emitLoad
                    if offset >= -256 && offset <= 255 {
                        emitLine("add \(reg.x), x29, #\(offset)")
                    } else {
                        emitLoadImm("x17", Int64(offset))
                        emitLine("add \(reg.x), x29, x17")
                    }
                    emitLoad(reg, type: t)
                } else {
                    emitLoadFP(reg.x, offset)
                }
                return reg
            } else if let globalName = staticLocalGlobals[id.name] {
                // Static local variable — load from its mangled global
                let reg = regAlloc.alloc() ?? .x9
                emitLine("adrp \(reg.x), \(globalName)@PAGE")
                emitLine("add \(reg.x), \(reg.x), \(globalName)@PAGEOFF")
                // If the static local is an array, return the address (array decays to pointer)
                if let t = localVarTypes[id.name], case .array = t.unqualified {
                    return reg
                }
                emitLine("ldr \(reg.x), [\(reg.x)]")
                return reg
            } else if globalLabels.contains(id.name) {
                let reg = regAlloc.alloc() ?? .x9
                if externGlobals.contains(id.name) {
                    // External global (e.g., __stderrp) — load address through GOT, then load value
                    emitLine("adrp \(reg.x), _\(id.name)@GOTPAGE")
                    emitLine("ldr \(reg.x), [\(reg.x), _\(id.name)@GOTPAGEOFF]")
                    // If the global is an array, return the address (array decays to pointer)
                    if let gt = globalVarTypes[id.name], case .array = gt.unqualified {
                        return reg
                    }
                    emitLine("ldr \(reg.x), [\(reg.x)]")
                } else {
                    emitLine("adrp \(reg.x), _\(id.name)@PAGE")
                    emitLine("add \(reg.x), \(reg.x), _\(id.name)@PAGEOFF")
                    // If the global is an array, return the address (array decays to pointer)
                    if let gt = globalVarTypes[id.name], case .array = gt.unqualified {
                        return reg
                    }
                    // Otherwise, load the value from the global address
                    emitLine("ldr \(reg.x), [\(reg.x)]")
                }
                return reg
            } else if functionNames.contains(id.name) {
                // Function name used as a value (e.g., assigned to a function pointer).
                let reg = regAlloc.alloc() ?? .x9
                if definedFunctions.contains(id.name) {
                    // Locally defined — direct address
                    emitLine("adrp \(reg.x), _\(id.name)@PAGE")
                    emitLine("add \(reg.x), \(reg.x), _\(id.name)@PAGEOFF")
                } else {
                    // External function — load address through GOT
                    emitLine("adrp \(reg.x), _\(id.name)@GOTPAGE")
                    emitLine("ldr \(reg.x), [\(reg.x), _\(id.name)@GOTPAGEOFF]")
                }
                return reg
            } else if id.name == "__builtin_va_list" || id.name == "__va_list_tag" {
                let reg = regAlloc.alloc() ?? .x9
                emitLine("mov \(reg.x), #0")
                return reg
            } else {
                // External symbol (function or variable) used as a value — load through GOT.
                let reg = regAlloc.alloc() ?? .x9
                emitLine("adrp \(reg.x), _\(id.name)@GOTPAGE")
                emitLine("ldr \(reg.x), [\(reg.x), _\(id.name)@GOTPAGEOFF]")
                return reg
            }

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
                // Resolve incomplete struct types via known records
                var t = typeName.unqualified
                if case .structType(let rec) = t, rec.fields.isEmpty, let completed = knownRecords[rec.name] {
                    t = .structType(completed)
                }
                if case .unionType(let rec) = t, rec.fields.isEmpty, let completed = knownRecords[rec.name] {
                    t = .unionType(completed)
                }
                size = t.sizeInBytes ?? 0
            } else if let e = s.expr {
                // Evaluate type of expression
                let t = exprType(e)
                size = t.sizeInBytes ?? 4
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
            let falseLabel = newLabel()
            let endLabel = newLabel()
            emitLine("cbz \(leftReg.x), \(falseLabel)")
            let rightReg = emitExpr(b.right)
            emitLine("cbz \(rightReg.x), \(falseLabel)")
            emitLine("mov \(leftReg.x), #1")
            emitLine("b \(endLabel)")
            emitLine("\(falseLabel):")
            emitLine("mov \(leftReg.x), #0")
            regAlloc.free(rightReg)
            emitLine("\(endLabel):")
            return leftReg

        case .logicOr:
            let leftReg = emitExpr(b.left)
            let trueLabel = newLabel()
            let endLabel = newLabel()
            emitLine("cbnz \(leftReg.x), \(trueLabel)")
            let rightReg = emitExpr(b.right)
            emitLine("cbnz \(rightReg.x), \(trueLabel)")
            emitLine("mov \(leftReg.x), #0")
            emitLine("b \(endLabel)")
            emitLine("\(trueLabel):")
            emitLine("mov \(leftReg.x), #1")
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

            // Determine if this is a signed 32-bit comparison
            let leftType = exprType(b.left).unqualified
            let rightType = exprType(b.right).unqualified
            let is32BitSigned: Bool = {
                switch leftType {
                case .int, .short, .schar, .char, .enumType:
                    return true
                case .uint, .ushort, .uchar:
                    return false
                default:
                    return false
                }
            }()

            // For pointer arithmetic (pointer + int or pointer - int), multiply
            // the integer operand by sizeof(pointee) before the add/sub.
            // Also sign-extend 32-bit signed int operands to 64 bits.
            // Skip when BOTH operands are pointers (that's pointer difference,
            // handled separately in the .sub case below).
            let isPtrArith = (leftType.isPointer || rightType.isPointer) && !(leftType.isPointer && rightType.isPointer)
            if isPtrArith && (b.op == .add || b.op == .sub) {
                // Determine which operand is the pointer and get the pointee size
                let ptrType: CType = leftType.isPointer ? leftType : rightType
                let pointeeSize: Int = {
                    if case .pointer(let to) = ptrType.unqualified {
                        let t = to.unqualified
                        return t.isPointer ? 8 : (t.sizeInBytes ?? 4)
                    }
                    return 4
                }()

                // Sign-extend 32-bit signed int operands and scale by pointee size
                let intReg = leftType.isPointer ? rightReg : leftReg
                if (leftType.isPointer ? rightType : leftType).isSigned32Bit {
                    emitLine("sxtw \(intReg.x), \(intReg.w)")
                }
                if pointeeSize > 1 {
                    if pointeeSize == 2 {
                        emitLine("lsl \(intReg.x), \(intReg.x), #1")
                    } else if pointeeSize == 4 {
                        emitLine("lsl \(intReg.x), \(intReg.x), #2")
                    } else if pointeeSize == 8 {
                        emitLine("lsl \(intReg.x), \(intReg.x), #3")
                    } else {
                        emitLine("mov x16, #\(pointeeSize)")
                        emitLine("mul \(intReg.x), \(intReg.x), x16")
                    }
                }
            }

            switch b.op {
            case .add:
                emitLine("add \(leftReg.x), \(leftReg.x), \(rightReg.x)")
            case .sub:
                if leftType.isPointer && rightType.isPointer {
                    // pointer - pointer: subtract then divide by element size
                    emitLine("sub \(leftReg.x), \(leftReg.x), \(rightReg.x)")
                    let pointeeSize: Int = {
                        if case .pointer(let to) = leftType.unqualified {
                            let t = to.unqualified
                            return t.isPointer ? 8 : (t.sizeInBytes ?? 4)
                        }
                        return 1
                    }()
                    if pointeeSize > 1 {
                        if pointeeSize == 2 {
                            emitLine("asr \(leftReg.x), \(leftReg.x), #1")
                        } else if pointeeSize == 4 {
                            emitLine("asr \(leftReg.x), \(leftReg.x), #2")
                        } else if pointeeSize == 8 {
                            emitLine("asr \(leftReg.x), \(leftReg.x), #3")
                        } else {
                            emitLine("mov x16, #\(pointeeSize)")
                            emitLine("sdiv \(leftReg.x), \(leftReg.x), x16")
                        }
                    }
                } else {
                    emitLine("sub \(leftReg.x), \(leftReg.x), \(rightReg.x)")
                }
            case .mul:
                emitLine("mul \(leftReg.x), \(leftReg.x), \(rightReg.x)")
            case .div:
                emitLine("sdiv \(leftReg.x), \(leftReg.x), \(rightReg.x)")
            case .mod:
                // sdiv temp, left, right  → temp = left / right
                // msub left, temp, right, left  → left = left - temp * right
                // Need a scratch register since rightReg holds the divisor
                emitLine("sdiv x16, \(leftReg.x), \(rightReg.x)")
                emitLine("msub \(leftReg.x), x16, \(rightReg.x), \(leftReg.x)")
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
                if is32BitSigned {
                    emitLine("sxtw \(leftReg.x), \(leftReg.w)")
                    emitLine("sxtw \(rightReg.x), \(rightReg.w)")
                }
                emitLine("cmp \(leftReg.x), \(rightReg.x)")
                emitLine("cset \(leftReg.x), eq")
            case .ne:
                if is32BitSigned {
                    emitLine("sxtw \(leftReg.x), \(leftReg.w)")
                    emitLine("sxtw \(rightReg.x), \(rightReg.w)")
                }
                emitLine("cmp \(leftReg.x), \(rightReg.x)")
                emitLine("cset \(leftReg.x), ne")
            case .lt:
                if is32BitSigned {
                    emitLine("sxtw \(leftReg.x), \(leftReg.w)")
                    emitLine("sxtw \(rightReg.x), \(rightReg.w)")
                }
                emitLine("cmp \(leftReg.x), \(rightReg.x)")
                emitLine("cset \(leftReg.x), lt")
            case .le:
                if is32BitSigned {
                    emitLine("sxtw \(leftReg.x), \(leftReg.w)")
                    emitLine("sxtw \(rightReg.x), \(rightReg.w)")
                }
                emitLine("cmp \(leftReg.x), \(rightReg.x)")
                emitLine("cset \(leftReg.x), le")
            case .gt:
                if is32BitSigned {
                    emitLine("sxtw \(leftReg.x), \(leftReg.w)")
                    emitLine("sxtw \(rightReg.x), \(rightReg.w)")
                }
                emitLine("cmp \(leftReg.x), \(rightReg.x)")
                emitLine("cset \(leftReg.x), gt")
            case .ge:
                if is32BitSigned {
                    emitLine("sxtw \(leftReg.x), \(leftReg.w)")
                    emitLine("sxtw \(rightReg.x), \(rightReg.w)")
                }
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
            // For arrays, *arr is equivalent to arr[0] — use emitAddr (address)
            // For pointers, *ptr loads the value pointed to — use emitExpr (pointer value)
            let operandType = exprType(u.operand).unqualified
            let addrReg: ARM64Reg
            if operandType.isArray {
                addrReg = emitAddr(u.operand)
            } else {
                addrReg = emitExpr(u.operand)
            }
            // Determine the pointed-to type and load with correct size
            let pointedType: CType
            if case .pointer(let to) = operandType { pointedType = to }
            else if case .array(let elem, _) = operandType { pointedType = elem }
            else { pointedType = .int }
            // If pointed type is an array, return address (array decays to pointer)
            if case .array = pointedType.unqualified {
                return addrReg
            }
            emitLoad(addrReg, type: pointedType)
            return addrReg
        }

        // For pre/post inc/dec, load, modify, store
        if u.op == .preInc || u.op == .preDec || u.op == .postInc || u.op == .postDec {
            let addrReg = emitAddr(u.operand)
            let valReg = regAlloc.alloc() ?? .x9
            // Determine the increment size (1 for scalars, sizeof(pointed) for pointers)
            let operandType = exprType(u.operand).unqualified
            let incSize: Int
            if operandType.isPointer {
                if case .pointer(let to) = operandType {
                    incSize = to.sizeInBytes ?? 1
                } else {
                    incSize = 1
                }
            } else {
                incSize = 1
            }
            // Use type-aware load/store
            // Move address to valReg first since emitLoad loads from [reg] into reg
            emitLine("mov \(valReg.x), \(addrReg.x)")
            emitLoad(valReg, type: operandType)

            let resultReg: ARM64Reg
            if u.op == .postInc || u.op == .postDec {
                let origReg = regAlloc.alloc() ?? .x9
                emitLine("mov \(origReg.x), \(valReg.x)")
                if u.op == .postInc {
                    emitLine("add \(valReg.x), \(valReg.x), #\(incSize)")
                } else {
                    emitLine("sub \(valReg.x), \(valReg.x), #\(incSize)")
                }
                emitStoreToAddr(addrReg, valReg, type: operandType)
                regAlloc.free(valReg)
                regAlloc.free(addrReg)
                resultReg = origReg
            } else {
                if u.op == .preInc {
                    emitLine("add \(valReg.x), \(valReg.x), #\(incSize)")
                } else {
                    emitLine("sub \(valReg.x), \(valReg.x), #\(incSize)")
                }
                emitStoreToAddr(addrReg, valReg, type: operandType)
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

            // For pointer arithmetic in compound assignments, scale the int by sizeof(pointee)
            let targetType = exprType(a.target).unqualified
            let valueType = exprType(a.value).unqualified
            let isPtrArithCompound = (targetType.isPointer || valueType.isPointer) && !(targetType.isPointer && valueType.isPointer)
            if isPtrArithCompound && (binaryOp == .add || binaryOp == .sub) {
                // Determine pointee size from the pointer operand
                let ptrType: CType = targetType.isPointer ? targetType : valueType
                let pointeeSize: Int = {
                    if case .pointer(let to) = ptrType.unqualified {
                        let t = to.unqualified
                        return t.isPointer ? 8 : (t.sizeInBytes ?? 4)
                    }
                    return 4
                }()
                if valueType.isSigned32Bit {
                    emitLine("sxtw \(rhsReg.x), \(rhsReg.w)")
                }
                if pointeeSize > 1 {
                    if pointeeSize == 2 {
                        emitLine("lsl \(rhsReg.x), \(rhsReg.x), #1")
                    } else if pointeeSize == 4 {
                        emitLine("lsl \(rhsReg.x), \(rhsReg.x), #2")
                    } else if pointeeSize == 8 {
                        emitLine("lsl \(rhsReg.x), \(rhsReg.x), #3")
                    } else {
                        emitLine("mov x16, #\(pointeeSize)")
                        emitLine("mul \(rhsReg.x), \(rhsReg.x), x16")
                    }
                }
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
        let targetType = exprType(a.target).unqualified
        if case .structType = targetType, let size = targetType.sizeInBytes, size > 8 {
            // Struct assignment: get source address and copy bytes to target
            let srcReg = emitAddr(a.value)
            let dstReg = emitAddr(a.target)
            var remaining = size
            var offset = 0
            while remaining >= 8 {
                emitLine("ldr x16, [\(srcReg.x), #\(offset)]")
                emitLine("str x16, [\(dstReg.x), #\(offset)]")
                offset += 8
                remaining -= 8
            }
            if remaining >= 4 {
                emitLine("ldr w16, [\(srcReg.x), #\(offset)]")
                emitLine("str w16, [\(dstReg.x), #\(offset)]")
                offset += 4
                remaining -= 4
            }
            if remaining >= 2 {
                emitLine("ldrh w16, [\(srcReg.x), #\(offset)]")
                emitLine("strh w16, [\(dstReg.x), #\(offset)]")
                offset += 2
                remaining -= 2
            }
            if remaining >= 1 {
                emitLine("ldrb w16, [\(srcReg.x), #\(offset)]")
                emitLine("strb w16, [\(dstReg.x), #\(offset)]")
            }
            regAlloc.free(srcReg)
            regAlloc.free(dstReg)
            return .x9  // return a dummy register
        }
        let valueReg = emitExpr(a.value)
        storeExprResult(a.target, valueReg)
        return valueReg
    }

    /// Store a register's value to an lvalue (local var, global, member, subscript, deref).
    private func storeExprResult(_ target: Expr, _ reg: ARM64Reg) {
        // Check if this is a bitfield member write (read-modify-write)
        if case .member(let m) = target,
           let bf = bitfieldInfo(exprType(m.base), m.memberName) {
            // Bitfield write: read-modify-write on the containing unit.
            // Push the value to the stack, then call emitAddr (which for simple
            // member expressions on locals/params does NOT push to the stack).
            // After emitAddr, the value is at [sp+16] (one 16-byte push).
            // For complex base expressions where emitAddr DOES push, this would
            // break — but that's rare and not needed for SQLite.
            emitLine("str \(reg.x), [sp, #-16]!")
            let addrReg = emitAddr(target)
            let unitReg: ARM64Reg = (addrReg == .x16) ? .x17 : .x16
            let valReg: ARM64Reg = (addrReg == .x16) ? .x16 : .x17
            // Load the containing unit into unitReg
            switch bf.unitSize {
            case 1: emitLine("ldrb \(unitReg.w), [\(addrReg.x)]")
            case 2: emitLine("ldrh \(unitReg.w), [\(addrReg.x)]")
            case 4: emitLine("ldr \(unitReg.w), [\(addrReg.x)]")
            case 8: emitLine("ldr \(unitReg.x), [\(addrReg.x)]")
            default: emitLine("ldr \(unitReg.w), [\(addrReg.x)]")
            }
            // Compute masks
            let bitfieldMask: UInt64 = (UInt64(1) << UInt64(bf.bitWidth) - 1) << UInt64(bf.bitOffset)
            let clearMask: UInt64 = ~bitfieldMask
            let valueMask: UInt64 = (UInt64(1) << UInt64(bf.bitWidth) - 1) << UInt64(bf.bitOffset)
            // Load the new value from stack (at sp — one 16-byte push before emitAddr)
            emitLine("ldr \(valReg.x), [sp]")
            // Shift the new value to the bitfield position
            if bf.bitOffset > 0 {
                emitLine("lsl \(valReg.x), \(valReg.x), #\(bf.bitOffset)")
            }
            // Mask the new value to bitWidth bits (shifted to position)
            if valueMask <= 255 {
                emitLine("and \(valReg.x), \(valReg.x), #\(valueMask)")
            } else {
                emitLine("mov \(unitReg.x), #\(valueMask & 0xffff)")
                if valueMask > 0xffff {
                    emitLine("movk \(unitReg.x), #\((valueMask >> 16) & 0xffff), lsl #16")
                }
                if valueMask > 0xffffff {
                    emitLine("movk \(unitReg.x), #\((valueMask >> 32) & 0xffff), lsl #32")
                }
                if valueMask > 0xffffffffffff {
                    emitLine("movk \(unitReg.x), #\((valueMask >> 48) & 0xffff), lsl #48")
                }
                emitLine("and \(valReg.x), \(valReg.x), \(unitReg.x)")
            }
            // Clear bitfield bits in containing unit
            if clearMask <= 255 {
                emitLine("and \(unitReg.x), \(unitReg.x), #\(clearMask)")
            } else {
                // Build clearMask in valReg, AND with unitReg, then reload valReg from stack
                emitLine("mov \(valReg.x), #\(clearMask & 0xffff)")
                if clearMask > 0xffff {
                    emitLine("movk \(valReg.x), #\((clearMask >> 16) & 0xffff), lsl #16")
                }
                if clearMask > 0xffffff {
                    emitLine("movk \(valReg.x), #\((clearMask >> 32) & 0xffff), lsl #32")
                }
                if clearMask > 0xffffffffffff {
                    emitLine("movk \(valReg.x), #\((clearMask >> 48) & 0xffff), lsl #48")
                }
                emitLine("and \(unitReg.x), \(unitReg.x), \(valReg.x)")
                // Reload original value from stack and recompute
                emitLine("ldr \(valReg.x), [sp]")
                if bf.bitOffset > 0 {
                    emitLine("lsl \(valReg.x), \(valReg.x), #\(bf.bitOffset)")
                }
                if valueMask <= 255 {
                    emitLine("and \(valReg.x), \(valReg.x), #\(valueMask)")
                }
            }
            // OR in the new value
            emitLine("orr \(unitReg.x), \(unitReg.x), \(valReg.x)")
            // Store the containing unit back
            switch bf.unitSize {
            case 1: emitLine("strb \(unitReg.w), [\(addrReg.x)]")
            case 2: emitLine("strh \(unitReg.w), [\(addrReg.x)]")
            case 4: emitLine("str \(unitReg.w), [\(addrReg.x)]")
            case 8: emitLine("str \(unitReg.x), [\(addrReg.x)]")
            default: emitLine("str \(unitReg.w), [\(addrReg.x)]")
            }
            emitLine("add sp, sp, #16")
            regAlloc.free(addrReg)
            return
        }

        // Save the value register to the stack before computing the target address,
        // because emitAddr may reuse the same register and clobber the value.
        emitLine("str \(reg.x), [sp, #-16]!")
        let addrReg = emitAddr(target)

        // Check if this is a struct assignment (needs multi-byte copy)
        let targetType = exprType(target).unqualified
        if case .structType = targetType, let size = targetType.sizeInBytes, size > 8 {
            // Struct assignment: copy size bytes from the source pointer to the target address.
            // The source pointer was saved on the stack. We must load it into a register
            // that is NOT addrReg (since addrReg holds the destination address).
            // Use x16 as scratch for the source pointer, x17 for the temp load.
            // But if addrReg is x16, swap them.
            let srcReg: ARM64Reg = (addrReg == .x16) ? .x17 : .x16
            let tmpReg: ARM64Reg = (addrReg == .x16) ? .x16 : .x17
            emitLine("ldr \(srcReg.x), [sp, #0]")
            var remaining = size
            var offset = 0
            while remaining >= 8 {
                emitLine("ldr \(tmpReg.x), [\(srcReg.x), #\(offset)]")
                emitLine("str \(tmpReg.x), [\(addrReg.x), #\(offset)]")
                offset += 8
                remaining -= 8
            }
            if remaining >= 4 {
                emitLine("ldr \(tmpReg.w), [\(srcReg.x), #\(offset)]")
                emitLine("str \(tmpReg.w), [\(addrReg.x), #\(offset)]")
                offset += 4
                remaining -= 4
            }
            if remaining >= 2 {
                emitLine("ldrh \(tmpReg.w), [\(srcReg.x), #\(offset)]")
                emitLine("strh \(tmpReg.w), [\(addrReg.x), #\(offset)]")
                offset += 2
                remaining -= 2
            }
            if remaining >= 1 {
                emitLine("ldrb \(tmpReg.w), [\(srcReg.x), #\(offset)]")
                emitLine("strb \(tmpReg.w), [\(addrReg.x), #\(offset)]")
            }
        } else {
            // Restore the value from the stack into a register that is NOT addrReg.
            // Use x16 if addrReg != x16, otherwise use x17.
            let valReg: ARM64Reg = (addrReg == .x16) ? .x17 : .x16
            emitLine("ldr \(valReg.x), [sp, #0]")
            // Use type-aware store based on target type
            emitStoreToAddr(addrReg, valReg, type: targetType)
        }
        emitLine("add sp, sp, #16")
        regAlloc.free(addrReg)
    }

    private func emitCallExpr(_ c: CallExpr) -> ARM64Reg {
        // Handle __builtin_va_start: return pointer to the pre-saved register area.
        // For variadic functions, x1-x7 are saved at function entry (before any calls).
        // The save area is at x29 + vaSaveAreaOffset.
        if case .identifier(let id) = c.function, id.name == "__builtin_va_start" {
            let reg = regAlloc.alloc() ?? .x9
            if vaSaveAreaOffset >= -256 && vaSaveAreaOffset <= 255 {
                emitLine("add \(reg.x), x29, #\(vaSaveAreaOffset)")
            } else {
                emitLoadImm("x16", Int64(vaSaveAreaOffset))
                emitLine("add \(reg.x), x29, x16")
            }
            return reg
        }

        var funcName = ""
        var isLocalFuncPtr = false
        if case .identifier(let id) = c.function {
            // Check if this is a local variable (function pointer) or a global function
            if localVarOffsets[id.name] != nil {
                isLocalFuncPtr = true
            } else if globalLabels.contains(id.name) {
                // Could be a global function pointer variable
                isLocalFuncPtr = true
            } else {
                funcName = id.name
            }
        }

        // Check if this is a variadic function (e.g., printf)
        // On Apple ARM64, named args go in registers x0..x(N-1), variadic args go on the stack.
        let variadicNamedParams: [String: Int] = [
            "printf": 1,     // printf(const char *format, ...)
            "fprintf": 2,    // fprintf(FILE *stream, const char *format, ...)
            "sprintf": 2,    // sprintf(char *buf, const char *format, ...)
            "snprintf": 3,   // snprintf(char *buf, size_t size, const char *format, ...)
            "scanf": 1,      // scanf(const char *format, ...)
            "fscanf": 2,     // fscanf(FILE *stream, const char *format, ...)
            "sscanf": 2,     // sscanf(const char *str, const char *format, ...)
            "vprintf": 1,    // vprintf(const char *format, va_list)
            "vfprintf": 2,   // vfprintf(FILE *stream, const char *format, va_list)
            "vsprintf": 2,   // vsprintf(char *buf, const char *format, va_list)
            "vsnprintf": 3,  // vsnprintf(char *buf, size_t size, const char *format, va_list)
        ]
        let namedParamCount = variadicNamedParams[funcName]

        // For variadic functions: named args in registers, variadic args on stack
        if let namedCount = namedParamCount, c.arguments.count > namedCount {
            // Evaluate named args and save on stack (they may be clobbered by
            // variadic arg evaluation, e.g. printf(fmt, func_call(...)))
            var namedArgRegs: [ARM64Reg] = []
            for i in 0..<min(namedCount, c.arguments.count) {
                let argReg = emitExpr(c.arguments[i])
                emitLine("str \(argReg.x), [sp, #-16]!")
                namedArgRegs.append(argReg)
                regAlloc.free(argReg)
            }

            // Evaluate variadic args, saving each to temp stack immediately
            var variadicArgRegs: [ARM64Reg] = []
            for i in namedCount..<c.arguments.count {
                let argReg = emitExpr(c.arguments[i])
                emitLine("str \(argReg.x), [sp, #-16]!")
                variadicArgRegs.append(argReg)
                regAlloc.free(argReg)
            }

            // Variadic args go on the stack
            let inUse = scratchRegs.filter { reg in
                !regAlloc.available.contains(reg)
            }
            let numVariadicArgs = c.arguments.count - namedCount
            let variadicSize = (numVariadicArgs * 8 + 15) & ~15
            let spillCount = inUse.count + (inUse.count % 2)
            let spillSize = spillCount * 8
            let namedTempSize = namedCount * 16
            let variadicTempSize = numVariadicArgs * 16
            let totalSize = (variadicSize + spillSize + namedTempSize + variadicTempSize + 15) & ~15

            if totalSize > 0 {
                emitLine("sub sp, sp, #\(totalSize)")
            }
            // Load variadic args from temp stack and place at the bottom (lowest address = [sp])
            // Variadic args were pushed in order: arg[namedCount] first (highest), arg[N-1] last (lowest).
            // After sub sp, the temp stack is at sp + totalSize.
            // arg[N-1] is at sp + totalSize + 0, arg[N-2] at sp + totalSize + 16, etc.
            // arg[namedCount+i] is at sp + totalSize + (numVariadicArgs - 1 - i) * 16
            for i in 0..<numVariadicArgs {
                let tempOffset = totalSize + (numVariadicArgs - 1 - i) * 16
                emitLine("ldr x9, [sp, #\(tempOffset)]")
                emitLine("str x9, [sp, #\(i * 8)]")
            }
            // Place scratch spills above the variadic args
            for (idx, reg) in inUse.enumerated() {
                emitLine("str \(reg.x), [sp, #\(variadicSize + idx * 8)]")
            }

            // Restore named args from temp stack into their target registers.
            // The named args were pushed in order, so arg[0] is at the highest
            // address (sp + totalSize + variadicTempSize + 0), arg[1] at sp + totalSize + variadicTempSize + 16, etc.
            for i in 0..<min(namedCount, c.arguments.count) {
                let tempOffset = totalSize + variadicTempSize + (namedCount - 1 - i) * 16
                emitLine("ldr \(argRegs[i].x), [sp, #\(tempOffset)]")
            }

            // Make the call
            if !funcName.isEmpty {
                emitLine("bl _\(funcName)")
            }

            // Restore spilled registers
            for (idx, reg) in inUse.enumerated() {
                emitLine("ldr \(reg.x), [sp, #\(variadicSize + idx * 8)]")
            }
            if totalSize > 0 {
                emitLine("add sp, sp, #\(totalSize)")
            }
            // Free the temp stack for named args
            for _ in 0..<min(namedCount, c.arguments.count) {
                emitLine("add sp, sp, #16")
            }
        } else {
            // Non-variadic (or internal variadic): evaluate args and place in x0-x7
            // For internal variadic functions, push variadic args on the stack so
            // __builtin_va_start can point to them (handles both int and FP args).
            let isInternalVariadic = variadicFunctions.contains(funcName) && definedFunctions.contains(funcName)
            let namedParamCount = isInternalVariadic ? (functionParamCounts[funcName] ?? 0) : 0

            // For indirect calls (function pointer), evaluate the function expression first
            // and save it in a register that won't be clobbered by arg evaluation.
            var funcPtrReg: ARM64Reg? = nil
            if funcName.isEmpty {
                // Indirect call — evaluate the function expression to get a function pointer
                // Use a register outside the arg registers (x0-x7) to avoid clobbering
                // We'll use x16 (IP0) which is safe for inter-procedural calls
                let fpReg = emitExpr(c.function)
                // Move to x16 which is safe as a temporary call target
                emitLine("mov x16, \(fpReg.x)")
                regAlloc.free(fpReg)
                // Save x16 on stack before arg evaluation (args may clobber x16)
                emitLine("str x16, [sp, #-16]!")
                funcPtrReg = .x16
            }

            // Evaluate all args first, saving results on the stack to avoid clobbering
            // by nested function calls within argument expressions.
            // For struct-by-value args (9-16 bytes), evaluate to address then load 2 chunks.
            var evaluatedArgs: [ARM64Reg] = []
            var wideArgs: Set<Int> = []  // indices of args that use 2 register slots
            for (i, arg) in c.arguments.enumerated() {
                let argType = exprType(arg).unqualified
                let argSize = argType.sizeInBytes ?? 8
                if case .structType = argType, argSize > 8, argSize <= 16 {
                    // Struct by value (9-16 bytes): load two 8-byte chunks
                    let addrReg = emitAddr(arg)
                    // Push 2 slots (32 bytes) for the two chunks
                    emitLine("str \(addrReg.x), [sp, #-16]!")  // placeholder for chunk 0
                    emitLine("str \(addrReg.x), [sp, #-16]!")  // placeholder for chunk 1
                    // Load chunk 0 (first 8 bytes) and chunk 1 (second 8 bytes).
                    // Use x16 as scratch to avoid clobbering addrReg.
                    emitLine("ldr x16, [\(addrReg.x)]")
                    emitLine("str x16, [sp, #16]")  // chunk 0
                    emitLine("ldr x16, [\(addrReg.x), #8]")
                    emitLine("str x16, [sp, #0]")   // chunk 1
                    evaluatedArgs.append(addrReg)
                    wideArgs.insert(i)
                    regAlloc.free(addrReg)
                } else {
                    let argReg = emitExpr(arg)
                    // Save the result on the stack to preserve it across subsequent arg evaluation
                    emitLine("str \(argReg.x), [sp, #-16]!")
                    evaluatedArgs.append(argReg)
                    regAlloc.free(argReg)
                }
            }

            // For internal variadic functions: variadic args need to be on the stack
            // at sp when bl is executed (so callee's va_start at x29+16 can read them).

            // Count stack-passed args (register index >= 8, wide args use 2 slots)
            var totalRegSlots = 0
            for i in 0..<evaluatedArgs.count {
                totalRegSlots += wideArgs.contains(i) ? 2 : 1
            }
            // For internal variadic: all variadic args go on the stack (not just overflow)
            let numStackArgs: Int
            if isInternalVariadic && evaluatedArgs.count > namedParamCount {
                numStackArgs = evaluatedArgs.count - namedParamCount
            } else {
                numStackArgs = max(totalRegSlots - 8, 0)
            }
            var stackArgSize = 0
            if numStackArgs > 0 {
                stackArgSize = (numStackArgs * 8 + 15) & ~15
            }

            // Now restore ALL args from temp stack and move to target registers
            var namedCount = min(evaluatedArgs.count, 8)
            if isInternalVariadic {
                namedCount = min(namedParamCount, evaluatedArgs.count)
            }

            // Save scratch registers and allocate stack arg space.
            // Layout at call time (low to high address):
            //   sp+0: stack-passed args (callee reads these via [x29, #16])
            //   sp+stackArgSize: scratch saves
            //   sp+stackArgSize+scratchSize: temp stack (already allocated, will be freed after call)
            //   sp+stackArgSize+scratchSize+tempStackSize: saved func ptr (if indirect)
            let inUse = scratchRegs.filter { reg in
                !regAlloc.available.contains(reg)
            }
            let paddedCount = inUse.count + (inUse.count % 2)
            let scratchSaveSize = paddedCount * 8

            // Allocate stack arg space first (lowest address)
            if stackArgSize > 0 {
                emitLine("sub sp, sp, #\(stackArgSize)")
            }
            // Allocate scratch saves above stack args
            if scratchSaveSize > 0 {
                emitLine("sub sp, sp, #\(scratchSaveSize)")
                for (idx, reg) in inUse.enumerated() {
                    emitLine("str \(reg.x), [sp, #\(idx * 8)]")
                }
            }

            // Pop all evaluated args (reverse order) from the temp stack.
            // The temp stack is above the scratch/stack-arg areas.
            // Each normal arg was pushed with str [sp, #-16]!, so each slot is 16 bytes.
            // Wide args (struct by value, 9-16 bytes) pushed 2 slots (32 bytes).
            // arg[0] was pushed first (highest address), arg[N-1] last (lowest).
            let tempBase = scratchSaveSize + stackArgSize
            let numArgs = evaluatedArgs.count

            // Compute temp stack slot offsets for each arg.
            // Slots are laid out from bottom (last arg) to top (first arg).
            var argSlotOffsets: [Int] = []  // offset from tempBase for each arg's lowest slot
            var cumulative = 0
            for i in (0..<numArgs).reversed() {
                let slotSize = wideArgs.contains(i) ? 32 : 16
                argSlotOffsets.insert(cumulative, at: 0)
                cumulative += slotSize
            }

            // Track current register index (wide args consume 2 registers)
            // Iterate forward (i=0 to N-1): arg[0] goes to x0, arg[1] to x1, etc.
            // arg[0] is at the highest temp offset (pushed first), arg[N-1] at lowest.
            var regIdx = 0
            for i in 0..<numArgs {
                let tempOffset = tempBase + argSlotOffsets[i]
                let isWide = wideArgs.contains(i)
                let regsNeeded = isWide ? 2 : 1

                // For internal variadic: named params go in registers, variadic args go on stack
                let isVariadicArg = isInternalVariadic && i >= namedParamCount
                if isVariadicArg {
                    let stackOffset = (i - namedParamCount) * 8
                    if isWide {
                        emitLine("ldr x9, [sp, #\(tempOffset)]")
                        emitLine("str x9, [sp, #\(stackOffset)]")
                        emitLine("ldr x9, [sp, #\(tempOffset + 16)]")
                        emitLine("str x9, [sp, #\(stackOffset + 8)]")
                    } else {
                        emitLine("ldr x9, [sp, #\(tempOffset)]")
                        emitLine("str x9, [sp, #\(stackOffset)]")
                    }
                    regAlloc.free(evaluatedArgs[i])
                    regIdx += regsNeeded
                    continue
                }

                if regIdx < 8 {
                    if isWide {
                        // chunk 1 (second 8 bytes) at tempOffset, chunk 0 at tempOffset+16
                        if regIdx + 1 < 8 {
                            emitLine("ldr \(argRegs[regIdx + 1].x), [sp, #\(tempOffset)]")
                            emitLine("ldr \(argRegs[regIdx].x), [sp, #\(tempOffset + 16)]")
                        } else {
                            // Second chunk goes on stack
                            emitLine("ldr x9, [sp, #\(tempOffset)]")
                            emitLine("str x9, [sp, #0]")
                            emitLine("ldr \(argRegs[regIdx].x), [sp, #\(tempOffset + 16)]")
                        }
                    } else {
                        emitLine("ldr x9, [sp, #\(tempOffset)]")
                        emitLine("mov \(argRegs[regIdx].x), x9")
                    }
                    regAlloc.free(evaluatedArgs[i])
                } else {
                    // Stack-passed args
                    let stackOffset = (regIdx - 8) * 8
                    if isWide {
                        emitLine("ldr x9, [sp, #\(tempOffset)]")
                        emitLine("str x9, [sp, #\(stackOffset)]")
                        emitLine("ldr x9, [sp, #\(tempOffset + 16)]")
                        emitLine("str x9, [sp, #\(stackOffset + 8)]")
                    } else {
                        emitLine("ldr x9, [sp, #\(tempOffset)]")
                        emitLine("str x9, [sp, #\(stackOffset)]")
                    }
                    regAlloc.free(evaluatedArgs[i])
                }
                regIdx += regsNeeded
            }
            // Re-allocate the target registers
            let totalRegArgs = isInternalVariadic ? min(namedParamCount, 8) : min(regIdx, 8)
            for _ in 0..<totalRegArgs {
                _ = regAlloc.alloc() // consume the register slot
            }

            // Variadic args already placed on stack by the loop above.
            var variadicStackArgSize = 0

            // Make the call
            let tempStackSize = cumulative  // total bytes pushed to temp stack
            if let fpReg = funcPtrReg {
                let fpOffset = variadicStackArgSize + stackArgSize + scratchSaveSize + tempStackSize
                emitLine("ldr \(fpReg.x), [sp, #\(fpOffset)]")
                emitLine("blr \(fpReg.x)")
            } else if !funcName.isEmpty {
                emitLine("bl _\(funcName)")
            }

            // Clean up variadic stack args (for internal variadic calls)
            if variadicStackArgSize > 0 {
                emitLine("add sp, sp, #\(variadicStackArgSize)")
            }
            // Clean up stack-passed arguments
            if stackArgSize > 0 {
                emitLine("add sp, sp, #\(stackArgSize)")
            }
            // Restore spilled scratch registers
            if scratchSaveSize > 0 {
                for (idx, reg) in inUse.enumerated() {
                    emitLine("ldr \(reg.x), [sp, #\(idx * 8)]")
                }
                emitLine("add sp, sp, #\(scratchSaveSize)")
            }
            // Deallocate temp stack (all args were read from it before the call)
            if tempStackSize > 0 {
                emitLine("add sp, sp, #\(tempStackSize)")
            }
            // Pop the saved function pointer
            if funcPtrReg != nil {
                emitLine("add sp, sp, #16")
            }
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
            // Apply usual arithmetic conversions to determine result type.
            // If either operand is long/longLong, result is at least that wide.
            let lu = lt.unqualified
            let ru = rt.unqualified
            if lu.isArithmetic && ru.isArithmetic {
                // Rank: longLong > long > int > short > char
                func rank(_ t: CType) -> Int {
                    switch t {
                    case .longLong, .ulongLong: return 4
                    case .long, .ulong: return 3
                    case .int, .uint: return 2
                    case .short, .ushort: return 1
                    default: return 0
                    }
                }
                if rank(lu) >= 4 || rank(ru) >= 4 { return rank(lu) >= rank(ru) ? lu : ru }
                if rank(lu) >= 3 || rank(ru) >= 3 { return rank(lu) >= rank(ru) ? lu : ru }
            }
            return lu.isArithmetic ? lt : rt
        case .unary(let u):
            switch u.op {
            case .dereference:
                let t = exprType(u.operand)
                if case .pointer(let to) = t.unqualified { return to }
                if case .array(let elem, _) = t.unqualified { return elem }
                return .int
            case .addressOf:
                return .pointer(to: exprType(u.operand))
            case .not:
                return .int  // logical NOT always returns int per C standard
            case .neg, .pos, .bitNot:
                // Integer promotion: char/short → int
                let t = exprType(u.operand).unqualified
                if t == .char || t == .schar || t == .uchar || t == .short || t == .ushort {
                    return .int
                }
                return t
            default:
                return exprType(u.operand)
            }
        case .assign(let a):
            return exprType(a.target)
        case .call(let c):
            // Look up function return type
            if case .identifier(let id) = c.function {
                if let t = functionReturnTypes[id.name] {
                    return t
                }
                // Check if it's a global variable with function type (function pointer)
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
            // Look up completed record if incomplete
            if case .structType(let rec) = recordType.unqualified, rec.fields.isEmpty {
                if let completed = knownRecords[rec.name] {
                    recordType = .structType(completed)
                }
            }
            if case .unionType(let rec) = recordType.unqualified, rec.fields.isEmpty {
                if let completed = knownRecords[rec.name] {
                    recordType = .unionType(completed)
                }
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

    /// Look up bitfield info for a struct member.
    /// Returns (bitWidth, bitOffsetWithinUnit, unitSizeInBytes) or nil if not a bitfield.
    /// bitOffsetWithinUnit is the bit position of the field within its containing unit.
    private func bitfieldInfo(_ baseType: CType, _ memberName: String) -> (bitWidth: Int, bitOffset: Int, unitSize: Int)? {
        var t = baseType.unqualified
        if case .pointer(let to) = t { t = to.unqualified }
        if case .structType(let rec) = t {
            if rec.fields.isEmpty, let completed = knownRecords[rec.name] {
                t = .structType(completed)
            }
        }
        if case .structType(let rec) = t {
            for field in rec.fields where field.name == memberName {
                guard let bw = field.bitWidth else { return nil }
                // Determine the containing unit size from the field type
                let unitSize = field.type.unqualified.sizeInBytes ?? 4
                // Use the bitOffset stored in the field (bit position within containing unit)
                return (bw, field.bitOffset, unitSize)
            }
        }
        return nil
    }

    /// Emit the address of an lvalue expression (without loading its value).
    /// Returns the register holding the address.
    private func emitAddr(_ expr: Expr) -> ARM64Reg {
        switch expr {
        case .identifier(let id):
            let reg = regAlloc.alloc() ?? .x9
            if let offset = localVarOffsets[id.name] {
                if offset >= -4095 && offset <= 4095 {
                    emitLine("add \(reg.x), x29, #\(offset)")
                } else {
                    // Use x17 as scratch for large offsets (x16 is used for blr)
                    emitLoadImm("x17", Int64(offset))
                    emitLine("add \(reg.x), x29, x17")
                }
            } else if let globalName = staticLocalGlobals[id.name] {
                // Static local variable — use its mangled global name
                emitLine("adrp \(reg.x), \(globalName)@PAGE")
                emitLine("add \(reg.x), \(reg.x), \(globalName)@PAGEOFF")
            } else if globalLabels.contains(id.name) {
                if externGlobals.contains(id.name) {
                    // External global — load address through GOT
                    emitLine("adrp \(reg.x), _\(id.name)@GOTPAGE")
                    emitLine("ldr \(reg.x), [\(reg.x), _\(id.name)@GOTPAGEOFF]")
                } else {
                    emitLine("adrp \(reg.x), _\(id.name)@PAGE")
                    emitLine("add \(reg.x), \(reg.x), _\(id.name)@PAGEOFF")
                }
            }
            return reg

        case .subscript_(let s):
            // For arrays: use emitAddr (get array base address, don't load value)
            // For pointers: use emitExpr (load pointer value)
            let baseTypeFull = exprType(s.base).unqualified
            let baseReg: ARM64Reg
            if baseTypeFull.isArray {
                // Array subscript: get address of the array, don't load its value
                baseReg = emitAddr(s.base)
            } else {
                // Pointer subscript: load the pointer value
                baseReg = emitExpr(s.base)
            }
            let indexReg = emitExpr(s.index)
            // Sign-extend the index if it's a 32-bit signed type (e.g., negative array indices)
            let indexType = exprType(s.index).unqualified
            if indexType.isSigned32Bit {
                emitLine("sxtw \(indexReg.x), \(indexReg.w)")
            }
            // Determine the element type (what the base points to or contains)
            let elemType: CType
            if case .array(let e, _) = baseTypeFull { elemType = e }
            else if case .incompleteArray(let e) = baseTypeFull { elemType = e }
            else if case .pointer(let e) = baseTypeFull { elemType = e }
            else { elemType = .int }
            let elemSize = elemType.unqualified.isPointer ? 8 : (elemType.sizeInBytes ?? 4)
            // addr = base + index * elemSize
            if elemSize == 1 {
                emitLine("add \(baseReg.x), \(baseReg.x), \(indexReg.x)")
            } else if elemSize == 2 {
                emitLine("add \(baseReg.x), \(baseReg.x), \(indexReg.x), lsl #1")
            } else if elemSize == 4 {
                emitLine("add \(baseReg.x), \(baseReg.x), \(indexReg.x), lsl #2")
            } else if elemSize == 8 {
                emitLine("add \(baseReg.x), \(baseReg.x), \(indexReg.x), lsl #3")
            } else {
                // Use mul for non-power-of-2 or large element sizes
                emitLine("mov x16, #\(elemSize)")
                emitLine("madd \(baseReg.x), \(indexReg.x), x16, \(baseReg.x)")
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
            // Address of *p is just p (for pointers) or the array base (for arrays)
            let operandType = exprType(u.operand).unqualified
            if operandType.isArray {
                return emitAddr(u.operand)
            }
            return emitExpr(u.operand)

        default:
            // Not an lvalue — just evaluate
            return emitExpr(expr)
        }
    }

    private func emitSubscriptExpr(_ s: SubscriptExpr) -> ARM64Reg {
        let addrReg = emitAddr(.subscript_(s))
        // Determine element type and load with correct size
        let bt = exprType(s.base).unqualified
        let elemType: CType
        if case .array(let e, _) = bt { elemType = e }
        else if case .incompleteArray(let e) = bt { elemType = e }
        else if case .pointer(let e) = bt { elemType = e }
        else { elemType = .int }
        // If element type is an array, return address (array decays to pointer)
        if case .array = elemType.unqualified {
            return addrReg
        }
        emitLoad(addrReg, type: elemType)
        return addrReg
    }

    private func emitMemberExpr(_ m: MemberExpr) -> ARM64Reg {
        // Check if this is a bitfield member
        if let bf = bitfieldInfo(exprType(m.base), m.memberName) {
            // Bitfield read: load containing unit, shift right, mask
            let addrReg = emitAddr(.member(m))
            // Load the containing unit
            switch bf.unitSize {
            case 1:
                emitLine("ldrb \(addrReg.w), [\(addrReg.x)]")
            case 2:
                emitLine("ldrh \(addrReg.w), [\(addrReg.x)]")
            case 4:
                emitLine("ldr \(addrReg.w), [\(addrReg.x)]")
            case 8:
                emitLine("ldr \(addrReg.x), [\(addrReg.x)]")
            default:
                emitLine("ldr \(addrReg.w), [\(addrReg.x)]")
            }
            // Shift right to align the bitfield to bit 0
            if bf.bitOffset > 0 {
                emitLine("lsr \(addrReg.x), \(addrReg.x), #\(bf.bitOffset)")
            }
            // Mask to bitWidth bits
            if bf.bitWidth < 64 {
                let mask = (1 << bf.bitWidth) - 1
                if mask <= 255 {
                    emitLine("and \(addrReg.x), \(addrReg.x), #\(mask)")
                } else if mask <= 65535 {
                    emitLine("mov x16, #\(mask)")
                    emitLine("and \(addrReg.x), \(addrReg.x), x16")
                } else {
                    emitLine("mov x16, #\(mask & 0xffff)")
                    if mask > 0xffff {
                        emitLine("movk x16, #\((mask >> 16) & 0xffff), lsl #16")
                    }
                    if mask > 0xffffff {
                        emitLine("movk x16, #\((mask >> 32) & 0xffff), lsl #32")
                    }
                    emitLine("and \(addrReg.x), \(addrReg.x), x16")
                }
            }
            return addrReg
        }
        let addrReg = emitAddr(.member(m))
        // If the member type is an array, the value IS the address (array decays to pointer)
        let mt = exprType(.member(m))
        if case .array = mt.unqualified {
            return addrReg
        }
        // Load the value with the correct size based on member type
        emitLoad(addrReg, type: mt)
        return addrReg
    }

    /// Load a value from the address in reg, using the correct load instruction for the type.
    private func emitLoad(_ reg: ARM64Reg, type: CType) {
        let t = type.unqualified
        switch t {
        case .bool, .char, .schar, .uchar:
            emitLine("ldrb \(reg.w), [\(reg.x)]")
            if t == .schar || t == .char {
                emitLine("sxtb \(reg.w), \(reg.w)")
            }
        case .short, .ushort:
            emitLine("ldrh \(reg.w), [\(reg.x)]")
            if t == .short {
                emitLine("sxth \(reg.w), \(reg.w)")
            }
        case .int, .uint:
            emitLine("ldr \(reg.w), [\(reg.x)]")
        case .float:
            emitLine("ldr s\(reg.regNum), [\(reg.x)]")
        case .double, .longDouble:
            emitLine("ldr d\(reg.regNum), [\(reg.x)]")
        default:
            // 8-byte load (pointer, long, etc.)
            emitLine("ldr \(reg.x), [\(reg.x)]")
        }
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
            let t = type.unqualified
            switch t {
            case .bool, .char, .schar, .uchar:
                emitStoreByteFP(reg.w, offset)
            case .short, .ushort:
                emitStoreHalfFP(reg.w, offset)
            case .int, .uint:
                emitStoreWordFP(reg.w, offset)
            default:
                emitStoreFP(reg.x, offset)
            }
        }
    }

    private func emitStoreByteFP(_ reg: String, _ offset: Int) {
        if offset >= -256 && offset <= 255 {
            emitLine("strb \(reg), [x29, #\(offset)]")
        } else {
            emitLoadImm("x16", Int64(offset))
            emitLine("strb \(reg), [x29, x16]")
        }
    }

    private func emitStoreHalfFP(_ reg: String, _ offset: Int) {
        if offset >= -256 && offset <= 255 {
            emitLine("strh \(reg), [x29, #\(offset)]")
        } else {
            emitLoadImm("x16", Int64(offset))
            emitLine("strh \(reg), [x29, x16]")
        }
    }

    private func emitStoreWordFP(_ reg: String, _ offset: Int) {
        if offset >= -256 && offset <= 255 {
            emitLine("str \(reg), [x29, #\(offset)]")
        } else {
            emitLoadImm("x16", Int64(offset))
            emitLine("str \(reg), [x29, x16]")
        }
    }

    // MARK: - Utility

    private func emitLine(_ s: String) {
        output += s + "\n"
    }

    /// Emit a store to [x29, #offset] handling large offsets (>255 or < -256)
    private func emitStoreFP(_ reg: String, _ offset: Int) {
        if offset >= -256 && offset <= 255 {
            emitLine("str \(reg), [x29, #\(offset)]")
        } else {
            // Use x16 as scratch for the offset
            emitLoadImm("x16", Int64(offset))
            emitLine("str \(reg), [x29, x16]")
        }
    }

    /// Emit a load from [x29, #offset] handling large offsets
    private func emitLoadFP(_ reg: String, _ offset: Int) {
        if offset >= -256 && offset <= 255 {
            emitLine("ldr \(reg), [x29, #\(offset)]")
        } else {
            emitLoadImm("x16", Int64(offset))
            emitLine("ldr \(reg), [x29, x16]")
        }
    }

    /// Emit a local aggregate initializer: write init list values to stack memory at addrReg.
    private func emitLocalInit(_ addrReg: ARM64Reg, _ expr: Expr, type: CType) {
        guard case .initList(let il) = expr else { return }
        let t = type.unqualified
        // Save base address to stack to avoid clobbering by emitExpr
        emitLine("sub sp, sp, #16")
        emitLine("str \(addrReg.x), [sp, #0]")
        if case .structType(let rec) = t {
            let fields = rec.fields
            for (i, v) in il.values.enumerated() {
                if i < fields.count {
                    let fieldOffset = fields[i].offset
                    let fieldAddr = regAlloc.alloc() ?? .x9
                    emitLine("ldr \(fieldAddr.x), [sp, #0]")
                    if fieldOffset != 0 {
                        emitLine("add \(fieldAddr.x), \(fieldAddr.x), #\(fieldOffset)")
                    }
                    if case .initList = v {
                        // Nested aggregate init
                        emitLocalInit(fieldAddr, v, type: fields[i].type)
                    } else {
                        let valReg = emitExpr(v)
                        emitStoreToAddr(fieldAddr, valReg, type: fields[i].type)
                    }
                    regAlloc.free(fieldAddr)
                }
            }
        } else if case .array(let elemType, _) = t {
            let elemSize = elemType.sizeInBytes ?? 8
            for (i, v) in il.values.enumerated() {
                let elemAddr = regAlloc.alloc() ?? .x9
                emitLine("ldr \(elemAddr.x), [sp, #0]")
                if i > 0 {
                    emitLine("add \(elemAddr.x), \(elemAddr.x), #\(i * elemSize)")
                }
                if case .initList = v {
                    emitLocalInit(elemAddr, v, type: elemType)
                } else {
                    let valReg = emitExpr(v)
                    emitStoreToAddr(elemAddr, valReg, type: elemType)
                }
                regAlloc.free(elemAddr)
            }
        }
        // Restore base address and stack
        emitLine("ldr \(addrReg.x), [sp, #0]")
        emitLine("add sp, sp, #16")
    }

    /// Store a register value to an address, using the correct store instruction for the type.
    private func emitStoreToAddr(_ addrReg: ARM64Reg, _ valReg: ARM64Reg, type: CType) {
        let t = type.unqualified
        switch t {
        case .bool, .char, .schar, .uchar:
            emitLine("strb \(valReg.w), [\(addrReg.x)]")
        case .short, .ushort:
            emitLine("strh \(valReg.w), [\(addrReg.x)]")
        case .int, .uint:
            emitLine("str \(valReg.w), [\(addrReg.x)]")
        case .float:
            emitLine("str s\(valReg.regNum), [\(addrReg.x)]")
        case .double, .longDouble:
            emitLine("str d\(valReg.regNum), [\(addrReg.x)]")
        default:
            emitLine("str \(valReg.x), [\(addrReg.x)]")
        }
    }

    /// Emit instructions to load a 64-bit immediate value into a register.
    /// ARM64 mov can only handle 16-bit immediates; larger values need movz/movk.
    private func emitLoadImm(_ reg: String, _ value: Int64) {
        let v = UInt64(bitPattern: value)
        if v <= 0xFFFF {
            emitLine("mov \(reg), #\(value)")
        } else if v == 0 {
            emitLine("mov \(reg), #0")
        } else {
            // Use movz for the low 16 bits, then movk for higher 16-bit chunks
            let w0 = UInt16(truncatingIfNeeded: v)
            let w1 = UInt16(truncatingIfNeeded: v >> 16)
            let w2 = UInt16(truncatingIfNeeded: v >> 32)
            let w3 = UInt16(truncatingIfNeeded: v >> 48)
            emitLine("movz \(reg), #\(w0)")
            if w1 != 0 { emitLine("movk \(reg), #\(w1), lsl #16") }
            if w2 != 0 { emitLine("movk \(reg), #\(w2), lsl #32") }
            if w3 != 0 { emitLine("movk \(reg), #\(w3), lsl #48") }
        }
    }

    private func newLabel() -> String {
        labelCounter += 1
        return "L_\(currentFuncName)_\(labelCounter)"
    }
}
