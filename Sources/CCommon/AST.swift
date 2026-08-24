import Foundation

// MARK: - AST Node base

/// Base protocol for all AST nodes — each carries a source location.
public protocol ASTNode {
    var loc: SourceLoc { get }
}

// MARK: - Declarations

/// A top-level or local declaration.
public indirect enum Decl: ASTNode, Equatable {
    case varDecl(VarDecl)
    case funcDecl(FuncDecl)
    case typedefDecl(TypedefDecl)
    case structDecl(StructDecl)
    case unionDecl(UnionDecl)
    case enumDecl(EnumDecl)
    case staticAssert(StaticAssertDecl)

    public var loc: SourceLoc {
        switch self {
        case .varDecl(let d): return d.loc
        case .funcDecl(let d): return d.loc
        case .typedefDecl(let d): return d.loc
        case .structDecl(let d): return d.loc
        case .unionDecl(let d): return d.loc
        case .enumDecl(let d): return d.loc
        case .staticAssert(let d): return d.loc
        }
    }
}

/// A variable declaration (global or local).
public struct VarDecl: Equatable {
    public let name: String
    public var type: CType
    public var initializer: Expr?
    public var storageClass: StorageClass
    public var isGlobal: Bool
    public let loc: SourceLoc
    /// VLA size expression (for variable-length arrays like `int arr[n]`).
    /// When non-nil, the array dimension is a runtime expression, not a constant.
    public var vlaSizeExpr: Expr?
    /// Inner VLA size expressions for multi-dimensional VLAs (e.g., `int matrix[m][n]`).
    /// The outer dimension goes in vlaSizeExpr; inner dimensions go here in order.
    public var vlaInnerSizeExprs: [Expr]

    public init(name: String, type: CType, initializer: Expr? = nil,
                storageClass: StorageClass = .none, isGlobal: Bool = false, loc: SourceLoc,
                vlaSizeExpr: Expr? = nil, vlaInnerSizeExprs: [Expr] = []) {
        self.name = name
        self.type = type
        self.initializer = initializer
        self.storageClass = storageClass
        self.isGlobal = isGlobal
        self.loc = loc
        self.vlaSizeExpr = vlaSizeExpr
        self.vlaInnerSizeExprs = vlaInnerSizeExprs
    }
}

/// A function declaration (prototype or definition).
public struct FuncDecl: Equatable {
    public let name: String
    public var returnType: CType
    public var params: [Param]
    public var variadic: Bool
    public var body: CompoundStmt?   // nil = prototype only
    public var storageClass: StorageClass
    public var isInline: Bool
    public let loc: SourceLoc

    public init(name: String, returnType: CType, params: [Param], variadic: Bool,
                body: CompoundStmt? = nil, storageClass: StorageClass = .none,
                isInline: Bool = false, loc: SourceLoc) {
        self.name = name
        self.returnType = returnType
        self.params = params
        self.variadic = variadic
        self.body = body
        self.storageClass = storageClass
        self.isInline = isInline
        self.loc = loc
    }
}

/// A function parameter.
public struct Param: Equatable {
    public let name: String?
    public var type: CType
    public let loc: SourceLoc

    public init(name: String?, type: CType, loc: SourceLoc) {
        self.name = name
        self.type = type
        self.loc = loc
    }
}

/// A typedef declaration.
public struct TypedefDecl: Equatable {
    public let name: String
    public var type: CType       // the aliased type
    public let loc: SourceLoc

    public init(name: String, type: CType, loc: SourceLoc) {
        self.name = name
        self.type = type
        self.loc = loc
    }
}

/// A struct declaration/definition.
public struct StructDecl: Equatable {
    public let name: String?
    public var record: RecordType
    public let loc: SourceLoc

    public init(name: String?, record: RecordType, loc: SourceLoc) {
        self.name = name
        self.record = record
        self.loc = loc
    }
}

/// A union declaration/definition.
public struct UnionDecl: Equatable {
    public let name: String?
    public var record: RecordType
    public let loc: SourceLoc

    public init(name: String?, record: RecordType, loc: SourceLoc) {
        self.name = name
        self.record = record
        self.loc = loc
    }
}

/// An enum declaration/definition.
public struct EnumDecl: Equatable {
    public let name: String?
    public var enumType: EnumType
    public let loc: SourceLoc

    public init(name: String?, enumType: EnumType, loc: SourceLoc) {
        self.name = name
        self.enumType = enumType
        self.loc = loc
    }
}

/// A _Static_assert declaration.
public struct StaticAssertDecl: Equatable {
    public let condition: Expr
    public let message: String?
    public let loc: SourceLoc

    public init(condition: Expr, message: String?, loc: SourceLoc) {
        self.condition = condition
        self.message = message
        self.loc = loc
    }
}

// MARK: - Storage classes

public enum StorageClass: Equatable, Sendable {
    case none
    case `static`
    case extern
    case auto      // default for local vars
    case register
}

// MARK: - Statements

public indirect enum Stmt: ASTNode, Equatable {
    case expr(ExprStmt)
    case compound(CompoundStmt)
    case `if`(IfStmt)
    case `while`(WhileStmt)
    case doWhile(DoWhileStmt)
    case `for`(ForStmt)
    case `switch`(SwitchStmt)
    case `case`(CaseStmt)
    case `default`(DefaultStmt)
    case `break`(BreakStmt)
    case `continue`(ContinueStmt)
    case `return`(ReturnStmt)
    case `goto`(GotoStmt)
    case computedGoto(ComputedGotoStmt)
    case label(LabelStmt)
    case decl(DeclStmt)
    case empty(EmptyStmt)
    case asm(AsmStmt)

    public var loc: SourceLoc {
        switch self {
        case .expr(let s): return s.loc
        case .compound(let s): return s.loc
        case .if(let s): return s.loc
        case .while(let s): return s.loc
        case .doWhile(let s): return s.loc
        case .for(let s): return s.loc
        case .switch(let s): return s.loc
        case .case(let s): return s.loc
        case .default(let s): return s.loc
        case .break(let s): return s.loc
        case .asm(let s): return s.loc
        case .continue(let s): return s.loc
        case .return(let s): return s.loc
        case .goto(let s): return s.loc
        case .computedGoto(let s): return s.loc
        case .label(let s): return s.loc
        case .decl(let s): return s.loc
        case .empty(let s): return s.loc
        }
    }
}

public struct ExprStmt: Equatable {
    public let expr: Expr?
    public let loc: SourceLoc
    public init(expr: Expr?, loc: SourceLoc) { self.expr = expr; self.loc = loc }
}

public struct CompoundStmt: Equatable {
    public var statements: [Stmt]
    public let loc: SourceLoc
    public init(statements: [Stmt], loc: SourceLoc) { self.statements = statements; self.loc = loc }
}

public struct IfStmt: Equatable {
    public let condition: Expr
    public let thenStmt: Stmt
    public let elseStmt: Stmt?
    public let loc: SourceLoc
    public init(condition: Expr, thenStmt: Stmt, elseStmt: Stmt?, loc: SourceLoc) {
        self.condition = condition; self.thenStmt = thenStmt; self.elseStmt = elseStmt; self.loc = loc
    }
}

public struct WhileStmt: Equatable {
    public let condition: Expr
    public let body: Stmt
    public let loc: SourceLoc
    public init(condition: Expr, body: Stmt, loc: SourceLoc) { self.condition = condition; self.body = body; self.loc = loc }
}

public struct DoWhileStmt: Equatable {
    public let body: Stmt
    public let condition: Expr
    public let loc: SourceLoc
    public init(body: Stmt, condition: Expr, loc: SourceLoc) { self.body = body; self.condition = condition; self.loc = loc }
}

public struct ForStmt: Equatable {
    public let initStmt: Stmt?       // can be a decl or expr or nil
    public let condition: Expr?
    public let increment: Expr?
    public let body: Stmt
    public let loc: SourceLoc
    public init(initStmt: Stmt?, condition: Expr?, increment: Expr?, body: Stmt, loc: SourceLoc) {
        self.initStmt = initStmt; self.condition = condition; self.increment = increment
        self.body = body; self.loc = loc
    }
}

public struct SwitchStmt: Equatable {
    public let value: Expr
    public var cases: [Stmt]    // CaseStmt and DefaultStmt nodes, followed by statements
    public let loc: SourceLoc
    public init(value: Expr, cases: [Stmt], loc: SourceLoc) { self.value = value; self.cases = cases; self.loc = loc }
}

public struct CaseStmt: Equatable {
    public let value: Expr      // constant expression
    public let stmt: Stmt?
    public let loc: SourceLoc
    public init(value: Expr, stmt: Stmt?, loc: SourceLoc) { self.value = value; self.stmt = stmt; self.loc = loc }
}

public struct DefaultStmt: Equatable {
    public let stmt: Stmt?
    public let loc: SourceLoc
    public init(stmt: Stmt?, loc: SourceLoc) { self.stmt = stmt; self.loc = loc }
}

public struct BreakStmt: Equatable {
    public let loc: SourceLoc
    public init(loc: SourceLoc) { self.loc = loc }
}

public struct ContinueStmt: Equatable {
    public let loc: SourceLoc
    public init(loc: SourceLoc) { self.loc = loc }
}

public struct ReturnStmt: Equatable {
    public let value: Expr?
    public let loc: SourceLoc
    public init(value: Expr?, loc: SourceLoc) { self.value = value; self.loc = loc }
}

public struct GotoStmt: Equatable {
    public let label: String
    public let loc: SourceLoc
    public init(label: String, loc: SourceLoc) { self.label = label; self.loc = loc }
}

public struct ComputedGotoStmt: Equatable {
    public let target: Expr
    public let loc: SourceLoc
    public init(target: Expr, loc: SourceLoc) { self.target = target; self.loc = loc }
}

public struct LabelStmt: Equatable {
    public let name: String
    public let stmt: Stmt
    public let loc: SourceLoc
    public init(name: String, stmt: Stmt, loc: SourceLoc) { self.name = name; self.stmt = stmt; self.loc = loc }
}

public struct DeclStmt: Equatable {
    public var decls: [Decl]    // usually VarDecls
    public let loc: SourceLoc
    public init(decls: [Decl], loc: SourceLoc) { self.decls = decls; self.loc = loc }
}

public struct EmptyStmt: Equatable {
    public let loc: SourceLoc
    public init(loc: SourceLoc) { self.loc = loc }
}

public struct AsmStmt: Equatable {
    public let instructions: String
    public let loc: SourceLoc
    public init(instructions: String, loc: SourceLoc) { self.instructions = instructions; self.loc = loc }
}

// MARK: - Expressions

public indirect enum Expr: ASTNode, Equatable {
    case integerLiteral(IntegerLiteral)
    case floatLiteral(FloatLiteral)
    case charLiteral(CharLiteral)
    case stringLiteral(StringLiteral)
    case boolLiteral(BoolLiteral)
    case identifier(Identifier)
    case member(MemberExpr)          // a.b or a->b
    case binary(BinaryExpr)
    case unary(UnaryExpr)
    case assign(AssignExpr)
    case conditional(ConditionalExpr)  // a ? b : c
    case call(CallExpr)
    case subscript_(SubscriptExpr)
    case cast(CastExpr)
    case sizeof(SizeofExpr)
    case compoundLiteral(CompoundLiteralExpr)
    case initList(InitListExpr)
    case genericExpr(GenericExpr)
    case stmtExpr(StmtExpr)

    public var loc: SourceLoc {
        switch self {
        case .integerLiteral(let e): return e.loc
        case .floatLiteral(let e): return e.loc
        case .charLiteral(let e): return e.loc
        case .stringLiteral(let e): return e.loc
        case .boolLiteral(let e): return e.loc
        case .identifier(let e): return e.loc
        case .member(let e): return e.loc
        case .binary(let e): return e.loc
        case .unary(let e): return e.loc
        case .assign(let e): return e.loc
        case .conditional(let e): return e.loc
        case .call(let e): return e.loc
        case .subscript_(let e): return e.loc
        case .cast(let e): return e.loc
        case .sizeof(let e): return e.loc
        case .compoundLiteral(let e): return e.loc
        case .initList(let e): return e.loc
        case .genericExpr(let e): return e.loc
        case .stmtExpr(let e): return e.loc
        }
    }
}

/// GCC statement expression: ({ ... })
public struct StmtExpr: Equatable {
    public let body: CompoundStmt
    public let loc: SourceLoc
    public init(body: CompoundStmt, loc: SourceLoc) {
        self.body = body
        self.loc = loc
    }
}

/// C11 _Generic selection expression
public struct GenericAssociation: Equatable {
    public let typeName: CType?
    public let isDefault: Bool
    public let expr: Expr
    public init(typeName: CType?, isDefault: Bool, expr: Expr) {
        self.typeName = typeName
        self.isDefault = isDefault
        self.expr = expr
    }
}

public struct GenericExpr: Equatable {
    public let controllingExpr: Expr
    public let associations: [GenericAssociation]
    public let loc: SourceLoc
    public init(controllingExpr: Expr, associations: [GenericAssociation], loc: SourceLoc) {
        self.controllingExpr = controllingExpr
        self.associations = associations
        self.loc = loc
    }
}

public struct IntegerLiteral: Equatable {
    public let value: Int64
    public let isUnsigned: Bool
    public let type: CType
    public let loc: SourceLoc
    public init(value: Int64, isUnsigned: Bool = false, type: CType = .int, loc: SourceLoc) {
        self.value = value; self.isUnsigned = isUnsigned; self.type = type; self.loc = loc
    }
}

public struct FloatLiteral: Equatable {
    public let value: Double
    public let type: CType
    public let isImaginary: Bool
    public let loc: SourceLoc
    public init(value: Double, type: CType = .double, isImaginary: Bool = false, loc: SourceLoc) {
        self.value = value; self.type = type; self.isImaginary = isImaginary; self.loc = loc
    }
}

public struct CharLiteral: Equatable {
    public let value: UInt8
    public let type: CType
    public let loc: SourceLoc
    public init(value: UInt8, type: CType = .int, loc: SourceLoc) {
        self.value = value; self.type = type; self.loc = loc
    }
}

public struct StringLiteral: Equatable {
    public let value: String       // the decoded string content
    public let type: CType         // array of char
    public let loc: SourceLoc
    public init(value: String, type: CType, loc: SourceLoc) {
        self.value = value; self.type = type; self.loc = loc
    }
}

public struct BoolLiteral: Equatable {
    public let value: Bool
    public let type: CType
    public let loc: SourceLoc
    public init(value: Bool, loc: SourceLoc) {
        self.value = value; self.type = .bool; self.loc = loc
    }
}

public struct Identifier: Equatable {
    public let name: String
    public var resolvedType: CType?   // filled by sema
    public let loc: SourceLoc
    public init(name: String, resolvedType: CType? = nil, loc: SourceLoc) {
        self.name = name; self.resolvedType = resolvedType; self.loc = loc
    }
}

public struct MemberExpr: Equatable {
    public let base: Expr
    public let memberName: String
    public let isArrow: Bool          // true for ->, false for .
    public var resolvedType: CType?
    public let loc: SourceLoc
    public init(base: Expr, memberName: String, isArrow: Bool,
                resolvedType: CType? = nil, loc: SourceLoc) {
        self.base = base; self.memberName = memberName; self.isArrow = isArrow
        self.resolvedType = resolvedType; self.loc = loc
    }
}

/// Binary operators.
public enum BinaryOp: String, Equatable, Sendable {
    case add = "+"
    case sub = "-"
    case mul = "*"
    case div = "/"
    case mod = "%"
    case shl = "<<"
    case shr = ">>"
    case bitAnd = "&"
    case bitOr = "|"
    case bitXor = "^"
    case logicAnd = "&&"
    case logicOr = "||"
    case eq = "=="
    case ne = "!="
    case lt = "<"
    case le = "<="
    case gt = ">"
    case ge = ">="
    case comma = ","
}

public struct BinaryExpr: Equatable {
    public let op: BinaryOp
    public let left: Expr
    public let right: Expr
    public var resolvedType: CType?
    public let loc: SourceLoc
    public init(op: BinaryOp, left: Expr, right: Expr, resolvedType: CType? = nil, loc: SourceLoc) {
        self.op = op; self.left = left; self.right = right
        self.resolvedType = resolvedType; self.loc = loc
    }
}

/// Unary operators.
public enum UnaryOp: String, Equatable, Sendable {
    case neg = "-"       // arithmetic negation
    case pos = "+"       // unary plus
    case not = "!"       // logical not
    case bitNot = "~"    // bitwise not
    case preInc = "++p"  // pre-increment
    case preDec = "--p"  // pre-decrement
    case postInc = "p++"
    case postDec = "p--"
    case addressOf = "&" // &x
    case dereference = "*" // *x
}

public struct UnaryExpr: Equatable {
    public let op: UnaryOp
    public let operand: Expr
    public var resolvedType: CType?
    public let loc: SourceLoc
    public init(op: UnaryOp, operand: Expr, resolvedType: CType? = nil, loc: SourceLoc) {
        self.op = op; self.operand = operand
        self.resolvedType = resolvedType; self.loc = loc
    }
}

/// Assignment operators.
public enum AssignOp: String, Equatable, Sendable {
    case assign = "="
    case addAssign = "+="
    case subAssign = "-="
    case mulAssign = "*="
    case divAssign = "/="
    case modAssign = "%="
    case shlAssign = "<<="
    case shrAssign = ">>="
    case andAssign = "&="
    case orAssign = "|="
    case xorAssign = "^="
}

public struct AssignExpr: Equatable {
    public let op: AssignOp
    public let target: Expr
    public let value: Expr
    public var resolvedType: CType?
    public let loc: SourceLoc
    public init(op: AssignOp, target: Expr, value: Expr, resolvedType: CType? = nil, loc: SourceLoc) {
        self.op = op; self.target = target; self.value = value
        self.resolvedType = resolvedType; self.loc = loc
    }
}

public struct ConditionalExpr: Equatable {
    public let condition: Expr
    public let trueExpr: Expr
    public let falseExpr: Expr
    public var resolvedType: CType?
    public let loc: SourceLoc
    public init(condition: Expr, trueExpr: Expr, falseExpr: Expr,
                resolvedType: CType? = nil, loc: SourceLoc) {
        self.condition = condition; self.trueExpr = trueExpr; self.falseExpr = falseExpr
        self.resolvedType = resolvedType; self.loc = loc
    }
}

public struct CallExpr: Equatable {
    public let function: Expr
    public var arguments: [Expr]
    public var resolvedType: CType?
    public let loc: SourceLoc
    public init(function: Expr, arguments: [Expr], resolvedType: CType? = nil, loc: SourceLoc) {
        self.function = function; self.arguments = arguments
        self.resolvedType = resolvedType; self.loc = loc
    }
}

public struct SubscriptExpr: Equatable {
    public let base: Expr
    public let index: Expr
    public var resolvedType: CType?
    public let loc: SourceLoc
    public init(base: Expr, index: Expr, resolvedType: CType? = nil, loc: SourceLoc) {
        self.base = base; self.index = index
        self.resolvedType = resolvedType; self.loc = loc
    }
}

public struct CastExpr: Equatable {
    public let type: CType
    public let expr: Expr
    public var resolvedType: CType?
    public let loc: SourceLoc
    public init(type: CType, expr: Expr, resolvedType: CType? = nil, loc: SourceLoc) {
        self.type = type; self.expr = expr
        self.resolvedType = resolvedType; self.loc = loc
    }
}

public struct SizeofExpr: Equatable {
    /// One of these is set: expr for `sizeof x`, typeName for `sizeof(int)`.
    public let expr: Expr?
    public let typeName: CType?
    public var resolvedType: CType?
    public let loc: SourceLoc
    /// True if this was created by __alignof__/_Alignof (returns alignment, not size)
    public let isAlignof: Bool
    public init(expr: Expr?, typeName: CType?, loc: SourceLoc, isAlignof: Bool = false) {
        self.expr = expr; self.typeName = typeName
        self.resolvedType = .ulong  // sizeof returns size_t = unsigned long on LP64
        self.loc = loc
        self.isAlignof = isAlignof
    }
}

public struct CompoundLiteralExpr: Equatable {
    public let type: CType
    public let initList: Expr
    public var resolvedType: CType?
    public let loc: SourceLoc
    public init(type: CType, initList: Expr, loc: SourceLoc) {
        self.type = type; self.initList = initList
        self.resolvedType = type; self.loc = loc
    }
}

public struct InitListExpr: Equatable {
    public var values: [Expr]
    /// Optional field designators for each value (e.g., ".a.j" → ["a", "j"]).
    /// When non-nil, the value should be placed at the designated field, not the next position.
    public var designators: [[String]?]  // per-value: nil = positional, [field names] = designated
    public let loc: SourceLoc
    public init(values: [Expr], designators: [[String]?] = [], loc: SourceLoc) {
        self.values = values
        self.designators = designators
        self.loc = loc
    }
}
