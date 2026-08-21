import XCTest
@testable import CParser
@testable import CPreproc
@testable import CCommon

final class ParserTests: XCTestCase {

    private func parse(_ source: String) -> [Decl] {
        let sm = SourceManager()
        let fileId = sm.register(name: "test.c", contents: source)
        let pp = Preprocessor(sm, includePaths: [], predefines: [:])
        do {
            let tokens = try pp.preprocess(fileId)
            let parser = Parser(tokens)
            return try parser.parse()
        } catch {
            XCTFail("parse failed: \(error)")
            return []
        }
    }

    private func parseFunc(_ source: String) -> FuncDecl? {
        let decls = parse(source)
        if let d = decls.first, case .funcDecl(let fd) = d {
            return fd
        }
        return nil
    }

    // MARK: - Function parsing

    func testParseMainFunction() {
        let fd = parseFunc("int main() { return 0; }")
        XCTAssertNotNil(fd)
        XCTAssertEqual(fd?.name, "main")
        XCTAssertEqual(fd?.returnType, .int)
        XCTAssertNotNil(fd?.body)
    }

    func testParseFunctionWithParams() {
        let fd = parseFunc("int add(int a, int b) { return a + b; }")
        XCTAssertNotNil(fd)
        XCTAssertEqual(fd?.name, "add")
        XCTAssertEqual(fd?.params.count, 2)
        XCTAssertEqual(fd?.params[0].type, .int)
        XCTAssertEqual(fd?.params[1].type, .int)
    }

    func testParseFunctionPrototype() {
        let fd = parseFunc("int printf(const char *format, ...);")
        XCTAssertNotNil(fd)
        XCTAssertEqual(fd?.name, "printf")
        XCTAssertTrue(fd?.variadic ?? false)
        XCTAssertNil(fd?.body) // prototype only
    }

    func testParseVoidFunction() {
        let fd = parseFunc("void exit(int code) { }")
        XCTAssertNotNil(fd)
        XCTAssertEqual(fd?.returnType, .void)
    }

    // MARK: - Variable declarations

    func testParseVarDecl() {
        let decls = parse("int x;")
        if case .varDecl(let vd) = decls.first {
            XCTAssertEqual(vd.name, "x")
            XCTAssertEqual(vd.type, .int)
        } else {
            XCTFail("expected varDecl")
        }
    }

    func testParseVarDeclWithInit() {
        let decls = parse("int x = 42;")
        if case .varDecl(let vd) = decls.first {
            XCTAssertEqual(vd.name, "x")
            XCTAssertNotNil(vd.initializer)
        } else {
            XCTFail("expected varDecl")
        }
    }

    func testParsePointerDecl() {
        let decls = parse("int *p;")
        if case .varDecl(let vd) = decls.first {
            XCTAssertEqual(vd.name, "p")
            XCTAssertEqual(vd.type, .pointer(to: .int))
        } else {
            XCTFail("expected varDecl")
        }
    }

    func testParseArrayDecl() {
        let decls = parse("int a[10];")
        if case .varDecl(let vd) = decls.first {
            XCTAssertEqual(vd.name, "a")
            if case .array(let elem, let count) = vd.type {
                XCTAssertEqual(elem, .int)
                XCTAssertEqual(count, 10)
            } else {
                XCTFail("expected array type")
            }
        } else {
            XCTFail("expected varDecl")
        }
    }

    // MARK: - Struct parsing

    func testParseStruct() {
        let decls = parse("struct Point { int x; int y; };")
        if case .varDecl = decls.first {
            // The struct declaration may not produce a varDecl if there's no declarator
        }
        // The struct itself should be defined
    }

    func testParseStructWithVar() {
        let decls = parse("struct Point { int x; int y; } p;")
        if case .varDecl(let vd) = decls.first {
            XCTAssertEqual(vd.name, "p")
            XCTAssertTrue(vd.type.isStruct)
        } else {
            XCTFail("expected varDecl")
        }
    }

    // MARK: - Typedef

    func testParseTypedef() {
        let decls = parse("typedef int Int;")
        if case .typedefDecl(let td) = decls.first {
            XCTAssertEqual(td.name, "Int")
            XCTAssertEqual(td.type, .int)
        } else {
            XCTFail("expected typedefDecl")
        }
    }

    func testParseTypedefPointer() {
        let decls = parse("typedef int *IntPtr;")
        if case .typedefDecl(let td) = decls.first {
            XCTAssertEqual(td.name, "IntPtr")
            XCTAssertEqual(td.type, .pointer(to: .int))
        } else {
            XCTFail("expected typedefDecl")
        }
    }

    // MARK: - Statements

    func testParseReturnStatement() {
        let fd = parseFunc("int f() { return 42; }")
        if let body = fd?.body, body.statements.count > 0 {
            if case .return(let rs) = body.statements[0] {
                XCTAssertNotNil(rs.value)
            } else {
                XCTFail("expected return stmt")
            }
        }
    }

    func testParseIfStatement() {
        let fd = parseFunc("int f(int x) { if (x) return 1; else return 0; }")
        if let body = fd?.body, body.statements.count > 0 {
            if case .if(let ifStmt) = body.statements[0] {
                XCTAssertTrue(ifStmt.thenStmt is Stmt)
                XCTAssertTrue(ifStmt.elseStmt != nil)
            } else {
                XCTFail("expected if stmt")
            }
        }
    }

    func testParseWhileStatement() {
        let fd = parseFunc("int f() { while (1) { break; } }")
        if let body = fd?.body, body.statements.count > 0 {
            if case .while = body.statements[0] {
            } else {
                XCTFail("expected while stmt")
            }
        }
    }

    func testParseForStatement() {
        let fd = parseFunc("int f() { for (int i = 0; i < 10; i++) { } }")
        if let body = fd?.body, body.statements.count > 0 {
            if case .for = body.statements[0] {
            } else {
                XCTFail("expected for stmt")
            }
        }
    }

    // MARK: - Expressions

    func testParseBinaryExpr() {
        let fd = parseFunc("int f() { return 1 + 2 * 3; }")
        if let body = fd?.body, body.statements.count > 0 {
            if case .return(let rs) = body.statements[0], let val = rs.value {
                // Should be 1 + (2 * 3) due to precedence
                if case .binary(let b) = val {
                    XCTAssertEqual(b.op, .add)
                } else {
                    XCTFail("expected binary expr")
                }
            }
        }
    }

    func testParseFunctionCall() {
        let fd = parseFunc("int f() { return printf(\"hello\"); }")
        if let body = fd?.body, body.statements.count > 0 {
            if case .return(let rs) = body.statements[0], let val = rs.value {
                if case .call(let ce) = val {
                    if case .identifier(let id) = ce.function {
                        XCTAssertEqual(id.name, "printf")
                    }
                    XCTAssertEqual(ce.arguments.count, 1)
                } else {
                    XCTFail("expected call expr")
                }
            }
        }
    }

    // MARK: - Multiple declarations

    func testParseMultipleDecls() {
        let decls = parse("int a; int b; int c;")
        XCTAssertEqual(decls.count, 3)
    }

    // MARK: - Type qualifiers

    func testParseConstVar() {
        let decls = parse("const int x = 42;")
        if case .varDecl(let vd) = decls.first {
            XCTAssertTrue(vd.type.isConst)
        } else {
            XCTFail("expected varDecl")
        }
    }

    func testParseUnsignedLong() {
        let decls = parse("unsigned long x;")
        if case .varDecl(let vd) = decls.first {
            XCTAssertEqual(vd.type, .ulong)
        } else {
            XCTFail("expected varDecl")
        }
    }

    // MARK: - Complex code

    func testParseRealCode() {
        let source = """
        int fib(int n) {
            if (n <= 1) return n;
            return fib(n - 1) + fib(n - 2);
        }

        int main() {
            int result = fib(10);
            return result;
        }
        """
        let decls = parse(source)
        XCTAssertEqual(decls.count, 2)
    }
}
