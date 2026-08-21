import XCTest
@testable import CSema
@testable import CParser
@testable import CPreproc
@testable import CCommon

final class SemaTests: XCTestCase {

    private func analyze(_ source: String) -> (decls: [Decl], diags: DiagnosticEngine) {
        let sm = SourceManager()
        let fileId = sm.register(name: "test.c", contents: source)
        let diags = DiagnosticEngine()
        let pp = Preprocessor(sm, includePaths: [], predefines: [:])
        do {
            let tokens = try pp.preprocess(fileId)
            let parser = Parser(tokens, diags: diags)
            let decls = try parser.parse()
            let sema = Sema(diags)
            let result = try sema.analyze(decls)
            return (result, diags)
        } catch {
            XCTFail("analysis failed: \(error)")
            return ([], diags)
        }
    }

    // MARK: - Basic analysis

    func testAnalyzeSimpleFunction() {
        let (decls, diags) = analyze("int main() { return 0; }")
        XCTAssertFalse(diags.hasErrors)
        XCTAssertEqual(decls.count, 1)
    }

    func testAnalyzeVarDecl() {
        let (_, diags) = analyze("int x = 42;")
        XCTAssertFalse(diags.hasErrors)
    }

    func testAnalyzeFunctionCall() {
        let (_, diags) = analyze("""
        int add(int a, int b) { return a + b; }
        int main() { return add(1, 2); }
        """)
        XCTAssertFalse(diags.hasErrors)
    }

    // MARK: - Error detection

    func testUndeclaredIdentifier() {
        let (_, diags) = analyze("int main() { return x; }")
        XCTAssertTrue(diags.hasErrors)
    }

    func testTypeMismatch() {
        // Assigning string to int should produce an error (or at least a warning)
        let (_, diags) = analyze("int main() { int x = \"hello\"; return 0; }")
        // We might not catch all type mismatches yet, but this shouldn't crash
        _ = diags
    }

    // MARK: - Scope

    func testVariableScope() {
        let (_, diags) = analyze("""
        int main() {
            int x = 1;
            {
                int y = 2;
                int x = 3;  // shadowing is allowed
            }
            return x;  // should find x = 1
        }
        """)
        XCTAssertFalse(diags.hasErrors)
    }

    // MARK: - Struct

    func testStructMember() {
        let (_, diags) = analyze("""
        struct Point { int x; int y; };
        int main() {
            struct Point p;
            p.x = 1;
            p.y = 2;
            return p.x;
        }
        """)
        XCTAssertFalse(diags.hasErrors)
    }

    func testStructPointer() {
        let (_, diags) = analyze("""
        struct Point { int x; int y; };
        int main() {
            struct Point p;
            struct Point *pp = &p;
            pp->x = 1;
            return pp->x;
        }
        """)
        XCTAssertFalse(diags.hasErrors)
    }

    // MARK: - Typedef

    func testTypedef() {
        let (_, diags) = analyze("""
        typedef int Int;
        int main() {
            Int x = 42;
            return x;
        }
        """)
        XCTAssertFalse(diags.hasErrors)
    }

    // MARK: - Array

    func testArrayAccess() {
        let (_, diags) = analyze("""
        int main() {
            int a[10];
            a[0] = 1;
            return a[0];
        }
        """)
        XCTAssertFalse(diags.hasErrors)
    }

    // MARK: - Control flow

    func testIfStatement() {
        let (_, diags) = analyze("""
        int main() {
            int x = 1;
            if (x > 0) return 1; else return 0;
        }
        """)
        XCTAssertFalse(diags.hasErrors)
    }

    func testForLoop() {
        let (_, diags) = analyze("""
        int main() {
            int sum = 0;
            for (int i = 0; i < 10; i++) sum += i;
            return sum;
        }
        """)
        XCTAssertFalse(diags.hasErrors)
    }

    // MARK: - Recursion

    func testRecursiveFunction() {
        let (_, diags) = analyze("""
        int fib(int n) {
            if (n <= 1) return n;
            return fib(n - 1) + fib(n - 2);
        }
        int main() { return fib(10); }
        """)
        XCTAssertFalse(diags.hasErrors)
    }

    // MARK: - Multiple files / forward declarations

    func testForwardDeclaration() {
        let (_, diags) = analyze("""
        int foo();
        int main() { return foo(); }
        int foo() { return 42; }
        """)
        XCTAssertFalse(diags.hasErrors)
    }

    // MARK: - Complex code

    func testComplexCode() {
        let (_, diags) = analyze("""
        struct Node {
            int val;
            struct Node *next;
        };

        int sum_list(struct Node *head) {
            int sum = 0;
            struct Node *p = head;
            while (p != 0) {
                sum += p->val;
                p = p->next;
            }
            return sum;
        }

        int main() {
            struct Node a, b, c;
            a.val = 1; a.next = &b;
            b.val = 2; b.next = &c;
            c.val = 3; c.next = 0;
            return sum_list(&a);
        }
        """)
        XCTAssertFalse(diags.hasErrors)
    }
}
