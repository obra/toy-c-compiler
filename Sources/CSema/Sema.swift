import CCommon
import CParser
import Foundation

// MARK: - Scope

/// A symbol table scope.
public final class Scope {
    var symbols: [String: Symbol] = [:]
    let parent: Scope?
    let isFunctionScope: Bool

    public init(parent: Scope? = nil, isFunctionScope: Bool = false) {
        self.parent = parent
        self.isFunctionScope = isFunctionScope
    }

    func lookup(_ name: String) -> Symbol? {
        if let s = symbols[name] { return s }
        return parent?.lookup(name)
    }

    func lookupLocal(_ name: String) -> Symbol? {
        return symbols[name]
    }

    func insert(_ symbol: Symbol) {
        symbols[symbol.name] = symbol
    }
}

// MARK: - Symbol

/// A symbol in the symbol table.
public enum Symbol {
    case variable(name: String, type: CType, isGlobal: Bool)
    case function(name: String, type: CType, params: [Param], variadic: Bool, defined: Bool)
    case typedef(name: String, type: CType)
    case `enum`(name: String, value: Int64, type: CType)

    public var name: String {
        switch self {
        case .variable(let n, _, _): return n
        case .function(let n, _, _, _, _): return n
        case .typedef(let n, _): return n
        case .enum(let n, _, _): return n
        }
    }
}

// MARK: - Semantic Analyzer

/// Semantic analysis: type-checks the AST, resolves symbols, and produces a typed AST.
public final class Sema {
    private let diags: DiagnosticEngine
    private var globalScope: Scope
    private var currentScope: Scope
    private var typedefs: [String: CType] = [:]
    private var records: [String: RecordType] = [:]
    private var enums: [String: EnumType] = [:]
    private var enumConstants: [String: Int64] = [:]
    private var functionReturnType: CType = .int
    private var inFunction: Bool = false

    public init(_ diags: DiagnosticEngine) {
        self.diags = diags
        self.globalScope = Scope()
        self.currentScope = globalScope
    }

    // MARK: - Public API

    public func analyze(_ decls: [Decl]) throws -> [Decl] {
        // First pass: collect all top-level declarations (functions, globals, typedefs)
        for decl in decls {
            collectTopLevel(decl)
        }
        // Second pass: analyze function bodies and global initializers
        for decl in decls {
            analyzeDecl(decl)
        }
        return decls
    }

    // MARK: - First pass: collect declarations

    private func collectTopLevel(_ decl: Decl) {
        switch decl {
        case .funcDecl(let fd):
            // Resolve return type
            let returnType = resolveType(fd.returnType)
            var params = fd.params.map { p in
                Param(name: p.name, type: resolveType(p.type), loc: p.loc)
            }
            // Decay array params to pointers
            params = params.map { p in
                var t = p.type
                if case .array(let elem, _) = t.unqualified { t = .pointer(to: elem) }
                else if case .incompleteArray(let elem) = t.unqualified { t = .pointer(to: elem) }
                return Param(name: p.name, type: t, loc: p.loc)
            }
            // Don't mutate the struct directly — but we need to. Since Decl is an enum with
            // associated structs, we can't easily mutate. For now, just register the symbol.
            let funcType = CType.function(params: params.map { $0.type }, returnType: returnType, variadic: fd.variadic)
            globalScope.insert(.function(name: fd.name, type: funcType, params: params, variadic: fd.variadic, defined: fd.body != nil))

        case .varDecl(let vd):
            let type = resolveType(vd.type)
            globalScope.insert(.variable(name: vd.name, type: type, isGlobal: true))

        case .typedefDecl(let td):
            let type = resolveType(td.type)
            typedefs[td.name] = type
            globalScope.insert(.typedef(name: td.name, type: type))

        case .structDecl(let sd):
            // Register the struct type
            records[sd.name ?? ""] = sd.record

        case .unionDecl(let ud):
            records[ud.name ?? ""] = ud.record

        case .enumDecl(let ed):
            // Register enum constants
            for c in ed.enumType.cases {
                enumConstants[c.name] = Int64(c.value)
                globalScope.insert(.enum(name: c.name, value: Int64(c.value), type: .int))
            }

        case .staticAssert:
            break
        }
    }

    // MARK: - Second pass: analyze

    private func analyzeDecl(_ decl: Decl) {
        switch decl {
        case .funcDecl(let fd):
            if let body = fd.body {
                analyzeFunctionBody(fd, body: body)
            }

        case .varDecl(let vd):
            if let init_ = vd.initializer {
                let _ = analyzeExpr(init_)
            }

        case .typedefDecl:
            break

        case .structDecl, .unionDecl, .enumDecl:
            break

        case .staticAssert(let sa):
            _ = analyzeExpr(sa.condition)

        default:
            break
        }
    }

    // MARK: - Function body analysis

    private func analyzeFunctionBody(_ fd: FuncDecl, body: CompoundStmt) {
        currentScope = Scope(parent: globalScope, isFunctionScope: true)
        inFunction = true
        functionReturnType = resolveType(fd.returnType)

        // Add parameters to scope
        for param in fd.params {
            currentScope.insert(.variable(name: param.name ?? "", type: resolveType(param.type), isGlobal: false))
        }

        analyzeCompoundStmt(body)

        currentScope = globalScope
        inFunction = false
    }

    // MARK: - Statement analysis

    private func analyzeStmt(_ stmt: Stmt) {
        switch stmt {
        case .expr(let es):
            if let e = es.expr {
                _ = analyzeExpr(e)
            }

        case .compound(let cs):
            analyzeCompoundStmt(cs)

        case .if(let is_):
            _ = analyzeExpr(is_.condition)
            analyzeStmt(is_.thenStmt)
            if let else_ = is_.elseStmt { analyzeStmt(else_) }

        case .while(let ws):
            _ = analyzeExpr(ws.condition)
            analyzeStmt(ws.body)

        case .doWhile(let dws):
            analyzeStmt(dws.body)
            _ = analyzeExpr(dws.condition)

        case .for(let fs):
            currentScope = Scope(parent: currentScope)
            if let init_ = fs.initStmt { analyzeStmt(init_) }
            if let cond = fs.condition { _ = analyzeExpr(cond) }
            if let incr = fs.increment { _ = analyzeExpr(incr) }
            analyzeStmt(fs.body)
            currentScope = currentScope.parent!

        case .switch(let ss):
            _ = analyzeExpr(ss.value)
            for c in ss.cases { analyzeStmt(c) }

        case .case(let cs):
            _ = analyzeExpr(cs.value)
            if let s = cs.stmt { analyzeStmt(s) }

        case .default(let ds):
            if let s = ds.stmt { analyzeStmt(s) }

        case .break, .continue, .empty, .goto:
            break

        case .return(let rs):
            if let v = rs.value { _ = analyzeExpr(v) }

        case .label(let ls):
            analyzeStmt(ls.stmt)

        case .decl(let ds):
            for d in ds.decls {
                if case .varDecl(let vd) = d {
                    let type = resolveType(vd.type)
                    currentScope.insert(.variable(name: vd.name, type: type, isGlobal: false))
                    if let init_ = vd.initializer {
                        _ = analyzeExpr(init_)
                    }
                }
            }
        }
    }

    private func analyzeCompoundStmt(_ cs: CompoundStmt) {
        currentScope = Scope(parent: currentScope)
        for stmt in cs.statements {
            analyzeStmt(stmt)
        }
        currentScope = currentScope.parent!
    }

    // MARK: - Expression analysis

    /// Analyze an expression and return its resolved type.
    private func analyzeExpr(_ expr: Expr) -> CType {
        switch expr {
        case .integerLiteral(let l):
            return l.type

        case .floatLiteral(let f):
            return f.type

        case .charLiteral:
            return .int

        case .stringLiteral(let s):
            return s.type

        case .boolLiteral:
            return .bool

        case .identifier(let id):
            if let sym = currentScope.lookup(id.name) {
                switch sym {
                case .variable(_, let type, _):
                    return type
                case .function(_, let type, _, _, _):
                    return type
                case .enum(_, let value, let type):
                    return type
                case .typedef(_, let type):
                    return type
                }
            }
            // Check enum constants
            if let _ = enumConstants[id.name] {
                return .int
            }
            // Undefined — report error but don't crash
            diags.error("use of undeclared identifier '\(id.name)'", at: id.loc)
            return .int

        case .binary(let b):
            let leftType = analyzeExpr(b.left)
            let rightType = analyzeExpr(b.right)
            return binaryResultType(b.op, leftType, rightType)

        case .unary(let u):
            let operandType = analyzeExpr(u.operand)
            switch u.op {
            case .neg, .pos, .bitNot:
                return integerPromote(operandType)
            case .not:
                return .int
            case .dereference:
                if case .pointer(let to) = operandType.unqualified {
                    return to
                }
                return .int
            case .addressOf:
                return .pointer(to: operandType)
            case .preInc, .preDec, .postInc, .postDec:
                return operandType
            }

        case .assign(let a):
            _ = analyzeExpr(a.target)
            _ = analyzeExpr(a.value)
            return analyzeExpr(a.target)

        case .conditional(let c):
            _ = analyzeExpr(c.condition)
            let t = analyzeExpr(c.trueExpr)
            let f = analyzeExpr(c.falseExpr)
            return usualArithmeticConversion(t, f)

        case .call(let c):
            let funcType = analyzeExpr(c.function)
            for arg in c.arguments {
                _ = analyzeExpr(arg)
            }
            if case .function(_, let retType, _) = funcType.unqualified {
                return retType
            }
            // If it's a function pointer
            if case .pointer(let to) = funcType.unqualified {
                if case .function(_, let retType, _) = to.unqualified {
                    return retType
                }
            }
            return .int

        case .subscript_(let s):
            let baseType = analyzeExpr(s.base)
            _ = analyzeExpr(s.index)
            if case .pointer(let to) = baseType.unqualified {
                return to
            }
            if case .array(let elem, _) = baseType.unqualified {
                return elem
            }
            return .int

        case .member(let m):
            let baseType = analyzeExpr(m.base)
            var recordType = baseType.unqualified
            if m.isArrow {
                if case .pointer(let to) = baseType.unqualified { recordType = to }
            }
            // Find the field
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
            _ = analyzeExpr(c.expr)
            return c.type

        case .sizeof(let s):
            if let typeName = s.typeName {
                return .ulong
            }
            if let e = s.expr {
                _ = analyzeExpr(e)
            }
            return .ulong

        case .compoundLiteral(let cl):
            _ = analyzeExpr(cl.initList)
            return cl.type

        case .initList(let il):
            for v in il.values {
                _ = analyzeExpr(v)
            }
            return .int
        }
    }

    // MARK: - Type resolution

    /// Resolve typedef names to their underlying types.
    private func resolveType(_ type: CType) -> CType {
        switch type {
        case .typedef(let name, let base):
            if let resolved = typedefs[name] {
                return resolved
            }
            return resolveType(base)

        case .qualified(let base, let c, let v, let r):
            return .qualified(base: resolveType(base), const: c, volatile: v, restrict: r)

        case .pointer(let to):
            return .pointer(to: resolveType(to))

        case .array(let elem, let count):
            return .array(of: resolveType(elem), count: count)

        case .incompleteArray(let elem):
            return .incompleteArray(of: resolveType(elem))

        case .function(let params, let ret, let variadic):
            return .function(params: params.map { resolveType($0) },
                             returnType: resolveType(ret), variadic: variadic)

        case .structType(let rec):
            // Check if we have a completed version
            if let completed = records[rec.name] {
                return .structType(completed)
            }
            return .structType(rec)

        case .unionType(let rec):
            if let completed = records[rec.name] {
                return .unionType(completed)
            }
            return .unionType(rec)

        case .enumType(let en):
            if let completed = enums[en.name] {
                return .enumType(completed)
            }
            return .enumType(en)

        default:
            return type
        }
    }

    // MARK: - Integer promotion

    /// Apply integer promotions (C99 6.3.1.1).
    private func integerPromote(_ type: CType) -> CType {
        let t = type.unqualified
        switch t {
        case .bool, .char, .schar, .uchar, .short, .ushort:
            return .int
        default:
            return t
        }
    }

    // MARK: - Usual arithmetic conversions

    /// Apply usual arithmetic conversions (C99 6.3.1.8).
    private func usualArithmeticConversion(_ a: CType, _ b: CType) -> CType {
        let ta = a.unqualified
        let tb = b.unqualified

        // If either is double or long double
        if ta == .longDouble || tb == .longDouble { return .longDouble }
        if ta == .double || tb == .double { return .double }
        if ta == .float || tb == .float { return .float }

        // Integer promotions
        let ia = integerPromote(ta)
        let ib = integerPromote(tb)

        // Same type
        if ia == ib { return ia }

        // Same signedness
        let aSigned = ia.isSigned
        let bSigned = ib.isSigned

        if aSigned == bSigned {
            // Return the larger type
            let aSize = ia.sizeInBytes ?? 0
            let bSize = ib.sizeInBytes ?? 0
            return aSize >= bSize ? ia : ib
        }

        // Different signedness
        // If the unsigned type has rank >= the signed type, use unsigned
        let aSize = ia.sizeInBytes ?? 0
        let bSize = ib.sizeInBytes ?? 0
        if !aSigned && aSize >= bSize { return ia }
        if !bSigned && bSize >= aSize { return ib }

        // Otherwise, if the signed type can represent all values of the unsigned type,
        // use the signed type; otherwise use the unsigned version of the signed type
        if aSigned && aSize > bSize { return ia }
        if bSigned && bSize > aSize { return ib }

        // Fallback
        return ia
    }

    // MARK: - Binary result type

    private func binaryResultType(_ op: BinaryOp, _ left: CType, _ right: CType) -> CType {
        switch op {
        case .logicAnd, .logicOr:
            return .int
        case .eq, .ne, .lt, .le, .gt, .ge:
            return .int
        case .comma:
            return right
        case .add, .sub, .mul, .div, .mod, .shl, .shr, .bitAnd, .bitOr, .bitXor:
            // Pointer arithmetic
            if left.isPointer && right.isInteger { return left }
            if left.isInteger && right.isPointer { return right }
            if left.isPointer && right.isPointer { return .long } // pointer difference
            return usualArithmeticConversion(left, right)
        }
    }
}
