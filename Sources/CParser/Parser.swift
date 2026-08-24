import CCommon
import CPreproc
import Foundation

// MARK: - Parse Error

public enum ParseError: Error {
    case unexpectedToken(String, SourceLoc)
    case expected(String, String, SourceLoc)  // (expected, got, loc)
    case undeclared(String, SourceLoc)
}

// MARK: - Parser

/// Recursive descent C99 parser: token stream → AST.
public final class Parser {
    private var tokens: [Token]
    private var pos = 0
    private var diags: DiagnosticEngine

    /// Set of known typedef names (for the lexer hack: distinguishing typedef names
    /// from identifiers in declarations).
    private var typedefNames: Set<String> = []

    /// Completed struct/union definitions by tag name (for looking up when
    /// `struct Tag` is referenced without a body after the definition).
    private var completedRecords: [String: RecordType] = [:]

    /// Maps typedef names to their resolved base types (e.g., "u8" → .uchar).
    /// Used so that when a typedef name is used as a type specifier, we know
    /// the actual size/alignment for struct field offset computation.
    private var typedefTypes: [String: CType] = [:]

    /// Last parsed function params (with names) — used by parseExternalDecl.
    private var lastFuncParams: [Param] = []

    /// VLA size expressions from the last parseDeclarator call (for variable-length arrays).
    /// For multi-dimensional VLAs, this contains inner dimension expressions in order.
    private var pendingVLASizeExprs: [Expr] = []
    private var pendingVLASizeExpr: Expr? { pendingVLASizeExprs.last }
    private var lastFuncVariadic: Bool = false
    /// VLA dimension expressions for each parameter in the last parsed function.
    /// Each entry is the list of dimension expressions for that parameter.
    private var lastFuncParamVLAExprs: [[Expr]] = []
    /// Current function name (for __func__ predefined identifier).
    private var currentFuncName: String? = nil
    /// Enum constants defined so far (name → value), for constant expression evaluation.
    private var parserEnumConstants: [String: Int64] = [:]

    /// Global variable types (name → type), for sizeof evaluation in constant expressions.
    private var globalVarTypes: [String: CType] = [:]

    /// Determine the type of an expression for typeof().
    /// Handles identifiers (globals, typedefs), integer/float literals, and simple expressions.
    private func typeofExprType(_ expr: Expr) -> CType {
        switch expr {
        case .identifier(let id):
            if let t = globalVarTypes[id.name] { return t }
            if let t = typedefTypes[id.name] { return t }
            if let _ = parserEnumConstants[id.name] { return .int }
            return .int
        case .integerLiteral(let il):
            return il.type
        case .floatLiteral(let fl):
            return fl.type
        case .cast(let c):
            return c.type
        case .unary(let u):
            switch u.op {
            case .dereference:
                if case .pointer(let to) = typeofExprType(u.operand).unqualified { return to }
                return .int
            case .addressOf:
                return .pointer(to: typeofExprType(u.operand))
            default:
                return integerPromoteType(typeofExprType(u.operand))
            }
        case .binary(let b):
            // Result type is the common type of both operands
            let lt = typeofExprType(b.left)
            let rt = typeofExprType(b.right)
            return lt.isFloating ? lt : rt.isFloating ? rt : lt
        case .sizeof:
            return .ulongLong
        case .subscript_(let s):
            if case .pointer(let to) = typeofExprType(s.base).unqualified { return to }
            if case .array(let elem, _) = typeofExprType(s.base).unqualified { return elem }
            return .int
        case .member(let m):
            var baseRecordType = typeofExprType(m.base).unqualified
            if m.isArrow {
                if case .pointer(let to) = baseRecordType { baseRecordType = to.unqualified }
            }
            if case .structType(let rec) = baseRecordType {
                for field in rec.fields {
                    if (field.name ?? "") == m.memberName { return field.type }
                }
            }
            if case .unionType(let rec) = baseRecordType {
                for field in rec.fields {
                    if (field.name ?? "") == m.memberName { return field.type }
                }
            }
            return .int
        default:
            return .int
        }
    }

    /// Integer promotion: char/short → int, others unchanged.
    private func integerPromoteType(_ t: CType) -> CType {
        let u = t.unqualified
        switch u {
        case .bool, .char, .schar, .uchar, .short, .ushort:
            return .int
        default:
            return t
        }
    }

    /// Check if two types are compatible (for __builtin_types_compatible_p).
    /// Types are compatible if they're the same type ignoring qualifiers.
    /// Arrays of different sizes are compatible (C99 6.7.5.2).
    private func typesCompatible(_ t1: CType, _ t2: CType) -> Bool {
        let a = t1.unqualified
        let b = t2.unqualified
        // Same type
        if a == b { return true }
        // Arrays: compatible if element types are compatible (size doesn't matter)
        if case .array(let e1, _) = a, case .array(let e2, _) = b { return typesCompatible(e1, e2) }
        if case .array(let e1, _) = a, case .incompleteArray(let e2) = b { return typesCompatible(e1, e2) }
        if case .incompleteArray(let e1) = a, case .array(let e2, _) = b { return typesCompatible(e1, e2) }
        if case .incompleteArray(let e1) = a, case .incompleteArray(let e2) = b { return typesCompatible(e1, e2) }
        // Typedefs: check underlying types
        if case .typedef(let n1, let base1) = a, case .typedef(let n2, let base2) = b {
            if n1 == n2 { return true }
            return typesCompatible(base1, base2)
        }
        // Enum and int are compatible
        if case .enumType = a, case .int = b { return true }
        if case .int = a, case .enumType = b { return true }
        return false
    }
    /// Stack of #pragma pack values (for struct alignment control).
    private var packStack: [Int] = []
    /// Current pack alignment (0 = use natural alignment).
    private var currentPack: Int = 0
    /// Pending __attribute__((aligned(N))) extracted from the last call to
    /// parseDeclSpecifiers (applied between the base type and the declarator,
    /// e.g. `int __attribute__((aligned(8))) a`). Reset after each field.
    private var pendingDeclAligned: Int? = nil
    /// Additional declarators from multi-declarator global declarations (e.g., `int a, b;`)
    private var pendingExternalDecls: [Decl] = []
    /// Nested function definitions discovered during function body parsing.
    /// These are hoisted to the top level (without access to parent locals).
    private var pendingNestedFunctions: [FuncDecl] = []
    /// Collects __label__ names encountered while parsing a function body.
    /// Uses a stack: each function scope pushes a new collection.
    private var pendingLocalLabelsStack: [[String]] = [[]]

    public init(_ tokens: [Token], diags: DiagnosticEngine = DiagnosticEngine()) {
        // Filter out EOF for easier processing, we'll add it back at the end
        self.tokens = tokens.filter { $0.kind != .eof }
        self.diags = diags
        // Predefined typedefs for GNU builtins
        // __builtin_va_list is a pointer-sized type on AArch64 (like char* or a struct of pointers)
        self.typedefNames.insert("__builtin_va_list")
        self.typedefTypes["__builtin_va_list"] = .pointer(to: .char)
    }

    // MARK: - Public API

    public func parse() throws -> [Decl] {
        var decls: [Decl] = []
        while !isAtEnd() {
            // Handle #pragma pack directives
            if current().kind == .pragma {
                handlePragmaPack(current())
                advance()
                continue
            }
            do {
                if let decl = try parseExternalDecl() {
                    decls.append(decl)
                }
                // Pick up any additional declarators from multi-declarator declarations
                decls.append(contentsOf: pendingExternalDecls)
                pendingExternalDecls.removeAll()
                // Pick up nested function definitions discovered during function body parsing
                for nfd in pendingNestedFunctions {
                    decls.append(.funcDecl(nfd))
                }
                pendingNestedFunctions.removeAll()
            } catch let error as ParseError {
                switch error {
                case .unexpectedToken(let msg, let loc):
                    diags.error("syntax error: \(msg)", at: loc)
                case .expected(let exp, let got, let loc):
                    diags.error("expected \(exp), got '\(got)'", at: loc)
                case .undeclared(let name, let loc):
                    diags.error("undeclared identifier '\(name)'", at: loc)
                }
                synchronize()
            }
        }
        return decls
    }

    /// Handle #pragma pack directives.
    private func handlePragmaPack(_ token: Token) {
        let text = token.spelling
        // Format: "pack push 1" or "pack pop" or "pack(1)" or "pack(push, 1)" etc.
        if text.contains("push") {
            // Extract pack value
            let words = text.split(separator: " ").map(String.init)
            // Look for a number in the pragma text
            if let n = words.compactMap({ Int($0.filter { $0.isNumber }) }).first {
                packStack.append(currentPack)
                currentPack = n
            } else {
                packStack.append(currentPack)
                // No explicit value — use default (which for push is usually the current value)
            }
        } else if text.contains("pop") {
            if let prev = packStack.popLast() {
                currentPack = prev
            }
        } else {
            // #pragma pack(N) — set pack value directly
            let words = text.split(separator: " ").map(String.init)
            if let n = words.compactMap({ Int($0.filter { $0.isNumber }) }).first {
                currentPack = n
            }
        }
    }

    // MARK: - Token helpers

    private func peek(_ offset: Int = 0) -> Token {
        let idx = pos + offset
        if idx >= tokens.count {
            return Token(kind: .eof, spelling: "", loc: SourceLoc.unknown)
        }
        return tokens[idx]
    }

    private func current() -> Token { return peek(0) }
    private func next() -> Token { return peek(1) }

    private func isAtEnd() -> Bool {
        return pos >= tokens.count
    }

    private func advance() -> Token {
        let t = current()
        if pos < tokens.count { pos += 1 }
        return t
    }

    private func check(kind: TokenKind, spelling: String? = nil) -> Bool {
        if current().kind != kind { return false }
        if let s = spelling { return current().spelling == s }
        return true
    }

    private func match(kind: TokenKind, spelling: String? = nil) -> Bool {
        if check(kind: kind, spelling: spelling) {
            _ = advance()
            return true
        }
        return false
    }

    private func consume(kind: TokenKind, spelling: String? = nil) throws -> Token {
        if check(kind: kind, spelling: spelling) {
            return advance()
        }
        let exp = spelling ?? kindDescription(kind)
        throw ParseError.expected(exp, current().spelling, current().loc)
    }

    private func kindDescription(_ k: TokenKind) -> String {
        switch k {
        case .identifier: return "identifier"
        case .keyword: return "keyword"
        case .integerLiteral: return "integer literal"
        case .floatLiteral: return "float literal"
        case .charLiteral: return "char literal"
        case .stringLiteral: return "string literal"
        case .punct: return "punctuator"
        case .eof: return "end of file"
        case .pragma: return "pragma"
        }
    }

    private func isPunct(_ s: String) -> Bool {
        return current().kind == .punct && current().spelling == s
    }

    private func isKeyword(_ s: String) -> Bool {
        return current().kind == .keyword && current().spelling == s
    }

    /// Check if the current token could start a K&R-style parameter declaration
    /// (a type specifier keyword, struct/union/enum, or a typedef name).
    private func isKAndRParamDeclStart() -> Bool {
        if current().kind == .keyword {
            switch current().spelling {
            case "char", "short", "int", "long", "float", "double", "void",
                 "signed", "unsigned", "const", "volatile", "restrict",
                 "struct", "union", "enum",
                 "register", "auto", "static", "extern",
                 "__const", "__const__", "__volatile", "__volatile__",
                 "__restrict", "__restrict__", "__signed", "__signed__":
                return true
            default:
                return false
            }
        }
        if isTypedefName() { return true }
        return false
    }

    private func isIdentifier(_ s: String? = nil) -> Bool {
        if current().kind != .identifier { return false }
        if let s = s { return current().spelling == s }
        return true
    }

    /// Check if the current token is a typedef name (for the lexer hack).
    private func isTypedefName() -> Bool {
        return current().kind == .identifier && typedefNames.contains(current().spelling)
    }

    /// Check if the current identifier is being used as a type in a typedef declaration.
    /// Only trigger in typedef context to avoid false positives with variable names.
    private func isForwardTypedef() -> Bool {
        // Only in typedef context (isTypedef was set by parseDeclSpecifiers)
        // This is checked via the `isTypedef` local in parseDeclSpecifiers,
        // but we can't access it here. So we use a simpler heuristic:
        // An unknown identifier is a forward typedef if it's followed by
        // another identifier (the new type name) in a typedef declaration.
        return next().kind == .identifier
    }

    // MARK: - Error recovery

    private func synchronize() {
        // Skip to the next likely declaration boundary
        while !isAtEnd() {
            if isPunct(";") { advance(); return }
            if isPunct("}") { advance(); return }
            // Stop at keywords that start a new declaration
            if current().kind == .keyword {
                let kw = current().spelling
                if ["int", "char", "short", "long", "float", "double", "void",
                    "unsigned", "signed", "const", "static", "extern", "struct",
                    "union", "enum", "typedef", "inline", "register", "volatile",
                    "_Bool", "auto"].contains(kw) {
                    return
                }
            }
            advance()
        }
    }

    // MARK: - External declarations

    /// Skip __asm("...") and __attribute__((...)) clauses that may follow a declarator.
    private func skipAsmAndAttributes() {
        while isKeyword("__asm") || isKeyword("__asm__") ||
              isKeyword("__attribute__") || isKeyword("__attribute") {
            advance() // consume the keyword
            if isPunct("(") {
                // Skip balanced parens
                var depth = 0
                while !isAtEnd() {
                    if isPunct("(") { depth += 1 }
                    else if isPunct(")") { depth -= 1; if depth == 0 { advance(); break } }
                    advance()
                }
            }
        }
    }

    /// Extract alignment from __attribute__((aligned(N))) or __attribute__((aligned)).
    /// Returns the alignment in bytes, or nil if no aligned attribute found.
    private func extractAlignment() -> Int? {
        var result: Int? = nil
        let savedPos = pos
        while isKeyword("__attribute__") || isKeyword("__attribute") {
            advance() // consume the keyword
            if isPunct("(") {
                advance() // outer (
                if isPunct("(") {
                    advance() // inner (
                    // Parse attribute list
                    while !isPunct(")") && !isAtEnd() {
                        if isPunct(",") { advance(); continue }
                        if current().kind == .identifier {
                            let attrName = current().spelling
                            advance()
                            if attrName == "aligned" || attrName == "__aligned__" {
                                if isPunct("(") {
                                    advance()
                                    // Parse the alignment expression
                                    if let alignExpr = try? parseAssignmentExpr() {
                                        let v = evalIntConst(alignExpr)
                                        if v > 0 { result = Int(v) }
                                    }
                                    if isPunct(")") { advance() }
                                } else {
                                    // aligned with no arg = natural alignment (e.g., 16 for long double)
                                    result = 16
                                }
                            } else {
                                // Skip any arguments for unknown attributes
                                if isPunct("(") {
                                    var depth = 0
                                    while !isAtEnd() {
                                        if isPunct("(") { depth += 1 }
                                        else if isPunct(")") { depth -= 1; if depth == 0 { advance(); break } }
                                        advance()
                                    }
                                }
                            }
                        } else {
                            advance()
                        }
                    }
                    if isPunct(")") { advance() } // inner )
                }
                if isPunct(")") { advance() } // outer )
            }
        }
        _ = savedPos
        return result
    }

    /// Skip C23 standard attributes: [[attr::args(...)]] — skip the whole [[...]] block.
    private func skipC23Attributes() {
        // We're at [[
        while isPunct("[") && next().spelling == "[" {
            advance() // first [
            advance() // second [
            // Skip until matching ]]
            var depth = 2 // we've consumed two [
            while !isAtEnd() && depth > 0 {
                if isPunct("[") && next().spelling == "[" {
                    depth += 2
                    advance(); advance()
                } else if isPunct("]") && next().spelling == "]" {
                    depth -= 2
                    advance(); advance()
                } else if isPunct("(") {
                    advance()
                    var parenDepth = 1
                    while !isAtEnd() && parenDepth > 0 {
                        if isPunct("(") { parenDepth += 1 }
                        else if isPunct(")") { parenDepth -= 1; if parenDepth == 0 { advance(); break } }
                        advance()
                    }
                } else {
                    advance()
                }
            }
        }
    }

    private func parseExternalDecl() throws -> Decl? {
        // Empty
        if isPunct(";") { advance(); return nil }

        // Skip C23 standard attributes [[...]]
        if isPunct("[") && next().spelling == "[" {
            skipC23Attributes()
        }

        // Skip __extension__ at the start of a declaration (GNU extension)
        while isKeyword("__extension__") { advance() }

        // Special: _Static_assert
        if isKeyword("_Static_assert") {
            return try parseStaticAssert()
        }

        // typedef
        if isKeyword("typedef") {
            return try parseTypedef()
        }

        // Parse declaration specifiers
        let (baseType, storageClass, isInline, _) = try parseDeclSpecifiers()

        // If nothing follows the specifiers, it's just a type declaration (e.g., struct S { ... };)
        if isPunct(";") {
            advance()
            // Return the struct/union/enum declaration if present
            if case .structType(let rec) = baseType {
                return .structDecl(StructDecl(name: rec.name, record: rec, loc: SourceLoc.unknown))
            }
            if case .unionType(let rec) = baseType {
                return .unionDecl(UnionDecl(name: rec.name, record: rec, loc: SourceLoc.unknown))
            }
            if case .enumType(let en) = baseType {
                return .enumDecl(EnumDecl(name: en.name, enumType: en, loc: SourceLoc.unknown))
            }
            return nil
        }

        // Parse one or more declarators
        var firstDecl: Decl? = nil
        var additionalDecls: [Decl] = []
        repeat {
            let (name, type, loc) = try parseDeclarator(baseType)
            skipAsmAndAttributes()

            if type.isFunction && (isPunct("{") || isKAndRParamDeclStart()) {
                // Function definition — parse the body and return immediately
                // (no semicolon after a function definition)
                // Save params BEFORE parsing body — body may contain function pointer
                // declarations that overwrite lastFuncParams via parseFunctionParams
                var savedParams = lastFuncParams
                let savedVariadic = lastFuncVariadic
                let savedParamVLAExprs = lastFuncParamVLAExprs
                let savedFuncName = currentFuncName
                currentFuncName = name
                // Push a new label scope for this function
                pendingLocalLabelsStack.append([])

                // K&R-style: parse parameter declaration list before the {
                // e.g., foo(p) int *p; { ... }
                while !isPunct("{") && !isAtEnd() {
                    // Parse a declaration (e.g., "int *p;" or "float *x, *y;")
                    let (krBaseType, _, _, _) = try parseDeclSpecifiers()
                    repeat {
                        let (krName, krType, _) = try parseDeclarator(krBaseType)
                        // Match this param name to update its type
                        for i in 0..<savedParams.count {
                            if savedParams[i].name == krName {
                                // Array types decay to pointers in function params
                                var actualType = krType
                                if case .array(let elem, _) = actualType.unqualified {
                                    actualType = .pointer(to: elem)
                                } else if case .incompleteArray(let elem) = actualType.unqualified {
                                    actualType = .pointer(to: elem)
                                }
                                savedParams[i] = Param(name: krName, type: actualType, loc: savedParams[i].loc)
                            }
                        }
                        if !match(kind: .punct, spelling: ",") {
                            break
                        }
                    } while true
                    _ = match(kind: .punct, spelling: ";")
                }

                let body = try parseCompoundStmt()
                currentFuncName = savedFuncName
                // Pop label scope for this function
                let labels = pendingLocalLabelsStack.removeLast()
                // Extract the return type from the function type
                let returnType: CType
                if case .function(_, let ret, _) = type {
                    returnType = ret
                } else {
                    returnType = type
                }
                let funcDecl = FuncDecl(name: name, returnType: returnType,
                                        params: savedParams,
                                        variadic: savedVariadic,
                                        body: body, storageClass: storageClass, isInline: isInline, loc: loc,
                                        localLabels: labels, paramVLAExprs: savedParamVLAExprs)
                return .funcDecl(funcDecl)
            }

            // Optional initializer
            var initExpr: Expr? = nil
            var actualType = type
            if match(kind: .punct, spelling: "=") {
                initExpr = try parseInitializer(type: type)
                // If the type is an incomplete array and initializer is an init list,
                // infer the array size from the number of elements
                if case .incompleteArray(let elem) = type.unqualified,
                   case .initList(let il) = initExpr! {
                    // For arrays of structs with flat init lists, divide by fields per struct
                    if case .structType(let rec) = elem.unqualified, !rec.fields.isEmpty {
                        let fieldsPerStruct = countScalarFields(rec)
                        if fieldsPerStruct > 0 {
                            // Check if any values are brace-enclosed (initList) — each counts as one element
                            let hasBraceElements = il.values.contains { v in
                                if case .initList = v { return true }
                                if case .compoundLiteral = v { return true }
                                return false
                            }
                            if hasBraceElements {
                                // Each initList is one element, each scalar is also one element
                                actualType = .array(of: elem, count: il.values.count)
                            } else {
                                actualType = .array(of: elem, count: (il.values.count + fieldsPerStruct - 1) / fieldsPerStruct)
                            }
                        } else {
                            actualType = .array(of: elem, count: il.values.count)
                        }
                    } else {
                        actualType = .array(of: elem, count: il.values.count)
                    }
                }
                // If the type is an incomplete char array and initializer is a string literal,
                // infer the array size from the string length + 1 (null terminator)
                if case .incompleteArray(let elem) = type.unqualified,
                   elem.isChar,
                   case .stringLiteral(let sl) = initExpr! {
                    actualType = .array(of: elem, count: countDecodedBytes(sl.value) + 1)
                }
            }

            // Function prototype (no body) — create a FuncDecl instead of VarDecl
            if type.isFunction {
                let returnType: CType
                if case .function(_, let ret, _) = type {
                    returnType = ret
                } else {
                    returnType = type
                }
                let fd = FuncDecl(name: name, returnType: returnType,
                                  params: lastFuncParams,
                                  variadic: lastFuncVariadic,
                                  body: nil, storageClass: storageClass, isInline: isInline, loc: loc,
                                  paramVLAExprs: lastFuncParamVLAExprs)
                if firstDecl == nil {
                    firstDecl = .funcDecl(fd)
                }
            } else {
                let varDecl = VarDecl(name: name, type: actualType, initializer: initExpr,
                                      storageClass: storageClass, isGlobal: true, loc: loc)
                globalVarTypes[name] = actualType
                additionalDecls.append(.varDecl(varDecl))
                if firstDecl == nil {
                    firstDecl = .varDecl(varDecl)
                }
            }

            // Comma for multiple declarators
        } while match(kind: .punct, spelling: ",")

        if !isPunct(";") {
            throw ParseError.expected("';'", current().spelling, current().loc)
        }
        _ = try consume(kind: .punct, spelling: ";")

        // If there were multiple declarators, queue the extras for parse() to pick up
        if additionalDecls.count > 1 {
            pendingExternalDecls = Array(additionalDecls.dropFirst())
        }
        return firstDecl
    }

    // MARK: - Static assert

    private func parseStaticAssert() throws -> Decl {
        let loc = advance().loc // _Static_assert
        _ = try consume(kind: .punct, spelling: "(")
        let cond = try parseAssignmentExpr()
        var msg: String? = nil
        if match(kind: .punct, spelling: ",") {
            if current().kind == .stringLiteral {
                msg = current().spelling
                advance()
            }
        }
        _ = try consume(kind: .punct, spelling: ")")
        _ = try consume(kind: .punct, spelling: ";")
        return .staticAssert(StaticAssertDecl(condition: cond, message: msg, loc: loc))
    }

    // MARK: - Typedef

    private func parseTypedef() throws -> Decl {
        let loc = advance().loc // typedef
        let (baseType, _, _, _) = try parseDeclSpecifiers()
        var firstDecl: Decl? = nil

        repeat {
            let (name, type, declLoc) = try parseDeclarator(baseType)
            // Skip __attribute__ after the typedef declarator
            skipAsmAndAttributes()
            typedefNames.insert(name)
            typedefTypes[name] = type
            let td = TypedefDecl(name: name, type: type, loc: declLoc)
            if firstDecl == nil { firstDecl = .typedefDecl(td) }
        } while match(kind: .punct, spelling: ",")

        _ = try consume(kind: .punct, spelling: ";")
        return firstDecl ?? .typedefDecl(TypedefDecl(name: "", type: .int, loc: loc))
    }

    // MARK: - Declaration specifiers

    /// Parse declaration specifiers: storage class, type qualifier, type specifier.
    /// Returns (type, storageClass, isInline, isTypedef).
    private func parseDeclSpecifiers() throws -> (CType, StorageClass, Bool, Bool) {
        var storageClass: StorageClass = .none
        var isInline = false
        var isTypedef = false
        var typeSpecifiers: [String] = []  // "int", "long", "unsigned", etc.
        var structType: CType? = nil
        var unionType: CType? = nil
        var enumType: CType? = nil
        var typedefBase: CType? = nil
        var isConst = false
        var isVolatile = false
        var isRestrict = false

        var done = false
        while !done && !isAtEnd() {
            let t = current()

            // C23 standard attributes: [[...]] — skip (like __attribute__)
            if isPunct("[") && next().spelling == "[" {
                skipC23Attributes()
                continue
            }

            if t.kind == .keyword {
                switch t.spelling {
                // Storage classes
                case "static": storageClass = .static; advance()
                case "extern": storageClass = .extern; advance()
                case "register": storageClass = .register; advance()
                case "auto": storageClass = .auto; advance()
                case "typedef": isTypedef = true; advance()

                // _Alignas(...) — skip alignment specifier (C11)
                case "_Alignas":
                    advance()
                    if isPunct("(") {
                        var depth = 0
                        while !isAtEnd() {
                            if isPunct("(") { depth += 1; advance() }
                            else if isPunct(")") { depth -= 1; advance(); if depth == 0 { break } }
                            else { advance() }
                        }
                    }

                // Type qualifiers
                case "const": isConst = true; advance()
                case "volatile": isVolatile = true; advance()
                case "restrict": isRestrict = true; advance()
                case "__restrict": isRestrict = true; advance()
                case "__restrict__": isRestrict = true; advance()
                case "__const": isConst = true; advance()
                case "__const__": isConst = true; advance()
                case "__volatile": isVolatile = true; advance()
                case "__volatile__": isVolatile = true; advance()
                case "__inline": isInline = true; advance()
                case "__inline__": isInline = true; advance()
                case "__signed": typeSpecifiers.append("signed"); advance()
                case "__signed__": typeSpecifiers.append("signed"); advance()
                case "inline": isInline = true; advance()

                // Type specifiers
                case "void": typeSpecifiers.append("void"); advance()
                case "char": typeSpecifiers.append("char"); advance()
                case "short": typeSpecifiers.append("short"); advance()
                case "int": typeSpecifiers.append("int"); advance()
                case "long": typeSpecifiers.append("long"); advance()
                case "float": typeSpecifiers.append("float"); advance()
                case "double": typeSpecifiers.append("double"); advance()
                case "signed": typeSpecifiers.append("signed"); advance()
                case "unsigned": typeSpecifiers.append("unsigned"); advance()
                case "_Bool": typeSpecifiers.append("_Bool"); advance()
                case "_Complex": typeSpecifiers.append("_Complex"); advance()
                case "__complex__": typeSpecifiers.append("_Complex"); advance()
                case "__complex": typeSpecifiers.append("_Complex"); advance()
                case "_Imaginary": typeSpecifiers.append("_Imaginary"); advance()

                case "struct":
                    structType = try parseStructOrUnion(isStruct: true)
                case "union":
                    unionType = try parseStructOrUnion(isStruct: false)
                case "enum":
                    enumType = try parseEnumSpec()

                // GCC extensions — skip
                case "__attribute__", "__attribute":
                    // Extract any aligned(N) for application to the declared type
                    // (e.g. `int __attribute__((aligned(8))) a` in a struct field).
                    if let aa = extractAlignment() {
                        pendingDeclAligned = max(pendingDeclAligned ?? 0, aa)
                    }
                case "__asm", "__asm__":
                    advance()
                    if isPunct("(") {
                        var depth = 0
                        while !isAtEnd() {
                            if isPunct("(") { depth += 1; advance() }
                            else if isPunct(")") { depth -= 1; advance(); if depth == 0 { break } }
                            else { advance() }
                        }
                    }
                case "__extension__":
                    advance() // just skip

                // typeof / __typeof / __typeof__ — GNU extension: type of an expression or type
                case "typeof", "__typeof", "__typeof__":
                    advance() // consume typeof keyword
                    _ = try consume(kind: .punct, spelling: "(")
                    // Check if this is typeof(type) or typeof(expr)
                    let nextTok = next()
                    if nextTok.kind == .keyword && isTypeKeyword(nextTok.spelling) ||
                       (nextTok.kind == .identifier && typedefNames.contains(nextTok.spelling)) {
                        // typeof(type) — parse the type
                        let (innerBase, _, _, _) = try parseDeclSpecifiers()
                        let (_, innerType, _) = try parseDeclarator(innerBase)
                        _ = try consume(kind: .punct, spelling: ")")
                        typedefBase = innerType
                    } else {
                        // typeof(expr) — parse the expression and get its type
                        let expr = try parseExpr()
                        _ = try consume(kind: .punct, spelling: ")")
                        typedefBase = typeofExprType(expr)
                    }

                default:
                    done = true
                }
            } else if isTypedefName() && typeSpecifiers.isEmpty && structType == nil && unionType == nil && enumType == nil && typedefBase == nil {
                // Typedef name used as type specifier
                let name = current().spelling
                // Use the actual resolved type if known, otherwise default to .int
                var base = typedefTypes[name] ?? .int
                // If the typedef points to an incomplete struct/union, try to
                // find the completed definition (the typedef may have been
                // parsed before the struct body was defined).
                if case .structType(let rec) = base, rec.fields.isEmpty, let tag = rec.name.isEmpty ? nil : rec.name,
                   let completed = completedRecords[tag] {
                    base = .structType(completed)
                } else if case .unionType(let rec) = base, rec.fields.isEmpty, let tag = rec.name.isEmpty ? nil : rec.name,
                          let completed = completedRecords[tag] {
                    base = .unionType(completed)
                }
                typedefBase = CType.typedef(name: name, base: base)
                advance()
            } else if current().kind == .identifier && isForwardTypedef() {
                // Unknown identifier used as a type in a typedef context
                // (e.g., typedef __int64 sqlite3_int64; where __int64 is unknown)
                let name = current().spelling
                typedefNames.insert(name)
                typedefBase = CType.typedef(name: name, base: .long)
                advance()
            } else {
                done = true
            }
        }

        // Build the type from specifiers
        var baseType: CType

        if let st = structType {
            baseType = st
        } else if let ut = unionType {
            baseType = ut
        } else if let et = enumType {
            baseType = et
        } else if let tb = typedefBase {
            baseType = tb
        } else if typeSpecifiers.isEmpty {
            baseType = .int  // default to int (implicit int, C89 style)
        } else {
            baseType = buildTypeFromSpecifiers(typeSpecifiers)
        }

        // Apply qualifiers
        if isConst || isVolatile || isRestrict {
            baseType = .qualified(base: baseType, const: isConst, volatile: isVolatile, restrict: isRestrict)
        }

        return (baseType, storageClass, isInline, isTypedef)
    }

    /// Build a CType from type specifier keywords like ["unsigned", "long", "long"].
    private func buildTypeFromSpecifiers(_ specs: [String]) -> CType {
        var isUnsigned = specs.contains("unsigned")
        let isSigned = specs.contains("signed")
        _ = isSigned
        let longCount = specs.filter { $0 == "long" }.count
        let hasShort = specs.contains("short")
        let hasInt = specs.contains("int")
        _ = hasInt
        let hasFloat = specs.contains("float")
        let hasDouble = specs.contains("double")
        let hasChar = specs.contains("char")
        let hasVoid = specs.contains("void")
        let hasBool = specs.contains("_Bool")
        let hasComplex = specs.contains("_Complex")
        let hasImaginary = specs.contains("_Imaginary")

        if hasVoid { return .void }
        if hasBool { return .bool }
        if hasChar { return isUnsigned ? .uchar : .char }
        if hasComplex {
            if hasFloat { return .complexFloat }
            if longCount > 0 { return .complexLongDouble }
            if hasDouble { return .complexDouble }
            // _Complex with integer type is allowed but rare; default to complex double
            return .complexDouble
        }
        if hasImaginary {
            // Treat _Imaginary like _Complex with zero real part
            if hasFloat { return .complexFloat }
            if longCount > 0 { return .complexLongDouble }
            if hasDouble { return .complexDouble }
            return .complexDouble
        }
        if hasDouble {
            if longCount > 0 { return .longDouble }
            return .double
        }
        if hasFloat { return .float }
        if hasShort { return isUnsigned ? .ushort : .short }
        if longCount >= 2 { return isUnsigned ? .ulongLong : .longLong }
        if longCount == 1 { return isUnsigned ? .ulong : .long }
        // Default: int (possibly unsigned)
        return isUnsigned ? .uint : .int
    }

    // MARK: - Struct / Union

    private func parseStructOrUnion(isStruct: Bool) throws -> CType {
        let kwLoc = advance().loc // struct/union keyword

        // Skip __attribute__ between keyword and tag
        skipAsmAndAttributes()

        // Optional tag name
        var tag: String? = nil
        if current().kind == .identifier {
            tag = current().spelling
            advance()
        }

        // Skip __attribute__ between tag and body
        skipAsmAndAttributes()

        // If there's a body { ... }
        if isPunct("{") {
            advance() // {
            var fields: [RecordField] = []
            var maxAlign = 1

            if isStruct {
                // Struct: sequential layout with alignment padding and bitfield packing
                var bitOffset = 0  // track position in bits for bitfield packing
                while !isPunct("}") && !isAtEnd() {
                    let (baseType, _, _, _) = try parseDeclSpecifiers()
                    repeat {
                        let (fieldName, fieldType, _) = try parseDeclarator(baseType)
                        // Skip __attribute__ after the field declarator
                        skipAsmAndAttributes()
                        var bitWidth: Int? = nil
                        if match(kind: .punct, spelling: ":") {
                            let widthExpr = try parseConditionalExpr()
                            bitWidth = Int(evalIntConst(widthExpr))
                        }
                        // Skip __attribute__ after the bitfield width (e.g., int x:3 __attribute__((packed)))
                        skipAsmAndAttributes()
                        if let bw = bitWidth {
                            // Bitfield: pack into allocation unit of the declared type
                            let typeSize = fieldType.sizeInBytes ?? 0
                            let typeAlign = fieldType.alignOf ?? 1
                            let unitBits = typeSize * 8
                            let alignBits = typeAlign * 8
                            maxAlign = max(maxAlign, typeAlign)
                            // Find current allocation unit boundary
                            let unitStart = (bitOffset / alignBits) * alignBits
                            let posInUnit = bitOffset - unitStart
                            // If bitfield doesn't fit in current unit, advance to next unit
                            if posInUnit + bw > unitBits {
                                bitOffset = unitStart + unitBits
                            }
                            // Recompute unit start (may have advanced)
                            let unitStart2 = (bitOffset / alignBits) * alignBits
                            let bitPosInUnit = bitOffset - unitStart2
                            let unitByteOff = unitStart2 / 8
                            fields.append(RecordField(name: fieldName, type: fieldType, bitWidth: bitWidth, offset: unitByteOff, bitOffset: bitPosInUnit))
                            bitOffset += bw
                        } else {
                            // Non-bitfield: round bit offset up to byte, then align
                            var byteOff = (bitOffset + 7) / 8
                            var fieldAlign = fieldType.alignOf ?? 1
                            // Apply __attribute__((aligned(N))) — either from the
                            // field declarator (parsed above via skipAsmAndAttributes)
                            // or from between the base type and declarator (captured
                            // by parseDeclSpecifiers into pendingDeclAligned).
                            if let attrAlign = extractAlignment() {
                                fieldAlign = max(fieldAlign, attrAlign)
                            } else {
                                skipAsmAndAttributes()
                            }
                            if let pa = pendingDeclAligned {
                                fieldAlign = max(fieldAlign, pa)
                            }
                            pendingDeclAligned = nil
                            let fieldSize = fieldType.sizeInBytes ?? 0
                            // Apply #pragma pack: effective alignment is min(natural, pack)
                            let effectiveAlign = currentPack > 0 ? min(fieldAlign, currentPack) : fieldAlign
                            maxAlign = max(maxAlign, effectiveAlign)
                            byteOff = (byteOff + effectiveAlign - 1) & ~(effectiveAlign - 1)
                            fields.append(RecordField(name: fieldName, type: fieldType, bitWidth: nil, offset: byteOff, bitOffset: 0))
                            bitOffset = (byteOff + fieldSize) * 8
                        }
                    } while match(kind: .punct, spelling: ",")
                    _ = try consume(kind: .punct, spelling: ";")
                }
                _ = try consume(kind: .punct, spelling: "}")
                // Parse __attribute__((aligned(N))) after the closing brace
                let attrAlign = extractAlignment()
                // Round up bitOffset to bytes, then to maxAlign
                var totalBytes = (bitOffset + 7) / 8
                if let aa = attrAlign { maxAlign = max(maxAlign, aa) }
                totalBytes = (totalBytes + maxAlign - 1) & ~(maxAlign - 1)
                let rec = RecordType(name: tag ?? "", fields: fields, size: totalBytes, alignment: maxAlign)
                if let tag = tag {
                    completedRecords[tag] = rec
                }
                return .structType(rec)
            } else {
                // Union: all fields at offset 0, size = max member size
                var maxSize = 0
                while !isPunct("}") && !isAtEnd() {
                    let (baseType, _, _, _) = try parseDeclSpecifiers()
                    repeat {
                        let (fieldName, fieldType, _) = try parseDeclarator(baseType)
                        // Skip __attribute__ after the field declarator
                        skipAsmAndAttributes()
                        var bitWidth: Int? = nil
                        if match(kind: .punct, spelling: ":") {
                            let widthExpr = try parseConditionalExpr()
                            bitWidth = Int(evalIntConst(widthExpr))
                        }
                        // Skip __attribute__ after the bitfield width (e.g., int x:3 __attribute__((packed)))
                        skipAsmAndAttributes()
                        let fieldSize = fieldType.sizeInBytes ?? 0
                        let fieldAlign = fieldType.alignOf ?? 1
                        maxAlign = max(maxAlign, fieldAlign)
                        maxSize = max(maxSize, fieldSize)
                        fields.append(RecordField(name: fieldName, type: fieldType, bitWidth: bitWidth, offset: 0))
                    } while match(kind: .punct, spelling: ",")
                    _ = try consume(kind: .punct, spelling: ";")
                }
                _ = try consume(kind: .punct, spelling: "}")
                let totalSize = (maxSize + maxAlign - 1) & ~(maxAlign - 1)
                let rec = RecordType(name: tag ?? "", fields: fields, size: totalSize, alignment: maxAlign)
                if let tag = tag {
                    completedRecords[tag] = rec
                }
                return .unionType(rec)
            }
        }

        // Forward declaration or reference: struct Tag (no body)
        // If we've previously seen the definition, return the completed record.
        if let tag = tag, let completed = completedRecords[tag] {
            return isStruct ? .structType(completed) : .unionType(completed)
        }
        // Create an incomplete record (will be completed when definition is seen)
        let rec = RecordType(name: tag ?? "", fields: [], size: nil, alignment: nil)
        return isStruct ? .structType(rec) : .unionType(rec)
    }

    // MARK: - Enum

    private func parseEnumSpec() throws -> CType {
        advance() // enum keyword

        var tag: String? = nil
        if current().kind == .identifier {
            tag = current().spelling
            advance()
        }

        if isPunct("{") {
            advance() // {
            var cases: [EnumCase] = []
            var nextValue = 0

            while !isPunct("}") && !isAtEnd() {
                guard current().kind == .identifier else {
                    if isPunct("}") { break }
                    throw ParseError.expected("enumerator name", current().spelling, current().loc)
                }
                let name = advance().spelling
                // Skip __attribute__ or __CLOCK_AVAILABILITY between name and =
                skipAsmAndAttributes()
                if match(kind: .punct, spelling: "=") {
                    let valExpr = try parseConditionalExpr()
                    nextValue = Int(evalIntConst(valExpr))
                }
                cases.append(EnumCase(name: name, value: nextValue))
                // Register enum constant for use in subsequent constant expressions
                parserEnumConstants[name] = Int64(nextValue)
                nextValue += 1
                if !match(kind: .punct, spelling: ",") {
                    break
                }
            }
            _ = try consume(kind: .punct, spelling: "}")
            let en = EnumType(name: tag ?? "", cases: cases, underlyingType: .int)
            return .enumType(en)
        }

        // Reference to named enum
        let en = EnumType(name: tag ?? "", cases: [], underlyingType: .int)
        return .enumType(en)
    }

    // MARK: - Declarator

    /// Parse a declarator. Returns (name, type, loc).
    /// The baseType is modified by pointer/array/function declarators.
    private func parseDeclarator(_ baseType: CType) throws -> (String, CType, SourceLoc) {
        var type = baseType

        // Pointer prefixes
        while isPunct("*") {
            advance()
            // Skip qualifiers after *
            while isKeyword("const") || isKeyword("volatile") || isKeyword("restrict") ||
                  isKeyword("__const") || isKeyword("__const__") ||
                  isKeyword("__volatile") || isKeyword("__volatile__") ||
                  isKeyword("__restrict") || isKeyword("__restrict__") {
                advance()
            }
            // Skip __attribute__ after pointer qualifiers (e.g., void *__attribute__((noinline)) baz())
            skipAsmAndAttributes()
            type = .pointer(to: type)
        }
        // Also skip __attribute__ that appears between base type and declarator name
        // (e.g., void __attribute__((noinline)) baz() — attribute applies to the function)
        skipAsmAndAttributes()

        // Parenthesized declarator (for function pointers)
        if isPunct("(") {
            // Could be a function declarator or a parenthesized declarator
            // Peek: if next is *, (, or identifier followed by ), it's likely a parenthesized declarator
            // For now, treat as function declarator if it looks like one
            // This is a simplification — full handling requires backtracking
            // Check: is this a function pointer? ( in declarator context usually means function pointer
            // E.g., int (*pf)(int)
            // Save position for backtracking
            let savePos = pos
            advance() // (
            // Skip __attribute__ between ( and *
            skipAsmAndAttributes()
            // Handle () — abstract function type (e.g., `int ()` means function returning int)
            if isPunct(")") {
                advance() // )
                // This is a function type with no params
                type = .function(params: [], returnType: type, variadic: false)
                // Check for suffix: (params) or [N]
                while isPunct("(") || isPunct("[") {
                    if isPunct("(") {
                        let (params, variadic, retType) = try parseFunctionParams(type)
                        type = .function(params: params.map { $0.type }, returnType: retType, variadic: variadic)
                    } else {
                        let dim = try parseArrayDimension()
                        if let c = dim.count { type = .array(of: type, count: c) }
                        else { type = .incompleteArray(of: type) }
                    }
                }
                return ("", type, SourceLoc.unknown)
            }
            // Handle (type ...) — abstract function declarator with params (e.g., `int (int x)`)
            if current().kind == .keyword && isTypeKeyword(current().spelling) {
                // Function type: int (int x) or int (int)
                // We already consumed (, so parse params manually
                var params: [Param] = []
                var variadic = false
                while !isPunct(")") && !isAtEnd() {
                    if isPunct("...") { advance(); variadic = true; break }
                    let (baseType, _, _, _) = try parseDeclSpecifiers()
                    let (paramName, paramType, paramLoc) = try parseDeclarator(baseType)
                    var actualType = paramType
                    if case .array(let elem, _) = actualType.unqualified {
                        actualType = .pointer(to: elem)
                    } else if case .incompleteArray(let elem) = actualType.unqualified {
                        actualType = .pointer(to: elem)
                    } else if case .function = actualType.unqualified {
                        actualType = .pointer(to: actualType)
                    }
                    params.append(Param(name: paramName.isEmpty ? nil : paramName, type: actualType, loc: paramLoc))
                    if !match(kind: .punct, spelling: ",") { break }
                }
                _ = try consume(kind: .punct, spelling: ")")
                type = .function(params: params.map { $0.type }, returnType: type, variadic: variadic)
                return ("", type, SourceLoc.unknown)
            }
            // Handle (*[N])(params) — array of function pointers
            if isPunct("*") {
                // Function pointer: (*name)(params) or (*(*name)(params))(params)
                advance() // consume the first *
                // Handle nested: (*(*name)...) — consume additional * and inner (
                var pointerDepth = 1
                while isPunct("*") {
                    advance()
                    pointerDepth += 1
                }
                // If we see (, it's a nested function pointer — skip the inner (*
                var hadInnerParen = false
                if isPunct("(") {
                    advance() // consume inner (
                    hadInnerParen = true
                    while isPunct("*") { advance(); pointerDepth += 1 }
                }
                // Skip qualifiers
                while isKeyword("const") || isKeyword("volatile") { advance() }
                // Save the base type (before pointer/array wrapping) for building the function type
                let baseTypeForFunc = type
                var innerType = type
                for _ in 0..<pointerDepth {
                    innerType = .pointer(to: innerType)
                }
                // Get the name (may be empty for abstract declarators)
                var name = ""
                var nameLoc = SourceLoc.unknown
                if current().kind == .identifier {
                    name = current().spelling
                    nameLoc = advance().loc
                } else if isPunct(")") {
                    // Abstract: (*) — no name, just a pointer
                    nameLoc = current().loc
                } else if isPunct("[") {
                    // Abstract: (*[N]) — array of N pointers, no name
                    nameLoc = current().loc
                    // Parse array dimensions
                    var arrayDims: [Int?] = []
                    while isPunct("[") {
                        arrayDims.append(try parseArrayDimension().count)
                    }
                    _ = try consume(kind: .punct, spelling: ")")
                    // Check for function params: (*[N])(params)
                    if isPunct("(") {
                        let (params, variadic, retType) = try parseFunctionParams(baseTypeForFunc)
                        var funcType = CType.function(params: params.map { $0.type }, returnType: retType, variadic: variadic)
                        // Wrap with pointer(s)
                        for _ in 0..<pointerDepth {
                            funcType = .pointer(to: funcType)
                        }
                        // Wrap with array dimensions (outermost last)
                        for d in arrayDims.reversed() {
                            if let c = d { funcType = .array(of: funcType, count: c) }
                            else { funcType = .incompleteArray(of: funcType) }
                        }
                        type = funcType
                        return ("", type, nameLoc)
                    }
                    // Just a pointer (possibly array of pointers)
                    var ptrType = innerType
                    for d in arrayDims.reversed() {
                        if let c = d { ptrType = .array(of: ptrType, count: c) }
                        else { ptrType = .incompleteArray(of: ptrType) }
                    }
                    type = ptrType
                    return ("", type, nameLoc)
                } else {
                    throw ParseError.expected("identifier", current().spelling, current().loc)
                }
                // Check if this is a function returning a function pointer:
                // void (*name(params))(return_params) — name is followed by ( for params
                if !name.isEmpty && isPunct("(") {
                    // Function returning function pointer: name(params)
                    let (funcParams, funcVariadic, funcRetType) = try parseFunctionParams(innerType)
                    // Save the function's own params (before parsing return type params overwrites lastFuncParams)
                    let savedFuncParams = lastFuncParams
                    let savedFuncVariadic = lastFuncVariadic
                    _ = try consume(kind: .punct, spelling: ")")
                    // Now parse the return params: ( return_params )
                    let (retParams, retVariadic, retRetType) = try parseFunctionParams(funcRetType)
                    let funcType = CType.function(params: funcParams.map { $0.type },
                                                  returnType: .function(params: retParams.map { $0.type },
                                                                        returnType: retRetType, variadic: retVariadic),
                                                  variadic: funcVariadic)
                    // Restore the function's own params for the FuncDecl
                    lastFuncParams = savedFuncParams
                    lastFuncVariadic = savedFuncVariadic
                    return (name, funcType, nameLoc)
                }
                // Handle array suffixes inside the parens: (*name[3])
                // Track how many array dimensions and their sizes
                var arrayDims: [(count: Int?, isPointer: Bool)] = []
                while isPunct("[") {
                    advance()
                    // Skip qualifiers
                    while isKeyword("const") || isKeyword("volatile") || isKeyword("restrict") ||
                          isKeyword("static") {
                        advance()
                    }
                    if isPunct("]") {
                        advance()
                        arrayDims.append((count: nil, isPointer: false))
                    } else if isPunct("*") {
                        advance()
                        _ = try consume(kind: .punct, spelling: "]")
                        arrayDims.append((count: nil, isPointer: false))
                    } else {
                        let sizeExpr = try parseAssignmentExpr()
                        _ = try consume(kind: .punct, spelling: "]")
                        let size = evalIntConst(sizeExpr)
                        arrayDims.append((count: Int(size), isPointer: false))
                    }
                }
                _ = try consume(kind: .punct, spelling: ")")
                // After (*name), check what follows:
                // ( params )  → function pointer: (*name)(int, double)
                // [ N ]       → pointer to array: char (*p)[4]
                // otherwise   → plain pointer
                if isPunct("(") {
                    // Function pointer: (*name)(params)
                    let (params, variadic, retType) = try parseFunctionParams(baseTypeForFunc)
                    var funcType = CType.function(params: params.map { $0.type }, returnType: retType, variadic: variadic)
                    // Wrap with pointer(s)
                    for _ in 0..<pointerDepth {
                        funcType = .pointer(to: funcType)
                    }
                    // Wrap with array dimensions from inside parens (outermost last)
                    for dim in arrayDims.reversed() {
                        if let count = dim.count {
                            funcType = .array(of: funcType, count: count)
                        } else {
                            funcType = .incompleteArray(of: funcType)
                        }
                    }
                    type = funcType
                    if hadInnerParen {
                        _ = try consume(kind: .punct, spelling: ")")
                    }
                    // Continue to suffix parsing (e.g., function returning function pointer)
                    let savedName = name
                    let savedLoc = nameLoc
                    while isPunct("[") || isPunct("(") {
                        if isPunct("[") {
                            var dims: [Int?] = []
                            while isPunct("[") {
                                dims.append(try parseArrayDimension().count)
                            }
                            for d in dims.reversed() {
                                if let c = d { type = .array(of: type, count: c) }
                                else { type = .incompleteArray(of: type) }
                            }
                        } else if isPunct("(") {
                            let (params2, variadic2, retType2) = try parseFunctionParams(type)
                            type = .function(params: params2.map { $0.type }, returnType: retType2, variadic: variadic2)
                        }
                    }
                    return (savedName, type, savedLoc)
                } else {
                    // Not a function pointer — pointer (possibly to array)
                    // e.g., char (*p)[4] → p is pointer to array of 4 chars
                    // Parse array suffixes after )
                    var suffixDims: [Int?] = []
                    while isPunct("[") {
                        suffixDims.append(try parseArrayDimension().count)
                    }
                    // Build inner type: apply suffix dims to base type (right-to-left),
                    // then wrap with pointer(s), then apply inner arrayDims as outer arrays
                    var innerType = baseTypeForFunc
                    for d in suffixDims.reversed() {
                        if let c = d { innerType = .array(of: innerType, count: c) }
                        else { innerType = .incompleteArray(of: innerType) }
                    }
                    for _ in 0..<pointerDepth {
                        innerType = .pointer(to: innerType)
                    }
                    for dim in arrayDims.reversed() {
                        if let count = dim.count {
                            innerType = .array(of: innerType, count: count)
                        } else {
                            innerType = .incompleteArray(of: innerType)
                        }
                    }
                    type = innerType
                    if hadInnerParen {
                        _ = try consume(kind: .punct, spelling: ")")
                    }
                    // Parse any more suffixes
                    let savedName = name
                    let savedLoc = nameLoc
                    while isPunct("[") || isPunct("(") {
                        if isPunct("[") {
                            var dims2: [Int?] = []
                            while isPunct("[") {
                                dims2.append(try parseArrayDimension().count)
                            }
                            for d in dims2.reversed() {
                                if let c = d { type = .array(of: type, count: c) }
                                else { type = .incompleteArray(of: type) }
                            }
                        } else if isPunct("(") {
                            let (params2, variadic2, retType2) = try parseFunctionParams(type)
                            type = .function(params: params2.map { $0.type }, returnType: retType2, variadic: variadic2)
                        }
                    }
                    return (savedName, type, savedLoc)
                }
            } else if current().kind == .identifier {
                // Parenthesized declarator: (name[dimensions]) or (name)
                // Parse the inner declarator recursively
                let (innerName, innerType, innerLoc) = try parseDeclarator(type)
                _ = try consume(kind: .punct, spelling: ")")
                // Apply any suffixes after the )
                var resultType = innerType
                var suffixName = innerName
                let suffixLoc = innerLoc
                while isPunct("[") || isPunct("(") {
                    if isPunct("[") {
                        var dims: [Int?] = []
                        while isPunct("[") {
                            dims.append(try parseArrayDimension().count)
                        }
                        for d in dims.reversed() {
                            if let c = d { resultType = .array(of: resultType, count: c) }
                            else { resultType = .incompleteArray(of: resultType) }
                        }
                    } else if isPunct("(") {
                        let (params, variadic, retType) = try parseFunctionParams(resultType)
                        resultType = .function(params: params.map { $0.type }, returnType: retType, variadic: variadic)
                    }
                }
                return (suffixName, resultType, suffixLoc)
            } else {
                // Not a function pointer — restore and parse as normal declarator
                pos = savePos
            }
        }

        // Direct declarator
        var name = ""
        var loc = SourceLoc.unknown

        if current().kind == .identifier {
            name = current().spelling
            loc = advance().loc
        }

        // Suffix: array [N] or function (params)
        // Collect all array dimensions first, then apply right-to-left
        while isPunct("[") || isPunct("(") {
            if isPunct("[") {
                var dims: [Int?] = []
                var vlaExprs: [Expr] = []
                while isPunct("[") {
                    let dim = try parseArrayDimension()
                    dims.append(dim.count)
                    if let vla = dim.vlaExpr {
                        vlaExprs.append(vla)
                    }
                }
                // VLA expressions: the last one is the outer dimension (stored in pendingVLASizeExprs).
                // Inner dimensions are stored in reverse order (innermost first).
                pendingVLASizeExprs = vlaExprs
                for d in dims.reversed() {
                    if let c = d { type = .array(of: type, count: c) }
                    else { type = .incompleteArray(of: type) }
                }
            } else if isPunct("(") {
                let (params, variadic, retType) = try parseFunctionParams(type)
                type = .function(params: params.map { $0.type }, returnType: retType, variadic: variadic)
            }
        }

        // Skip postfix __attribute__ after declarator (e.g., int a[4] __attribute__((aligned(16))))
        skipAsmAndAttributes()

        return (name, type, loc)
    }

    /// Count the number of scalar fields in a struct (recursively).
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

    /// Parse a single array dimension `[ ... ]`, skipping type qualifiers
    /// (const, volatile, restrict, static) that may appear before the size.
    /// Returns nil for `[]` (incomplete array) or the constant size.
    private func parseArrayDimension() throws -> (count: Int?, vlaExpr: Expr?) {
        _ = try consume(kind: .punct, spelling: "[")
        // Skip qualifiers: static, const, volatile, restrict
        while isKeyword("const") || isKeyword("volatile") || isKeyword("restrict") ||
              isKeyword("static") || isKeyword("__restrict") || isKeyword("__restrict__") {
            advance()
        }
        if isPunct("]") {
            advance()
            return (nil, nil)
        }
        // `[*]` means variable-length array (VLA) — decays to pointer in params
        if isPunct("*") {
            advance()
            _ = try consume(kind: .punct, spelling: "]")
            return (nil, nil)
        }
        // The size expression may be preceded by qualifiers (e.g., `[const 5]`)
        // — already skipped above. Now parse the size expression.
        let sizeExpr = try parseAssignmentExpr()
        _ = try consume(kind: .punct, spelling: "]")
        // Only treat as a fixed-size array if the expression is a true compile-time
        // constant. evalIntConst returns 0 for unknown identifiers, so an expression
        // like `n + 1` would otherwise fold to `0 + 1 = 1` and be misidentified as a
        // fixed array of size 1 instead of a VLA. Any variable reference makes the
        // dimension a VLA.
        if isConstantExpr(sizeExpr) {
            let constVal = evalIntConst(sizeExpr)
            if constVal != 0 {
                return (Int(constVal), nil)
            }
            // [0] is a zero-size array (GCC extension); only valid as a constant.
            if case .integerLiteral = sizeExpr {
                return (0, nil)
            }
        }
        // Non-constant expression: VLA
        return (nil, sizeExpr)
    }

    /// Parse function parameters: ( int a, int b, ... )
    /// Returns (params, variadic, returnType).
    private func parseFunctionParams(_ returnType: CType) throws -> ([Param], Bool, CType) {
        _ = try consume(kind: .punct, spelling: "(")
        var params: [Param] = []
        var variadic = false

        // void as sole parameter means no parameters
        if isKeyword("void") && next().kind == .punct && next().spelling == ")" {
            advance() // void
            _ = try consume(kind: .punct, spelling: ")")
            lastFuncParams = []
            lastFuncVariadic = false
            return ([], false, returnType)
        }

        // K&R-style identifier list: (a, b, c) with no type specifiers
        // The types are declared after the ) in a separate declaration list.
        // Only treat as K&R if the first identifier is NOT a typedef name.
        if current().kind == .identifier && next().kind == .punct &&
           (next().spelling == "," || next().spelling == ")") &&
           !typedefNames.contains(current().spelling) {
            // Parse identifier list — all params default to int
            while !isPunct(")") && !isAtEnd() {
                if isPunct("...") {
                    advance()
                    variadic = true
                    break
                }
                let paramName = current().spelling
                let paramLoc = current().loc
                advance()
                params.append(Param(name: paramName, type: .int, loc: paramLoc))
                if !match(kind: .punct, spelling: ",") {
                    break
                }
            }
            _ = try consume(kind: .punct, spelling: ")")
            lastFuncParams = params
            lastFuncVariadic = variadic
            // Signal K&R style by returning a special marker
            // The caller will parse the declaration list before the body
            return (params, variadic, returnType)
        }

        var paramVLAExprs: [[Expr]] = []
        while !isPunct(")") && !isAtEnd() {
            if isPunct("...") {
                advance()
                variadic = true
                break
            }

            let (baseType, _, _, _) = try parseDeclSpecifiers()
            let (paramName, paramType, paramLoc) = try parseDeclarator(baseType)
            // Capture VLA dimension expressions (for side effects like a++)
            let vlaExprs = pendingVLASizeExprs
            pendingVLASizeExprs = []
            // In function params, array types decay to pointers
            var actualType = paramType
            if case .array(let elem, _) = actualType.unqualified {
                actualType = .pointer(to: elem)
            } else if case .incompleteArray(let elem) = actualType.unqualified {
                actualType = .pointer(to: elem)
            }
            params.append(Param(name: paramName.isEmpty ? nil : paramName, type: actualType, loc: paramLoc))
            paramVLAExprs.append(vlaExprs)

            if !match(kind: .punct, spelling: ",") {
                break
            }
        }
        _ = try consume(kind: .punct, spelling: ")")
        lastFuncParams = params
        lastFuncVariadic = variadic
        lastFuncParamVLAExprs = paramVLAExprs
        return (params, variadic, returnType)
    }

    // MARK: - Initializer

    private func parseInitializer(type: CType) throws -> Expr {
        if isPunct("{") {
            return try parseInitList()
        }
        return try parseAssignmentExpr()
    }

    private func parseInitList() throws -> Expr {
        let loc = current().loc
        _ = try consume(kind: .punct, spelling: "{")
        var values: [Expr] = []
        var designators: [[String]?] = []

        // Handle designators: [index] = val, [start ... end] = val, .field = val,
        // and nested designators like .a.j = 5 or [0].b = 3
        outerLoop: while !isPunct("}") && !isAtEnd() {
            var fieldDesignators: [String] = []  // e.g., ["a", "j"] for .a.j
            // Check for old GNU designator syntax: field: value (instead of .field = value)
            if current().kind == .identifier && next().kind == .punct && next().spelling == ":" {
                let fieldName = advance().spelling
                advance() // consume ':'
                fieldDesignators.append(fieldName)
                // Value can be a nested init list or an expression
                let val: Expr
                if isPunct("{") {
                    val = try parseInitList()
                } else {
                    val = try parseAssignmentExpr()
                }
                values.append(val)
                designators.append(fieldDesignators)
                if !match(kind: .punct, spelling: ",") {
                    break
                }
                continue
            }
            // Parse designators (may be multiple: .a.j, [0].b, etc.)
            var hasRangeDesignator = false
            var singleArrayIndex: Int? = nil  // [index] = value (non-range)
            // fieldDesignators already declared above
            while isPunct("[") || isPunct(".") {
                if isPunct("[") {
                    // Array designator [index] or [start ... end]
                    advance()
                    let startExpr = try parseAssignmentExpr()
                    if isPunct("...") {
                        advance()
                        let endExpr = try parseAssignmentExpr()
                        _ = try consume(kind: .punct, spelling: "]")
                        _ = match(kind: .punct, spelling: "=")
                        let rangeStart = Int(evalIntConst(startExpr))
                        let rangeEnd = Int(evalIntConst(endExpr))
                        if isPunct("{") {
                            let val = try parseInitList()
                            // Expand values array to fit range
                            while values.count <= rangeEnd {
                                values.append(.integerLiteral(IntegerLiteral(value: 0, type: .int, loc: loc)))
                                designators.append(nil)
                            }
                            for i in rangeStart...rangeEnd {
                                values[i] = val
                                designators[i] = nil
                            }
                        } else {
                            let val = try parseAssignmentExpr()
                            while values.count <= rangeEnd {
                                values.append(.integerLiteral(IntegerLiteral(value: 0, type: .int, loc: loc)))
                                designators.append(nil)
                            }
                            for i in rangeStart...rangeEnd {
                                values[i] = val
                                designators[i] = nil
                            }
                        }
                        hasRangeDesignator = true
                        if !match(kind: .punct, spelling: ",") {
                            break
                        }
                        continue outerLoop
                    }
                    _ = try consume(kind: .punct, spelling: "]")
                    // Single [index] designator
                    singleArrayIndex = Int(evalIntConst(startExpr))
                } else if isPunct(".") {
                    // Field designator .field
                    advance()
                    let fieldName = try consume(kind: .identifier).spelling
                    fieldDesignators.append(fieldName)
                }
            }
            if hasRangeDesignator {
                continue
            }
            _ = match(kind: .punct, spelling: "=")

            // Value can be a nested init list or an expression
            let val: Expr
            if isPunct("{") {
                val = try parseInitList()
            } else {
                val = try parseAssignmentExpr()
            }
            if let idx = singleArrayIndex {
                // Place value at specified index, expanding with zeros if needed
                while values.count <= idx {
                    values.append(.integerLiteral(IntegerLiteral(value: 0, type: .int, loc: loc)))
                    designators.append(nil)
                }
                values[idx] = val
                designators[idx] = fieldDesignators.isEmpty ? nil : fieldDesignators
            } else {
                values.append(val)
                designators.append(fieldDesignators.isEmpty ? nil : fieldDesignators)
            }

            if !match(kind: .punct, spelling: ",") {
                break
            }
        }
        _ = try consume(kind: .punct, spelling: "}")
        return .initList(InitListExpr(values: values, designators: designators, loc: loc))
    }

    // MARK: - Statements

    private func parseCompoundStmt() throws -> CompoundStmt {
        let loc = try consume(kind: .punct, spelling: "{").loc
        var stmts: [Stmt] = []

        while !isPunct("}") && !isAtEnd() {
            stmts.append(try parseStmt())
        }
        _ = try consume(kind: .punct, spelling: "}")
        return CompoundStmt(statements: stmts, loc: loc)
    }

    private func parseStmt() throws -> Stmt {
        // __asm__("...") statement - emit inline assembly
        if isKeyword("__asm") || isKeyword("__asm__") || isKeyword("asm") {
            let loc = advance().loc
            // Skip __volatile__ if present
            if isKeyword("__volatile__") || isKeyword("volatile") { advance() }
            // Skip 'goto' for asm goto (GNU extension: asm goto("" : : : : label))
            if isKeyword("goto") { advance() }
            if isPunct("(") {
                advance()
                // Skip everything inside the asm parens, collecting the first string literal
                var asmText = ""
                var depth = 1
                while !isAtEnd() && depth > 0 {
                    let tk = current()
                    if tk.kind == .punct && tk.spelling == "(" { depth += 1 }
                    else if tk.kind == .punct && tk.spelling == ")" { depth -= 1 }
                    if depth == 0 { advance(); break }
                    if depth == 1 && tk.kind == .stringLiteral && asmText.isEmpty {
                        asmText = tk.spelling
                    }
                    advance()
                }
                if isPunct(";") { advance() }
                // Strip quotes from the string literal
                if asmText.hasPrefix("\"") { asmText = String(asmText.dropFirst()) }
                if asmText.hasSuffix("\"") { asmText = String(asmText.dropLast()) }
                return .asm(AsmStmt(instructions: asmText, loc: loc))
            }
        }

        // Labeled statements
        if current().kind == .identifier && next().kind == .punct && next().spelling == ":" {
            let label = advance().spelling
            _ = advance() // :
            let stmt = try parseStmt()
            return .label(LabelStmt(name: label, stmt: stmt, loc: SourceLoc.unknown))
        }

        if isKeyword("case") {
            let loc = advance().loc
            let val = try parseConditionalExpr()
            // GNU extension: case A ... B (range case)
            if isPunct("...") {
                advance()
                let endVal = try parseConditionalExpr()
                _ = try consume(kind: .punct, spelling: ":")
                let stmt: Stmt? = isPunct("}") || isKeyword("case") || isKeyword("default") ? nil : try parseStmt()
                // Encode range using initList [start, end] — codegen recognizes this in case
                let rangeExpr: Expr = .initList(InitListExpr(values: [val, endVal], designators: [nil, nil], loc: loc))
                return .case(CaseStmt(value: rangeExpr, stmt: stmt, loc: loc))
            }
            _ = try consume(kind: .punct, spelling: ":")
            let stmt: Stmt? = isPunct("}") || isKeyword("case") || isKeyword("default") ? nil : try parseStmt()
            return .case(CaseStmt(value: val, stmt: stmt, loc: loc))
        }

        if isKeyword("default") {
            let loc = advance().loc
            _ = try consume(kind: .punct, spelling: ":")
            let stmt: Stmt? = isPunct("}") || isKeyword("case") || isKeyword("default") ? nil : try parseStmt()
            return .default(DefaultStmt(stmt: stmt, loc: loc))
        }

        switch current().kind {
        case .punct:
            if isPunct("{") {
                return .compound(try parseCompoundStmt())
            }
            if isPunct(";") {
                let loc = advance().loc
                return .empty(EmptyStmt(loc: loc))
            }

        case .keyword:
            // __label__ declares local labels (GNU extension): __label__ name1, name2;
            if isKeyword("__label__") {
                advance() // consume __label__
                while !isPunct(";") && !isAtEnd() {
                    if current().kind == .identifier {
                        pendingLocalLabelsStack[pendingLocalLabelsStack.count - 1].append(current().spelling)
                        advance()
                    }
                    if !match(kind: .punct, spelling: ",") { break }
                }
                _ = try consume(kind: .punct, spelling: ";")
                return try parseStmt()
            }
            if isKeyword("if") { return .if(try parseIfStmt()) }
            if isKeyword("while") { return .while(try parseWhileStmt()) }
            if isKeyword("do") { return .doWhile(try parseDoWhileStmt()) }
            if isKeyword("for") { return .for(try parseForStmt()) }
            if isKeyword("switch") { return .switch(try parseSwitchStmt()) }
            if isKeyword("break") { let loc = advance().loc; _ = try consume(kind: .punct, spelling: ";"); return .break(BreakStmt(loc: loc)) }
            if isKeyword("continue") { let loc = advance().loc; _ = try consume(kind: .punct, spelling: ";"); return .continue(ContinueStmt(loc: loc)) }
            if isKeyword("return") { let loc = advance().loc; var val: Expr? = nil; if !isPunct(";") { val = try parseExpr() }; _ = try consume(kind: .punct, spelling: ";"); return .return(ReturnStmt(value: val, loc: loc)) }
            if isKeyword("goto") {
                let loc = advance().loc
                if isPunct("*") {
                    // Computed goto: goto *expr;
                    advance() // consume *
                    let target = try parseExpr()
                    _ = try consume(kind: .punct, spelling: ";")
                    return .computedGoto(ComputedGotoStmt(target: target, loc: loc))
                }
                let label = try consume(kind: .identifier).spelling
                _ = try consume(kind: .punct, spelling: ";")
                return .goto(GotoStmt(label: label, loc: loc))
            }
            if isKeyword("sizeof") || isKeyword("__alignof__") || isKeyword("__alignof") ||
               isKeyword("_Alignof") || isKeyword("__real__") || isKeyword("__real") ||
               isKeyword("__imag__") || isKeyword("__imag") ||
               isKeyword("__typeof") || isKeyword("__typeof__") {
                // These keywords start an expression statement — fall through to expression parsing
            } else {
                // Declaration (starts with a type keyword)
                return .decl(try parseDeclStmt())
            }

        case .identifier:
            // Could be a declaration (typedef name) or an expression
            if isTypedefName() {
                return .decl(try parseDeclStmt())
            }
            // Fall through to expression statement

        default:
            break
        }

        // Expression statement
        let loc = current().loc
        let expr = try parseExpr()
        _ = try consume(kind: .punct, spelling: ";")
        return .expr(ExprStmt(expr: expr, loc: loc))
    }

    private func parseDeclStmt() throws -> DeclStmt {
        let loc = current().loc
        // Special: _Static_assert
        if isKeyword("_Static_assert") {
            let d = try parseStaticAssert()
            return DeclStmt(decls: [d], loc: loc)
        }

        // Handle typedef inside function body
        if isKeyword("typedef") {
            let d = try parseTypedef()
            return DeclStmt(decls: [d], loc: loc)
        }

        let (baseType, storageClass, _, _) = try parseDeclSpecifiers()
        var decls: [Decl] = []

        repeat {
            let (name, type, dloc) = try parseDeclarator(baseType)
            // Check for nested function definition: type is function and next is '{'
            if case .function = type, isPunct("{") {
                // Parse the nested function body and hoist it as a top-level function
                pendingLocalLabelsStack.append([])
                let body = try parseCompoundStmt()
                let labels = pendingLocalLabelsStack.removeLast()
                // Use the params from lastFuncParams (has names) instead of the type
                let retType: CType = {
                    if case .function(_, let r, _) = type { return r }
                    return type
                }()
                let fd = FuncDecl(name: name, returnType: retType,
                                  params: lastFuncParams, variadic: lastFuncVariadic,
                                  body: body, storageClass: .static, isInline: false, loc: dloc,
                                  parentFuncName: currentFuncName,
                                  localLabels: labels)
                pendingNestedFunctions.append(fd)
                // Register the function name as a global so calls work
                globalVarTypes[name] = type
                // Don't create a local varDecl — the function is emitted as a top-level
                // function and calls to it should resolve to the function name directly.
                // Nested function definitions don't end with ';' — return immediately
                return DeclStmt(decls: decls, loc: loc)
            }
            // Collect VLA size expressions: outer dimension + inner dimensions
            // vlaExprs is in parse order (left to right): [outer_dim, inner_dim1, ...]
            // The outer dimension is first, inner dimensions follow.
            let vlaExprs = pendingVLASizeExprs
            pendingVLASizeExprs = []
            let vlaExpr = vlaExprs.first  // outer dimension (first parsed)
            let vlaInnerExprs = vlaExprs.count > 1 ? Array(vlaExprs.dropFirst()) : []
            var initExpr: Expr? = nil
            var actualType = type
            if match(kind: .punct, spelling: "=") {
                initExpr = try parseInitializer(type: type)
                if case .incompleteArray(let elem) = type.unqualified,
                   case .initList(let il) = initExpr! {
                    actualType = .array(of: elem, count: il.values.count)
                }
                if case .incompleteArray(let elem) = type.unqualified,
                   elem.isChar,
                   case .stringLiteral(let sl) = initExpr! {
                    actualType = .array(of: elem, count: countDecodedBytes(sl.value) + 1)
                }
            }
            decls.append(.varDecl(VarDecl(name: name, type: actualType, initializer: initExpr,
                                          storageClass: storageClass, isGlobal: false, loc: dloc,
                                          vlaSizeExpr: vlaExpr, vlaInnerSizeExprs: vlaInnerExprs)))
        } while match(kind: .punct, spelling: ",")

        _ = try consume(kind: .punct, spelling: ";")
        return DeclStmt(decls: decls, loc: loc)
    }

    private func parseIfStmt() throws -> IfStmt {
        let loc = advance().loc // if
        _ = try consume(kind: .punct, spelling: "(")
        let cond = try parseExpr()
        _ = try consume(kind: .punct, spelling: ")")
        let thenStmt = try parseStmt()
        var elseStmt: Stmt? = nil
        if isKeyword("else") {
            advance()
            elseStmt = try parseStmt()
        }
        return IfStmt(condition: cond, thenStmt: thenStmt, elseStmt: elseStmt, loc: loc)
    }

    private func parseWhileStmt() throws -> WhileStmt {
        let loc = advance().loc // while
        _ = try consume(kind: .punct, spelling: "(")
        let cond = try parseExpr()
        _ = try consume(kind: .punct, spelling: ")")
        let body = try parseStmt()
        return WhileStmt(condition: cond, body: body, loc: loc)
    }

    private func parseDoWhileStmt() throws -> DoWhileStmt {
        let loc = advance().loc // do
        let body = try parseStmt()
        _ = try consume(kind: .keyword, spelling: "while")
        _ = try consume(kind: .punct, spelling: "(")
        let cond = try parseExpr()
        _ = try consume(kind: .punct, spelling: ")")
        _ = try consume(kind: .punct, spelling: ";")
        return DoWhileStmt(body: body, condition: cond, loc: loc)
    }

    private func parseForStmt() throws -> ForStmt {
        let loc = advance().loc // for
        _ = try consume(kind: .punct, spelling: "(")
        var initStmt: Stmt? = nil
        if !isPunct(";") {
            initStmt = try parseStmt() // This consumes the ; for the init clause
        } else {
            advance() // ;
        }
        var cond: Expr? = nil
        if !isPunct(";") {
            cond = try parseExpr()
        }
        _ = try consume(kind: .punct, spelling: ";")
        var incr: Expr? = nil
        if !isPunct(")") {
            incr = try parseExpr()
        }
        _ = try consume(kind: .punct, spelling: ")")
        let body = try parseStmt()
        return ForStmt(initStmt: initStmt, condition: cond, increment: incr, body: body, loc: loc)
    }

    private func parseSwitchStmt() throws -> SwitchStmt {
        let loc = advance().loc // switch
        _ = try consume(kind: .punct, spelling: "(")
        let val = try parseExpr()
        _ = try consume(kind: .punct, spelling: ")")
        // The body is a compound statement containing case/default labels
        var cases: [Stmt] = []
        if isPunct("{") {
            _ = advance()
            while !isPunct("}") && !isAtEnd() {
                cases.append(try parseStmt())
            }
            _ = try consume(kind: .punct, spelling: "}")
        } else {
            cases.append(try parseStmt())
        }
        return SwitchStmt(value: val, cases: cases, loc: loc)
    }

    // MARK: - Expressions

    /// Full expression (includes comma operator).
    private func parseExpr() throws -> Expr {
        return try parseCommaExpr()
    }

    private func parseCommaExpr() throws -> Expr {
        var left = try parseAssignmentExpr()
        while isPunct(",") {
            let loc = advance().loc
            let right = try parseAssignmentExpr()
            left = .binary(BinaryExpr(op: .comma, left: left, right: right, loc: loc))
        }
        return left
    }

    private func parseAssignmentExpr() throws -> Expr {
        var left = try parseConditionalExpr()

        if isPunct("=") || isPunct("+=") || isPunct("-=") || isPunct("*=") ||
           isPunct("/=") || isPunct("%=") || isPunct("<<=") || isPunct(">>=") ||
           isPunct("&=") || isPunct("|=") || isPunct("^=") {
            let opStr = advance().spelling
            let op = AssignOp(rawValue: opStr) ?? .assign
            let right = try parseAssignmentExpr()
            left = .assign(AssignExpr(op: op, target: left, value: right, loc: left.loc))
        }
        return left
    }

    private func parseConditionalExpr() throws -> Expr {
        let cond = try parseLogicalOrExpr()
        if isPunct("?") {
            let loc = advance().loc
            // GNU extension: x ?: y — missing middle operand uses x as the true expr
            let trueE: Expr
            if isPunct(":") {
                trueE = cond
                _ = try consume(kind: .punct, spelling: ":")
            } else {
                trueE = try parseExpr()
                _ = try consume(kind: .punct, spelling: ":")
            }
            let falseE = try parseConditionalExpr()
            return .conditional(ConditionalExpr(condition: cond, trueExpr: trueE, falseExpr: falseE, loc: loc))
        }
        return cond
    }

    private func parseLogicalOrExpr() throws -> Expr {
        var left = try parseLogicalAndExpr()
        while isPunct("||") {
            let loc = advance().loc
            let right = try parseLogicalAndExpr()
            left = .binary(BinaryExpr(op: .logicOr, left: left, right: right, loc: loc))
        }
        return left
    }

    private func parseLogicalAndExpr() throws -> Expr {
        var left = try parseBitwiseOrExpr()
        while isPunct("&&") {
            let loc = advance().loc
            let right = try parseBitwiseOrExpr()
            left = .binary(BinaryExpr(op: .logicAnd, left: left, right: right, loc: loc))
        }
        return left
    }

    private func parseBitwiseOrExpr() throws -> Expr {
        var left = try parseBitwiseXorExpr()
        while isPunct("|") {
            let loc = advance().loc
            let right = try parseBitwiseXorExpr()
            left = .binary(BinaryExpr(op: .bitOr, left: left, right: right, loc: loc))
        }
        return left
    }

    private func parseBitwiseXorExpr() throws -> Expr {
        var left = try parseBitwiseAndExpr()
        while isPunct("^") {
            let loc = advance().loc
            let right = try parseBitwiseAndExpr()
            left = .binary(BinaryExpr(op: .bitXor, left: left, right: right, loc: loc))
        }
        return left
    }

    private func parseBitwiseAndExpr() throws -> Expr {
        var left = try parseEqualityExpr()
        while isPunct("&") {
            let loc = advance().loc
            let right = try parseEqualityExpr()
            left = .binary(BinaryExpr(op: .bitAnd, left: left, right: right, loc: loc))
        }
        return left
    }

    private func parseEqualityExpr() throws -> Expr {
        var left = try parseRelationalExpr()
        while isPunct("==") || isPunct("!=") {
            let op = BinaryOp(rawValue: advance().spelling) ?? .eq
            let right = try parseRelationalExpr()
            left = .binary(BinaryExpr(op: op, left: left, right: right, loc: left.loc))
        }
        return left
    }

    private func parseRelationalExpr() throws -> Expr {
        var left = try parseShiftExpr()
        while isPunct("<") || isPunct(">") || isPunct("<=") || isPunct(">=") {
            let op = BinaryOp(rawValue: advance().spelling) ?? .lt
            let right = try parseShiftExpr()
            left = .binary(BinaryExpr(op: op, left: left, right: right, loc: left.loc))
        }
        return left
    }

    private func parseShiftExpr() throws -> Expr {
        var left = try parseAddExpr()
        while isPunct("<<") || isPunct(">>") {
            let op = BinaryOp(rawValue: advance().spelling) ?? .shl
            let right = try parseAddExpr()
            left = .binary(BinaryExpr(op: op, left: left, right: right, loc: left.loc))
        }
        return left
    }

    private func parseAddExpr() throws -> Expr {
        var left = try parseMulExpr()
        while isPunct("+") || isPunct("-") {
            let op = BinaryOp(rawValue: advance().spelling) ?? .add
            let right = try parseMulExpr()
            left = .binary(BinaryExpr(op: op, left: left, right: right, loc: left.loc))
        }
        return left
    }

    private func parseMulExpr() throws -> Expr {
        var left = try parseCastExpr()
        while isPunct("*") || isPunct("/") || isPunct("%") {
            let op = BinaryOp(rawValue: advance().spelling) ?? .mul
            let right = try parseCastExpr()
            left = .binary(BinaryExpr(op: op, left: left, right: right, loc: left.loc))
        }
        return left
    }

    private func parseCastExpr() throws -> Expr {
        // Cast: ( type-name ) unary-expr
        // Need to distinguish from parenthesized expression: ( expr )
        // Also handle ( __attribute__((...)) type-name ) expr
        if isPunct("(") {
            let nextTok = next()
            let isCastStart = (nextTok.kind == .keyword && isTypeKeyword(nextTok.spelling)) ||
                  (nextTok.kind == .keyword && (nextTok.spelling == "__attribute__" || nextTok.spelling == "__attribute")) ||
                  (nextTok.kind == .identifier && typedefNames.contains(nextTok.spelling))
            if isCastStart {
                // Parse as cast
                let savePos = pos
                advance() // (
                let (baseType, _, _, _) = try parseDeclSpecifiers()
                let (_, castType, _) = try parseDeclarator(baseType)
                _ = try consume(kind: .punct, spelling: ")")
                // Compound literal: (type) { init-list }
                if isPunct("{") {
                    let initList = try parseInitList()
                    var resolvedType = castType
                    // Infer array size from init list for incomplete arrays
                    if case .incompleteArray(let elem) = castType.unqualified,
                       case .initList(let il) = initList {
                        resolvedType = .array(of: elem, count: il.values.count)
                    }
                    var expr: Expr = .compoundLiteral(CompoundLiteralExpr(type: resolvedType, initList: initList, loc: current().loc))
                    // Parse postfix operations on compound literal (e.g., (int[]){}[index])
                    while isPunct("[") || isPunct(".") || isPunct("->") || isPunct("++") || isPunct("--") {
                        if isPunct("[") {
                            let loc = advance().loc
                            let index = try parseExpr()
                            _ = try consume(kind: .punct, spelling: "]")
                            expr = .subscript_(SubscriptExpr(base: expr, index: index, loc: loc))
                        } else if isPunct(".") {
                            let loc = advance().loc
                            let member = try consume(kind: .identifier).spelling
                            expr = .member(MemberExpr(base: expr, memberName: member, isArrow: false, loc: loc))
                        } else if isPunct("->") {
                            let loc = advance().loc
                            let member = try consume(kind: .identifier).spelling
                            expr = .member(MemberExpr(base: expr, memberName: member, isArrow: true, loc: loc))
                        } else {
                            let opStr = advance().spelling
                            let op: UnaryOp = opStr == "++" ? .postInc : .postDec
                            expr = .unary(UnaryExpr(op: op, operand: expr, loc: SourceLoc.unknown))
                        }
                    }
                    return expr
                }
                let operand = try parseCastExpr()
                return .cast(CastExpr(type: castType, expr: operand, loc: current().loc))
            }
        }

        return try parseUnaryExpr()
    }

    private func isTypeKeyword(_ s: String) -> Bool {
        return ["void", "char", "short", "int", "long", "float", "double",
                "signed", "unsigned", "const", "volatile", "struct", "union",
                "enum", "_Bool", "restrict", "_Complex", "_Imaginary",
                "typeof", "__typeof", "__typeof__"].contains(s)
    }

    private func parseUnaryExpr() throws -> Expr {
        // GNU extension: &&label (address-of-label for computed goto)
        if isPunct("&&") && next().kind == .identifier {
            let loc = advance().loc // consume &&
            let labelName = advance().spelling // consume label name
            return .unary(UnaryExpr(op: .addressOf,
                                    operand: .identifier(Identifier(name: labelName, loc: loc)),
                                    loc: loc))
        }

        // Prefix operators
        if isPunct("!") || isPunct("~") || isPunct("-") || isPunct("+") ||
           isPunct("*") || isPunct("&") || isPunct("++") || isPunct("--") {
            let opStr = advance().spelling
            let op: UnaryOp
            switch opStr {
            case "!": op = .not
            case "~": op = .bitNot
            case "-": op = .neg
            case "+": op = .pos
            case "*": op = .dereference
            case "&": op = .addressOf
            case "++": op = .preInc
            case "--": op = .preDec
            default: op = .not
            }
            let operand = try parseCastExpr()
            return .unary(UnaryExpr(op: op, operand: operand, loc: SourceLoc.unknown))
        }

        // __real__ / __imag__ — GNU extensions for complex number access
        // __real__ expr returns the real part, __imag__ returns the imaginary part.
        // For non-complex types, __real__ is identity and __imag__ returns 0.
        if isKeyword("__real__") || isKeyword("__real") || isKeyword("__imag__") || isKeyword("__imag") {
            let isReal = isKeyword("__real__") || isKeyword("__real")
            advance() // consume keyword
            let operand = try parseCastExpr()
            if isReal {
                return operand
            } else {
                return .integerLiteral(IntegerLiteral(value: 0, type: .int, loc: SourceLoc.unknown))
            }
        }

        // sizeof
        if isKeyword("sizeof") {
            let loc = advance().loc
            if isPunct("(") {
                let nextTok = next()
                if nextTok.kind == .keyword && isTypeKeyword(nextTok.spelling) ||
                   (nextTok.kind == .identifier && typedefNames.contains(nextTok.spelling)) {
                    // sizeof ( type )
                    advance() // (
                    let (baseType, _, _, _) = try parseDeclSpecifiers()
                    let (_, typeName, _) = try parseDeclarator(baseType)
                    _ = try consume(kind: .punct, spelling: ")")
                    return .sizeof(SizeofExpr(expr: nil, typeName: typeName, loc: loc))
                }
            }
            // sizeof expr
            let e = try parseUnaryExpr()
            return .sizeof(SizeofExpr(expr: e, typeName: nil, loc: loc))
        }

        // __alignof__ / __alignof / _Alignof — returns alignment of a type or expression
        if isKeyword("__alignof__") || isKeyword("__alignof") || isKeyword("_Alignof") {
            let loc = advance().loc
            if isPunct("(") {
                let nextTok = next()
                if nextTok.kind == .keyword && isTypeKeyword(nextTok.spelling) ||
                   (nextTok.kind == .identifier && typedefNames.contains(nextTok.spelling)) {
                    // __alignof__ ( type )
                    advance() // (
                    let (baseType, _, _, _) = try parseDeclSpecifiers()
                    let (_, typeName, _) = try parseDeclarator(baseType)
                    _ = try consume(kind: .punct, spelling: ")")
                    return .sizeof(SizeofExpr(expr: nil, typeName: typeName, loc: loc, isAlignof: true))
                }
            }
            // __alignof__ expr
            let e = try parseUnaryExpr()
            return .sizeof(SizeofExpr(expr: e, typeName: nil, loc: loc, isAlignof: true))
        }

        // _Generic(expr, type: expr, ..., default: expr)
        if isKeyword("_Generic") {
            let loc = advance().loc
            _ = try consume(kind: .punct, spelling: "(")
            let controllingExpr = try parseAssignmentExpr()
            _ = try consume(kind: .punct, spelling: ",")
            var associations: [GenericAssociation] = []
            while !isPunct(")") && !isAtEnd() {
                var typeName: CType? = nil
                var isDefault = false
                if isKeyword("default") {
                    advance()
                    isDefault = true
                } else {
                    let (baseType, _, _, _) = try parseDeclSpecifiers()
                    let (_, t, _) = try parseDeclarator(baseType)
                    typeName = t
                }
                _ = try consume(kind: .punct, spelling: ":")
                let e = try parseAssignmentExpr()
                associations.append(GenericAssociation(typeName: typeName, isDefault: isDefault, expr: e))
                if !match(kind: .punct, spelling: ",") {
                    break
                }
            }
            _ = try consume(kind: .punct, spelling: ")")
            let ge = Expr.genericExpr(GenericExpr(controllingExpr: controllingExpr, associations: associations, loc: loc))
            // Fall through to parsePostfixExpr for () and [] suffixes
            var expr = ge
            while true {
                if isPunct("(") {
                    let callLoc = advance().loc
                    var args: [Expr] = []
                    if !isPunct(")") {
                        args.append(try parseAssignmentExpr())
                        while match(kind: .punct, spelling: ",") {
                            args.append(try parseAssignmentExpr())
                        }
                    }
                    _ = try consume(kind: .punct, spelling: ")")
                    expr = .call(CallExpr(function: expr, arguments: args, loc: callLoc))
                } else if isPunct("[") {
                    let subLoc = advance().loc
                    let index = try parseExpr()
                    _ = try consume(kind: .punct, spelling: "]")
                    expr = .subscript_(SubscriptExpr(base: expr, index: index, loc: subLoc))
                } else {
                    break
                }
            }
            return expr
        }

        return try parsePostfixExpr()
    }

    private func parsePostfixExpr() throws -> Expr {
        var expr = try parsePrimaryExpr()

        while true {
            if isPunct("[") {
                let loc = advance().loc
                let index = try parseExpr()
                _ = try consume(kind: .punct, spelling: "]")
                expr = .subscript_(SubscriptExpr(base: expr, index: index, loc: loc))
            } else if isPunct("(") {
                let loc = advance().loc
                var args: [Expr] = []
                if !isPunct(")") {
                    args.append(try parseAssignmentExpr())
                    while match(kind: .punct, spelling: ",") {
                        args.append(try parseAssignmentExpr())
                    }
                }
                _ = try consume(kind: .punct, spelling: ")")
                expr = .call(CallExpr(function: expr, arguments: args, loc: loc))
            } else if isPunct(".") {
                let loc = advance().loc
                let member = try consume(kind: .identifier).spelling
                expr = .member(MemberExpr(base: expr, memberName: member, isArrow: false, loc: loc))
            } else if isPunct("->") {
                let loc = advance().loc
                let member = try consume(kind: .identifier).spelling
                expr = .member(MemberExpr(base: expr, memberName: member, isArrow: true, loc: loc))
            } else if isPunct("++") || isPunct("--") {
                let opStr = advance().spelling
                let op: UnaryOp = opStr == "++" ? .postInc : .postDec
                expr = .unary(UnaryExpr(op: op, operand: expr, loc: SourceLoc.unknown))
            } else {
                break
            }
        }
        return expr
    }

    private func parsePrimaryExpr() throws -> Expr {
        let token = current()

        // Skip __extension__ in expression context
        if token.kind == .keyword && (token.spelling == "__extension__" || token.spelling == "__typeof" || token.spelling == "__typeof__") {
            advance()
            return try parsePrimaryExpr()
        }

        // __builtin_offsetof(type, member) — first arg is a type, not an expression
        if token.kind == .identifier && token.spelling == "__builtin_offsetof" {
            let loc = advance().loc
            _ = try consume(kind: .punct, spelling: "(")
            // Parse the type
            let (baseType, _, _, _) = try parseDeclSpecifiers()
            let (_, typeName, _) = try parseDeclarator(baseType)
            _ = match(kind: .punct, spelling: ",")
            // Parse the member access chain (e.g., b, or a.b, or a.b.c)
            // Use a dummy sizeof expression to carry the type, followed by .member
            var memberBase: Expr = .sizeof(SizeofExpr(expr: nil, typeName: typeName, loc: loc))
            var memberName = try consume(kind: .identifier).spelling
            memberBase = .member(MemberExpr(base: memberBase, memberName: memberName, isArrow: false, loc: loc))
            while isPunct(".") {
                advance()
                let m = try consume(kind: .identifier).spelling
                memberBase = .member(MemberExpr(base: memberBase, memberName: m, isArrow: false, loc: loc))
            }
            _ = try consume(kind: .punct, spelling: ")")
            // Return as a call — codegen recognizes __builtin_offsetof and computes the offset
            return .call(CallExpr(function: .identifier(Identifier(name: "__builtin_offsetof", loc: loc)),
                                  arguments: [memberBase], loc: loc))
        }

        // __builtin_choose_expr(const_cond, expr1, expr2) — compile-time conditional
        if token.kind == .identifier && token.spelling == "__builtin_choose_expr" {
            let loc = advance().loc
            _ = try consume(kind: .punct, spelling: "(")
            let cond = try parseAssignmentExpr()
            _ = try consume(kind: .punct, spelling: ",")
            let thenExpr = try parseAssignmentExpr()
            _ = try consume(kind: .punct, spelling: ",")
            let elseExpr = try parseAssignmentExpr()
            _ = try consume(kind: .punct, spelling: ")")
            // Evaluate the condition at compile time
            let condVal = evalIntConst(cond)
            return condVal != 0 ? thenExpr : elseExpr
        }

        // __builtin_types_compatible_p(type1, type2) — compile-time type compatibility check
        if token.kind == .identifier && token.spelling == "__builtin_types_compatible_p" {
            let loc = advance().loc
            _ = try consume(kind: .punct, spelling: "(")
            let (base1, _, _, _) = try parseDeclSpecifiers()
            let (_, type1, _) = try parseDeclarator(base1)
            _ = try consume(kind: .punct, spelling: ",")
            let (base2, _, _, _) = try parseDeclSpecifiers()
            let (_, type2, _) = try parseDeclarator(base2)
            _ = try consume(kind: .punct, spelling: ")")
            // Check type compatibility at compile time
            let compatible = typesCompatible(type1, type2)
            return .integerLiteral(IntegerLiteral(value: compatible ? 1 : 0, type: .int, loc: loc))
        }

        // __builtin_va_arg(ap, type) — variadic argument access
        if token.kind == .identifier && token.spelling == "__builtin_va_arg" {
            let loc = advance().loc
            _ = try consume(kind: .punct, spelling: "(")
            let apExpr = try parseAssignmentExpr()
            _ = try consume(kind: .punct, spelling: ",")
            // Parse the type
            let (baseType, _, _, _) = try parseDeclSpecifiers()
            let (_, typeName, _) = try parseDeclarator(baseType)
            _ = try consume(kind: .punct, spelling: ")")
            // Encode as: *(type*)((ap += sizeof(type)) - sizeof(type))
            // Use a call to __builtin_va_arg with sizeof(type) as arg for codegen
            return .call(CallExpr(function: .identifier(Identifier(name: "__builtin_va_arg", loc: loc)),
                                  arguments: [apExpr, .sizeof(SizeofExpr(expr: nil, typeName: typeName, loc: loc))],
                                  loc: loc))
        }

        switch token.kind {
        case .integerLiteral:
            advance()
            let (val, isUnsigned, type) = parseIntLiteral(token.spelling)
            return .integerLiteral(IntegerLiteral(value: val, isUnsigned: isUnsigned, type: type, loc: token.loc))

        case .floatLiteral:
            advance()
            let val = parseDoubleLiteral(token.spelling)
            // Determine type: f/F suffix = float, i/I/j/J suffix = imaginary (treat as double for now)
            let isFloat = token.spelling.hasSuffix("f") || token.spelling.hasSuffix("F")
            let isImaginary = token.spelling.hasSuffix("i") || token.spelling.hasSuffix("I") ||
                              token.spelling.hasSuffix("j") || token.spelling.hasSuffix("J") ||
                              token.spelling.hasSuffix("fi") || token.spelling.hasSuffix("Fi") ||
                              token.spelling.hasSuffix("li") || token.spelling.hasSuffix("Li")
            let type: CType = isFloat ? .float : .double
            return .floatLiteral(FloatLiteral(value: val, type: type, isImaginary: isImaginary, loc: token.loc))

        case .charLiteral:
            advance()
            let val = parseCharLiteralValue(token.spelling)
            return .charLiteral(CharLiteral(value: val, type: .int, loc: token.loc))

        case .stringLiteral:
            // Check for wide string prefix L"..."
            let isWide = token.spelling.hasPrefix("L")
            if isWide {
                // For wide strings, extract raw content between quotes and decode UTF-8
                // Don't process C escape sequences (except standard ones)
                var rawContent = token.spelling
                // Strip L prefix
                if rawContent.hasPrefix("L") { rawContent = String(rawContent.dropFirst()) }
                // Strip quotes
                if rawContent.hasPrefix("\"") && rawContent.hasSuffix("\"") {
                    rawContent = String(rawContent.dropFirst().dropLast())
                }
                // Process standard escape sequences but preserve UTF-8 multibyte chars
                var processed = ""
                var i = rawContent.startIndex
                while i < rawContent.endIndex {
                    if rawContent[i] == "\\" && rawContent.index(after: i) < rawContent.endIndex {
                        let next = rawContent[rawContent.index(after: i)]
                        switch next {
                        case "n": processed += "\n"
                        case "t": processed += "\t"
                        case "r": processed += "\r"
                        case "\\": processed += "\\"
                        case "'": processed += "'"
                        case "\"": processed += "\""
                        case "0": processed += "\0"
                        default: processed += "\\"
                        processed.append(next)
                        }
                        i = rawContent.index(i, offsetBy: 2)
                    } else {
                        processed.append(rawContent[i])
                        i = rawContent.index(after: i)
                    }
                }
                advance()
                // Concatenate adjacent wide string literals
                while current().kind == .stringLiteral {
                    var nextRaw = current().spelling
                    if nextRaw.hasPrefix("L") { nextRaw = String(nextRaw.dropFirst()) }
                    if nextRaw.hasPrefix("\"") && nextRaw.hasSuffix("\"") {
                        nextRaw = String(nextRaw.dropFirst().dropLast())
                    }
                    processed += nextRaw
                    advance()
                }
                // Decode UTF-8 into Unicode code points
                var codePoints: [UInt32] = []
                for scalar in processed.unicodeScalars {
                    codePoints.append(scalar.value)
                }
                codePoints.append(0) // null terminator
                let type = CType.array(of: .int, count: codePoints.count)
                var wideStr = ""
                for cp in codePoints {
                    wideStr += String(format: "%08x", cp)
                }
                return .stringLiteral(StringLiteral(value: "WIDE:" + wideStr, type: type, loc: token.loc))
            }
            // Regular string: concatenate adjacent string literals
            var str = parseStringLiteralValue(token.spelling)
            advance()
            while current().kind == .stringLiteral {
                str += parseStringLiteralValue(current().spelling)
                advance()
            }
            let byteCount = countDecodedBytes(str)
            let type = CType.array(of: .char, count: byteCount + 1)
            return .stringLiteral(StringLiteral(value: str, type: type, loc: token.loc))

        case .identifier:
            // __func__ predefined identifier: expands to a string literal with the function name
            if token.spelling == "__func__" || token.spelling == "__FUNCTION__" {
                advance()
                let funcName = currentFuncName ?? ""
                let type = CType.array(of: .char, count: funcName.utf8.count + 1)
                return .stringLiteral(StringLiteral(value: funcName, type: type, loc: token.loc))
            }
            advance()
            return .identifier(Identifier(name: token.spelling, loc: token.loc))

        case .punct:
            if isPunct("(") {
                // Statement expression: ({ ... })
                if next().kind == .punct && next().spelling == "{" {
                    advance() // (
                    let stmts = try parseCompoundStmt()
                    _ = try consume(kind: .punct, spelling: ")")
                    return .stmtExpr(StmtExpr(body: stmts, loc: token.loc))
                }
                // Check for cast: ( type-name ) ... or ( __attribute__ ... type ) ...
                let nextTok = next()
                let isCastStart = (nextTok.kind == .keyword && isTypeKeyword(nextTok.spelling)) ||
                  (nextTok.kind == .keyword && (nextTok.spelling == "__attribute__" || nextTok.spelling == "__attribute")) ||
                  (nextTok.kind == .identifier && typedefNames.contains(nextTok.spelling))
                if isCastStart {
                    // Try to parse as cast via parseCastExpr
                    if let castExpr = try? parseCastExpr() {
                        return castExpr
                    }
                }
                // Regular parenthesized expression
                advance() // (
                let e = try parseExpr()
                _ = try consume(kind: .punct, spelling: ")")
                return e
            }

        default:
            break
        }

        throw ParseError.unexpectedToken("unexpected token '\(token.spelling)' in expression", token.loc)
    }

    // MARK: - Literal parsing helpers

    private func parseIntLiteral(_ spelling: String) -> (Int64, Bool, CType) {
        var s = spelling
        var isUnsigned = false
        var isLong = false
        var isLongLong = false
        var isImaginary = false

        // Strip imaginary suffix (i, I, j, J) — GNU extension
        if s.hasSuffix("i") || s.hasSuffix("I") || s.hasSuffix("j") || s.hasSuffix("J") {
            isImaginary = true
            s = String(s.dropLast())
        }

        // Strip suffixes
        while s.hasSuffix("u") || s.hasSuffix("U") || s.hasSuffix("l") || s.hasSuffix("L") {
            if s.hasSuffix("u") || s.hasSuffix("U") { isUnsigned = true }
            if s.hasSuffix("l") || s.hasSuffix("L") {
                if isLong { isLongLong = true; isLong = false }
                else { isLong = true }
            }
            s = String(s.dropLast())
        }

        let value: Int64
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            // Parse as UInt64 to handle values > Int64.max, then reinterpret
            if let uv = UInt64(s.dropFirst(2), radix: 16) {
                value = Int64(bitPattern: uv)
            } else {
                value = 0
            }
        } else if s.hasPrefix("0b") || s.hasPrefix("0B") {
            if let uv = UInt64(s.dropFirst(2), radix: 2) {
                value = Int64(bitPattern: uv)
            } else {
                value = 0
            }
        } else if s.hasPrefix("0") && s.count > 1 {
            if let uv = UInt64(s.dropFirst(), radix: 8) {
                value = Int64(bitPattern: uv)
            } else {
                value = 0
            }
        } else {
            if let uv = UInt64(s) {
                value = Int64(bitPattern: uv)
            } else {
                value = Int64(s) ?? 0
            }
        }

        let type: CType
        if isLongLong { type = isUnsigned ? .ulongLong : .longLong }
        else if isLong { type = isUnsigned ? .ulong : .long }
        else {
            // C standard integer literal type rules:
            // For decimal: int -> long -> long long (all signed)
            // For hex/octal/binary: int -> unsigned int -> long -> unsigned long -> long long -> unsigned long long
            let uv = UInt64(bitPattern: value)
            if isUnsigned {
                if uv <= UInt64(UInt32.max) { type = .uint }
                else if uv <= UInt64(UInt64(Int.max)) { type = .long }
                else if uv <= UInt64(UInt64.max) { type = .ulong }
                else { type = .ulong }
            } else if s.hasPrefix("0x") || s.hasPrefix("0X") || s.hasPrefix("0b") || s.hasPrefix("0B") || (s.hasPrefix("0") && s.count > 1) {
                // Hex/octal/binary: can be unsigned
                if uv <= UInt64(Int32.max) { type = .int }
                else if uv <= UInt64(UInt32.max) { type = .uint }
                else if uv <= UInt64(Int64.max) { type = .long }
                else if uv <= UInt64(UInt64.max) { type = .ulong }
                else { type = .longLong }
            } else {
                // Decimal: only signed types
                if uv <= UInt64(Int32.max) { type = .int }
                else if uv <= UInt64(Int64.max) { type = .long }
                else { type = .longLong }
            }
        }

        return (value, isUnsigned, type)
    }

    private func parseDoubleLiteral(_ spelling: String) -> Double {
        var s = spelling
        // Strip imaginary suffix first (i, I, j, J), possibly combined with f/l
        if s.hasSuffix("i") || s.hasSuffix("I") || s.hasSuffix("j") || s.hasSuffix("J") {
            s = String(s.dropLast())
        }
        if s.hasSuffix("f") || s.hasSuffix("F") || s.hasSuffix("l") || s.hasSuffix("L") {
            s = String(s.dropLast())
        }
        // May have another imaginary suffix after f/l (e.g., "1.0fi")
        if s.hasSuffix("i") || s.hasSuffix("I") || s.hasSuffix("j") || s.hasSuffix("J") {
            s = String(s.dropLast())
        }
        return Double(s) ?? 0.0
    }

    private func parseCharLiteralValue(_ spelling: String) -> UInt32 {
        // Strip quotes and prefix
        var s = spelling
        if s.hasPrefix("L") || s.hasPrefix("u") || s.hasPrefix("U") { s = String(s.dropFirst()) }
        guard s.hasPrefix("'") && s.hasSuffix("'") else { return 0 }
        s = String(s.dropFirst().dropLast())
        if s.isEmpty { return 0 }
        if s.hasPrefix("\\") {
            return parseEscape(String(s.dropFirst()))
        }
        // Use the first Unicode scalar (not first UTF-8 byte) for wide char support
        return s.unicodeScalars.first.map { $0.value } ?? UInt32(Array(s.utf8).first ?? 0)
    }

    /// Count the decoded byte length of a string literal value produced by
    /// parseStringLiteralValue.  Bytes >= 128 are stored as `\NNN` octal escape
    /// sequences (4 chars for 1 byte), so `str.utf8.count` overcounts.  This
    /// helper walks the string treating `\NNN` as a single byte.
    private func countDecodedBytes(_ s: String) -> Int {
        let scalars = s.unicodeScalars
        var count = 0
        var i = scalars.startIndex
        while i < scalars.endIndex {
            if scalars[i] == "\\" {
                let next = scalars.index(after: i)
                if next < scalars.endIndex && scalars[next] >= "0" && scalars[next] <= "7" {
                    // Octal escape \NNN — consume up to 3 octal digits, counts as 1 byte
                    count += 1
                    var j = next
                    var digits = 0
                    while j < scalars.endIndex && scalars[j] >= "0" && scalars[j] <= "7" && digits < 3 {
                        j = scalars.index(after: j)
                        digits += 1
                    }
                    i = j
                    continue
                }
                // Other escape sequences (\n, \t, \\, etc.) are 1 decoded byte each
                count += 1
                i = scalars.index(after: i)
                if i < scalars.endIndex { i = scalars.index(after: i) }
                continue
            }
            count += 1
            i = scalars.index(after: i)
        }
        return count
    }

    private func parseStringLiteralValue(_ spelling: String) -> String {
        var s = spelling
        if s.hasPrefix("L") || s.hasPrefix("u") || s.hasPrefix("U") { s = String(s.dropFirst()) }
        guard s.hasPrefix("\"") && s.hasSuffix("\"") else { return s }
        s = String(s.dropFirst().dropLast())
        // Process escape sequences
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\" && s.index(after: i) < s.endIndex {
                let next = s[s.index(after: i)]
                switch next {
                case "a": result += "\u{07}"
                case "b": result += "\u{08}"
                case "f": result += "\u{0C}"
                case "n": result += "\n"
                case "r": result += "\r"
                case "t": result += "\t"
                case "v": result += "\u{0B}"
                case "\\": result += "\\"
                case "'": result += "'"
                case "\"": result += "\""
                case "?": result += "?"
                case "x":
                    // Hex escape
                    let afterBackslash = s.index(after: i)
                    let hexStart = afterBackslash < s.endIndex ? s.index(after: afterBackslash) : s.endIndex
                    var hexStr = ""
                    var j = hexStart
                    while j < s.endIndex && s[j].isHexDigit && hexStr.count < 2 {
                        hexStr.append(s[j]); j = s.index(after: j)
                    }
                    if let val = UInt8(hexStr, radix: 16) {
                        if val < 128 {
                            result.append(Character(UnicodeScalar(val)))
                        } else {
                            // For bytes >= 128, keep as octal escape to avoid UTF-8 multi-byte encoding
                            result += String(format: "\\%03o", val)
                        }
                    }
                    // Advance past \xHH (skip \ and the hex digits)
                    i = j
                    continue
                default:
                    // Octal escape (including \0, \0XX, \1XX, etc.)
                    if next >= "0" && next <= "7" {
                        var octStart = s.index(after: i)
                        var octStr = ""
                        var j = octStart
                        while j < s.endIndex && s[j] >= "0" && s[j] <= "7" && octStr.count < 3 {
                            octStr.append(s[j]); j = s.index(after: j)
                        }
                        if let val = UInt8(octStr, radix: 8) {
                            if val < 128 {
                                result.append(Character(UnicodeScalar(val)))
                            } else {
                                // For bytes >= 128, keep as octal escape to avoid UTF-8 multi-byte encoding
                                result += String(format: "\\%03o", val)
                            }
                        }
                        // Advance past \OOO (skip \ and the octal digits)
                        i = j
                        continue
                    } else {
                        result.append(next)
                    }
                }
                // For simple escapes (\n, \t, etc.): advance past \ and the escape char
                i = s.index(after: i)  // skip the escape char
            } else {
                result.append(s[i])
            }
            i = s.index(after: i)
        }
        return result
    }

    private func parseEscape(_ s: String) -> UInt32 {
        guard let first = s.first else { return 0 }
        switch first {
        case "a": return 0x07
        case "b": return 0x08
        case "f": return 0x0C
        case "n": return 0x0A
        case "r": return 0x0D
        case "t": return 0x09
        case "v": return 0x0B
        case "\\": return 0x5C
        case "'": return 0x27
        case "\"": return 0x22
        case "?": return 0x3F
        case "x":
            // Hex escape: \xHH (up to 2 hex digits for char, more for wide)
            let hex = String(s.dropFirst())
            return UInt32(hex, radix: 16) ?? 0
        default:
            // Octal escape: \0, \0XX, \1XX, etc. (up to 3 octal digits)
            if first >= "0" && first <= "7" {
                return UInt32(s.prefix(3), radix: 8) ?? 0
            }
            return UInt32(Array(String(first).utf8).first ?? 0)
        }
    }

    // MARK: - Constant expression evaluation

    /// Returns true if `expr` is a compile-time integer constant: integer/char
    /// literals, enum constants, sizeof, or constant folds of the above. Any
    /// reference to a variable (an identifier that is not an enum constant)
    /// makes this return false, so VLA dimensions like `n + 1` are recognized
    /// as variable-length rather than folded against an unknown identifier's
    /// default value of 0.
    private func isConstantExpr(_ expr: Expr) -> Bool {
        switch expr {
        case .integerLiteral, .charLiteral, .boolLiteral:
            return true
        case .floatLiteral:
            return true
        case .identifier(let id):
            return parserEnumConstants[id.name] != nil
        case .binary(let b):
            return isConstantExpr(b.left) && isConstantExpr(b.right)
        case .unary(let u):
            return isConstantExpr(u.operand)
        case .conditional(let c):
            return isConstantExpr(c.condition) && isConstantExpr(c.trueExpr) && isConstantExpr(c.falseExpr)
        case .cast(let c):
            return isConstantExpr(c.expr)
        case .sizeof:
            return true
        default:
            return false
        }
    }

    private func evalIntConst(_ expr: Expr) -> Int64 {
        switch expr {
        case .integerLiteral(let l):
            return l.value
        case .charLiteral(let l):
            return Int64(l.value)
        case .identifier(let id):
            // Look up enum constants
            if let val = parserEnumConstants[id.name] {
                return val
            }
            return 0
        case .binary(let b):
            let l = evalIntConst(b.left)
            let r = evalIntConst(b.right)
            switch b.op {
            case .add: return l &+ r
            case .sub: return l &- r
            case .mul: return l &* r
            case .div: return r != 0 ? l / r : 0
            case .mod: return r != 0 ? l % r : 0
            case .shl: return Int64(bitPattern: UInt64(bitPattern: l) &<< UInt64(r))
            case .shr: return Int64(bitPattern: UInt64(bitPattern: l) >> UInt64(r))
            case .bitAnd: return l & r
            case .bitOr: return l | r
            case .bitXor: return l ^ r
            case .logicAnd: return (l != 0 && r != 0) ? 1 : 0
            case .logicOr: return (l != 0 || r != 0) ? 1 : 0
            case .eq: return l == r ? 1 : 0
            case .ne: return l != r ? 1 : 0
            case .lt: return l < r ? 1 : 0
            case .le: return l <= r ? 1 : 0
            case .gt: return l > r ? 1 : 0
            case .ge: return l >= r ? 1 : 0
            case .comma: return r
            }
        case .unary(let u):
            let v = evalIntConst(u.operand)
            switch u.op {
            case .neg: return 0 &- v
            case .pos: return v
            case .not: return v == 0 ? 1 : 0
            case .bitNot: return ~v
            default: return 0
            }
        case .conditional(let c):
            return evalIntConst(c.condition) != 0 ? evalIntConst(c.trueExpr) : evalIntConst(c.falseExpr)
        case .cast(let c):
            return evalIntConst(c.expr)
        case .sizeof(let s):
            if let typeName = s.typeName {
                return Int64(typeName.sizeInBytes ?? 0)
            }
            return Int64(evalExprType(s.expr ?? .integerLiteral(IntegerLiteral(value: 0, loc: SourceLoc.unknown))).sizeInBytes ?? 0)
        default:
            return 0
        }
    }

    /// Placeholder for type inference — will be replaced by sema.
    private func evalExprType(_ expr: Expr) -> CType {
        switch expr {
        case .integerLiteral(let l): return l.type
        case .charLiteral: return .int
        case .stringLiteral(let s): return s.type
        case .floatLiteral(let f): return f.type
        case .boolLiteral: return .bool
        case .identifier(let id):
            // Look up global variable types for sizeof evaluation
            if let t = globalVarTypes[id.name] {
                return t
            }
            return .int
        default: return .int
        }
    }

    // MARK: - Helper to extract params and variadic from function type

    private func extractParams(_ type: CType) -> [Param] {
        if case .function(let params, _, _) = type {
            return params.map { Param(name: nil, type: $0, loc: SourceLoc.unknown) }
        }
        return []
    }

    private func extractVariadic(_ type: CType) -> Bool {
        if case .function(_, _, let variadic) = type {
            return variadic
        }
        return false
    }
}

// MARK: - String extension for hex digit check

private extension Character {
    var isHexDigit: Bool {
        return ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
