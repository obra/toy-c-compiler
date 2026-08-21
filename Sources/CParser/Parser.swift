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

    public init(_ tokens: [Token], diags: DiagnosticEngine = DiagnosticEngine()) {
        // Filter out EOF for easier processing, we'll add it back at the end
        self.tokens = tokens.filter { $0.kind != .eof }
        self.diags = diags
    }

    // MARK: - Public API

    public func parse() throws -> [Decl] {
        var decls: [Decl] = []
        while !isAtEnd() {
            do {
                if let decl = try parseExternalDecl() {
                    decls.append(decl)
                }
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
        }
    }

    private func isPunct(_ s: String) -> Bool {
        return current().kind == .punct && current().spelling == s
    }

    private func isKeyword(_ s: String) -> Bool {
        return current().kind == .keyword && current().spelling == s
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

    private func parseExternalDecl() throws -> Decl? {
        // Empty
        if isPunct(";") { advance(); return nil }

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
            // Could be a struct/union/enum decl — we already processed it in parseDeclSpecifiers
            return nil
        }

        // Parse one or more declarators
        var firstDecl: Decl? = nil
        repeat {
            let (name, type, loc) = try parseDeclarator(baseType)

            if isPunct("{") && type.isFunction {
                // Function definition — parse the body and return immediately
                // (no semicolon after a function definition)
                let body = try parseCompoundStmt()
                // Extract the return type from the function type
                let returnType: CType
                let params: [CType]
                let variadic: Bool
                if case .function(let p, let ret, let v) = type {
                    returnType = ret
                    params = p
                    variadic = v
                } else {
                    returnType = type
                    params = []
                    variadic = false
                }
                let funcDecl = FuncDecl(name: name, returnType: returnType,
                                        params: params.map { Param(name: nil, type: $0, loc: SourceLoc.unknown) },
                                        variadic: variadic,
                                        body: body, storageClass: storageClass, isInline: isInline, loc: loc)
                return .funcDecl(funcDecl)
            }

            // Optional initializer
            var initExpr: Expr? = nil
            if match(kind: .punct, spelling: "=") {
                initExpr = try parseInitializer(type: type)
            }

            // Function prototype (no body) — create a FuncDecl instead of VarDecl
            if type.isFunction {
                let returnType: CType
                let params: [CType]
                let variadic: Bool
                if case .function(let p, let ret, let v) = type {
                    returnType = ret
                    params = p
                    variadic = v
                } else {
                    returnType = type
                    params = []
                    variadic = false
                }
                let fd = FuncDecl(name: name, returnType: returnType,
                                  params: params.map { Param(name: nil, type: $0, loc: SourceLoc.unknown) },
                                  variadic: variadic,
                                  body: nil, storageClass: storageClass, isInline: isInline, loc: loc)
                if firstDecl == nil {
                    firstDecl = .funcDecl(fd)
                }
            } else {
                let varDecl = VarDecl(name: name, type: type, initializer: initExpr,
                                      storageClass: storageClass, isGlobal: true, loc: loc)
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
            typedefNames.insert(name)
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

            if t.kind == .keyword {
                switch t.spelling {
                // Storage classes
                case "static": storageClass = .static; advance()
                case "extern": storageClass = .extern; advance()
                case "register": storageClass = .register; advance()
                case "auto": storageClass = .auto; advance()
                case "typedef": isTypedef = true; advance()

                // Type qualifiers
                case "const": isConst = true; advance()
                case "volatile": isVolatile = true; advance()
                case "restrict": isRestrict = true; advance()
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

                case "struct":
                    structType = try parseStructOrUnion(isStruct: true)
                case "union":
                    unionType = try parseStructOrUnion(isStruct: false)
                case "enum":
                    enumType = try parseEnumSpec()

                default:
                    done = true
                }
            } else if isTypedefName() {
                // Typedef name used as type specifier
                let name = current().spelling
                typedefBase = CType.typedef(name: name, base: .int) // base will be resolved by sema
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

        if hasVoid { return .void }
        if hasBool { return .bool }
        if hasChar { return isUnsigned ? .uchar : .char }
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

        // Optional tag name
        var tag: String? = nil
        if current().kind == .identifier {
            tag = current().spelling
            advance()
        }

        // If there's a body { ... }
        if isPunct("{") {
            advance() // {
            var fields: [RecordField] = []
            var offset = 0
            var maxAlign = 1

            while !isPunct("}") && !isAtEnd() {
                // Parse field declaration(s)
                let (baseType, _, _, _) = try parseDeclSpecifiers()

                repeat {
                    let (fieldName, fieldType, _) = try parseDeclarator(baseType)
                    var bitWidth: Int? = nil
                    if match(kind: .punct, spelling: ":") {
                        // Bitfield
                        let widthExpr = try parseConditionalExpr()
                        bitWidth = Int(evalIntConst(widthExpr))
                    }
                    let fieldSize = fieldType.sizeInBytes ?? 0
                    let fieldAlign = fieldType.alignOf ?? 1
                    maxAlign = max(maxAlign, fieldAlign)
                    // Align offset
                    offset = (offset + fieldAlign - 1) & ~(fieldAlign - 1)
                    fields.append(RecordField(name: fieldName, type: fieldType, bitWidth: bitWidth, offset: offset))
                    offset += fieldSize
                } while match(kind: .punct, spelling: ",")

                _ = try consume(kind: .punct, spelling: ";")
            }
            _ = try consume(kind: .punct, spelling: "}")

            let totalSize = (offset + maxAlign - 1) & ~(maxAlign - 1)
            let rec = RecordType(name: tag ?? "", fields: fields, size: totalSize, alignment: maxAlign)
            return isStruct ? .structType(rec) : .unionType(rec)
        }

        // Forward declaration or reference: struct Tag (no body)
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
                if match(kind: .punct, spelling: "=") {
                    let valExpr = try parseConditionalExpr()
                    nextValue = Int(evalIntConst(valExpr))
                }
                cases.append(EnumCase(name: name, value: nextValue))
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
            while isKeyword("const") || isKeyword("volatile") || isKeyword("restrict") {
                advance()
            }
            type = .pointer(to: type)
        }

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
            if isPunct("*") {
                // Function pointer: (*name)(params)
                // Already consumed ( and *
                var innerType = type
                // Skip qualifiers
                while isKeyword("const") || isKeyword("volatile") { advance() }
                innerType = .pointer(to: innerType)
                // Get the name
                guard current().kind == .identifier else {
                    throw ParseError.expected("identifier", current().spelling, current().loc)
                }
                let name = current().spelling
                let nameLoc = advance().loc
                _ = try consume(kind: .punct, spelling: ")")
                // Now parse the function parameters: ( params )
                let (params, variadic, retType) = try parseFunctionParams(innerType)
                let funcType = CType.function(params: params, returnType: retType, variadic: variadic)
                return (name, funcType, nameLoc)
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
        while isPunct("[") || isPunct("(") {
            if isPunct("[") {
                advance() // [
                if isPunct("]") {
                    advance() // ]
                    type = .incompleteArray(of: type)
                } else {
                    let sizeExpr = try parseAssignmentExpr()
                    _ = try consume(kind: .punct, spelling: "]")
                    let size = evalIntConst(sizeExpr)
                    type = .array(of: type, count: Int(size))
                }
            } else if isPunct("(") {
                let (params, variadic, retType) = try parseFunctionParams(type)
                type = .function(params: params, returnType: retType, variadic: variadic)
            }
        }

        return (name, type, loc)
    }

    /// Parse function parameters: ( int a, int b, ... )
    /// Returns (param types, variadic, returnType).
    private func parseFunctionParams(_ returnType: CType) throws -> ([CType], Bool, CType) {
        _ = try consume(kind: .punct, spelling: "(")
        var params: [CType] = []
        var variadic = false

        // void as sole parameter means no parameters
        if isKeyword("void") && next().kind == .punct && next().spelling == ")" {
            advance() // void
            _ = try consume(kind: .punct, spelling: ")")
            return ([], false, returnType)
        }

        while !isPunct(")") && !isAtEnd() {
            if isPunct("...") {
                advance()
                variadic = true
                break
            }

            let (baseType, _, _, _) = try parseDeclSpecifiers()
            let (paramName, paramType, _) = try parseDeclarator(baseType)
            // In function params, array types decay to pointers
            var actualType = paramType
            if case .array(let elem, _) = actualType.unqualified {
                actualType = .pointer(to: elem)
            } else if case .incompleteArray(let elem) = actualType.unqualified {
                actualType = .pointer(to: elem)
            }
            params.append(actualType)
            _ = paramName // param names not used in type but could be for sema

            if !match(kind: .punct, spelling: ",") {
                break
            }
        }
        _ = try consume(kind: .punct, spelling: ")")
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

        // Handle designators: [index] = val or .field = val
        while !isPunct("}") && !isAtEnd() {
            // Skip designators (we just parse the value)
            if isPunct("[") {
                // Array designator [index]
                advance()
                _ = try parseAssignmentExpr()
                _ = try consume(kind: .punct, spelling: "]")
                _ = match(kind: .punct, spelling: "=")
            } else if isPunct(".") {
                // Field designator .field
                advance()
                _ = try consume(kind: .identifier)
                _ = match(kind: .punct, spelling: "=")
            }

            values.append(try parseAssignmentExpr())

            if !match(kind: .punct, spelling: ",") {
                break
            }
        }
        _ = try consume(kind: .punct, spelling: "}")
        return .initList(InitListExpr(values: values, loc: loc))
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
            if isKeyword("if") { return .if(try parseIfStmt()) }
            if isKeyword("while") { return .while(try parseWhileStmt()) }
            if isKeyword("do") { return .doWhile(try parseDoWhileStmt()) }
            if isKeyword("for") { return .for(try parseForStmt()) }
            if isKeyword("switch") { return .switch(try parseSwitchStmt()) }
            if isKeyword("break") { let loc = advance().loc; _ = try consume(kind: .punct, spelling: ";"); return .break(BreakStmt(loc: loc)) }
            if isKeyword("continue") { let loc = advance().loc; _ = try consume(kind: .punct, spelling: ";"); return .continue(ContinueStmt(loc: loc)) }
            if isKeyword("return") { let loc = advance().loc; var val: Expr? = nil; if !isPunct(";") { val = try parseExpr() }; _ = try consume(kind: .punct, spelling: ";"); return .return(ReturnStmt(value: val, loc: loc)) }
            if isKeyword("goto") { let loc = advance().loc; let label = try consume(kind: .identifier).spelling; _ = try consume(kind: .punct, spelling: ";"); return .goto(GotoStmt(label: label, loc: loc)) }
            // Declaration (starts with a type keyword)
            return .decl(try parseDeclStmt())

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

        let (baseType, storageClass, _, _) = try parseDeclSpecifiers()
        var decls: [Decl] = []

        repeat {
            let (name, type, dloc) = try parseDeclarator(baseType)
            var initExpr: Expr? = nil
            if match(kind: .punct, spelling: "=") {
                initExpr = try parseInitializer(type: type)
            }
            decls.append(.varDecl(VarDecl(name: name, type: type, initializer: initExpr,
                                          storageClass: storageClass, isGlobal: false, loc: dloc)))
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
            let trueE = try parseExpr()
            _ = try consume(kind: .punct, spelling: ":")
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
        // Heuristic: if the token after ( is a type keyword or a typedef name, it's a cast.
        if isPunct("(") {
            let nextTok = next()
            if nextTok.kind == .keyword && isTypeKeyword(nextTok.spelling) ||
               (nextTok.kind == .identifier && typedefNames.contains(nextTok.spelling)) {
                // Parse as cast
                let savePos = pos
                advance() // (
                let (baseType, _, _, _) = try parseDeclSpecifiers()
                let (_, castType, _) = try parseDeclarator(baseType)
                _ = try consume(kind: .punct, spelling: ")")
                let operand = try parseCastExpr()
                return .cast(CastExpr(type: castType, expr: operand, loc: current().loc))
            }
        }

        return try parseUnaryExpr()
    }

    private func isTypeKeyword(_ s: String) -> Bool {
        return ["void", "char", "short", "int", "long", "float", "double",
                "signed", "unsigned", "const", "volatile", "struct", "union",
                "enum", "_Bool", "restrict"].contains(s)
    }

    private func parseUnaryExpr() throws -> Expr {
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

        switch token.kind {
        case .integerLiteral:
            advance()
            let (val, isUnsigned, type) = parseIntLiteral(token.spelling)
            return .integerLiteral(IntegerLiteral(value: val, isUnsigned: isUnsigned, type: type, loc: token.loc))

        case .floatLiteral:
            advance()
            let val = parseDoubleLiteral(token.spelling)
            let type: CType = token.spelling.hasSuffix("f") || token.spelling.hasSuffix("F") ? .float : .double
            return .floatLiteral(FloatLiteral(value: val, type: type, loc: token.loc))

        case .charLiteral:
            advance()
            let val = parseCharLiteralValue(token.spelling)
            return .charLiteral(CharLiteral(value: val, type: .int, loc: token.loc))

        case .stringLiteral:
            // Concatenate adjacent string literals
            var str = parseStringLiteralValue(token.spelling)
            advance()
            while current().kind == .stringLiteral {
                str += parseStringLiteralValue(current().spelling)
                advance()
            }
            let type = CType.array(of: .char, count: str.utf8.count + 1)
            return .stringLiteral(StringLiteral(value: str, type: type, loc: token.loc))

        case .identifier:
            advance()
            return .identifier(Identifier(name: token.spelling, loc: token.loc))

        case .punct:
            if isPunct("(") {
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
            value = Int64(s.dropFirst(2), radix: 16) ?? 0
        } else if s.hasPrefix("0b") || s.hasPrefix("0B") {
            value = Int64(s.dropFirst(2), radix: 2) ?? 0
        } else if s.hasPrefix("0") && s.count > 1 {
            value = Int64(s.dropFirst(), radix: 8) ?? 0
        } else {
            value = Int64(s) ?? 0
        }

        let type: CType
        if isLongLong { type = isUnsigned ? .ulongLong : .longLong }
        else if isLong { type = isUnsigned ? .ulong : .long }
        else { type = isUnsigned ? .uint : .int }

        return (value, isUnsigned, type)
    }

    private func parseDoubleLiteral(_ spelling: String) -> Double {
        var s = spelling
        if s.hasSuffix("f") || s.hasSuffix("F") || s.hasSuffix("l") || s.hasSuffix("L") {
            s = String(s.dropLast())
        }
        return Double(s) ?? 0.0
    }

    private func parseCharLiteralValue(_ spelling: String) -> UInt8 {
        // Strip quotes and prefix
        var s = spelling
        if s.hasPrefix("L") || s.hasPrefix("u") || s.hasPrefix("U") { s = String(s.dropFirst()) }
        guard s.hasPrefix("'") && s.hasSuffix("'") else { return 0 }
        s = String(s.dropFirst().dropLast())
        if s.isEmpty { return 0 }
        if s.hasPrefix("\\") {
            return parseEscape(String(s.dropFirst()))
        }
        return Array(s.utf8).first ?? 0
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
                case "n": result += "\n"
                case "t": result += "\t"
                case "r": result += "\r"
                case "0": result += "\0"
                case "\\": result += "\\"
                case "'": result += "'"
                case "\"": result += "\""
                case "x":
                    // Hex escape
                    let hexStart = s.index(i, offsetBy: 2)
                    var hexStr = ""
                    var j = hexStart
                    while j < s.endIndex && s[j].isHexDigit && hexStr.count < 2 {
                        hexStr.append(s[j]); j = s.index(after: j)
                    }
                    if let val = UInt8(hexStr, radix: 16) {
                        result.append(Character(UnicodeScalar(val)))
                    }
                    i = s.index(before: j)
                default:
                    // Octal escape
                    if next.isNumber {
                        var octStart = s.index(after: i)
                        var octStr = ""
                        var j = octStart
                        while j < s.endIndex && s[j].isNumber && octStr.count < 3 {
                            octStr.append(s[j]); j = s.index(after: j)
                        }
                        if let val = UInt8(octStr, radix: 8) {
                            result.append(Character(UnicodeScalar(val)))
                        }
                        i = s.index(before: j)
                    } else {
                        result.append(next)
                    }
                }
                i = s.index(after: i)
            } else {
                result.append(s[i])
            }
            i = s.index(after: i)
        }
        return result
    }

    private func parseEscape(_ s: String) -> UInt8 {
        guard let first = s.first else { return 0 }
        switch first {
        case "n": return 0x0A
        case "t": return 0x09
        case "r": return 0x0D
        case "0": return 0x00
        case "\\": return 0x5C
        case "'": return 0x27
        case "\"": return 0x22
        case "x":
            let hex = String(s.dropFirst())
            return UInt8(hex, radix: 16) ?? 0
        default:
            if first.isNumber {
                return UInt8(s, radix: 8) ?? 0
            }
            return Array(String(first).utf8).first ?? 0
        }
    }

    // MARK: - Constant expression evaluation

    private func evalIntConst(_ expr: Expr) -> Int64 {
        switch expr {
        case .integerLiteral(let l):
            return l.value
        case .charLiteral(let l):
            return Int64(l.value)
        case .binary(let b):
            let l = evalIntConst(b.left)
            let r = evalIntConst(b.right)
            switch b.op {
            case .add: return l + r
            case .sub: return l - r
            case .mul: return l * r
            case .div: return r != 0 ? l / r : 0
            case .mod: return r != 0 ? l % r : 0
            case .shl: return l << r
            case .shr: return l >> r
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
            case .neg: return -v
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
        return self.isHexDigit
    }
}
