import XCTest
@testable import CCompilerTests

/// End-to-end tests using OUR compiler (not system clang).
/// These test that our compiler can compile, assemble, link, and run C programs.
final class OurCompilerE2ETests: XCTestCase {

    func testReturnConstant() {
        let source = "int main() { return 42; }"
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 42))
    }

    func testReturnZero() {
        let source = "int main() { return 0; }"
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 0))
    }

    func testArithmetic() {
        let source = """
        int main() {
            int a = 20;
            int b = 22;
            return a + b;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 42))
    }

    func testSubtraction() {
        let source = """
        int main() {
            return 100 - 58;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 42))
    }

    func testMultiplication() {
        let source = """
        int main() {
            return 6 * 7;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 42))
    }

    func testIfElse() {
        let source = """
        int main() {
            int x = 10;
            if (x > 5) return 1;
            else return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 1))
    }

    func testWhileLoop() {
        let source = """
        int main() {
            int i = 1;
            int sum = 0;
            while (i <= 10) {
                sum += i;
                i += 1;
            }
            return sum;
        }
        """
        // 1+2+...+10 = 55
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 55))
    }

    func testFunctionCall() {
        let source = """
        int add(int a, int b) {
            return a + b;
        }
        int main() {
            return add(20, 22);
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 42))
    }

    func testRecursion() {
        let source = """
        int fib(int n) {
            if (n <= 1) return n;
            return fib(n - 1) + fib(n - 2);
        }
        int main() {
            return fib(10);
        }
        """
        // fib(10) = 55
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 55))
    }

    // MARK: - printf (external function call + string literal)

    func testPrintfHello() {
        let source = """
        int printf(const char *format, ...);
        int main() {
            printf("hello\\n");
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 0, expectedStdout: "hello\n"))
    }

    func testPrintfHelloWorld() {
        let source = """
        int printf(const char *format, ...);
        int main() {
            printf("hello world\\n");
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 0, expectedStdout: "hello world\n"))
    }

    func testPrintfMultiple() {
        let source = """
        int printf(const char *format, ...);
        int main() {
            printf("line1\\n");
            printf("line2\\n");
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 0, expectedStdout: "line1\nline2\n"))
    }

    // MARK: - Structs

    func testStructMemberAccess() {
        let source = """
        struct Point { int x; int y; };
        int main() {
            struct Point p;
            p.x = 3;
            p.y = 4;
            return p.x + p.y;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 7))
    }

    func testStructPointerArrow() {
        let source = """
        struct Point { int x; int y; };
        int main() {
            struct Point p;
            struct Point *pp = &p;
            pp->x = 7;
            pp->y = 3;
            return pp->x * pp->y;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 21))
    }

    // MARK: - Pointers and arrays

    func testPointerDereference() {
        let source = """
        int main() {
            int x = 10;
            int *p = &x;
            *p = 42;
            return x;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 42))
    }

    func testArraySubscript() {
        let source = """
        int main() {
            int a[5];
            a[0] = 10;
            a[1] = 20;
            a[2] = 30;
            return a[0] + a[1] + a[2];
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 60))
    }

    func testForLoopIncrement() {
        let source = """
        int printf(const char *format, ...);
        int main() {
            int sum = 0;
            for (int i = 1; i <= 100; i++) {
                sum += i;
            }
            printf("%d\\n", sum);
            return 0;
        }
        """
        // 1+2+...+100 = 5050
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 0, expectedStdout: "5050\n"))
    }

    // MARK: - Global variables

    func testGlobalInitInt() {
        let source = """
        int printf(const char *format, ...);
        int x = 42;
        int main() {
            printf("%d\\n", x);
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 0, expectedStdout: "42\n"))
    }

    func testGlobalWrite() {
        let source = """
        int printf(const char *format, ...);
        int x;
        int main() {
            x = 99;
            printf("%d\\n", x);
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 0, expectedStdout: "99\n"))
    }

    func testGlobalMultiple() {
        let source = """
        int printf(const char *format, ...);
        int a = 10;
        int b = 20;
        int main() {
            printf("%d\\n", a + b);
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 0, expectedStdout: "30\n"))
    }

    // MARK: - Switch/break/continue

    func testSwitchStatement() {
        let source = """
        int printf(const char *format, ...);
        int main() {
            int x = 2;
            switch (x) {
                case 1: printf("one\\n"); break;
                case 2: printf("two\\n"); break;
                case 3: printf("three\\n"); break;
                default: printf("other\\n"); break;
            }
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 0, expectedStdout: "two\n"))
    }

    func testSwitchDefault() {
        let source = """
        int printf(const char *format, ...);
        int main() {
            int x = 99;
            switch (x) {
                case 1: printf("one\\n"); break;
                default: printf("other\\n"); break;
            }
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 0, expectedStdout: "other\n"))
    }

    func testBreakInForLoop() {
        let source = """
        int printf(const char *format, ...);
        int main() {
            int i;
            for (i = 0; i < 10; i++) {
                if (i == 5) break;
                printf("%d\\n", i);
            }
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 0, expectedStdout: "0\n1\n2\n3\n4\n"))
    }

    func testContinueInForLoop() {
        let source = """
        int printf(const char *format, ...);
        int main() {
            int i;
            for (i = 0; i < 10; i++) {
                if (i == 3) continue;
                printf("%d\\n", i);
            }
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 0, expectedStdout: "0\n1\n2\n4\n5\n6\n7\n8\n9\n"))
    }

    // MARK: - Real programs

    func testLinkedList() {
        let source = """
        #include <stdio.h>
        #include <stdlib.h>

        struct Node {
            int val;
            struct Node *next;
        };

        struct Node *create(int v) {
            struct Node *n = malloc(sizeof(struct Node));
            n->val = v;
            n->next = 0;
            return n;
        }

        int main() {
            struct Node *head = create(1);
            head->next = create(2);
            head->next->next = create(3);

            int sum = 0;
            struct Node *p = head;
            while (p != 0) {
                sum += p->val;
                p = p->next;
            }

            printf("sum=%d\\n", sum);
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompiler(source, expectedExit: 0, expectedStdout: "sum=6\n", extraArgs: ["-I", "include"]))
    }
}
