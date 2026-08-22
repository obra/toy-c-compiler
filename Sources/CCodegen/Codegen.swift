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
    private var vlaBasePointers: Set<String> = []  // local vars that are VLA base pointers
    private var vlaInnerDims: [String: [String]] = [:]  // VLA name → inner dimension local var names (excludes outer)
    private var vlaAllDims: [String: [String]] = [:]   // VLA name → ALL dimension local var names (outer first, for sizeof)
    private var globalVarTypes: [String: CType] = [:]
    private var knownRecords: [String: RecordType] = [:]
    private var functionNames: Set<String> = []   // names of all declared functions
    private var definedFunctions: Set<String> = []  // functions with bodies (locally defined)
    private var functionReturnTypes: [String: CType] = [:]  // function name → return type
    private var variadicFunctions: Set<String> = []  // functions with variadic params (...)
    private var functionParamCounts: [String: Int] = [:]  // function name → number of named params
    private var functionParamTypes: [String: [CType]] = [:]  // function name → param types
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
                var varType = vd.type
                // If it's an incomplete array with an initializer, compute the element count
                if case .incompleteArray(let elemType) = varType.unqualified, let init_ = vd.initializer {
                    if case .initList(let il) = init_ {
                        if case .structType(let rec) = elemType.unqualified {
                            // Array of structs: count = total values / values per struct
                            let fieldsPerStruct = countScalarFields(rec)
                            let count = (il.values.count + fieldsPerStruct - 1) / max(fieldsPerStruct, 1)
                            varType = .array(of: elemType, count: count)
                        } else {
                            // Array of scalars: count = number of values
                            varType = .array(of: elemType, count: il.values.count)
                        }
                    }
                }
                globalVarTypes[vd.name] = varType
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
                functionParamTypes[fd.name] = fd.params.map { $0.type }
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
                case .structType(let rec), .unionType(let rec):
                    // Emit based on struct/union size
                    let s = rec.size ?? size
                    switch s {
                    case 1: emitLine(".byte \(l.value & 0xFF)")
                    case 2: emitLine(".short \(l.value & 0xFFFF)")
                    case 3, 4: emitLine(".long \(l.value & 0xFFFFFFFF)")
                    default: emitLine(".quad \(l.value)")
                    }
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
                    // Build designator map for designated initializers
                    // (multiple designators can target the same struct field, e.g. .inner.x and .inner.y)
                    var designatedFields: [String: [Int]] = [:]
                    for (vi, desig) in il.designators.enumerated() {
                        if let names = desig, let firstName = names.first {
                            designatedFields[firstName, default: []].append(vi)
                        }
                    }
                    let hasDesignators = !designatedFields.isEmpty
                    for field in fields {
                        let fieldOffset = field.offset
                        let fieldName = field.name ?? ""
                        // Handle designated initializers
                        if hasDesignators {
                            var designatedIndices: [Int] = []
                            if !fieldName.isEmpty, let indices = designatedFields[fieldName] {
                                designatedIndices = indices
                            } else if fieldName.isEmpty {
                                for (vi, desig) in il.designators.enumerated() {
                                    if let names = desig, let firstName = names.first {
                                        if fieldHasMember(field.type, firstName) {
                                            designatedIndices.append(vi)
                                        }
                                    }
                                }
                            }
                            if !designatedIndices.isEmpty {
                                for idx in designatedIndices {
                                // Emit padding before this field
                                if fieldOffset > currentOffset {
                                    emitLine(".zero \(fieldOffset - currentOffset)")
                                }
                                let v = il.values[idx]
                                let fieldType = field.type.unqualified
                                let nestedNames: [String] = {
                                    if let names = il.designators[idx] {
                                        return Array(names.dropFirst())
                                    }
                                    return []
                                }()
                                if !nestedNames.isEmpty {
                                    // Nested designator: compute offset and emit scalar
                                    var nestedType = field.type
                                    var nestedOffset = 0
                                    for name in nestedNames {
                                        if case .structType(let r) = nestedType.unqualified {
                                            for nf in r.fields {
                                                if (nf.name ?? "") == name || ((nf.name ?? "").isEmpty && fieldHasMember(nf.type, name)) {
                                                    nestedOffset += nf.offset
                                                    nestedType = nf.type
                                                    break
                                                }
                                            }
                                        } else if case .unionType(let r) = nestedType.unqualified {
                                            for nf in r.fields {
                                                if (nf.name ?? "") == name || ((nf.name ?? "").isEmpty && fieldHasMember(nf.type, name)) {
                                                    nestedOffset += nf.offset
                                                    nestedType = nf.type
                                                    break
                                                }
                                            }
                                        }
                                    }
                                    // Emit padding for nested offset
                                    if nestedOffset > 0 {
                                        emitLine(".zero \(nestedOffset)")
                                    }
                                    emitInitializer(v, size: nestedType.sizeInBytes ?? 8, type: nestedType)
                                    let fieldTotalSize = field.type.sizeInBytes ?? 0
                                    let emitted = nestedOffset + (nestedType.sizeInBytes ?? 0)
                                    if fieldTotalSize > emitted {
                                        emitLine(".zero \(fieldTotalSize - emitted)")
                                    }
                                } else if case .initList = v {
                                    emitInitializer(v, size: field.type.sizeInBytes ?? 8, type: field.type)
                                } else if case .compoundLiteral(let cl) = v {
                                    emitInitializer(cl.initList, size: field.type.sizeInBytes ?? 8, type: field.type)
                                } else {
                                    emitInitializer(v, size: field.type.sizeInBytes ?? 8, type: field.type)
                                }
                                currentOffset = fieldOffset + (field.type.sizeInBytes ?? 0)
                                } // end for idx in designatedIndices
                                continue
                            }
                            // No designator for this field — emit zeros
                            if fieldOffset > currentOffset {
                                emitLine(".zero \(fieldOffset - currentOffset)")
                            }
                            let fieldSize = field.type.sizeInBytes ?? 0
                            if fieldSize > 0 {
                                emitLine(".zero \(fieldSize)")
                            }
                            currentOffset = fieldOffset + fieldSize
                            continue
                        }
                        // Emit padding before this field if needed
                        if fieldOffset > currentOffset {
                            emitLine(".zero \(fieldOffset - currentOffset)")
                        }
                        let fieldType = field.type.unqualified
                        let fieldSize = field.type.sizeInBytes ?? 0
                        if fieldSize == 0 {
                            // Empty struct field: consume the value but emit nothing
                            if valueIdx < il.values.count {
                                valueIdx += 1
                            }
                            currentOffset = fieldOffset
                            continue
                        }
                        if case .array(let elemType, let count) = fieldType {
                            // Check if the current value is a string literal for a char array
                            if valueIdx < il.values.count, elemType.isChar,
                               case .stringLiteral(let sl) = il.values[valueIdx] {
                                // Emit string literal inline for char array
                                valueIdx += 1
                                let bytes = sl.value
                                if bytes.count <= count {
                                    emitLine(".asciz \"\(escapeStringLiteral(bytes))\"")
                                    let emitted = bytes.count + 1
                                    if count > emitted {
                                        emitLine(".zero \(count - emitted)")
                                    }
                                } else {
                                    emitLine(".ascii \"\(escapeStringLiteral(String(bytes.prefix(count))))\"")
                                }
                            } else if valueIdx < il.values.count, case .initList(let subIl) = il.values[valueIdx] {
                                // Nested init list for array field
                                valueIdx += 1
                                var emitted = 0
                                for subV in subIl.values {
                                    emitInitializer(subV, size: elemType.sizeInBytes ?? 8, type: elemType)
                                    emitted += 1
                                }
                                if emitted < count {
                                    emitLine(".zero \((count - emitted) * (elemType.sizeInBytes ?? 8))")
                                }
                            } else {
                                // Array field: consume values for array elements
                                for _ in 0..<count {
                                    if valueIdx < il.values.count {
                                        emitInitializer(il.values[valueIdx], size: elemType.sizeInBytes ?? 8, type: elemType)
                                        valueIdx += 1
                                    } else {
                                        emitLine(".zero \(elemType.sizeInBytes ?? 8)")
                                    }
                                }
                            }
                            currentOffset = fieldOffset + (field.type.sizeInBytes ?? count * (elemType.sizeInBytes ?? 8))
                        } else {
                            // Scalar, struct, or other non-array field: consume one value
                            if valueIdx < il.values.count {
                                let v = il.values[valueIdx]
                                if case .initList = v {
                                    // Nested init list for this field — recurse
                                    valueIdx += 1
                                    emitInitializer(v, size: field.type.sizeInBytes ?? 8, type: field.type)
                                } else if case .compoundLiteral = v {
                                    // Compound literal — emit its init list
                                    valueIdx += 1
                                    if case .compoundLiteral(let cl) = v {
                                        emitInitializer(cl.initList, size: field.type.sizeInBytes ?? 8, type: field.type)
                                    }
                                } else if case .structType(let subRec) = fieldType {
                                    // Flat init for a struct field: consume values for sub-fields
                                    emitFlatStructInit(il.values, idx: &valueIdx, rec: subRec)
                                } else if case .stringLiteral = v, field.type.sizeInBytes ?? 0 > 0 {
                                    // String literal for a field (e.g., char array or char field)
                                    valueIdx += 1
                                    emitInitializer(v, size: field.type.sizeInBytes ?? 8, type: field.type)
                                } else {
                                    valueIdx += 1
                                    emitInitializer(v, size: field.type.sizeInBytes ?? 8, type: field.type)
                                }
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
                } else if case .unionType(let rec) = t {
                    // Union initializer: initialize the first field (or first named field)
                    // Check for field designators (e.g., .b = 8, .a = 7 for anonymous struct member)
                    var hasFieldDesignators = false
                    for desig in il.designators {
                        if desig != nil { hasFieldDesignators = true; break }
                    }
                    if hasFieldDesignators, let firstField = rec.fields.first {
                        // Designated init for a union: designators refer to the first
                        // (anonymous) struct member's fields. Create a synthetic initList
                        // with the designators and recurse into the struct type.
                        let syntheticIl = Expr.initList(InitListExpr(values: il.values, designators: il.designators, loc: il.loc))
                        emitInitializer(syntheticIl, size: firstField.type.sizeInBytes ?? rec.size ?? 8, type: firstField.type)
                    } else if let firstField = rec.fields.first {
                        if il.values.count > 0 {
                            let v = il.values[0]
                            if case .initList = v {
                                // Nested init list for the first field
                                emitInitializer(v, size: firstField.type.sizeInBytes ?? rec.size ?? 8, type: firstField.type)
                            } else if case .compoundLiteral(let cl) = v {
                                emitInitializer(cl.initList, size: firstField.type.sizeInBytes ?? rec.size ?? 8, type: firstField.type)
                            } else if case .array = firstField.type.unqualified {
                                // First field is an array: treat the entire initList as
                                // the array initializer (not just values[0])
                                emitInitializer(expr, size: firstField.type.sizeInBytes ?? rec.size ?? 8, type: firstField.type)
                            } else {
                                // Scalar value for the first field
                                emitInitializer(v, size: firstField.type.sizeInBytes ?? rec.size ?? 8, type: firstField.type)
                            }
                        }
                        // Pad to union size
                        let emitted = firstField.type.sizeInBytes ?? 0
                        let totalUSize = rec.size ?? emitted
                        if totalUSize > emitted {
                            emitLine(".zero \(totalUSize - emitted)")
                        }
                    }
                } else if case .array(let elemType, let count) = t {
                    // Array initializer: use element type
                    if case .structType(let subRec) = elemType.unqualified {
                        // Flat init for array of structs: consume values per struct element
                        var valueIdx = 0
                        var emitted = 0
                        while valueIdx < il.values.count && emitted < count {
                            let v = il.values[valueIdx]
                            if case .initList = v {
                                // Brace-enclosed init for one element
                                valueIdx += 1
                                emitInitializer(v, size: elemType.sizeInBytes ?? 8, type: elemType)
                            } else if case .compoundLiteral(let cl) = v {
                                valueIdx += 1
                                emitInitializer(cl.initList, size: elemType.sizeInBytes ?? 8, type: elemType)
                            } else {
                                // Flat init: consume values for one struct element
                                emitFlatStructInit(il.values, idx: &valueIdx, rec: subRec)
                            }
                            emitted += 1
                        }
                        // Fill remaining elements with zero
                        if emitted < count {
                            emitLine(".zero \((count - emitted) * (elemType.sizeInBytes ?? 8))")
                        }
                    } else {
                        var emitted = 0
                        for v in il.values {
                            emitInitializer(v, size: elemType.sizeInBytes ?? 8, type: elemType)
                            emitted += 1
                        }
                        if emitted < count {
                            emitLine(".zero \((count - emitted) * (elemType.sizeInBytes ?? 8))")
                        }
                    }
                } else if case .incompleteArray(let elemType) = t {
                    // Incomplete array: count determined by number of init values
                    if case .structType(let subRec) = elemType.unqualified {
                        // Flat init for array of structs: consume values per struct element
                        var valueIdx = 0
                        while valueIdx < il.values.count {
                            emitFlatStructInit(il.values, idx: &valueIdx, rec: subRec)
                        }
                    } else {
                        for v in il.values {
                            emitInitializer(v, size: elemType.sizeInBytes ?? 8, type: elemType)
                        }
                    }
                } else {
                    // Scalar type with brace-enclosed initializer: emit first value
                    if il.values.count > 0 {
                        emitInitializer(il.values[0], size: size, type: type)
                    } else {
                        emitLine(".zero \(size)")
                    }
                }
            } else {
                for v in il.values {
                    emitInitializer(v, size: 8)
                }
            }
        case .stringLiteral(let sl):
            // Check for wide string literal
            if sl.value.hasPrefix("WIDE:") {
                // Wide string: emit each code point as a 4-byte .long
                let hexPart = String(sl.value.dropFirst(5))
                var i = hexPart.startIndex
                while i < hexPart.endIndex {
                    let end = hexPart.index(i, offsetBy: 8, limitedBy: hexPart.endIndex) ?? hexPart.endIndex
                    if let cp = UInt32(hexPart[i..<end], radix: 16) {
                        emitLine(".long \(cp)")
                    }
                    i = end
                }
            } else if let type = type, case .array(let elemType, let count) = type.unqualified,
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
        case .compoundLiteral(let cl):
            // Compound literal in initializer — emit its init list
            emitInitializer(cl.initList, size: size, type: type)
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

    /// Consume values from a flat init list for a struct field.
    /// Used when a struct field is initialized without braces, e.g.,
    /// `struct U gu = {3, 5, 6, 7, 8, 4, "huhu", 43}` where `s` is a struct.
    private func emitFlatStructInit(_ allValues: [Expr], idx: inout Int, rec: RecordType) {
        for field in rec.fields {
            let fieldSize = field.type.sizeInBytes ?? 0
            if fieldSize == 0 { continue }
            let fieldOffset = field.offset
            // Emit padding if needed (caller handles padding for top-level; for nested flat,
            // we assume values map to consecutive fields)
            _ = fieldOffset
            if idx < allValues.count {
                let v = allValues[idx]
                if case .initList = v {
                    // Nested init list — recurse
                    idx += 1
                    emitInitializer(v, size: fieldSize, type: field.type)
                } else if case .stringLiteral = v, case .array(let elemType, let count) = field.type.unqualified, elemType.isChar {
                    // String literal for char array field — emit inline bytes
                    idx += 1
                    if case .stringLiteral(let sl) = v {
                        let bytes = sl.value
                        if bytes.count <= count {
                            emitLine(".asciz \"\(escapeStringLiteral(bytes))\"")
                            let emitted = bytes.count + 1
                            if count > emitted {
                                emitLine(".zero \(count - emitted)")
                            }
                        } else {
                            emitLine(".ascii \"\(escapeStringLiteral(String(bytes.prefix(count))))\"")
                        }
                    }
                } else if case .structType(let subRec) = field.type.unqualified {
                    // Another level of flat struct init
                    emitFlatStructInit(allValues, idx: &idx, rec: subRec)
                } else if case .array(let elemType, let count) = field.type.unqualified {
                    // Array field: consume values for each element
                    for _ in 0..<count {
                        if idx < allValues.count {
                            emitInitializer(allValues[idx], size: elemType.sizeInBytes ?? 8, type: elemType)
                            idx += 1
                        } else {
                            emitLine(".zero \(elemType.sizeInBytes ?? 8)")
                        }
                    }
                } else {
                    idx += 1
                    emitInitializer(v, size: fieldSize, type: field.type)
                }
            } else {
                emitLine(".zero \(fieldSize)")
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
            case .div: return rhs != 0 ? Int64(bitPattern: UInt64(bitPattern: lhs) / UInt64(bitPattern: rhs)) : nil
            case .mod: return rhs != 0 ? Int64(bitPattern: UInt64(bitPattern: lhs) % UInt64(bitPattern: rhs)) : nil
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
        // Emit wide strings first (with 4-byte alignment), then regular strings
        let wideStrings = stringLiterals.filter { $0.value.hasPrefix("WIDE:") }
        let regStrings = stringLiterals.filter { !$0.value.hasPrefix("WIDE:") }
        if !wideStrings.isEmpty {
            emitLine(".section __TEXT,__const")
            emitLine(".p2align 2")
            for sl in wideStrings {
                emitLine("\(sl.label):")
                let hexPart = String(sl.value.dropFirst(5))
                var i = hexPart.startIndex
                while i < hexPart.endIndex {
                    let end = hexPart.index(i, offsetBy: 8, limitedBy: hexPart.endIndex) ?? hexPart.endIndex
                    if let cp = UInt32(hexPart[i..<end], radix: 16) {
                        emitLine(".long \(cp)")
                    }
                    i = end
                }
            }
        }
        if !regStrings.isEmpty {
            emitLine(".section __TEXT,__cstring")
            for sl in regStrings {
                emitLine("\(sl.label):")
                emitLine(".asciz \"\(escapeString(sl.value))\"")
            }
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
        localVarTypes = [:]
        vlaBasePointers = []
        vlaInnerDims = [:]
        vlaAllDims = [:]
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
        // (our internal variadic calling convention). The args are above the
        // saved fp/lr, at x29 + 16. We don't need to save x1-x7.
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
        var fpRegIndex = 0  // current FP register index (d0, d1, ...)
        var stackParamIdx = 0  // tracks stack-passed param slots
        for (i, param) in fd.params.enumerated() {
            let pt = param.type.unqualified
            let paramSize = pt.sizeInBytes ?? 8
            // Check if this is an HFA (Homogeneous Floating-point Aggregate)
            let hfaInfo = isHFA(pt)
            let isHFA = hfaInfo != nil
            let hfaCount = hfaInfo?.count ?? 0  // number of FP registers
            let hfaIsFloat = hfaInfo?.isFloat ?? false  // true=float, false=double

            let regWidth: Int
            if isHFA {
                regWidth = hfaCount
            } else if case .structType = pt, paramSize > 8, paramSize <= 16 {
                regWidth = 2
            } else if case .structType = pt, paramSize > 16 {
                // Large struct: entirely on stack, rounded up to 8-byte slots
                regWidth = (paramSize + 7) / 8
            } else {
                regWidth = 1
            }

            if isHFA && fpRegIndex + hfaCount <= 8 {
                // HFA: passed in FP registers (s0-s7 or d0-d7)
                let memberSize = hfaIsFloat ? 4 : 8
                ensureLocalSpace(size: hfaCount * memberSize)
                let offset = -(localOffset)
                localVarOffsets[param.name ?? "_param_\(i)"] = offset
                for j in 0..<hfaCount {
                    let fpReg = hfaIsFloat ? "s\(fpRegIndex + j)" : "d\(fpRegIndex + j)"
                    if hfaIsFloat {
                        // Float member: store as 4 bytes
                        if offset + j * memberSize >= -256 && offset + j * memberSize <= 255 {
                            emitLine("str \(fpReg), [x29, #\(offset + j * memberSize)]")
                        } else {
                            emitLoadImm("x16", Int64(offset + j * memberSize))
                            emitLine("str \(fpReg), [x29, x16]")
                        }
                    } else {
                        emitStoreFP(fpReg, offset + j * memberSize)
                    }
                }
                localVarTypes[param.name ?? "_param_\(i)"] = param.type
                fpRegIndex += hfaCount
                regIndex += hfaCount  // HFA also consumes integer register slots
            } else if isHFA {
                // HFA overflow: entire HFA passed on the stack
                // Read from caller's stack at [x29, #16 + (regIndex-8)*8]
                let memberSize = hfaIsFloat ? 4 : 8
                ensureLocalSpace(size: hfaCount * memberSize)
                let offset = -(localOffset)
                localVarOffsets[param.name ?? "_param_\(i)"] = offset
                for j in 0..<hfaCount {
                    let stackSrcOffset = 16 + (stackParamIdx + j) * 8
                    if hfaIsFloat {
                        emitLoadFP("s9", stackSrcOffset)
                        if offset + j * memberSize >= -256 && offset + j * memberSize <= 255 {
                            emitLine("str s9, [x29, #\(offset + j * memberSize)]")
                        } else {
                            emitLoadImm("x16", Int64(offset + j * memberSize))
                            emitLine("str s9, [x29, x16]")
                        }
                    } else {
                        emitLoadFP("d9", stackSrcOffset)
                        emitStoreFP("d9", offset + j * memberSize)
                    }
                }
                localVarTypes[param.name ?? "_param_\(i)"] = param.type
                regIndex += hfaCount
                stackParamIdx += hfaCount
            } else if !isHFA && pt.isFloating && fpRegIndex < 8 {
                // Float/double parameter arrives in d0-d7 (separate FP register file).
                // Per AAPCS64, FP and integer registers are independent — float params
                // do NOT consume integer register slots.
                ensureLocalSpace(size: 8)  // always allocate 8 bytes for simplicity
                let offset = -(localOffset)
                localVarOffsets[param.name ?? "_param_\(i)"] = offset
                let fpReg = pt == .float ? "s\(fpRegIndex)" : "d\(fpRegIndex)"
                emitStoreFP(fpReg, offset)
                localVarTypes[param.name ?? "_param_\(i)"] = param.type
                fpRegIndex += 1
            } else if !isHFA && pt.isFloating {
                // Float/double parameter overflow: passed on the stack
                let stackSrcOffset = 16 + stackParamIdx * 8
                ensureLocalSpace(size: 8)
                let localOff = -(localOffset)
                localVarOffsets[param.name ?? "_param_\(i)"] = localOff
                emitLoadFP("d9", stackSrcOffset)
                emitStoreFP("d9", localOff)
                localVarTypes[param.name ?? "_param_\(i)"] = param.type
                stackParamIdx += 1
            } else if !isHFA && regIndex < 8 && regWidth <= 2 {
                // Parameters come in x0-x7 (int), store them on the stack
                // Large structs (regWidth > 2) always go on the stack path below.
                ensureLocalSpace(size: regWidth * 8)
                let offset = -(localOffset)
                localVarOffsets[param.name ?? "_param_\(i)"] = offset
                let isInt = pt.isInteger || pt.isPointer || pt.isFunction
                if isInt {
                    // Always use 64-bit store for simplicity
                    emitStoreFP(argRegs[regIndex].x, offset)
                } else if case .structType = pt {
                    // Struct parameter: store register(s) to stack
                    emitStoreFP(argRegs[regIndex].x, offset)
                    if regWidth == 2 {
                        if regIndex + 1 < 8 {
                            // Both chunks fit in registers
                            emitStoreFP(argRegs[regIndex + 1].x, offset + 8)
                        } else {
                            // Second chunk is on the stack (split across regs/stack)
                            let stackSrcOffset = 16 + stackParamIdx * 8
                            emitLoadFP("x9", stackSrcOffset)
                            emitStoreFP("x9", offset + 8)
                            stackParamIdx += 1
                        }
                    }
                }
                localVarTypes[param.name ?? "_param_\(i)"] = param.type
                regIndex += regWidth
            } else {
                // Parameters beyond x0-x7 are passed on the stack by the caller.
                // They are at [x29, #16 + stackParamIdx*8] (above saved fp/lr).
                let stackSrcOffset = 16 + stackParamIdx * 8
                ensureLocalSpace(size: regWidth * 8)
                let localOff = -(localOffset)
                localVarOffsets[param.name ?? "_param_\(i)"] = localOff
                // Load from caller's stack and store to our local frame
                for j in 0..<regWidth {
                    emitLoadFP("x9", stackSrcOffset + j * 8)
                    emitStoreFP("x9", localOff + j * 8)
                }
                localVarTypes[param.name ?? "_param_\(i)"] = param.type
                regIndex += regWidth
                stackParamIdx += regWidth
            }
        }

        // Emit body
        if let body = fd.body {
            emitCompoundStmt(body)        }

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
                        // Check for VLA (variable-length array)
                        if let vlaExpr = vd.vlaSizeExpr,
                           case .incompleteArray(let elemType) = vd.type.unqualified {
                            // VLA: evaluate size expression, multiply by element size,
                            // allocate on stack, store base pointer in a local variable.
                            // For multi-dimensional VLAs, find the leaf element type (e.g., int for int[m][n]).
                            var leafType = elemType
                            while case .incompleteArray(let inner) = leafType.unqualified {
                                leafType = inner
                            }
                            let elemSize = leafType.unqualified.sizeInBytes ?? 1
                            // Allocate a local variable to hold the base pointer
                            allocLocal(name: vd.name, type: .pointer(to: elemType))

                            // For multi-dimensional VLAs, evaluate inner dimensions and
                            // compute the total element size (outer_size * inner_size * ... * elemSize).
                            // Store inner dimension sizes in local variables for subscript stride.
                            var innerDimNames: [String] = []
                            // Store outer dimension in a local var for runtime sizeof(VLA)
                            let outerDimName = "\(vd.name)_vla_dim_outer"
                            allocLocal(name: outerDimName, type: .int)
                            var totalSizeReg = emitExpr(vlaExpr)
                            if exprType(vlaExpr).unqualified.isSigned32Bit {
                                emitLine("sxtw \(totalSizeReg.x), \(totalSizeReg.w)")
                            }
                            storeLocal(outerDimName, totalSizeReg, type: .int)
                            for (idx, innerExpr) in vd.vlaInnerSizeExprs.enumerated() {
                                let dimName = "\(vd.name)_vla_dim\(idx)"
                                allocLocal(name: dimName, type: .int)
                                let innerReg = emitExpr(innerExpr)
                                if exprType(innerExpr).unqualified.isSigned32Bit {
                                    emitLine("sxtw \(innerReg.x), \(innerReg.w)")
                                }
                                storeLocal(dimName, innerReg, type: .int)
                                regAlloc.free(innerReg)
                                // Multiply total size by inner dimension
                                emitLine("mul \(totalSizeReg.x), \(totalSizeReg.x), \(innerReg.x)")
                                innerDimNames.append(dimName)
                            }
                            // Store inner dims for subscript stride (excludes outer)
                            if !innerDimNames.isEmpty {
                                vlaInnerDims[vd.name] = innerDimNames
                            }
                            // Store all dims for runtime sizeof (outer first)
                            vlaAllDims[vd.name] = [outerDimName] + innerDimNames

                            let sizeReg = totalSizeReg
                            // Multiply by element size
                            if elemSize > 1 {
                                if elemSize == 2 { emitLine("lsl \(sizeReg.x), \(sizeReg.x), #1") }
                                else if elemSize == 4 { emitLine("lsl \(sizeReg.x), \(sizeReg.x), #2") }
                                else if elemSize == 8 { emitLine("lsl \(sizeReg.x), \(sizeReg.x), #3") }
                                else {
                                    emitLoadImm("x16", Int64(elemSize))
                                    emitLine("mul \(sizeReg.x), \(sizeReg.x), x16")
                                }
                            }
                            // Align to 16 bytes
                            emitLine("add \(sizeReg.x), \(sizeReg.x), #15")
                            emitLine("and \(sizeReg.x), \(sizeReg.x), #0xFFFFFFFFFFFFFFF0")
                            // Allocate on stack
                            emitLine("sub sp, sp, \(sizeReg.x)")
                            // Store the base pointer (sp after allocation)
                            emitLine("mov \(sizeReg.x), sp")
                            storeLocal(vd.name, sizeReg, type: .pointer(to: elemType))
                            regAlloc.free(sizeReg)
                            // Mark this local as a VLA base pointer
                            vlaBasePointers.insert(vd.name)
                        } else {
                            allocLocal(name: vd.name, type: vd.type)
                            if let init_ = vd.initializer {
                            if case .stringLiteral(let sl) = init_,
                               sl.value.hasPrefix("WIDE:"),
                               case .array(let elemType, let count) = vd.type.unqualified,
                               elemType.isInteger {
                                // wchar_t arr[] = L"string" — copy 4-byte ints to local array
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
                                    for i in 0..<count {
                                        if i > 0 {
                                            emitLine("ldr w16, [\(srcReg.x), #\(i * 4)]")
                                            emitLine("str w16, [\(addrReg.x), #\(i * 4)]")
                                        } else {
                                            emitLine("ldr w16, [\(srcReg.x)]")
                                            emitLine("str w16, [\(addrReg.x)]")
                                        }
                                    }
                                    regAlloc.free(srcReg)
                                }
                                regAlloc.free(addrReg)
                            } else if case .stringLiteral(let sl) = init_,
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
                            } else if case .call = init_, case .structType = vd.type.unqualified {
                                // Function call returning a struct: read return registers
                                // and store to the local variable's address.
                                // Resolve the struct type through knownRecords (in case vd.type has an incomplete record)
                                var resolvedType = vd.type
                                if case .structType(let rec) = vd.type.unqualified, rec.fields.isEmpty, let completed = knownRecords[rec.name] {
                                    resolvedType = .structType(completed)
                                }
                                let structSize = resolvedType.unqualified.sizeInBytes ?? 0
                                if let offset = localVarOffsets[vd.name] {
                                    if let hfaInfo = isHFA(resolvedType) {
                                        // HFA return: read from s0-s3 or d0-d3
                                        _ = emitExpr(init_)  // make the call
                                        // Store FP return registers to local var
                                        let fpPrefix = hfaInfo.isFloat ? "s" : "d"
                                        for j in 0..<hfaInfo.count {
                                            let memberOff = j * (hfaInfo.isFloat ? 4 : 8)
                                            if offset + memberOff >= -256 && offset + memberOff <= 255 {
                                                emitLine("str \(fpPrefix)\(j), [x29, #\(offset + memberOff)]")
                                            } else {
                                                emitLoadImm("x16", Int64(offset + memberOff))
                                                emitLine("str \(fpPrefix)\(j), [x29, x16]")
                                            }
                                        }
                                    } else if structSize <= 16 {
                                        // Small/medium struct: read from x0 (and x1)
                                        _ = emitExpr(init_)  // make the call
                                        if offset >= -256 && offset <= 255 {
                                            emitLine("str x0, [x29, #\(offset)]")
                                        } else {
                                            emitLoadImm("x16", Int64(offset))
                                            emitLine("str x0, [x29, x16]")
                                        }
                                        if structSize > 8 {
                                            let off2 = offset + 8
                                            if off2 >= -256 && off2 <= 255 {
                                                emitLine("str x1, [x29, #\(off2)]")
                                            } else {
                                                emitLoadImm("x16", Int64(off2))
                                                emitLine("str x1, [x29, x16]")
                                            }
                                        }
                                    } else {
                                        // Large struct: pass x8 pointer, callee writes to it
                                        if offset >= -256 && offset <= 255 {
                                            emitLine("add x8, x29, #\(offset)")
                                        } else {
                                            emitLoadImm("x16", Int64(offset))
                                            emitLine("add x8, x29, x16")
                                        }
                                        _ = emitExpr(init_)  // make the call
                                    }
                                }
                            } else {
                                let varType = vd.type.unqualified
                                // For struct types initialized from a non-call expression (e.g., va_arg),
                                // emitExpr returns the address of the struct data.
                                // Copy the struct from that address to the local variable.
                                if case .structType = varType, let structSize = varType.sizeInBytes, structSize > 0 {
                                    // For struct-to-struct copy, get the source address (not value)
                                    let srcAddr: ARM64Reg
                                    if case .identifier = init_ {
                                        // Use emitAddr for identifiers to get the struct's address
                                        srcAddr = emitAddr(init_)
                                    } else {
                                        srcAddr = emitExpr(init_)
                                    }
                                    let dstAddr = regAlloc.alloc() ?? .x9
                                    if let offset = localVarOffsets[vd.name] {
                                        if offset >= -256 && offset <= 255 {
                                            emitLine("add \(dstAddr.x), x29, #\(offset)")
                                        } else {
                                            emitLoadImm("x16", Int64(offset))
                                            emitLine("add \(dstAddr.x), x29, x16")
                                        }
                                    }
                                    emitStructCopyToField(dstAddr.x, srcAddr, structSize)
                                    regAlloc.free(dstAddr)
                                } else if varType.isComplex, let offset = localVarOffsets[vd.name] {
                                    // _Complex variable initialization
                                    let isFloat = (varType == .complexFloat)
                                    emitComplexExpr(init_, storeAtOffset: offset, isFloat: isFloat)
                                } else {
                                    let reg = emitExpr(init_)
                                    // Convert type if needed (e.g., double→float, int→float)
                                    let initType = exprType(init_).unqualified
                                    if initType.isFloating && varType.isFloating {
                                        convertFloat(reg, from: initType, to: vd.type)
                                    } else if initType.isInteger && varType.isFloating {
                                        if initType.isSigned32Bit {
                                            emitLine("sxtw \(reg.x), \(reg.w)")
                                        }
                                        let fp = varType == .float ? "s" : "d"
                                        emitLine("scvtf \(fp)\(reg.regNum), \(reg.x)")
                                    } else if initType.isFloating && varType.isInteger {
                                        let srcFp = initType == .float ? "s" : "d"
                                        if varType.isSigned32Bit {
                                            emitLine("fcvtzs \(reg.w), \(srcFp)\(reg.regNum)")
                                        } else {
                                            emitLine("fcvtzs \(reg.x), \(srcFp)\(reg.regNum)")
                                        }
                                    } else if initType.isInteger && varType.isInteger && initType != varType {
                                        // int-to-int conversion: sign-extend or zero-extend as needed
                                        let srcSize = initType.sizeInBytes ?? 4
                                        let dstSize = varType.sizeInBytes ?? 8
                                        if srcSize < dstSize {
                                            if initType.isUnsigned {
                                                if srcSize == 4 {
                                                    emitLine("mov w\(reg.regNum), w\(reg.regNum)")
                                                }
                                            } else {
                                                if srcSize == 4 {
                                                    emitLine("sxtw \(reg.x), \(reg.w)")
                                                } else if srcSize == 2 {
                                                    emitLine("sxth \(reg.x), w\(reg.regNum)")
                                                } else if srcSize == 1 {
                                                    emitLine("sxtb \(reg.x), w\(reg.regNum)")
                                                }
                                            }
                                        }
                                    }
                                    storeLocal(vd.name, reg, type: vd.type)
                                }
                            }
                        }
                        }  // end VLA else
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
                let retType = exprType(v).unqualified
                if case .structType = retType {
                    // Struct return: depends on size and HFA status
                    let structSize = retType.sizeInBytes ?? 0
                    if let hfaInfo = isHFA(retType) {
                        // HFA return: load members into FP registers (s0-s3 or d0-d3)
                        let srcAddr = emitAddr(v)
                        let fpPrefix = hfaInfo.isFloat ? "s" : "d"
                        for j in 0..<hfaInfo.count {
                            let memberOff = j * (hfaInfo.isFloat ? 4 : 8)
                            emitLine("ldr \(fpPrefix)\(j), [\(srcAddr.x), #\(memberOff)]")
                        }
                        regAlloc.free(srcAddr)
                    } else if structSize <= 8 {
                        // Small struct (≤8 bytes): return in x0
                        let srcAddr = emitAddr(v)
                        emitLine("ldr x0, [\(srcAddr.x)]")
                        regAlloc.free(srcAddr)
                    } else if structSize <= 16 {
                        // Medium struct (9-16 bytes): return in x0, x1
                        let srcAddr = emitAddr(v)
                        emitLine("ldr x0, [\(srcAddr.x)]")
                        emitLine("ldr x1, [\(srcAddr.x), #8]")
                        regAlloc.free(srcAddr)
                    } else {
                        // Large struct (>16 bytes): copy to indirect return pointer (x8)
                        // The caller passes a pointer in x8 to the return location.
                        let srcAddr = emitAddr(v)
                        // Use emitStructCopyToField which uses x15 as scratch
                        emitStructCopyToField("x8", srcAddr, structSize)
                        regAlloc.free(srcAddr)
                    }
                } else if retType.isFloating {
                    // Float/double return value goes in s0 (float) or d0 (double)
                    let reg = emitExpr(v)
                    let fpReg = retType == .float ? "s\(reg.regNum)" : "d\(reg.regNum)"
                    let retFpReg = retType == .float ? "s0" : "d0"
                    if reg != .x0 {
                        emitLine("fmov \(retFpReg), \(fpReg)")
                    }
                } else {
                    // Move result to x0
                    let reg = emitExpr(v)
                    if reg != .x0 {
                        // For 32-bit return types, use mov w0 (truncates to 32 bits,
                        // zero-extending to 64-bit). For 64-bit types (long, pointer),
                        // use mov x0 to preserve the full value.
                        if (retType.isSigned32Bit || retType == .uint || retType == .ushort || retType == .uchar || retType == .bool) && !retType.isPointer {
                            emitLine("mov w0, \(reg.w)")
                        } else {
                            emitLine("mov x0, \(reg.x)")
                        }
                    }
                    regAlloc.free(reg)
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
            // Get or create the assembly label for this C label.
            // Use a distinct prefix to avoid collisions with newLabel() labels.
            let asmLabel: String
            if let existing = gotoLabels[g.label] {
                asmLabel = existing
            } else {
                labelCounter += 1
                asmLabel = "L_\(currentFuncName)_G\(labelCounter)"
                gotoLabels[g.label] = asmLabel
            }
            emitLine("b \(asmLabel)")

        case .label(let l):
            // Use existing label if goto already created one, else create new
            let asmLabel: String
            if let existing = gotoLabels[l.name] {
                asmLabel = existing
            } else {
                labelCounter += 1
                asmLabel = "L_\(currentFuncName)_G\(labelCounter)"
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
                // Scan for case labels at this level and recursively in nested statements
                scanAndEmitCaseLabels(comp, caseLabelMap: &caseLabelMap, defaultLabel: &defaultLabel, keyPrefix: "\(idx)", emitCaseComparison: emitCaseComparison)
            } else if case .if(let ifStmt) = stmt {
                // Case labels inside if blocks at switch top level
                if case .compound(let thenComp) = ifStmt.thenStmt {
                    scanAndEmitCaseLabels(thenComp, caseLabelMap: &caseLabelMap, defaultLabel: &defaultLabel, keyPrefix: "\(idx).t", emitCaseComparison: emitCaseComparison)
                }
                if let elseStmt = ifStmt.elseStmt, case .compound(let elseComp) = elseStmt {
                    scanAndEmitCaseLabels(elseComp, caseLabelMap: &caseLabelMap, defaultLabel: &defaultLabel, keyPrefix: "\(idx).e", emitCaseComparison: emitCaseComparison)
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

        // Recursively scan for case/default labels in a compound statement
        func scanAndEmitCaseLabels(_ comp: CompoundStmt, caseLabelMap: inout [String: String], defaultLabel: inout String?, keyPrefix: String, emitCaseComparison: (Expr) -> String) {
            for (innerIdx, innerStmt) in comp.statements.enumerated() {
                let key = "\(keyPrefix).\(innerIdx)"
                if case .case(let cs) = innerStmt {
                    caseLabelMap[key] = emitCaseComparison(cs.value)
                    // Recursively scan the case body
                    if let s = cs.stmt, case .compound(let innerComp) = s {
                        scanAndEmitCaseLabels(innerComp, caseLabelMap: &caseLabelMap, defaultLabel: &defaultLabel, keyPrefix: key, emitCaseComparison: emitCaseComparison)
                    }
                } else if case .default = innerStmt {
                    defaultLabel = newLabel()
                } else if case .compound(let innerComp) = innerStmt {
                    scanAndEmitCaseLabels(innerComp, caseLabelMap: &caseLabelMap, defaultLabel: &defaultLabel, keyPrefix: key, emitCaseComparison: emitCaseComparison)
                } else if case .if(let ifStmt) = innerStmt {
                    // Case labels inside if blocks — scan both branches
                    if case .compound(let thenComp) = ifStmt.thenStmt {
                        scanAndEmitCaseLabels(thenComp, caseLabelMap: &caseLabelMap, defaultLabel: &defaultLabel, keyPrefix: "\(key).t", emitCaseComparison: emitCaseComparison)
                    }
                    if let elseStmt = ifStmt.elseStmt, case .compound(let elseComp) = elseStmt {
                        scanAndEmitCaseLabels(elseComp, caseLabelMap: &caseLabelMap, defaultLabel: &defaultLabel, keyPrefix: "\(key).e", emitCaseComparison: emitCaseComparison)
                    }
                }
            }
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
                    if let s = cs.stmt {
                        if case .compound(let comp) = s {
                            emitCompoundWithCases(comp, keyPrefix: key)
                        } else {
                            emitStmt(s)
                        }
                    }
                } else if case .default(let ds) = innerStmt {
                    if let s = ds.stmt { emitStmt(s) }
                } else if case .if(let ifStmt) = innerStmt {
                    // Emit if statement, but inject case labels inside its body
                    let condReg = emitExpr(ifStmt.condition)
                    regAlloc.reset()
                    let elseLabel = newLabel()
                    emitLine("cbz \(condReg.x), \(elseLabel)")
                    if case .compound(let thenComp) = ifStmt.thenStmt {
                        emitCompoundWithCases(thenComp, keyPrefix: "\(key).t")
                    } else {
                        emitStmt(ifStmt.thenStmt)
                    }
                    regAlloc.reset()
                    if let elseStmt = ifStmt.elseStmt {
                        let ifEndLabel = newLabel()
                        emitLine("b \(ifEndLabel)")
                        emitLine("\(elseLabel):")
                        if case .compound(let elseComp) = elseStmt {
                            emitCompoundWithCases(elseComp, keyPrefix: "\(key).e")
                        } else {
                            emitStmt(elseStmt)
                        }
                        regAlloc.reset()
                        emitLine("\(ifEndLabel):")
                    } else {
                        emitLine("\(elseLabel):")
                    }
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
            case .if(let ifStmt):
                // Emit if statement with case labels injected inside
                let condReg = emitExpr(ifStmt.condition)
                regAlloc.reset()
                let elseLabel = newLabel()
                emitLine("cbz \(condReg.x), \(elseLabel)")
                if case .compound(let thenComp) = ifStmt.thenStmt {
                    emitCompoundWithCases(thenComp, keyPrefix: "\(idx).t")
                } else {
                    emitStmt(ifStmt.thenStmt)
                }
                regAlloc.reset()
                if let elseStmt = ifStmt.elseStmt {
                    let ifEndLabel = newLabel()
                    emitLine("b \(ifEndLabel)")
                    emitLine("\(elseLabel):")
                    if case .compound(let elseComp) = elseStmt {
                        emitCompoundWithCases(elseComp, keyPrefix: "\(idx).e")
                    } else {
                        emitStmt(elseStmt)
                    }
                    regAlloc.reset()
                    emitLine("\(ifEndLabel):")
                } else {
                    emitLine("\(elseLabel):")
                }
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

        case .floatLiteral(let f):
            // Load IEEE 754 bit pattern into an integer register, then transfer
            // to the FP register (dN for double, sN for float).
            let reg = regAlloc.alloc() ?? .x9
            if f.type.unqualified == .float {
                let bits = UInt64(Float(f.value).bitPattern)
                emitLoadImm(reg.x, Int64(bitPattern: bits))
                emitLine("fmov s\(reg.regNum), w\(reg.regNum)")
            } else {
                // double (or longDouble treated as double)
                let bits = f.value.bitPattern
                emitLoadImm(reg.x, Int64(bitPattern: bits))
                emitLine("fmov d\(reg.regNum), \(reg.x)")
            }
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
                // Type-aware load for static local
                if let t = localVarTypes[id.name] {
                    emitLoad(reg, type: t)
                } else {
                    emitLine("ldr \(reg.x), [\(reg.x)]")
                }
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
                    // Type-aware load for external global
                    if let gt = globalVarTypes[id.name] {
                        emitLoad(reg, type: gt)
                    } else {
                        emitLine("ldr \(reg.x), [\(reg.x)]")
                    }
                } else {
                    emitLine("adrp \(reg.x), _\(id.name)@PAGE")
                    emitLine("add \(reg.x), \(reg.x), _\(id.name)@PAGEOFF")
                    // If the global is an array, return the address (array decays to pointer)
                    if let gt = globalVarTypes[id.name], case .array = gt.unqualified {
                        return reg
                    }
                    // Type-aware load for global
                    if let gt = globalVarTypes[id.name] {
                        emitLoad(reg, type: gt)
                    } else {
                        // Otherwise, load the value from the global address
                        emitLine("ldr \(reg.x), [\(reg.x)]")
                    }
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
            // Handle int↔float conversions. Other casts just evaluate the inner expr.
            let fromType = exprType(c.expr).unqualified
            let toType = c.type.unqualified
            if fromType.isFloating && toType.isFloating {
                // float ↔ double conversion
                let reg = emitExpr(c.expr)
                if fromType == .float && (toType == .double || toType == .longDouble) {
                    // float → double: fcvt dN, sN
                    emitLine("fcvt d\(reg.regNum), s\(reg.regNum)")
                } else if (fromType == .double || fromType == .longDouble) && toType == .float {
                    // double → float: fcvt sN, dN
                    emitLine("fcvt s\(reg.regNum), d\(reg.regNum)")
                }
                return reg
            }
            if fromType.isInteger && toType.isFloating {
                // int → float/double: scvtf
                let reg = emitExpr(c.expr)
                // Sign-extend 32-bit signed ints to 64 bits first
                if fromType.isSigned32Bit {
                    emitLine("sxtw \(reg.x), \(reg.w)")
                }
                if toType == .float {
                    emitLine("scvtf s\(reg.regNum), \(reg.x)")
                } else {
                    emitLine("scvtf d\(reg.regNum), \(reg.x)")
                }
                return reg
            }
            if fromType.isFloating && toType.isInteger {
                // float/double → int: fcvtzs
                let reg = emitExpr(c.expr)
                let srcReg = fromType == .float ? "s\(reg.regNum)" : "d\(reg.regNum)"
                if toType.isSigned32Bit {
                    // Convert to 32-bit int: fcvtzs wN, sN/dN
                    emitLine("fcvtzs \(reg.w), \(srcReg)")
                } else {
                    // Convert to 64-bit int: fcvtzs xN, sN/dN
                    emitLine("fcvtzs \(reg.x), \(srcReg)")
                }
                return reg
            }
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
                // For VLAs, compute size at runtime (check vlaBasePointers first,
                // since the local var type is stored as a pointer, not incompleteArray)
                if case .identifier(let id) = e,
                   vlaBasePointers.contains(id.name),
                   let allDims = vlaAllDims[id.name], !allDims.isEmpty {
                    // Get the VLA's element type from the stored pointer type
                    var elemType = exprType(e).unqualified
                    if case .pointer(let pt) = elemType { elemType = pt }
                    var leafType = elemType
                    while case .incompleteArray(let inner) = leafType.unqualified {
                        leafType = inner
                    }
                    let leafSize = leafType.unqualified.sizeInBytes ?? 1
                    // Load the first (outer) dimension
                    let firstDimOffset = localVarOffsets[allDims[0]] ?? 0
                    if firstDimOffset >= -256 && firstDimOffset <= 255 {
                        emitLine("ldr \(reg.w), [x29, #\(firstDimOffset)]")
                    } else {
                        emitLoadImm("x16", Int64(firstDimOffset))
                        emitLine("ldr \(reg.w), [x29, x16]")
                    }
                    emitLine("sxtw \(reg.x), \(reg.w)")
                    // Multiply by remaining dimensions
                    for i in 1..<allDims.count {
                        let dimOffset = localVarOffsets[allDims[i]] ?? 0
                        emitLine("ldr w16, [x29, #\(dimOffset)]")
                        emitLine("sxtw x16, w16")
                        emitLine("mul \(reg.x), \(reg.x), x16")
                    }
                    // Multiply by leaf element size
                    if leafSize > 1 {
                        if leafSize == 2 { emitLine("lsl \(reg.x), \(reg.x), #1") }
                        else if leafSize == 4 { emitLine("lsl \(reg.x), \(reg.x), #2") }
                        else if leafSize == 8 { emitLine("lsl \(reg.x), \(reg.x), #3") }
                        else {
                            emitLoadImm("x16", Int64(leafSize))
                            emitLine("mul \(reg.x), \(reg.x), x16")
                        }
                    }
                    return reg
                } else {
                    let t = exprType(e)
                    size = t.sizeInBytes ?? 4
                }
            } else {
                size = 0
            }
            emitLine("mov \(reg.x), #\(size)")
            return reg

        case .compoundLiteral(let cl):
            // Compound literal: allocate stack space, initialize, return address
            let litType = cl.type.unqualified
            let litSize = litType.sizeInBytes ?? 8
            // Allocate space on the stack (aligned to 16)
            let alignedSize = (litSize + 15) & ~15
            emitLine("sub sp, sp, #\(alignedSize)")
            // Use the stack pointer as the base address
            let addrReg = regAlloc.alloc() ?? .x9
            emitLine("mov \(addrReg.x), sp")
            // Initialize the memory from the init list
            emitLocalInit(addrReg, cl.initList, type: cl.type)
            return addrReg

        case .initList(let il):
            // Return first value for now
            if let first = il.values.first {
                return emitExpr(first)
            }
            let reg = regAlloc.alloc() ?? .x9
            emitLine("mov \(reg.x), #0")
            return reg

        case .genericExpr(let ge):
            // Evaluate the controlling expression's type and select the matching branch
            let ctrlType = exprType(ge.controllingExpr).unqualified
            // Find matching association
            var selected: Expr? = nil
            var defaultExpr: Expr? = nil
            for assoc in ge.associations {
                if assoc.isDefault {
                    defaultExpr = assoc.expr
                } else if let tn = assoc.typeName {
                    let assocType = tn.unqualified
                    // Compare types
                    if typeMatches(ctrlType, assocType) {
                        selected = assoc.expr
                        break
                    }
                }
            }
            if selected == nil { selected = defaultExpr }
            if let s = selected {
                return emitExpr(s)
            }
            let reg = regAlloc.alloc() ?? .x9
            emitLine("mov \(reg.x), #0")
            return reg

        case .stmtExpr(let se):
            // Emit all statements in the body
            for stmt in se.body.statements {
                _ = emitStmt(stmt)
            }
            // Return the value of the last expression statement
            if let lastStmt = se.body.statements.last,
               case .expr(let es) = lastStmt, let e = es.expr {
                return emitExpr(e)
            }
            let reg = regAlloc.alloc() ?? .x9
            emitLine("mov \(reg.x), #0")
            return reg
        }
    }

    /// Evaluate a complex-typed expression and store the result (real, imag) at
/// the given stack offset (relative to x29). Used for initializing _Complex local
/// variables. Supports: imaginary literals, real+complex, complex+real,
/// real*complex, complex*real, complex*complex, and plain complex identifiers.
    private func emitComplexExpr(_ expr: Expr, storeAtOffset offset: Int, isFloat: Bool) {
        let fpPrefix = isFloat ? "s" : "d"
        let partSize = isFloat ? 4 : 8

        // Helper to emit a load of a double/float constant into an FP register
        func loadFPConst(_ _reg: ARM64Reg, _ value: Double, _ float: Bool) {
            if float {
                let bits = UInt64(Float(value).bitPattern)
                emitLoadImm(_reg.x, Int64(bitPattern: bits))
                emitLine("fmov s\(_reg.regNum), w\(_reg.regNum)")
            } else {
                let bits = value.bitPattern
                emitLoadImm(_reg.x, Int64(bitPattern: bits))
                emitLine("fmov d\(_reg.regNum), \(_reg.x)")
            }
        }

        switch expr {
        case .floatLiteral(let f) where f.isImaginary:
            // Imaginary literal: real=0, imag=value
            let realReg = regAlloc.alloc() ?? .x9
            let imagReg = regAlloc.alloc() ?? .x10
            emitLine("fmov \(fpPrefix)\(realReg.regNum), #0.0")
            loadFPConst(imagReg, f.value, isFloat)
            emitStoreFP(realReg, offset: offset, isFloat: isFloat)
            emitStoreFP(imagReg, offset: offset + partSize, isFloat: isFloat)
            regAlloc.free(realReg)
            regAlloc.free(imagReg)

        case .binary(let b) where b.op == .add || b.op == .sub:
            // Complex addition/subtraction
            let leftComplex = exprType(b.left).unqualified.isComplex
            let rightComplex = exprType(b.right).unqualified.isComplex

            if leftComplex && rightComplex {
                // complex ± complex: (a±c, b±d)
                // Store left parts to temp, right parts to temp2, then add/sub
                let tmpOff = ensureTempSpace(size: partSize * 4)
                emitComplexExpr(b.left, storeAtOffset: tmpOff, isFloat: isFloat)
                emitComplexExpr(b.right, storeAtOffset: tmpOff + partSize * 2, isFloat: isFloat)
                // Real part
                let lr = regAlloc.alloc() ?? .x9
                let rr = regAlloc.alloc() ?? .x10
                emitLoadFP(lr, offset: tmpOff, isFloat: isFloat)
                emitLoadFP(rr, offset: tmpOff + partSize * 2, isFloat: isFloat)
                if b.op == .add { emitLine("fadd \(fpPrefix)\(lr.regNum), \(fpPrefix)\(lr.regNum), \(fpPrefix)\(rr.regNum)") }
                else { emitLine("fsub \(fpPrefix)\(lr.regNum), \(fpPrefix)\(lr.regNum), \(fpPrefix)\(rr.regNum)") }
                emitStoreFP(lr, offset: offset, isFloat: isFloat)
                // Imaginary part
                emitLoadFP(lr, offset: tmpOff + partSize, isFloat: isFloat)
                emitLoadFP(rr, offset: tmpOff + partSize * 3, isFloat: isFloat)
                if b.op == .add { emitLine("fadd \(fpPrefix)\(lr.regNum), \(fpPrefix)\(lr.regNum), \(fpPrefix)\(rr.regNum)") }
                else { emitLine("fsub \(fpPrefix)\(lr.regNum), \(fpPrefix)\(lr.regNum), \(fpPrefix)\(rr.regNum)") }
                emitStoreFP(lr, offset: offset + partSize, isFloat: isFloat)
                regAlloc.free(lr)
                regAlloc.free(rr)
            } else if leftComplex && !rightComplex {
                // complex + real: (a+real, b)
                // Store left complex parts
                let tmpOff = ensureTempSpace(size: partSize * 2)
                emitComplexExpr(b.left, storeAtOffset: tmpOff, isFloat: isFloat)
                // Evaluate right (real)
                let rightReg = emitExpr(b.right)
                // Convert to FP if needed
                if !exprType(b.right).unqualified.isFloating {
                    if exprType(b.right).unqualified.isSigned32Bit {
                        emitLine("sxtw \(rightReg.x), \(rightReg.w)")
                    }
                    if isFloat { emitLine("scvtf s\(rightReg.regNum), \(rightReg.x)") }
                    else { emitLine("scvtf d\(rightReg.regNum), \(rightReg.x)") }
                } else if exprType(b.right).unqualified == .float && !isFloat {
                    emitLine("fcvt d\(rightReg.regNum), s\(rightReg.regNum)")
                } else if exprType(b.right).unqualified == .double && isFloat {
                    emitLine("fcvt s\(rightReg.regNum), d\(rightReg.regNum)")
                }
                let realReg = regAlloc.alloc() ?? .x9
                emitLoadFP(realReg, offset: tmpOff, isFloat: isFloat)
                if b.op == .add { emitLine("fadd \(fpPrefix)\(realReg.regNum), \(fpPrefix)\(realReg.regNum), \(fpPrefix)\(rightReg.regNum)") }
                else { emitLine("fsub \(fpPrefix)\(realReg.regNum), \(fpPrefix)\(realReg.regNum), \(fpPrefix)\(rightReg.regNum)") }
                emitStoreFP(realReg, offset: offset, isFloat: isFloat)
                // Imaginary part stays the same
                emitLoadFP(realReg, offset: tmpOff + partSize, isFloat: isFloat)
                emitStoreFP(realReg, offset: offset + partSize, isFloat: isFloat)
                regAlloc.free(realReg)
                regAlloc.free(rightReg)
            } else if !leftComplex && rightComplex {
                // real + complex: (real+a, d)
                let tmpOff = ensureTempSpace(size: partSize * 2)
                emitComplexExpr(b.right, storeAtOffset: tmpOff, isFloat: isFloat)
                let leftReg = emitExpr(b.left)
                if !exprType(b.left).unqualified.isFloating {
                    if exprType(b.left).unqualified.isSigned32Bit {
                        emitLine("sxtw \(leftReg.x), \(leftReg.w)")
                    }
                    if isFloat { emitLine("scvtf s\(leftReg.regNum), \(leftReg.x)") }
                    else { emitLine("scvtf d\(leftReg.regNum), \(leftReg.x)") }
                } else if exprType(b.left).unqualified == .float && !isFloat {
                    emitLine("fcvt d\(leftReg.regNum), s\(leftReg.regNum)")
                } else if exprType(b.left).unqualified == .double && isFloat {
                    emitLine("fcvt s\(leftReg.regNum), d\(leftReg.regNum)")
                }
                let realReg = regAlloc.alloc() ?? .x9
                emitLoadFP(realReg, offset: tmpOff, isFloat: isFloat)
                if b.op == .add { emitLine("fadd \(fpPrefix)\(realReg.regNum), \(fpPrefix)\(leftReg.regNum), \(fpPrefix)\(realReg.regNum)") }
                else { emitLine("fsub \(fpPrefix)\(realReg.regNum), \(fpPrefix)\(leftReg.regNum), \(fpPrefix)\(realReg.regNum)") }
                emitStoreFP(realReg, offset: offset, isFloat: isFloat)
                emitLoadFP(realReg, offset: tmpOff + partSize, isFloat: isFloat)
                emitStoreFP(realReg, offset: offset + partSize, isFloat: isFloat)
                regAlloc.free(realReg)
                regAlloc.free(leftReg)
            } else {
                // Both real — shouldn't happen (result would be real, not complex)
                // Fall through: evaluate as real, store with imag=0
                let realReg = emitExpr(expr)
                emitStoreFP(realReg, offset: offset, isFloat: isFloat)
                let zeroReg = regAlloc.alloc() ?? .x9
                emitLine("fmov \(fpPrefix)\(zeroReg.regNum), #0.0")
                emitStoreFP(zeroReg, offset: offset + partSize, isFloat: isFloat)
                regAlloc.free(zeroReg)
            }

        case .binary(let b) where b.op == .mul:
            let leftComplex = exprType(b.left).unqualified.isComplex
            let rightComplex = exprType(b.right).unqualified.isComplex

            if leftComplex && rightComplex {
                // complex * complex: (a*c-b*d, a*d+b*c)
                let tmpOff = ensureTempSpace(size: partSize * 4)
                emitComplexExpr(b.left, storeAtOffset: tmpOff, isFloat: isFloat)
                emitComplexExpr(b.right, storeAtOffset: tmpOff + partSize * 2, isFloat: isFloat)
                let ar = regAlloc.alloc() ?? .x9
                let br = regAlloc.alloc() ?? .x10
                let cr = regAlloc.alloc() ?? .x11
                let dr = regAlloc.alloc() ?? .x12
                emitLoadFP(ar, offset: tmpOff, isFloat: isFloat)
                emitLoadFP(br, offset: tmpOff + partSize, isFloat: isFloat)
                emitLoadFP(cr, offset: tmpOff + partSize * 2, isFloat: isFloat)
                emitLoadFP(dr, offset: tmpOff + partSize * 3, isFloat: isFloat)
                // real = a*c - b*d
                emitLine("fmul \(fpPrefix)\(ar.regNum), \(fpPrefix)\(ar.regNum), \(fpPrefix)\(cr.regNum)")
                emitLine("fmul \(fpPrefix)\(br.regNum), \(fpPrefix)\(br.regNum), \(fpPrefix)\(dr.regNum)")
                emitLine("fsub \(fpPrefix)\(ar.regNum), \(fpPrefix)\(ar.regNum), \(fpPrefix)\(br.regNum)")
                emitStoreFP(ar, offset: offset, isFloat: isFloat)
                // imag = a*d + b*c  — but we overwrote ar and br. Reload.
                emitLoadFP(ar, offset: tmpOff, isFloat: isFloat)
                emitLoadFP(br, offset: tmpOff + partSize, isFloat: isFloat)
                emitLine("fmul \(fpPrefix)\(ar.regNum), \(fpPrefix)\(ar.regNum), \(fpPrefix)\(dr.regNum)")
                emitLine("fmul \(fpPrefix)\(br.regNum), \(fpPrefix)\(br.regNum), \(fpPrefix)\(cr.regNum)")
                emitLine("fadd \(fpPrefix)\(ar.regNum), \(fpPrefix)\(ar.regNum), \(fpPrefix)\(br.regNum)")
                emitStoreFP(ar, offset: offset + partSize, isFloat: isFloat)
                regAlloc.free(ar)
                regAlloc.free(br)
                regAlloc.free(cr)
                regAlloc.free(dr)
            } else if leftComplex && !rightComplex {
                // complex * real: (a*r, b*r)
                let tmpOff = ensureTempSpace(size: partSize * 2)
                emitComplexExpr(b.left, storeAtOffset: tmpOff, isFloat: isFloat)
                let rightReg = emitExpr(b.right)
                if !exprType(b.right).unqualified.isFloating {
                    if exprType(b.right).unqualified.isSigned32Bit {
                        emitLine("sxtw \(rightReg.x), \(rightReg.w)")
                    }
                    if isFloat { emitLine("scvtf s\(rightReg.regNum), \(rightReg.x)") }
                    else { emitLine("scvtf d\(rightReg.regNum), \(rightReg.x)") }
                } else if exprType(b.right).unqualified == .float && !isFloat {
                    emitLine("fcvt d\(rightReg.regNum), s\(rightReg.regNum)")
                } else if exprType(b.right).unqualified == .double && isFloat {
                    emitLine("fcvt s\(rightReg.regNum), d\(rightReg.regNum)")
                }
                let realReg = regAlloc.alloc() ?? .x9
                emitLoadFP(realReg, offset: tmpOff, isFloat: isFloat)
                emitLine("fmul \(fpPrefix)\(realReg.regNum), \(fpPrefix)\(realReg.regNum), \(fpPrefix)\(rightReg.regNum)")
                emitStoreFP(realReg, offset: offset, isFloat: isFloat)
                emitLoadFP(realReg, offset: tmpOff + partSize, isFloat: isFloat)
                emitLine("fmul \(fpPrefix)\(realReg.regNum), \(fpPrefix)\(realReg.regNum), \(fpPrefix)\(rightReg.regNum)")
                emitStoreFP(realReg, offset: offset + partSize, isFloat: isFloat)
                regAlloc.free(realReg)
                regAlloc.free(rightReg)
            } else if !leftComplex && rightComplex {
                // real * complex: (r*a, r*b)
                let tmpOff = ensureTempSpace(size: partSize * 2)
                emitComplexExpr(b.right, storeAtOffset: tmpOff, isFloat: isFloat)
                let leftReg = emitExpr(b.left)
                if !exprType(b.left).unqualified.isFloating {
                    if exprType(b.left).unqualified.isSigned32Bit {
                        emitLine("sxtw \(leftReg.x), \(leftReg.w)")
                    }
                    if isFloat { emitLine("scvtf s\(leftReg.regNum), \(leftReg.x)") }
                    else { emitLine("scvtf d\(leftReg.regNum), \(leftReg.x)") }
                } else if exprType(b.left).unqualified == .float && !isFloat {
                    emitLine("fcvt d\(leftReg.regNum), s\(leftReg.regNum)")
                } else if exprType(b.left).unqualified == .double && isFloat {
                    emitLine("fcvt s\(leftReg.regNum), d\(leftReg.regNum)")
                }
                let realReg = regAlloc.alloc() ?? .x9
                emitLoadFP(realReg, offset: tmpOff, isFloat: isFloat)
                emitLine("fmul \(fpPrefix)\(realReg.regNum), \(fpPrefix)\(leftReg.regNum), \(fpPrefix)\(realReg.regNum)")
                emitStoreFP(realReg, offset: offset, isFloat: isFloat)
                emitLoadFP(realReg, offset: tmpOff + partSize, isFloat: isFloat)
                emitLine("fmul \(fpPrefix)\(realReg.regNum), \(fpPrefix)\(leftReg.regNum), \(fpPrefix)\(realReg.regNum)")
                emitStoreFP(realReg, offset: offset + partSize, isFloat: isFloat)
                regAlloc.free(realReg)
                regAlloc.free(leftReg)
            } else {
                // Both real (shouldn't produce complex result)
                let realReg = emitExpr(expr)
                emitStoreFP(realReg, offset: offset, isFloat: isFloat)
                let zeroReg = regAlloc.alloc() ?? .x9
                emitLine("fmov \(fpPrefix)\(zeroReg.regNum), #0.0")
                emitStoreFP(zeroReg, offset: offset + partSize, isFloat: isFloat)
                regAlloc.free(zeroReg)
            }

        case .cast(let c):
            // Cast of a complex expression — just forward
            emitComplexExpr(c.expr, storeAtOffset: offset, isFloat: isFloat)

        case .identifier(let id):
            // Copy from existing complex local variable
            if let srcOff = localVarOffsets[id.name] {
                let realReg = regAlloc.alloc() ?? .x9
                let imagReg = regAlloc.alloc() ?? .x10
                emitLoadFP(realReg, offset: srcOff, isFloat: isFloat)
                emitLoadFP(imagReg, offset: srcOff + partSize, isFloat: isFloat)
                emitStoreFP(realReg, offset: offset, isFloat: isFloat)
                emitStoreFP(imagReg, offset: offset + partSize, isFloat: isFloat)
                regAlloc.free(realReg)
                regAlloc.free(imagReg)
            }

        default:
            // Fallback: evaluate as real, store with imag=0
            let realReg = emitExpr(expr)
            emitStoreFP(realReg, offset: offset, isFloat: isFloat)
            let zeroReg = regAlloc.alloc() ?? .x9
            emitLine("fmov \(fpPrefix)\(zeroReg.regNum), #0.0")
            emitStoreFP(zeroReg, offset: offset + partSize, isFloat: isFloat)
            regAlloc.free(zeroReg)
        }
    }

    /// Allocate temporary stack space and return the offset (negative, relative to x29).
    private func ensureTempSpace(size: Int) -> Int {
        let aligned = (size + 7) & ~7  // align to 8 bytes
        localOffset += aligned
        if localOffset > frameSize { frameSize = localOffset }
        return -localOffset  // return the negative offset
    }

    private func emitStoreFP(_ reg: ARM64Reg, offset: Int, isFloat: Bool) {
        let fpReg = isFloat ? "s\(reg.regNum)" : "d\(reg.regNum)"
        if offset >= -256 && offset <= 255 {
            emitLine("str \(fpReg), [x29, #\(offset)]")
        } else {
            emitLoadImm("x16", Int64(offset))
            emitLine("str \(fpReg), [x29, x16]")
        }
    }

    private func emitLoadFP(_ reg: ARM64Reg, offset: Int, isFloat: Bool) {
        let fpReg = isFloat ? "s\(reg.regNum)" : "d\(reg.regNum)"
        if offset >= -256 && offset <= 255 {
            emitLine("ldr \(fpReg), [x29, #\(offset)]")
        } else {
            emitLoadImm("x16", Int64(offset))
            emitLine("ldr \(fpReg), [x29, x16]")
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
            // Determine the operand types to decide between integer and FP operations.
            // For arithmetic, the result type reflects the (possibly promoted) float type.
            // For comparisons, the result is int but the operands may be float.
            let leftType = exprType(b.left).unqualified
            let rightType = exprType(b.right).unqualified
            let isFloatOp = leftType.isFloating || rightType.isFloating
            // For arithmetic, result type determines s vs d register width.
            let resultType = exprType(.binary(b)).unqualified
            let isFloatResult = resultType.isFloating

            let leftReg = emitExpr(b.left)
            let rightReg = emitExpr(b.right)

            if isFloatOp {
                // Floating-point arithmetic: use d registers (or s for float).
                // For comparisons the result goes into an integer register.
                let isFloat = isFloatResult ? (resultType == .float) :
                              (leftType == .float && rightType == .float)

                // Implicit conversion: if one operand is int and the other is float,
                // convert the int operand to float (C usual arithmetic conversions).
                if !leftType.isFloating {
                    // left is int, convert to float
                    if leftType.isSigned32Bit {
                        emitLine("sxtw \(leftReg.x), \(leftReg.w)")
                    }
                    if isFloat {
                        emitLine("scvtf s\(leftReg.regNum), \(leftReg.x)")
                    } else {
                        emitLine("scvtf d\(leftReg.regNum), \(leftReg.x)")
                    }
                } else if leftType == .float && !isFloat {
                    // left is float but result is double: promote to double
                    emitLine("fcvt d\(leftReg.regNum), s\(leftReg.regNum)")
                } else if leftType == .double && isFloat {
                    // left is double but result is float: demote to float
                    emitLine("fcvt s\(leftReg.regNum), d\(leftReg.regNum)")
                }
                if !rightType.isFloating {
                    // right is int, convert to float
                    if rightType.isSigned32Bit {
                        emitLine("sxtw \(rightReg.x), \(rightReg.w)")
                    }
                    if isFloat {
                        emitLine("scvtf s\(rightReg.regNum), \(rightReg.x)")
                    } else {
                        emitLine("scvtf d\(rightReg.regNum), \(rightReg.x)")
                    }
                } else if rightType == .float && !isFloat {
                    emitLine("fcvt d\(rightReg.regNum), s\(rightReg.regNum)")
                } else if rightType == .double && isFloat {
                    emitLine("fcvt s\(rightReg.regNum), d\(rightReg.regNum)")
                }

                let lReg = isFloat ? "s\(leftReg.regNum)" : "d\(leftReg.regNum)"
                let rReg = isFloat ? "s\(rightReg.regNum)" : "d\(rightReg.regNum)"
                switch b.op {
                case .add: emitLine("fadd \(lReg), \(lReg), \(rReg)")
                case .sub: emitLine("fsub \(lReg), \(lReg), \(rReg)")
                case .mul: emitLine("fmul \(lReg), \(lReg), \(rReg)")
                case .div: emitLine("fdiv \(lReg), \(lReg), \(rReg)")
                case .eq:
                    emitLine("fcmp \(lReg), \(rReg)")
                    emitLine("cset \(leftReg.x), eq")
                case .ne:
                    emitLine("fcmp \(lReg), \(rReg)")
                    emitLine("cset \(leftReg.x), ne")
                case .lt:
                    emitLine("fcmp \(lReg), \(rReg)")
                    emitLine("cset \(leftReg.x), lt")
                case .le:
                    emitLine("fcmp \(lReg), \(rReg)")
                    emitLine("cset \(leftReg.x), le")
                case .gt:
                    emitLine("fcmp \(lReg), \(rReg)")
                    emitLine("cset \(leftReg.x), gt")
                case .ge:
                    emitLine("fcmp \(lReg), \(rReg)")
                    emitLine("cset \(leftReg.x), ge")
                default:
                    break
                }
                regAlloc.free(rightReg)
                return leftReg
            }

            // Determine if this is a signed 32-bit comparison.
            // C99: when comparing signed and unsigned of the same rank, both are
            // converted to unsigned. So if either operand is unsigned 32-bit,
            // the comparison is unsigned.
            let is32BitSigned: Bool = {
                switch leftType {
                case .int, .short, .schar, .char, .enumType:
                    // Check if right is unsigned 32-bit — if so, comparison is unsigned
                    switch rightType {
                    case .uint, .ushort, .uchar: return false
                    default: return true
                    }
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
                            emitLine("udiv \(leftReg.x), \(leftReg.x), x16")
                        }
                    }
                } else {
                    emitLine("sub \(leftReg.x), \(leftReg.x), \(rightReg.x)")
                }
            case .mul:
                emitLine("mul \(leftReg.x), \(leftReg.x), \(rightReg.x)")
            case .div:
                // Use udiv for unsigned types, sdiv for signed types
                if resultType.isUnsigned {
                    emitLine("udiv \(leftReg.x), \(leftReg.x), \(rightReg.x)")
                } else {
                    emitLine("sdiv \(leftReg.x), \(leftReg.x), \(rightReg.x)")
                }
            case .mod:
                // udiv/sdiv temp, left, right  → temp = left / right
                // msub left, temp, right, left  → left = left - temp * right
                // Need a scratch register since rightReg holds the divisor
                if resultType.isUnsigned {
                    emitLine("udiv x16, \(leftReg.x), \(rightReg.x)")
                } else {
                    emitLine("sdiv x16, \(leftReg.x), \(rightReg.x)")
                }
                emitLine("msub \(leftReg.x), x16, \(rightReg.x), \(leftReg.x)")
            case .shl:
                if resultType.sizeInBytes == 4 {
                    emitLine("lsl \(leftReg.w), \(leftReg.w), \(rightReg.w)")
                } else {
                    emitLine("lsl \(leftReg.x), \(leftReg.x), \(rightReg.x)")
                }
            case .shr:
                // Use lsr for unsigned, asr for signed
                if resultType.sizeInBytes == 4 {
                    if is32BitSigned {
                        emitLine("asr \(leftReg.w), \(leftReg.w), \(rightReg.w)")
                    } else {
                        emitLine("lsr \(leftReg.w), \(leftReg.w), \(rightReg.w)")
                    }
                } else {
                    if leftType.isUnsigned {
                        emitLine("lsr \(leftReg.x), \(leftReg.x), \(rightReg.x)")
                    } else {
                        emitLine("asr \(leftReg.x), \(leftReg.x), \(rightReg.x)")
                    }
                }
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
            // For structs, we can't load into a single register.
            // Return the address — the caller (e.g., struct init) will use emitAddr/emitStructCopy.
            if case .structType = pointedType.unqualified, (pointedType.sizeInBytes ?? 0) > 0 {
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
        let operandType = exprType(u.operand).unqualified

        switch u.op {
        case .neg:
            if operandType.isFloating {
                let fpReg = operandType == .float ? "s\(operandReg.regNum)" : "d\(operandReg.regNum)"
                emitLine("fneg \(fpReg), \(fpReg)")
            } else {
                emitLine("neg \(operandReg.x), \(operandReg.x)")
            }
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

            // Implicit conversion for compound assignment.
            // C standard: a op= b is equivalent to a = (a_type)((promoted_a) op b).
            // If target is float and rhs is double, promote target to double, operate
            // in double, then narrow back to float.
            let needDoubleOp = targetType == .float && valueType == .double
            if needDoubleOp {
                // Promote current value from float to double
                emitLine("fcvt d\(currentReg.regNum), s\(currentReg.regNum)")
            } else if targetType.isFloating && !valueType.isFloating {
                // int → float
                if valueType.isSigned32Bit {
                    emitLine("sxtw \(rhsReg.x), \(rhsReg.w)")
                }
                let fp = targetType == .float ? "s" : "d"
                emitLine("scvtf \(fp)\(rhsReg.regNum), \(rhsReg.x)")
            } else if targetType == .double && valueType == .float {
                emitLine("fcvt d\(rhsReg.regNum), s\(rhsReg.regNum)")
            }

            // The operation is done in the wider type (double if promoted)
            let opFp = needDoubleOp ? "d" : (targetType == .float ? "s" : "d")
            switch binaryOp {
            case .add:
                if targetType.isFloating {
                    emitLine("fadd \(opFp)\(currentReg.regNum), \(opFp)\(currentReg.regNum), \(opFp)\(rhsReg.regNum)")
                } else {
                    emitLine("add \(currentReg.x), \(currentReg.x), \(rhsReg.x)")
                }
            case .sub:
                if targetType.isFloating {
                    emitLine("fsub \(opFp)\(currentReg.regNum), \(opFp)\(currentReg.regNum), \(opFp)\(rhsReg.regNum)")
                } else {
                    emitLine("sub \(currentReg.x), \(currentReg.x), \(rhsReg.x)")
                }
            case .mul:
                if targetType.isFloating {
                    emitLine("fmul \(opFp)\(currentReg.regNum), \(opFp)\(currentReg.regNum), \(opFp)\(rhsReg.regNum)")
                } else {
                    emitLine("mul \(currentReg.x), \(currentReg.x), \(rhsReg.x)")
                }
            case .div:
                if targetType.isFloating {
                    emitLine("fdiv \(opFp)\(currentReg.regNum), \(opFp)\(currentReg.regNum), \(opFp)\(rhsReg.regNum)")
                } else if targetType.isUnsigned {
                    emitLine("udiv \(currentReg.x), \(currentReg.x), \(rhsReg.x)")
                } else {
                    emitLine("sdiv \(currentReg.x), \(currentReg.x), \(rhsReg.x)")
                }
            case .mod:
                // result = current - (current / rhs) * rhs
                let temp = regAlloc.alloc() ?? .x9
                if targetType.isUnsigned {
                    emitLine("udiv \(temp.x), \(currentReg.x), \(rhsReg.x)")
                } else {
                    emitLine("sdiv \(temp.x), \(currentReg.x), \(rhsReg.x)")
                }
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

            // Narrow result back to float if we promoted to double for the operation
            if needDoubleOp {
                emitLine("fcvt s\(currentReg.regNum), d\(currentReg.regNum)")
            }

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
        // Convert float type if needed (e.g., double→float for assignment to float var)
        let valueType = exprType(a.value).unqualified
        if valueType.isFloating && targetType.isFloating {
            convertFloat(valueReg, from: valueType, to: targetType)
        } else if valueType.isInteger && targetType.isFloating {
            // int → float/double
            if valueType.isSigned32Bit {
                emitLine("sxtw \(valueReg.x), \(valueReg.w)")
            }
            let fp = targetType == .float ? "s" : "d"
            emitLine("scvtf \(fp)\(valueReg.regNum), \(valueReg.x)")
        } else if valueType.isFloating && targetType.isInteger {
            // float/double → int
            let srcFp = valueType == .float ? "s" : "d"
            if targetType.isSigned32Bit {
                emitLine("fcvtzs \(valueReg.w), \(srcFp)\(valueReg.regNum)")
            } else {
                emitLine("fcvtzs \(valueReg.x), \(srcFp)\(valueReg.regNum)")
            }
        } else if valueType.isInteger && targetType.isInteger && valueType != targetType {
            // int-to-int conversion: sign-extend or zero-extend as needed
            let srcSize = valueType.sizeInBytes ?? 4
            let dstSize = targetType.sizeInBytes ?? 8
            if srcSize < dstSize {
                if valueType.isUnsigned {
                    // Zero-extend (e.g., unsigned int → long long)
                    if srcSize == 4 {
                        emitLine("mov w\(valueReg.regNum), w\(valueReg.regNum)")
                    }
                    // For 1/2 byte sources, the load already zero-extends
                } else {
                    // Sign-extend signed types (e.g., int → long long)
                    if srcSize == 4 {
                        emitLine("sxtw \(valueReg.x), \(valueReg.w)")
                    } else if srcSize == 2 {
                        emitLine("sxth \(valueReg.x), w\(valueReg.regNum)")
                    } else if srcSize == 1 {
                        emitLine("sxtb \(valueReg.x), w\(valueReg.regNum)")
                    }
                }
            }
        }
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
        // For float/double values, save/restore via the FP register (dN/sN).
        let targetType = exprType(target).unqualified
        let isFloatVal = targetType.isFloating
        if isFloatVal {
            let fpReg = targetType == .float ? "s\(reg.regNum)" : "d\(reg.regNum)"
            emitLine("str \(fpReg), [sp, #-16]!")
        } else {
            emitLine("str \(reg.x), [sp, #-16]!")
        }
        let addrReg = emitAddr(target)

        // Check if this is a struct assignment (needs multi-byte copy)
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
        } else if isFloatVal {
            // Restore the float value from the stack into a scratch FP register.
            // x16/x17 map to d16/d17 (or s16/s17) for FP scratch.
            let fpScratch: ARM64Reg = (addrReg == .x16) ? .x17 : .x16
            let fpLoad = targetType == .float ? "s\(fpScratch.regNum)" : "d\(fpScratch.regNum)"
            emitLine("ldr \(fpLoad), [sp, #0]")
            emitStoreToAddr(addrReg, fpScratch, type: targetType)
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

        // __builtin_expect(expr, expected) → just return expr
        if case .identifier(let id) = c.function, id.name == "__builtin_expect" {
            if c.arguments.count >= 1 {
                return emitExpr(c.arguments[0])
            }
            let reg = regAlloc.alloc() ?? .x9
            emitLine("mov \(reg.x), #0")
            return reg
        }

        // __builtin_offsetof(type, member) → compile-time constant
        if case .identifier(let id) = c.function, id.name == "__builtin_offsetof" {
            // Not commonly used, but handle gracefully
            let reg = regAlloc.alloc() ?? .x9
            emitLine("mov \(reg.x), #0")
            return reg
        }

        // __builtin_types_compatible_p(type1, type2) → compile-time 0 or 1
        if case .identifier(let id) = c.function, id.name == "__builtin_types_compatible_p" {
            let reg = regAlloc.alloc() ?? .x9
            emitLine("mov \(reg.x), #1") // assume compatible
            return reg
        }

        // Inline creal(z) / cimag(z) — extract real/imaginary part from a _Complex value
        if case .identifier(let id) = c.function,
           (id.name == "creal" || id.name == "cimag" || id.name == "crealf" || id.name == "cimagf" ||
            id.name == "creall" || id.name == "cimagl"),
           c.arguments.count >= 1 {
            let arg = c.arguments[0]
            let isFloat = id.name.hasSuffix("f")
            let isImagPart = id.name.hasPrefix("cimag")
            let partSize = isFloat ? 4 : 8
            let fpPrefix = isFloat ? "s" : "d"
            let reg = regAlloc.alloc() ?? .x9
            // If the argument is an identifier referencing a complex local variable,
            // load the part directly from the stack slot
            if case .identifier(let argId) = arg, let argOff = localVarOffsets[argId.name] {
                let partOff = argOff + (isImagPart ? partSize : 0)
                if partOff >= -256 && partOff <= 255 {
                    emitLine("ldr \(fpPrefix)\(reg.regNum), [x29, #\(partOff)]")
                } else {
                    emitLoadImm("x16", Int64(partOff))
                    emitLine("ldr \(fpPrefix)\(reg.regNum), [x29, x16]")
                }
            } else {
                // Evaluate the complex expression to a temp and extract the part
                let tmpOff = ensureTempSpace(size: partSize * 2)
                emitComplexExpr(arg, storeAtOffset: tmpOff, isFloat: isFloat)
                let partOff = tmpOff + (isImagPart ? partSize : 0)
                if partOff >= -256 && partOff <= 255 {
                    emitLine("ldr \(fpPrefix)\(reg.regNum), [x29, #\(partOff)]")
                } else {
                    emitLoadImm("x16", Int64(partOff))
                    emitLine("ldr \(fpPrefix)\(reg.regNum), [x29, x16]")
                }
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
            // Track sp before and after arg evaluation to account for stack-allocating
            // expressions (e.g., compound literals) that change sp.
            emitLine("str x19, [sp, #-16]!")
            emitLine("mov x19, sp")
            var namedArgRegs: [ARM64Reg] = []
            for i in 0..<min(namedCount, c.arguments.count) {
                let argReg = emitExpr(c.arguments[i])
                emitLine("str \(argReg.x), [sp, #-16]!")
                namedArgRegs.append(argReg)
                regAlloc.free(argReg)
            }

            // Evaluate variadic args, saving each to temp stack immediately
            var variadicArgRegs: [ARM64Reg] = []
            var variadicArgIsFloat: [Bool] = []  // track float args for correct store/load
            for i in namedCount..<c.arguments.count {
                let argType = exprType(c.arguments[i]).unqualified
                let isFloatArg = argType.isFloating
                variadicArgIsFloat.append(isFloatArg)
                let argReg = emitExpr(c.arguments[i])
                if isFloatArg {
                    // Variadic functions promote float to double (default argument promotion).
                    // Always save as double (8 bytes) so the load-back is correct.
                    if argType == .float {
                        emitLine("fcvt d\(argReg.regNum), s\(argReg.regNum)")
                    }
                    emitLine("str d\(argReg.regNum), [sp, #-16]!")
                } else {
                    emitLine("str \(argReg.x), [sp, #-16]!")
                }
                variadicArgRegs.append(argReg)
                regAlloc.free(argReg)
            }

            // Compute extra stack allocated during arg evaluation (e.g., compound literals).
            // x19 = sp before args. Current sp = sp after all pushes + extra allocations.
            // The pushes themselves account for (namedCount + numVariadicArgs) * 16 bytes.
            // x20 = extra = (x19 - sp) - pushes
            let numVariadicArgs = c.arguments.count - namedCount
            let totalPushSize = (min(namedCount, c.arguments.count) + numVariadicArgs) * 16
            emitLine("mov x9, sp")
            emitLine("sub x20, x19, x9")
            if totalPushSize > 0 {
                emitLine("sub x20, x20, #\(totalPushSize)")
            }

            // Variadic args go on the stack
            let inUse = scratchRegs.filter { reg in
                !regAlloc.available.contains(reg)
            }
            let variadicSize = (numVariadicArgs * 8 + 15) & ~15
            let spillCount = inUse.count + (inUse.count % 2)
            let spillSize = spillCount * 8
            let namedTempSize = namedCount * 16
            let variadicTempSize = numVariadicArgs * 16
            let totalSize = (variadicSize + spillSize + namedTempSize + variadicTempSize + 15) & ~15

            if totalSize > 0 {
                emitLine("sub sp, sp, #\(totalSize)")
            }
            // The temp stack layout (high to low):
            //   x19:                [x19 save]
            //   x19 - 16:            [named arg 0]
            //   ...                  [named arg namedCount-1]
            //   x19 - namedCount*16: [extra stack from compound literals, etc.]
            //   x19 - namedCount*16 - extra:  [variadic arg 0] (first variadic, highest)
            //   ...                  [variadic arg numVariadicArgs-1] (last pushed, lowest)
            //
            // After `sub sp, sp, totalSize`, sp is below all temp stack entries.
            // variadic arg[i] (last pushed = lowest) is at: sp + totalSize + (numVariadicArgs-1-i)*16
            // named arg[i] (first pushed = highest) is at: sp + totalSize + x20 + variadicTempSize + (namedCount-1-i)*16
            for i in 0..<numVariadicArgs {
                let tempOffset = totalSize + (numVariadicArgs - 1 - i) * 16
                if variadicArgIsFloat[i] {
                    emitLine("ldr d9, [sp, #\(tempOffset)]")
                    emitLine("str d9, [sp, #\(i * 8)]")
                } else {
                    emitLine("ldr x9, [sp, #\(tempOffset)]")
                    emitLine("str x9, [sp, #\(i * 8)]")
                }
            }
            // Place scratch spills above the variadic args
            for (idx, reg) in inUse.enumerated() {
                emitLine("str \(reg.x), [sp, #\(variadicSize + idx * 8)]")
            }

            // Restore named args from temp stack into their target registers.
            for i in 0..<min(namedCount, c.arguments.count) {
                let tempOffset = totalSize + variadicTempSize + (namedCount - 1 - i) * 16
                emitLine("add x21, sp, #\(tempOffset)")
                emitLine("ldr \(argRegs[i].x), [x21, x20]")
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
            // Free the temp stack for named args and variadic args
            for _ in 0..<(min(namedCount, c.arguments.count) + numVariadicArgs) {
                emitLine("add sp, sp, #16")
            }
            // Free extra stack allocated during arg evaluation (e.g., compound literals)
            emitLine("add sp, sp, x20")
            // Restore x19 (post-index pop: load then sp += 16)
            emitLine("ldr x19, [sp], #16")
        } else {
            // Non-variadic (or internal variadic): evaluate args and place in x0-x7
            // For internal variadic functions, push variadic args on the stack so
            // __builtin_va_start can point to them (handles both int and FP args).
            let isInternalVariadic = variadicFunctions.contains(funcName) && definedFunctions.contains(funcName)
            var namedParamCount = isInternalVariadic ? (functionParamCounts[funcName] ?? 0) : 0

            // For indirect variadic calls (function pointer to a variadic function),
            // detect the variadic-ness from the function pointer type.
            var isIndirectVariadic = false
            if funcName.isEmpty {
                var funcType = exprType(c.function).unqualified
                if case .unary(let u) = c.function, u.op == .dereference {
                    funcType = exprType(u.operand).unqualified
                }
                if case .pointer(let to) = funcType, case .function(let params, _, let variadic) = to.unqualified {
                    isIndirectVariadic = variadic
                    namedParamCount = params.count
                }
            }

            // For indirect calls (function pointer), evaluate the function expression first
            // and save it in a register that won't be clobbered by arg evaluation.
            var funcPtrReg: ARM64Reg? = nil
            if funcName.isEmpty {
                // Indirect call — evaluate the function expression to get a function pointer
                // Use a register outside the arg registers (x0-x7) to avoid clobbering
                // We'll use x16 (IP0) which is safe for inter-procedural calls
                // For *f (dereference of function pointer), just use f directly —
                // dereferencing a function pointer is a no-op in C.
                let fpReg: ARM64Reg
                if case .unary(let u) = c.function, u.op == .dereference {
                    fpReg = emitExpr(u.operand)
                } else {
                    fpReg = emitExpr(c.function)
                }
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
            var largeStructArgs: [Int: Int] = [:]  // indices of >16 byte struct args, value = num 8-byte chunks
            var floatArgs: Set<Int> = []  // indices of float/double args (go in d0-d7)
            var hfaArgs: [Int: (count: Int, isFloat: Bool)] = [:]  // HFA struct args
            let paramTypes = functionParamTypes[funcName] ?? []
            for (i, arg) in c.arguments.enumerated() {
                let argType = exprType(arg).unqualified
                // Use the declared parameter type to determine if the arg should be float.
                // This handles implicit int→float conversion for function calls (e.g., sin(2)).
                let paramType: CType? = i < paramTypes.count ? paramTypes[i].unqualified : nil
                let isFloatParam = paramType?.isFloating ?? false
                let isIntParam = paramType?.isInteger ?? false
                let argSize = argType.sizeInBytes ?? 8
                // For variadic args (past named params), do NOT use HFA — structs use integer ABI.
                let isVariadicArg = (isInternalVariadic || isIndirectVariadic) && i >= namedParamCount
                if let hfaInfo = isHFA(argType), !isVariadicArg {
                    // HFA struct: load each float/double member into FP registers
                    // Push hfaInfo.count slots on temp stack (one per FP register)
                    let addrReg = emitAddr(arg)
                    for j in 0..<hfaInfo.count {
                        // Push a placeholder slot
                        emitLine("str \(addrReg.x), [sp, #-16]!")
                    }
                    // Load each member and store to temp stack
                    let fpPrefix = hfaInfo.isFloat ? "s" : "d"
                    for j in 0..<hfaInfo.count {
                        let memberOffset = j * (hfaInfo.isFloat ? 4 : 8)
                        emitLine("ldr \(fpPrefix)16, [\(addrReg.x), #\(memberOffset)]")
                        // Store at the correct temp stack position
                        // The last-pushed slot is at sp+0, the first-pushed is at sp+(count-1)*16
                        let slotOffset = (hfaInfo.count - 1 - j) * 16
                        emitLine("str \(fpPrefix)16, [sp, #\(slotOffset)]")
                    }
                    evaluatedArgs.append(addrReg)
                    hfaArgs[i] = hfaInfo
                    regAlloc.free(addrReg)
                } else if case .structType = argType, argSize <= 8 {
                    // Small struct (≤8 bytes): load the struct value from its address
                    let addrReg = emitAddr(arg)
                    emitLine("str \(addrReg.x), [sp, #-16]!")  // placeholder
                    // Load the 8-byte (or smaller) struct value
                    emitLine("ldr x16, [\(addrReg.x)]")
                    emitLine("str x16, [sp, #0]")
                    evaluatedArgs.append(addrReg)
                    regAlloc.free(addrReg)
                } else if case .structType = argType, argSize > 8, argSize <= 16 {
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
                } else if case .structType = argType, argSize > 16 {
                    // Large struct (>16 bytes): copy all chunks to temp stack
                    let addrReg = emitAddr(arg)
                    let numChunks = (argSize + 7) / 8
                    // Push placeholder slots
                    for _ in 0..<numChunks {
                        emitLine("str \(addrReg.x), [sp, #-16]!")
                    }
                    // Load each 8-byte chunk and store to temp stack
                    // Last-pushed slot is at sp+0, first-pushed is at sp+(numChunks-1)*16
                    for j in 0..<numChunks {
                        emitLine("ldr x16, [\(addrReg.x), #\(j * 8)]")
                        let slotOffset = (numChunks - 1 - j) * 16
                        emitLine("str x16, [sp, #\(slotOffset)]")
                    }
                    evaluatedArgs.append(addrReg)
                    largeStructArgs[i] = numChunks
                    regAlloc.free(addrReg)
                } else if argType.isFloating && isIntParam {
                    // Float arg but int param: convert float→int
                    let argReg = emitExpr(arg)
                    let srcFp = argType == .float ? "s" : "d"
                    if let pt = paramType, pt.isSigned32Bit {
                        emitLine("fcvtzs \(argReg.w), \(srcFp)\(argReg.regNum)")
                    } else {
                        emitLine("fcvtzs \(argReg.x), \(srcFp)\(argReg.regNum)")
                    }
                    emitLine("str \(argReg.x), [sp, #-16]!")
                    evaluatedArgs.append(argReg)
                    regAlloc.free(argReg)
                } else if argType.isFloating {
                    // Float/double arg: convert to param type if needed, save to temp stack.
                    // Always save as 8 bytes (double) for consistent load-back.
                    let argReg = emitExpr(arg)
                    if isFloatParam, let pt = paramType, pt != argType {
                        convertFloat(argReg, from: argType, to: pt)
                    }
                    // If the value is float (4 bytes), promote to double for storage
                    let saveType = isFloatParam ? paramType! : argType
                    if saveType == .float {
                        emitLine("fcvt d\(argReg.regNum), s\(argReg.regNum)")
                    }
                    emitLine("str d\(argReg.regNum), [sp, #-16]!")
                    evaluatedArgs.append(argReg)
                    floatArgs.insert(i)
                    regAlloc.free(argReg)
                } else if isFloatParam {
                    // Int arg but float param: convert int→float, promote to double for storage
                    let argReg = emitExpr(arg)
                    if argType.isSigned32Bit {
                        emitLine("sxtw \(argReg.x), \(argReg.w)")
                    }
                    if paramType == .float {
                        emitLine("scvtf s\(argReg.regNum), \(argReg.x)")
                        emitLine("fcvt d\(argReg.regNum), s\(argReg.regNum)")
                    } else {
                        emitLine("scvtf d\(argReg.regNum), \(argReg.x)")
                    }
                    emitLine("str d\(argReg.regNum), [sp, #-16]!")
                    evaluatedArgs.append(argReg)
                    floatArgs.insert(i)
                    regAlloc.free(argReg)
                } else {
                    let argReg = emitExpr(arg)
                    // Sign-extend 32-bit signed int to 64-bit for wide parameters
                    // (e.g., int -1 passed to i64 parameter must become -1, not 0xFFFFFFFF)
                    if argType.isSigned32Bit {
                        if let pt = paramType, pt.sizeInBytes == 8 {
                            emitLine("sxtw \(argReg.x), \(argReg.w)")
                        } else if paramType == nil {
                            // Variadic function: always sign-extend signed 32-bit ints
                            emitLine("sxtw \(argReg.x), \(argReg.w)")
                        }
                    }
                    // Save the result on the stack to preserve it across subsequent arg evaluation
                    emitLine("str \(argReg.x), [sp, #-16]!")
                    evaluatedArgs.append(argReg)
                    regAlloc.free(argReg)
                }
            }

            // For internal variadic functions: variadic args need to be on the stack
            // at sp when bl is executed (so callee's va_start at x29+16 can read them).

            // Count stack-passed args (register index >= 8, wide args use 2 slots)
            // For HFA: if it fits in remaining FP regs, it uses FP reg slots.
            // If it doesn't fit, the ENTIRE HFA goes on the stack (hfaCount slots).
            var totalRegSlots = 0
            var fpSlotsUsed = 0
            var largeStructStackSlots = 0  // large structs always go on stack
            for i in 0..<evaluatedArgs.count {
                if wideArgs.contains(i) { totalRegSlots += 2 }
                else if let largeChunks = largeStructArgs[i], largeChunks > 0 {
                    // Large structs (>16 bytes) always go on stack, don't use register slots
                    largeStructStackSlots += largeChunks
                }
                else if let hfaInfo = hfaArgs[i] {
                    if fpSlotsUsed + hfaInfo.count <= 8 {
                        fpSlotsUsed += hfaInfo.count
                        totalRegSlots += hfaInfo.count
                    } else {
                        // Entire HFA goes on stack
                        totalRegSlots += hfaInfo.count
                    }
                } else { totalRegSlots += 1 }
            }
            // For internal variadic: variadic args go on the stack (not just overflow)
            let numStackArgs: Int
            if isInternalVariadic && evaluatedArgs.count > namedParamCount {
                numStackArgs = evaluatedArgs.count - namedParamCount
            } else {
                numStackArgs = max(totalRegSlots - 8, 0)
            }
            // Compute actual stack size for variadic args (structs may need 16 bytes each)
            var stackArgSize = 0
            if isInternalVariadic && evaluatedArgs.count > namedParamCount {
                var variadicSize = 0
                for i in namedParamCount..<evaluatedArgs.count {
                    let argType = exprType(c.arguments[i]).unqualified
                    let argSize = argType.sizeInBytes ?? 8
                    variadicSize += (argSize + 7) & ~7  // round up to 8
                }
                stackArgSize = (variadicSize + 15) & ~15  // align to 16
            } else {
                stackArgSize = ((numStackArgs + largeStructStackSlots) * 8 + 15) & ~15
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
                let hfaCount = hfaArgs[i]?.count ?? 0
                let largeChunks = largeStructArgs[i] ?? 0
                let slotSize: Int
                if wideArgs.contains(i) { slotSize = 32 }
                else if largeChunks > 0 { slotSize = largeChunks * 16 }
                else if hfaCount > 0 { slotSize = hfaCount * 16 }
                else { slotSize = 16 }
                argSlotOffsets.insert(cumulative, at: 0)
                cumulative += slotSize
            }

            // Track current register index (wide args consume 2 registers)
            // Iterate forward (i=0 to N-1): arg[0] goes to x0, arg[1] to x1, etc.
            // arg[0] is at the highest temp offset (pushed first), arg[N-1] at lowest.
            // Float args use a separate register file (d0-d7) with an independent index.
            var regIdx = 0
            var fpRegIdx = 0
            var stackArgIdx = 0  // tracks stack-passed arg slots
            var variadicStackOffset = 0  // tracks byte offset for variadic args on stack
            for i in 0..<numArgs {
                let tempOffset = tempBase + argSlotOffsets[i]
                let isWide = wideArgs.contains(i)
                let isLargeStruct = largeStructArgs[i] ?? 0 > 0
                let largeChunks = largeStructArgs[i] ?? 0
                let isFloatArg = floatArgs.contains(i)
                let isHFAArg = hfaArgs[i] != nil
                let regsNeeded = isWide ? 2 : (largeChunks > 0 ? largeChunks : 1)

                // For internal variadic: named params go in registers, variadic args go on stack
                let isVariadicArg = isInternalVariadic && i >= namedParamCount
                if isVariadicArg {
                    let argSize = exprType(c.arguments[i]).unqualified.sizeInBytes ?? 8
                    let slotSize = (argSize + 7) & ~7  // round up to 8
                    let stackOffset = variadicStackOffset
                    variadicStackOffset += slotSize
                    if isWide {
                        // chunk 0 (first 8 bytes) is at tempOffset+16, chunk 1 at tempOffset
                        // Place chunk 0 at stackOffset (low), chunk 1 at stackOffset+8 (high)
                        emitLine("ldr x9, [sp, #\(tempOffset + 16)]")
                        emitLine("str x9, [sp, #\(stackOffset)]")
                        emitLine("ldr x9, [sp, #\(tempOffset)]")
                        emitLine("str x9, [sp, #\(stackOffset + 8)]")
                    } else if largeChunks > 0 {
                        // Temp stack has chunk 0 at highest offset, chunk N-1 at lowest.
                        // Place chunk 0 at stackOffset (low), chunk N-1 at highest.
                        for j in 0..<largeChunks {
                            let slotOff = tempOffset + j * 16
                            emitLine("ldr x9, [sp, #\(slotOff)]")
                            emitLine("str x9, [sp, #\(stackOffset + (largeChunks - 1 - j) * 8)]")
                        }
                    } else if isFloatArg {
                        emitLine("ldr d9, [sp, #\(tempOffset)]")
                        emitLine("str d9, [sp, #\(stackOffset)]")
                    } else {
                        emitLine("ldr x9, [sp, #\(tempOffset)]")
                        emitLine("str x9, [sp, #\(stackOffset)]")
                    }
                    regAlloc.free(evaluatedArgs[i])
                    regIdx += regsNeeded
                    continue
                }

                if isFloatArg {
                    // Float/double arg goes in d0-d7
                    // The value was saved as double; convert back to float if param is float.
                    let paramTypes = functionParamTypes[funcName] ?? []
                    let isFloatParam = i < paramTypes.count && paramTypes[i].unqualified == .float
                    if fpRegIdx < 8 {
                        emitLine("ldr d\(fpRegIdx), [sp, #\(tempOffset)]")
                        if isFloatParam {
                            emitLine("fcvt s\(fpRegIdx), d\(fpRegIdx)")
                        }
                    } else {
                        // Overflow: float arg goes on stack
                        let stackOffset = stackArgIdx * 8
                        if isFloatParam {
                            emitLine("ldr d9, [sp, #\(tempOffset)]")
                            emitLine("fcvt s9, d9")
                            emitLine("str s9, [sp, #\(stackOffset)]")
                        } else {
                            emitLine("ldr d9, [sp, #\(tempOffset)]")
                            emitLine("str d9, [sp, #\(stackOffset)]")
                        }
                        stackArgIdx += 1
                    }
                    regAlloc.free(evaluatedArgs[i])
                    fpRegIdx += 1
                    continue
                }

                if isHFAArg, let hfaInfo = hfaArgs[i] {
                    // HFA: load each member into FP registers (d0-d7 or s0-s7)
                    // AAPCS64: if the entire HFA doesn't fit in remaining FP regs,
                    // the entire HFA goes on the stack.
                    let fpPrefix = hfaInfo.isFloat ? "s" : "d"
                    let memberSize = hfaInfo.isFloat ? 4 : 8
                    if fpRegIdx + hfaInfo.count <= 8 {
                        // Fits entirely in FP registers
                        for j in 0..<hfaInfo.count {
                            let slotOff = tempOffset + (hfaInfo.count - 1 - j) * 16
                            emitLine("ldr \(fpPrefix)\(fpRegIdx), [sp, #\(slotOff)]")
                            fpRegIdx += 1
                        }
                    } else {
                        // Entire HFA goes on the stack
                        for j in 0..<hfaInfo.count {
                            let slotOff = tempOffset + (hfaInfo.count - 1 - j) * 16
                            let stackOff = stackArgIdx * 8
                            emitLine("ldr d9, [sp, #\(slotOff)]")
                            if hfaInfo.isFloat {
                                emitLine("str s9, [sp, #\(stackOff)]")
                            } else {
                                emitLine("str d9, [sp, #\(stackOff)]")
                            }
                            stackArgIdx += 1
                        }
                        regAlloc.free(evaluatedArgs[i])
                        regIdx += hfaInfo.count
                        continue
                    }
                    regAlloc.free(evaluatedArgs[i])
                    regIdx += hfaInfo.count  // HFA also consumes integer register slots
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
                            emitLine("str x9, [sp, #\(stackArgIdx * 8)]")
                            emitLine("ldr \(argRegs[regIdx].x), [sp, #\(tempOffset + 16)]")
                            stackArgIdx += 1
                        }
                    } else if largeChunks > 0 {
                        // Large struct: goes entirely on stack (too big for registers)
                        for j in 0..<largeChunks {
                            let slotOff = tempOffset + j * 16
                            emitLine("ldr x9, [sp, #\(slotOff)]")
                            emitLine("str x9, [sp, #\((stackArgIdx + (largeChunks - 1 - j)) * 8)]")
                        }
                        stackArgIdx += largeChunks
                    } else {
                        emitLine("ldr x9, [sp, #\(tempOffset)]")
                        emitLine("mov \(argRegs[regIdx].x), x9")
                    }
                    regAlloc.free(evaluatedArgs[i])
                } else {
                    // Stack-passed args
                    let stackOffset = stackArgIdx * 8
                    if isWide {
                        // chunk 0 (first 8 bytes) at tempOffset+16, chunk 1 at tempOffset
                        // Place chunk 0 at stackOffset (low), chunk 1 at stackOffset+8 (high)
                        emitLine("ldr x9, [sp, #\(tempOffset + 16)]")
                        emitLine("str x9, [sp, #\(stackOffset)]")
                        emitLine("ldr x9, [sp, #\(tempOffset)]")
                        emitLine("str x9, [sp, #\(stackOffset + 8)]")
                        stackArgIdx += 2
                    } else if largeChunks > 0 {
                        for j in 0..<largeChunks {
                            let slotOff = tempOffset + j * 16
                            emitLine("ldr x9, [sp, #\(slotOff)]")
                            emitLine("str x9, [sp, #\(stackOffset + (largeChunks - 1 - j) * 8)]")
                        }
                        stackArgIdx += largeChunks
                    } else {
                        emitLine("ldr x9, [sp, #\(tempOffset)]")
                        emitLine("str x9, [sp, #\(stackOffset)]")
                        stackArgIdx += 1
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

        // Result is in x0 (int), s0 (float), or d0 (double)
        let resultReg = regAlloc.alloc() ?? .x9
        let callReturnType = exprType(.call(c)).unqualified
        if callReturnType.isFloating {
            let fpPrefix = callReturnType == .float ? "s" : "d"
            if resultReg != .x0 {
                emitLine("fmov \(fpPrefix)\(resultReg.regNum), \(fpPrefix)0")
            }
        } else {
            if resultReg != .x0 {
                emitLine("mov \(resultReg.x), x0")
            }
        }
        return resultReg
    }

    // MARK: - Type inference for codegen

    /// Determine the type of an expression (for computing offsets, element sizes, etc.)
    private func exprType(_ expr: Expr) -> CType {
        switch expr {
        case .integerLiteral(let l): return l.type
        case .charLiteral: return .int
        case .floatLiteral(let f):
            if f.isImaginary {
                switch f.type {
                case .float: return .complexFloat
                case .double: return .complexDouble
                case .longDouble: return .complexLongDouble
                default: return .complexDouble
                }
            }
            return f.type
        case .stringLiteral(let s): return s.type
        case .boolLiteral: return .bool
        case .identifier(let id):
            if let t = localVarTypes[id.name] { return t }
            if let t = globalVarTypes[id.name] { return t }
            // Function name → function type (decays to function pointer in _Generic)
            if functionNames.contains(id.name) {
                let params = functionParamTypes[id.name] ?? []
                let ret = functionReturnTypes[id.name] ?? .int
                let isVariadic = variadicFunctions.contains(id.name)
                return .function(params: params, returnType: ret, variadic: isVariadic)
            }
            return .int
        case .binary(let b):
            // Comparison and logical operators always return int (C standard)
            switch b.op {
            case .eq, .ne, .lt, .le, .gt, .ge, .logicAnd, .logicOr:
                return .int
            default: break
            }
            // For pointer arithmetic, result type is the pointer type
            let lt = exprType(b.left)
            let rt = exprType(b.right)
            if lt.isPointer && rt.isInteger { return lt }
            if lt.isInteger && rt.isPointer { return rt }
            // Shift operators: result type is the promoted left operand
            if b.op == .shl || b.op == .shr {
                let lu = lt.unqualified
                // Integer promotion: char/short → int
                if lu == .char || lu == .schar || lu == .uchar || lu == .short || lu == .ushort {
                    return .int
                }
                return lt
            }
            // Apply usual arithmetic conversions to determine result type.
            let lu = lt.unqualified
            let ru = rt.unqualified
            if lu.isArithmetic && ru.isArithmetic {
                // Complex type rules (C99 6.3.1.8)
                if lu == .complexLongDouble || ru == .complexLongDouble { return .complexLongDouble }
                if lu == .complexDouble || ru == .complexDouble { return .complexDouble }
                if lu == .complexFloat || ru == .complexFloat { return .complexFloat }
                // Floating-point usual arithmetic conversions
                if lu == .longDouble || ru == .longDouble { return .longDouble }
                if lu == .double || ru == .double { return .double }
                if lu == .float || ru == .float { return .float }
                // Integer ranks: longLong > long > int > short > char
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
                if rank(lu) >= 2 || rank(ru) >= 2 { return rank(lu) >= rank(ru) ? lu : ru }
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
            // For function pointer calls (e.g., x->func(), (*fp)()),
            // determine the return type from the function pointer's type
            let funcType = exprType(c.function).unqualified
            if case .function(_, let ret, _) = funcType { return ret }
            if case .pointer(let to) = funcType {
                if case .function(_, let ret, _) = to.unqualified { return ret }
            }
            return .int
        case .subscript_(let s):
            let bt = exprType(s.base)
            if case .pointer(let to) = bt.unqualified { return to }
            if case .array(let elem, _) = bt.unqualified { return elem }
            if case .incompleteArray(let elem) = bt.unqualified { return elem }
            return .int
        case .member(let m):
            let bt = exprType(m.base)
            var recordType = bt.unqualified
            if m.isArrow {
                if case .pointer(let to) = bt.unqualified { recordType = to }
                else if case .array(let to, _) = bt.unqualified { recordType = to }
                else if case .incompleteArray(let to) = bt.unqualified { recordType = to }
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
                for field in rec.fields {
                    if (field.name ?? "") == m.memberName { return field.type }
                    if (field.name ?? "").isEmpty {
                        if fieldHasMember(field.type, m.memberName) {
                            return findMemberType(field.type, m.memberName)
                        }
                    }
                }
            }
            if case .unionType(let rec) = recordType.unqualified {
                for field in rec.fields {
                    if (field.name ?? "") == m.memberName { return field.type }
                    if (field.name ?? "").isEmpty {
                        if fieldHasMember(field.type, m.memberName) {
                            return findMemberType(field.type, m.memberName)
                        }
                    }
                }
            }
            return .int
        case .cast(let c):
            return c.type
        case .conditional(let c):
            let t = exprType(c.trueExpr)
            let f = exprType(c.falseExpr)
            let tu = t.unqualified
            let fu = f.unqualified
            if tu == fu { return t }
            // One side is a pointer, the other is 0 (null pointer constant)
            if tu.isPointer && fu.isInteger { return t }
            if fu.isPointer && tu.isInteger { return f }
            if tu.isPointer && fu.isPointer {
                if case .pointer(let to) = tu, to.unqualified == .void { return t }
                if case .pointer(let to) = fu, to.unqualified == .void { return f }
                return t
            }
            // Arithmetic conversion
            if tu.isArithmetic && fu.isArithmetic {
                if tu == .longDouble || fu == .longDouble { return .longDouble }
                if tu == .double || fu == .double { return .double }
                if tu == .float || fu == .float { return .float }
            }
            return t
        case .sizeof:
            return .ulong
        case .compoundLiteral(let cl):
            return cl.type
        case .initList:
            return .int
        case .genericExpr(let ge):
            // Evaluate the controlling expression and return the selected branch's type
            let ctrlType = exprType(ge.controllingExpr).unqualified
            for assoc in ge.associations {
                if assoc.isDefault { continue }
                if let tn = assoc.typeName, typeMatches(ctrlType, tn.unqualified) {
                    return exprType(assoc.expr)
                }
            }
            for assoc in ge.associations where assoc.isDefault {
                return exprType(assoc.expr)
            }
            return .int
        case .stmtExpr(let se):
            if let lastStmt = se.body.statements.last,
               case .expr(let es) = lastStmt, let e = es.expr {
                return exprType(e)
            }
            return .int
        }
    }

    /// Count the number of scalar fields in a struct (recursively for nested structs and arrays).
    private func countScalarFields(_ rec: RecordType) -> Int {
        var count = 0
        for field in rec.fields {
            let ft = field.type.unqualified
            if case .structType(let subRec) = ft {
                count += countScalarFields(subRec)
            } else if case .array(_, let arrCount) = ft {
                count += arrCount
            } else {
                count += 1
            }
        }
        return count
    }

    /// Strip all qualifiers recursively (including pointee qualifiers) from a type.
    private func stripAllQualifiers(_ type: CType) -> CType {
        let t = type.unqualified
        switch t {
        case .pointer(let to):
            return .pointer(to: stripAllQualifiers(to))
        case .qualified(let base, _, _, _):
            return stripAllQualifiers(base)
        default:
            return t
        }
    }

    /// Check if two types match for _Generic (respects qualifiers on pointee types)
    private func typeMatches(_ a: CType, _ b: CType) -> Bool {
        var au = a.unqualified
        var bu = b.unqualified
        // Array decays to pointer in _Generic
        if case .array(let elem, _) = au { au = .pointer(to: elem) }
        if case .incompleteArray(let elem) = au { au = .pointer(to: elem) }
        if case .array(let elem, _) = bu { bu = .pointer(to: elem) }
        if case .incompleteArray(let elem) = bu { bu = .pointer(to: elem) }
        // Function decays to function pointer in _Generic
        if case .function = au { au = .pointer(to: au) }
        if case .function = bu { bu = .pointer(to: bu) }
        if au == bu { return true }
        // Match struct types by name
        if case .structType(let ra) = au, case .structType(let rb) = bu {
            return ra.name == rb.name
        }
        if case .unionType(let ra) = au, case .unionType(let rb) = bu {
            return ra.name == rb.name
        }
        // Match pointer types — check pointee types (with qualifiers)
        if case .pointer(let ta) = au, case .pointer(let tb) = bu {
            // For pointers, compare pointee types including qualifiers
            let taU = ta.unqualified
            let tbU = tb.unqualified
            if taU == tbU {
                // Check if qualifiers match (const/volatile on pointee)
                let aIsConst = ta.isConst
                let bIsConst = tb.isConst
                return aIsConst == bIsConst
            }
            return typeMatches(taU, tbU)
        }
        return false
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
    /// Find the type of a named member (recursively for anonymous members)
    private func findMemberType(_ type: CType, _ memberName: String) -> CType {
        let t = type.unqualified
        if case .structType(let rec) = t {
            for field in rec.fields {
                if (field.name ?? "") == memberName { return field.type }
                if (field.name ?? "").isEmpty, fieldHasMember(field.type, memberName) {
                    return findMemberType(field.type, memberName)
                }
            }
        }
        if case .unionType(let rec) = t {
            for field in rec.fields {
                if (field.name ?? "") == memberName { return field.type }
                if (field.name ?? "").isEmpty, fieldHasMember(field.type, memberName) {
                    return findMemberType(field.type, memberName)
                }
            }
        }
        return .int
    }

    /// Check if a type is an HFA (Homogeneous Floating-point Aggregate).
    /// Returns (count, isFloat) if it is, nil otherwise.
    /// An HFA is a struct with 1-4 members all of the same FP type (float or double).
    private func isHFA(_ type: CType) -> (count: Int, isFloat: Bool)? {
        let t = type.unqualified
        guard case .structType(let rec) = t else { return nil }
        let fields = rec.fields
        guard fields.count >= 1, fields.count <= 4 else { return nil }
        var isFloat = false
        var isDouble = false
        for field in fields {
            let ft = field.type.unqualified
            if ft == .float { isFloat = true }
            else if ft == .double || ft == .longDouble { isDouble = true }
            else { return nil }  // Not a floating-point member
        }
        if isFloat && !isDouble { return (count: fields.count, isFloat: true) }
        if isDouble && !isFloat { return (count: fields.count, isFloat: false) }
        return nil
    }

    /// Check if a record type has a named member (recursively for anonymous members)
    private func fieldHasMember(_ type: CType, _ memberName: String) -> Bool {
        let t = type.unqualified
        if case .structType(let rec) = t {
            for field in rec.fields {
                if (field.name ?? "") == memberName { return true }
                if (field.name ?? "").isEmpty, fieldHasMember(field.type, memberName) { return true }
            }
        }
        if case .unionType(let rec) = t {
            for field in rec.fields {
                if (field.name ?? "") == memberName { return true }
                if (field.name ?? "").isEmpty, fieldHasMember(field.type, memberName) { return true }
            }
        }
        return false
    }

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
            for field in rec.fields {
                if (field.name ?? "") == memberName {
                    return field.offset
                }
                // Anonymous struct/union member: search recursively
                if (field.name ?? "").isEmpty {
                    let ft = field.type.unqualified
                    switch ft {
                        case .structType, .unionType:
                            let subOffset = memberOffset(field.type, memberName)
                            if subOffset != 0 || fieldHasMember(field.type, memberName) {
                                return field.offset + subOffset
                            }
                        default: break
                        }
                }
            }
        }
        if case .unionType(let rec) = t {
            for field in rec.fields {
                if (field.name ?? "") == memberName {
                    return field.offset
                }
                // Anonymous struct/union member: search recursively
                if (field.name ?? "").isEmpty {
                    let ft = field.type.unqualified
                    switch ft {
                        case .structType, .unionType:
                            let subOffset = memberOffset(field.type, memberName)
                            if subOffset != 0 || fieldHasMember(field.type, memberName) {
                                return field.offset + subOffset
                            }
                        default: break
                        }
                }
            }
        }
        return 0
    }

    /// Look up bitfield info for a struct member.
    /// Returns (bitWidth, bitOffsetWithinUnit, unitSizeInBytes, isSigned) or nil if not a bitfield.
    /// bitOffsetWithinUnit is the bit position of the field within its containing unit.
    private func bitfieldInfo(_ baseType: CType, _ memberName: String) -> (bitWidth: Int, bitOffset: Int, unitSize: Int, isSigned: Bool)? {
        var t = baseType.unqualified
        if case .pointer(let to) = t { t = to.unqualified }
        if case .structType(let rec) = t {
            if rec.fields.isEmpty, let completed = knownRecords[rec.name] {
                t = .structType(completed)
            }
        }
        if case .structType(let rec) = t {
            for field in rec.fields where (field.name ?? "") == memberName {
                guard let bw = field.bitWidth else { return nil }
                // Determine the containing unit size from the field type
                let unitSize = field.type.unqualified.sizeInBytes ?? 4
                // Determine if the field is signed.
                // Enum bitfields are treated as unsigned by default on ARM64 (GCC behavior).
                let fieldBaseType = field.type.unqualified
                let isSigned: Bool
                if case .enumType = fieldBaseType {
                    isSigned = false
                } else {
                    isSigned = !fieldBaseType.isUnsigned
                }
                // Use the bitOffset stored in the field (bit position within containing unit)
                return (bw, field.bitOffset, unitSize, isSigned)
            }
        }
        return nil
    }

    /// Convert a float/double value in a register from one FP type to another.
    /// Handles double→float (fcvt s, d) and float→double (fcvt d, s).
    private func convertFloat(_ reg: ARM64Reg, from: CType, to: CType) {
        let ft = from.unqualified
        let tt = to.unqualified
        if ft == tt { return }
        if ft == .double && tt == .float {
            emitLine("fcvt s\(reg.regNum), d\(reg.regNum)")
        } else if ft == .float && (tt == .double || tt == .longDouble) {
            emitLine("fcvt d\(reg.regNum), s\(reg.regNum)")
        }
    }

    /// Emit the address of an lvalue expression (without loading its value).
    /// Returns the register holding the address.
    private func emitAddr(_ expr: Expr) -> ARM64Reg {
        switch expr {
        case .identifier(let id):
            let reg = regAlloc.alloc() ?? .x9
            if vlaBasePointers.contains(id.name), let offset = localVarOffsets[id.name] {
                // VLA base pointer: load the pointer value from the local variable
                if offset >= -256 && offset <= 255 {
                    emitLine("ldr \(reg.x), [x29, #\(offset)]")
                } else {
                    emitLoadImm("x17", Int64(offset))
                    emitLine("ldr \(reg.x), [x29, x17]")
                }
            } else if let offset = localVarOffsets[id.name] {
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
            } else if functionNames.contains(id.name) {
                // Function name — take its address
                emitLine("adrp \(reg.x), _\(id.name)@PAGE")
                emitLine("add \(reg.x), \(reg.x), _\(id.name)@PAGEOFF")
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
            } else if case .incompleteArray = baseTypeFull,
                      case .identifier(let id) = s.base,
                      vlaBasePointers.contains(id.name) {
                // VLA subscript: load the base pointer value
                baseReg = emitExpr(s.base)
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

            // Check for multi-dimensional VLA: if the base is a VLA and the element
            // type is also an incompleteArray, compute stride at runtime.
            if case .incompleteArray(let innerElemType) = elemType.unqualified,
               case .identifier(let id) = s.base,
               vlaBasePointers.contains(id.name),
               let innerDims = vlaInnerDims[id.name], !innerDims.isEmpty {
                // Multi-dimensional VLA subscript: stride = inner_dim * inner_elem_size
                // The first inner dimension determines the row stride.
                let dimName = innerDims[0]
                let dimOffset = localVarOffsets[dimName] ?? 0
                // Load the inner dimension value
                if dimOffset >= -256 && dimOffset <= 255 {
                    emitLine("ldr w16, [x29, #\(dimOffset)]")
                } else {
                    emitLoadImm("x17", Int64(dimOffset))
                    emitLine("ldr w16, [x29, x17]")
                }
                // Sign-extend the dimension
                emitLine("sxtw x16, w16")
                // stride = index * inner_dim
                emitLine("mul \(indexReg.x), \(indexReg.x), x16")
                // Multiply by inner element size
                let innerElemSize = innerElemType.unqualified.sizeInBytes ?? 4
                if innerElemSize == 4 {
                    emitLine("add \(baseReg.x), \(baseReg.x), \(indexReg.x), lsl #2")
                } else if innerElemSize == 8 {
                    emitLine("add \(baseReg.x), \(baseReg.x), \(indexReg.x), lsl #3")
                } else if innerElemSize == 2 {
                    emitLine("add \(baseReg.x), \(baseReg.x), \(indexReg.x), lsl #1")
                } else if innerElemSize == 1 {
                    emitLine("add \(baseReg.x), \(baseReg.x), \(indexReg.x)")
                } else {
                    emitLoadImm("x17", Int64(innerElemSize))
                    emitLine("madd \(baseReg.x), \(indexReg.x), x17, \(baseReg.x)")
                }
                regAlloc.free(indexReg)
                return baseReg
            }

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

    /// Try to get the address of an lvalue expression. Returns nil if the expression
    /// is not an lvalue (cannot take its address). Handles casts by stripping them.
    private func emitAddrOrNil(_ expr: Expr) -> ARM64Reg? {
        switch expr {
        case .identifier, .subscript_, .member:
            return emitAddr(expr)
        case .unary(let u) where u.op == .dereference:
            return emitExpr(u.operand)
        case .cast(let c):
            // Cast to the same type — get address of the inner expression
            return emitAddrOrNil(c.expr)
        default:
            return nil
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
        // If element type is an array (including incompleteArray/VLA), return address (array decays to pointer)
        if case .array = elemType.unqualified {
            return addrReg
        }
        if case .incompleteArray = elemType.unqualified {
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
            // Sign-extend for signed bitfields
            if bf.isSigned && bf.bitWidth < 64 {
                // Test the sign bit (bit bitWidth-1). If set, sign-extend.
                // sbfx extracts and sign-extends: sbfx xReg, xReg, #lsb, #width
                // But we already shifted to bit 0, so we can use sbfx from bit 0
                emitLine("sbfx \(addrReg.x), \(addrReg.x), #0, #\(bf.bitWidth)")
            }
            return addrReg
        }
        // Handle member access on a function call returning a struct (e.g., fr_hfa11().a)
        // The struct return is in registers (s0-s3/d0-d3 for HFA, x0-x1 for small struct),
        // so we need to store it to a temp, load the member, then free the temp.
        if case .call = m.base, case .structType = exprType(m.base).unqualified {
            let baseType = exprType(m.base).unqualified
            var resolvedType = baseType
            if case .structType(let rec) = baseType, rec.fields.isEmpty, let completed = knownRecords[rec.name] {
                resolvedType = .structType(completed)
            }
            let structSize = resolvedType.sizeInBytes ?? 0
            let alignedSize = max((structSize + 15) & ~15, 16)
            // Allocate temp on stack (16-byte aligned), plus 16 bytes to save x19
            emitLine("sub sp, sp, #\(alignedSize + 16)")
            emitLine("str x19, [sp, #\(alignedSize)]")  // save x19
            emitLine("mov x19, sp")  // x19 = temp address
            if let hfaInfo = isHFA(resolvedType) {
                _ = emitExpr(m.base)  // makes the call (x19 is callee-saved, preserved)
                let fpPrefix = hfaInfo.isFloat ? "s" : "d"
                for j in 0..<hfaInfo.count {
                    let memberOff = j * (hfaInfo.isFloat ? 4 : 8)
                    emitLine("str \(fpPrefix)\(j), [x19, #\(memberOff)]")
                }
            } else if structSize <= 16 {
                _ = emitExpr(m.base)  // makes the call
                emitLine("str x0, [x19]")
                if structSize > 8 {
                    emitLine("str x1, [x19, #8]")
                }
            } else {
                emitLine("mov x8, x19")
                _ = emitExpr(m.base)  // makes the call
            }
            let addrReg = regAlloc.alloc() ?? .x9
            emitLine("mov \(addrReg.x), x19")
            emitLine("ldr x19, [sp, #\(alignedSize)]")  // restore x19
            // Add member offset
            let mOffset = memberOffset(resolvedType, m.memberName)
            if mOffset != 0 {
                emitLine("add \(addrReg.x), \(addrReg.x), #\(mOffset)")
            }
            let mt = exprType(.member(m))
            if case .array = mt.unqualified {
                // Restore x19 and free temp (but keep addrReg pointing to the member)
                emitLine("add sp, sp, #\(alignedSize + 16)")
                return addrReg
            }
            // Load the member value
            emitLoad(addrReg, type: mt)
            regAlloc.free(addrReg)
            // Free the temp + x19 save area
            emitLine("add sp, sp, #\(alignedSize + 16)")
            return addrReg
        }
        let addrReg = emitAddr(.member(m))
        // If the member type is an array, the value IS the address (array decays to pointer)
        let mt = exprType(.member(m))
        if case .array = mt.unqualified { return addrReg }
        if case .incompleteArray = mt.unqualified { return addrReg }
        // For structs, we can't load into a single register. Return the address
        // so the caller (e.g., struct copy, struct assignment) can use it.
        if case .structType = mt.unqualified, (mt.sizeInBytes ?? 0) > 0 { return addrReg }
        if case .unionType = mt.unqualified, (mt.sizeInBytes ?? 0) > 0 { return addrReg }
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
        let resultType = exprType(.conditional(c)).unqualified
        let isFloat = resultType.isFloating
        emitLine("cbz \(condReg.x), \(elseLabel)")
        let trueReg = emitExpr(c.trueExpr)
        if isFloat {
            emitLine("fmov \(resultType == .float ? "s" : "d")\(resultReg.regNum), \(resultType == .float ? "s" : "d")\(trueReg.regNum)")
        } else {
            emitLine("mov \(resultReg.x), \(trueReg.x)")
        }
        regAlloc.free(trueReg)
        emitLine("b \(endLabel)")
        emitLine("\(elseLabel):")
        let falseReg = emitExpr(c.falseExpr)
        if isFloat {
            emitLine("fmov \(resultType == .float ? "s" : "d")\(resultReg.regNum), \(resultType == .float ? "s" : "d")\(falseReg.regNum)")
        } else {
            emitLine("mov \(resultReg.x), \(falseReg.x)")
        }
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
            case .float:
                emitStoreFP("s\(reg.regNum)", offset)
            case .double, .longDouble:
                emitStoreFP("d\(reg.regNum)", offset)
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

    /// Copy struct bytes from srcReg to dstAddrName (a raw register name like "x16")
    private func emitStructCopyToField(_ dstAddrName: String, _ srcReg: ARM64Reg, _ size: Int) {
        var offset = 0
        var remaining = size
        while remaining >= 8 {
            emitLine("ldr x15, [\(srcReg.x), #\(offset)]")
            emitLine("str x15, [\(dstAddrName), #\(offset)]")
            offset += 8
            remaining -= 8
        }
        if remaining >= 4 {
            emitLine("ldr w15, [\(srcReg.x), #\(offset)]")
            emitLine("str w15, [\(dstAddrName), #\(offset)]")
            offset += 4
            remaining -= 4
        }
        if remaining >= 2 {
            emitLine("ldrh w15, [\(srcReg.x), #\(offset)]")
            emitLine("strh w15, [\(dstAddrName), #\(offset)]")
            offset += 2
            remaining -= 2
        }
        if remaining >= 1 {
            emitLine("ldrb w15, [\(srcReg.x), #\(offset)]")
            emitLine("strb w15, [\(dstAddrName), #\(offset)]")
        }
    }

    /// Emit a local aggregate initializer: write init list values to stack memory at addrReg.
    private func emitLocalInit(_ addrReg: ARM64Reg, _ expr: Expr, type: CType) {
        guard case .initList(let il) = expr else { return }
        let t = type.unqualified
        // Zero-initialize the aggregate before writing init list values.
        // C99 requires that fields/elements not explicitly initialized be set to zero.
        if let totalSize = t.sizeInBytes, totalSize > 0 {
            emitLine("mov w15, #0")
            for i in stride(from: 0, to: totalSize, by: 1) {
                if i > 0 {
                    emitLine("strb w15, [\(addrReg.x), #\(i)]")
                } else {
                    emitLine("strb w15, [\(addrReg.x)]")
                }
            }
        }
        // Save base address to stack to avoid clobbering by emitExpr
        emitLine("sub sp, sp, #16")
        emitLine("str \(addrReg.x), [sp, #0]")
        if case .structType(let rec) = t {
            let fields = rec.fields
            var valueIdx = 0
            // Build a map from field name → list of value indices for designated initializers
            // (multiple designators can target the same struct field, e.g. .inner.x and .inner.y)
            var designatedFields: [String: [Int]] = [:]
            for (vi, desig) in il.designators.enumerated() {
                if let names = desig, let firstName = names.first {
                    designatedFields[firstName, default: []].append(vi)
                }
            }
            let hasDesignators = !designatedFields.isEmpty
            for field in fields {
                let fieldOffset = field.offset
                let fieldSize = field.type.sizeInBytes ?? 0
                if fieldSize == 0 {
                    if valueIdx < il.values.count { valueIdx += 1 }
                    continue
                }
                // Check if this field has a designator
                if hasDesignators {
                    // Find all values designated for this field (including anonymous members)
                    var designatedIndices: [Int] = []
                    let fieldName = field.name ?? ""
                    if !fieldName.isEmpty, let indices = designatedFields[fieldName] {
                        designatedIndices = indices
                    } else if fieldName.isEmpty {
                        // Anonymous struct/union member: check if any designator matches a sub-field
                        for (vi, desig) in il.designators.enumerated() {
                            if let names = desig, let firstName = names.first {
                                if fieldHasMember(field.type, firstName) {
                                    designatedIndices.append(vi)
                                }
                            }
                        }
                    }
                    if !designatedIndices.isEmpty {
                        for idx in designatedIndices {
                        // Emit the designated value for this field
                        emitLine("ldr x16, [sp, #0]")
                        if fieldOffset != 0 {
                            emitLine("add x16, x16, #\(fieldOffset)")
                        }
                        let v = il.values[idx]
                        let fieldType = field.type.unqualified
                        // Handle nested designators (e.g., .a.j = 5)
                        let nestedNames: [String] = {
                            if let names = il.designators[idx] {
                                return Array(names.dropFirst())
                            }
                            return []
                        }()
                        if !nestedNames.isEmpty {
                            // Nested designator: compute offset of the nested field chain
                            // and store the scalar value at that offset
                            var nestedType = field.type
                            var nestedOffset = 0
                            for name in nestedNames {
                                if case .structType(let rec) = nestedType.unqualified {
                                    for nf in rec.fields {
                                        if (nf.name ?? "") == name {
                                            nestedOffset += nf.offset
                                            nestedType = nf.type
                                            break
                                        }
                                        if (nf.name ?? "").isEmpty, fieldHasMember(nf.type, name) {
                                            nestedOffset += nf.offset
                                            nestedType = nf.type
                                            break
                                        }
                                    }
                                } else if case .unionType(let rec) = nestedType.unqualified {
                                    for nf in rec.fields {
                                        if (nf.name ?? "") == name {
                                            nestedOffset += nf.offset
                                            nestedType = nf.type
                                            break
                                        }
                                        if (nf.name ?? "").isEmpty, fieldHasMember(nf.type, name) {
                                            nestedOffset += nf.offset
                                            nestedType = nf.type
                                            break
                                        }
                                    }
                                }
                            }
                            if nestedOffset != 0 {
                                emitLine("add x16, x16, #\(nestedOffset)")
                            }
                            let valReg = emitExpr(v)
                            emitStoreToAddrRaw("x16", valReg, type: nestedType)
                            regAlloc.free(valReg)
                        } else if case .initList = v {
                            let fieldAddr = regAlloc.alloc() ?? .x9
                            emitLine("mov \(fieldAddr.x), x16")
                            emitLocalInit(fieldAddr, v, type: field.type)
                            regAlloc.free(fieldAddr)
                        } else if case .compoundLiteral(let cl) = v {
                            let fieldAddr = regAlloc.alloc() ?? .x9
                            emitLine("mov \(fieldAddr.x), x16")
                            emitLocalInit(fieldAddr, cl.initList, type: field.type)
                            regAlloc.free(fieldAddr)
                        } else if case .structType = fieldType, let srcAddr = emitAddrOrNil(v) {
                            emitStructCopyToField("x16", srcAddr, field.type.sizeInBytes ?? 0)
                            regAlloc.free(srcAddr)
                        } else if case .structType = fieldType, case .unary(let u) = v, u.op == .dereference {
                            let ptrReg = emitExpr(u.operand)
                            emitStructCopyToField("x16", ptrReg, field.type.sizeInBytes ?? 0)
                            regAlloc.free(ptrReg)
                        } else {
                            // Scalar value — store to field address
                            let valReg = emitExpr(v)
                            // Convert float/double if needed
                            let valType = exprType(v).unqualified
                            if valType == .double && field.type.unqualified == .float {
                                emitLine("fcvt s\(valReg.regNum), d\(valReg.regNum)")
                            } else if valType == .float && field.type.unqualified == .double {
                                emitLine("fcvt d\(valReg.regNum), s\(valReg.regNum)")
                            }
                            emitStoreToAddrRaw("x16", valReg, type: field.type)
                            regAlloc.free(valReg)
                        }
                        } // end for idx in designatedIndices
                        continue
                    }
                    // No designator for this field — leave it zero-initialized
                    continue
                }
                // Use x16 as field address to avoid clobbering by emitExpr
                emitLine("ldr x16, [sp, #0]")
                if fieldOffset != 0 {
                    emitLine("add x16, x16, #\(fieldOffset)")
                }
                let fieldType = field.type.unqualified
                if valueIdx < il.values.count {
                    let v = il.values[valueIdx]
                    if case .initList = v {
                        // Nested aggregate init
                        valueIdx += 1
                        let fieldAddr = regAlloc.alloc() ?? .x9
                        emitLine("mov \(fieldAddr.x), x16")
                        emitLocalInit(fieldAddr, v, type: field.type)
                        regAlloc.free(fieldAddr)
                    } else if case .compoundLiteral(let cl) = v {
                        valueIdx += 1
                        let fieldAddr = regAlloc.alloc() ?? .x9
                        emitLine("mov \(fieldAddr.x), x16")
                        emitLocalInit(fieldAddr, cl.initList, type: field.type)
                        regAlloc.free(fieldAddr)
                    } else if case .stringLiteral(let sl) = v, case .array(let elemType, let count) = fieldType, elemType.isChar {
                        // String literal for char array field — copy bytes inline
                        valueIdx += 1
                        let label = addStringLiteral(sl.value)
                        // Use x14 as src to avoid clobbering x16 (field addr)
                        emitLine("adrp x14, \(label)@PAGE")
                        emitLine("add x14, x14, \(label)@PAGEOFF")
                        let bytes = Array(sl.value.utf8)
                        let copyLen = min(count, bytes.count + 1)
                        for i in 0..<copyLen {
                            if i > 0 {
                                emitLine("ldrb w15, [x14, #\(i)]")
                                emitLine("strb w15, [x16, #\(i)]")
                            } else {
                                emitLine("ldrb w15, [x14]")
                                emitLine("strb w15, [x16]")
                            }
                        }
                        // Zero-fill remaining bytes
                        if copyLen < count {
                            emitLine("mov w15, #0")
                            for i in copyLen..<count {
                                emitLine("strb w15, [x16, #\(i)]")
                            }
                        }
                    } else if case .array(let elemType, let count) = fieldType {
                        // Array field: consume values for each element
                        for _ in 0..<count {
                            if valueIdx < il.values.count {
                                let ev = il.values[valueIdx]
                                valueIdx += 1
                                if case .initList = ev {
                                    let elemAddr = regAlloc.alloc() ?? .x9
                                    emitLine("mov \(elemAddr.x), x16")
                                    emitLocalInit(elemAddr, ev, type: elemType)
                                    regAlloc.free(elemAddr)
                                } else {
                                    let valReg = emitExpr(ev)
                                    emitStoreToAddrRaw("x16", valReg, type: elemType)
                                    regAlloc.free(valReg)
                                }
                            } else {
                                break
                            }
                            // Advance x16 by elemSize
                            let elemSize = elemType.sizeInBytes ?? 8
                            emitLine("add x16, x16, #\(elemSize)")
                        }
                    } else if case .stringLiteral(let sl) = v, case .array(let elemType, let count) = fieldType, elemType.isChar {
                        // String literal for char array — already handled above
                        valueIdx += 1
                    } else if case .identifier = v, case .structType = fieldType {
                        // Struct copy from a variable — copy bytes from source to field
                        valueIdx += 1
                        let srcAddr = emitAddr(v)
                        emitStructCopyToField("x16", srcAddr, field.type.sizeInBytes ?? 0)
                        regAlloc.free(srcAddr)
                    } else if case .unary(let u) = v, u.op == .dereference, case .structType = fieldType {
                        // Struct copy from *ptr — dereference pointer and copy
                        valueIdx += 1
                        let ptrReg = emitExpr(u.operand)
                        emitStructCopyToField("x16", ptrReg, field.type.sizeInBytes ?? 0)
                        regAlloc.free(ptrReg)
                    } else if case .identifier = v, case .unionType = fieldType {
                        // Union copy from a variable
                        valueIdx += 1
                        let srcAddr = emitAddr(v)
                        emitStructCopyToField("x16", srcAddr, field.type.sizeInBytes ?? 0)
                        regAlloc.free(srcAddr)
                    } else if case .structType = fieldType {
                        // Struct field initialized from a non-init expression:
                        // Could be a cast, member access, dereference, etc.
                        // Try to get the address of the expression and copy bytes.
                        valueIdx += 1
                        if let srcAddr = emitAddrOrNil(v) {
                            emitStructCopyToField("x16", srcAddr, field.type.sizeInBytes ?? 0)
                            regAlloc.free(srcAddr)
                        } else {
                            // Fallback: evaluate as flat init
                            valueIdx -= 1  // undo the increment since emitLocalInitStructElem advances it
                            if case .structType(let subRec) = fieldType {
                                emitLine("mov x17, x16")
                                emitLocalInitStructElem(il.values, idx: &valueIdx, rec: subRec, baseAddrReg: "x17")
                            }
                        }
                    } else {
                        // Scalar field (or bitfield)
                        valueIdx += 1
                        let valReg = emitExpr(v)
                        // Convert float/double if needed
                        let valType = exprType(v).unqualified
                        if valType == .double && field.type.unqualified == .float {
                            emitLine("fcvt s\(valReg.regNum), d\(valReg.regNum)")
                        } else if valType == .float && field.type.unqualified == .double {
                            emitLine("fcvt d\(valReg.regNum), s\(valReg.regNum)")
                        }
                        if field.bitWidth != nil {
                            // Bitfield initialization: read-modify-write
                            // Save the value on stack first
                            emitLine("str \(valReg.x), [sp, #-16]!")
                            regAlloc.free(valReg)
                            // Load the containing unit
                            let unitSize = field.type.unqualified.sizeInBytes ?? 4
                            switch unitSize {
                            case 1: emitLine("ldrb w17, [x16]")
                            case 2: emitLine("ldrh w17, [x16]")
                            case 4: emitLine("ldr w17, [x16]")
                            case 8: emitLine("ldr x17, [x16]")
                            default: emitLine("ldr w17, [x16]")
                            }
                            // Load the value from stack into x14
                            emitLine("ldr x14, [sp]")
                            // Compute masks
                            let bw = field.bitWidth!
                            let bo = field.bitOffset
                            let bitfieldMask: UInt64 = ((UInt64(1) << UInt64(bw)) - 1) << UInt64(bo)
                            let clearMask: UInt64 = ~bitfieldMask
                            // Clear the bitfield bits in the unit (use x15 for clearMask)
                            emitLine("mov x15, #\(clearMask & 0xffff)")
                            if clearMask > 0xffff {
                                emitLine("movk x15, #\((clearMask >> 16) & 0xffff), lsl #16")
                            }
                            if clearMask > 0xffffff {
                                emitLine("movk x15, #\((clearMask >> 32) & 0xffff), lsl #32")
                            }
                            if clearMask > 0xffffffffffff {
                                emitLine("movk x15, #\((clearMask >> 48) & 0xffff), lsl #48")
                            }
                            emitLine("and x17, x17, x15")
                            // Shift the new value to the bitfield position
                            if bo > 0 {
                                emitLine("lsl x14, x14, #\(bo)")
                            }
                            // Mask the new value to bitWidth bits (shifted to position)
                            emitLine("mov x15, #\(bitfieldMask & 0xffff)")
                            if bitfieldMask > 0xffff {
                                emitLine("movk x15, #\((bitfieldMask >> 16) & 0xffff), lsl #16")
                            }
                            if bitfieldMask > 0xffffff {
                                emitLine("movk x15, #\((bitfieldMask >> 32) & 0xffff), lsl #32")
                            }
                            if bitfieldMask > 0xffffffffffff {
                                emitLine("movk x15, #\((bitfieldMask >> 48) & 0xffff), lsl #48")
                            }
                            emitLine("and x14, x14, x15")
                            emitLine("orr x17, x17, x14")
                            // Store the unit back
                            switch unitSize {
                            case 1: emitLine("strb w17, [x16]")
                            case 2: emitLine("strh w17, [x16]")
                            case 4: emitLine("str w17, [x16]")
                            case 8: emitLine("str x17, [x16]")
                            default: emitLine("str w17, [x16]")
                            }
                            emitLine("add sp, sp, #16")  // free the pushed value
                        } else {
                            emitStoreToAddrRaw("x16", valReg, type: field.type)
                            regAlloc.free(valReg)
                        }
                    }
                }
            }
        } else if case .unionType(let rec) = t {
            // Union init: initialize the first field (or first named field)
            if let firstField = rec.fields.first {
                if il.values.count > 0 {
                    let v = il.values[0]
                    let fieldAddr = regAlloc.alloc() ?? .x9
                    emitLine("ldr \(fieldAddr.x), [sp, #0]")
                    if case .initList = v {
                        emitLocalInit(fieldAddr, v, type: firstField.type)
                    } else if case .compoundLiteral(let cl) = v {
                        emitLocalInit(fieldAddr, cl.initList, type: firstField.type)
                    } else if case .identifier = v, case .structType = firstField.type.unqualified {
                        // Struct copy from variable
                        let srcAddr = emitAddr(v)
                        emitStructCopyToField("\(fieldAddr.x)", srcAddr, firstField.type.sizeInBytes ?? 0)
                        regAlloc.free(srcAddr)
                    } else if case .array = firstField.type.unqualified {
                        // Array field with flat init — use emitLocalInit with a synthetic initList
                        // Actually, all values belong to the first field's array
                        emitLocalInit(fieldAddr, .initList(InitListExpr(values: il.values, loc: SourceLoc.unknown)), type: firstField.type)
                    } else {
                        let valReg = emitExpr(v)
                        emitStoreToAddrRaw("\(fieldAddr.x)", valReg, type: firstField.type)
                        regAlloc.free(valReg)
                    }
                    regAlloc.free(fieldAddr)
                }
            }
        } else if case .array(let elemType, _) = t {
            let elemSize = elemType.sizeInBytes ?? 8
            if case .structType(let subRec) = elemType.unqualified {
                // Array of structs: consume values per struct element
                var valueIdx = 0
                var elemI = 0
                while valueIdx < il.values.count {
                    emitLine("ldr x16, [sp, #0]")
                    if elemI > 0 {
                        emitLine("add x16, x16, #\(elemI * elemSize)")
                    }
                    let v = il.values[valueIdx]
                    if case .initList = v {
                        // Complete element with brace init
                        valueIdx += 1
                        let elemAddr = regAlloc.alloc() ?? .x9
                        emitLine("mov \(elemAddr.x), x16")
                        emitLocalInit(elemAddr, v, type: elemType)
                        regAlloc.free(elemAddr)
                    } else if case .compoundLiteral(let cl) = v {
                        valueIdx += 1
                        let elemAddr = regAlloc.alloc() ?? .x9
                        emitLine("mov \(elemAddr.x), x16")
                        emitLocalInit(elemAddr, cl.initList, type: elemType)
                        regAlloc.free(elemAddr)
                    } else {
                        // Flat init: consume values for one struct element
                        let startIdx = valueIdx
                        emitLocalInitStructElem(il.values, idx: &valueIdx, rec: subRec, baseAddrReg: "x16")
                        if valueIdx == startIdx { break }
                    }
                    elemI += 1
                }
            } else {
                let elemSize = elemType.sizeInBytes ?? 8
                for (i, v) in il.values.enumerated() {
                    emitLine("ldr x16, [sp, #0]")
                    if i > 0 {
                        emitLine("add x16, x16, #\(i * elemSize)")
                    }
                    if case .initList = v {
                        let elemAddr = regAlloc.alloc() ?? .x9
                        emitLine("mov \(elemAddr.x), x16")
                        emitLocalInit(elemAddr, v, type: elemType)
                        regAlloc.free(elemAddr)
                    } else if case .compoundLiteral(let cl) = v {
                        let elemAddr = regAlloc.alloc() ?? .x9
                        emitLine("mov \(elemAddr.x), x16")
                        emitLocalInit(elemAddr, cl.initList, type: elemType)
                        regAlloc.free(elemAddr)
                    } else {
                        let valReg = emitExpr(v)
                        emitStoreToAddrRaw("x16", valReg, type: elemType)
                        regAlloc.free(valReg)
                    }
                }
            }
        }
        // Restore base address and stack
        emitLine("ldr \(addrReg.x), [sp, #0]")
        emitLine("add sp, sp, #16")
    }

    /// Emit a local init for one struct element from a flat init list.
    /// Consumes values from allValues starting at idx, for the fields of rec.
    /// Uses x16 as the base address register (string name).
    private func emitLocalInitStructElem(_ allValues: [Expr], idx: inout Int, rec: RecordType, baseAddrReg: String) {
        for field in rec.fields {
            let fieldSize = field.type.sizeInBytes ?? 0
            if fieldSize == 0 { continue }
            let fieldOffset = field.offset
            let fieldType = field.type.unqualified
            if idx < allValues.count {
                let v = allValues[idx]
                // Compute field address: x16 = base + fieldOffset
                if fieldOffset == 0 {
                    emitLine("mov x16, \(baseAddrReg)")
                } else {
                    emitLine("add x16, \(baseAddrReg), #\(fieldOffset)")
                }
                if case .initList = v {
                    idx += 1
                    let fieldAddr = regAlloc.alloc() ?? .x9
                    emitLine("mov \(fieldAddr.x), x16")
                    emitLocalInit(fieldAddr, v, type: field.type)
                    regAlloc.free(fieldAddr)
                } else if case .stringLiteral(let sl) = v, case .array(let elemType, let count) = fieldType, elemType.isChar {
                    // String literal for char array — copy bytes inline
                    idx += 1
                    let label = addStringLiteral(sl.value)
                    // Use x14/x15 to avoid clobbering base addr register
                    emitLine("adrp x14, \(label)@PAGE")
                    emitLine("add x14, x14, \(label)@PAGEOFF")
                    let bytes = Array(sl.value.utf8)
                    let copyLen = min(count, bytes.count + 1)
                    for i in 0..<copyLen {
                        if i > 0 {
                            emitLine("ldrb w15, [x14, #\(i)]")
                            emitLine("strb w15, [x16, #\(i)]")
                        } else {
                            emitLine("ldrb w15, [x14]")
                            emitLine("strb w15, [x16]")
                        }
                    }
                    if copyLen < count {
                        emitLine("mov w15, #0")
                        for i in copyLen..<count {
                            emitLine("strb w15, [x16, #\(i)]")
                        }
                    }
                } else if case .array(let elemType, let count) = fieldType {
                    // Array field: consume values for each element
                    for _ in 0..<count {
                        if idx < allValues.count {
                            let ev = allValues[idx]
                            idx += 1
                            let valReg = emitExpr(ev)
                            emitStoreToAddrRaw("x16", valReg, type: elemType)
                            regAlloc.free(valReg)
                            let es = elemType.sizeInBytes ?? 8
                            emitLine("add x16, x16, #\(es)")
                        }
                    }
                } else {
                    idx += 1
                    let valReg = emitExpr(v)
                    emitStoreToAddrRaw("x16", valReg, type: field.type)
                    regAlloc.free(valReg)
                }
            }
        }
    }

    /// Store a register value to an address (given as a raw register name), using the correct store instruction for the type.
    private func emitStoreToAddrRaw(_ addrRegName: String, _ valReg: ARM64Reg, type: CType) {
        let t = type.unqualified
        switch t {
        case .bool, .char, .schar, .uchar:
            emitLine("strb \(valReg.w), [\(addrRegName)]")
        case .short, .ushort:
            emitLine("strh \(valReg.w), [\(addrRegName)]")
        case .int, .uint:
            emitLine("str \(valReg.w), [\(addrRegName)]")
        case .float:
            emitLine("str s\(valReg.regNum), [\(addrRegName)]")
        case .double, .longDouble:
            emitLine("str d\(valReg.regNum), [\(addrRegName)]")
        case .structType(let rec), .unionType(let rec):
            // Store based on size
            let size = rec.size ?? 8
            switch size {
            case 1: emitLine("strb \(valReg.w), [\(addrRegName)]")
            case 2: emitLine("strh \(valReg.w), [\(addrRegName)]")
            case 4: emitLine("str \(valReg.w), [\(addrRegName)]")
            default: emitLine("str \(valReg.x), [\(addrRegName)]")
            }
        default:
            emitLine("str \(valReg.x), [\(addrRegName)]")
        }
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
