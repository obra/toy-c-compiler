import XCTest
@testable import CCompilerTests

final class E2ETests: XCTestCase {

    // MARK: - Baseline tests (via system clang) — establish that the harness works

    func testBaselineReturn0() {
        let source = """
        int main() {
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaClang(source, expectedExit: 0))
    }

    func testBaselineReturn42() {
        let source = """
        int main() {
            return 42;
        }
        """
        XCTAssertTrue(Harness.runViaClang(source, expectedExit: 42))
    }

    func testBaselineHelloWorld() {
        let source = """
        #include <stdio.h>

        int main() {
            printf("hello\\n");
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaClang(source, expectedExit: 0, expectedStdout: "hello\n"))
    }

    func testBaselineArithmetic() {
        let source = """
        int main() {
            int a = 20;
            int b = 22;
            return a + b;
        }
        """
        XCTAssertTrue(Harness.runViaClang(source, expectedExit: 42))
    }

    func testBaselineControlFlow() {
        let source = """
        int main() {
            int i;
            int sum = 0;
            for (i = 1; i <= 10; i++) {
                if (i % 2 == 0) {
                    sum += i;
                }
            }
            return sum;
        }
        """
        // 2+4+6+8+10 = 30
        XCTAssertTrue(Harness.runViaClang(source, expectedExit: 30))
    }

    func testBaselineStrings() {
        let source = """
        #include <stdio.h>
        #include <string.h>

        int main() {
            char s[] = "hello";
            int len = 0;
            while (s[len] != 0) { len++; }
            printf("len=%d\\n", len);
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaClang(source, expectedExit: 0, expectedStdout: "len=5\n"))
    }

    func testBaselineStructs() {
        let source = """
        #include <stdio.h>

        struct Point {
            int x;
            int y;
        };

        int main() {
            struct Point p;
            p.x = 3;
            p.y = 4;
            printf("%d %d\\n", p.x, p.y);
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaClang(source, expectedExit: 0, expectedStdout: "3 4\n"))
    }

    func testBaselinePointers() {
        let source = """
        int main() {
            int x = 10;
            int *p = &x;
            *p = 42;
            return x;
        }
        """
        XCTAssertTrue(Harness.runViaClang(source, expectedExit: 42))
    }

    func testBaselineFunctionCall() {
        let source = """
        int add(int a, int b) {
            return a + b;
        }

        int main() {
            return add(20, 22);
        }
        """
        XCTAssertTrue(Harness.runViaClang(source, expectedExit: 42))
    }

    func testBaselineRecursion() {
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
        XCTAssertTrue(Harness.runViaClang(source, expectedExit: 55))
    }
}
