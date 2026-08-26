import XCTest
@testable import CCompilerTests

/// Tests that exercise the IR optimizer (--ir flag).
/// These verify that the optimized output assembles correctly and produces
/// the right results. They catch bugs where the IR optimizer produces
/// invalid ARM64 assembly (register width mismatches, invalid operands, etc.)
/// that the regular E2E tests miss because they don't use --ir.
final class IROptimizerTests: XCTestCase {

    // MARK: - Basic correctness with IR optimization

    func testIRReturnConstant() {
        let source = "int main() { return 42; }"
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 42))
    }

    func testIRArithmetic() {
        let source = """
        int main() {
            int a = 20;
            int b = 22;
            return a + b;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 42))
    }

    func testIRFactorial() {
        let source = """
        int factorial(int n) {
            if (n <= 1) return 1;
            return n * factorial(n - 1);
        }
        int main() { return factorial(5); }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 120))
    }

    func testIRFibonacci() {
        let source = """
        int fib(int n) {
            if (n < 2) return n;
            return fib(n-1) + fib(n-2);
        }
        int main() { return fib(10); }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 55))
    }

    // MARK: - Register width correctness

    /// Test that 32-bit and 64-bit values are handled correctly.
    /// The IR optimizer must not produce mov xN, wM (invalid ARM64).
    func testIRRegisterWidthMismatch() {
        let source = """
        int main() {
            int a = 255;
            long b = (long)a;
            return (int)(b + 1);
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 0))
    }

    /// Test that byte/halfword loads use w-form registers (ldrb wN, not ldrb xN).
    func testIRByteLoad() {
        let source = """
        char get(char *p) { return *p; }
        int main() {
            char buf[4] = {1, 2, 3, 4};
            return get(buf);
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 1))
    }

    /// Test that halfword loads use w-form registers.
    func testIRHalfwordLoad() {
        let source = """
        short get(short *p) { return *p; }
        int main() {
            short arr[4] = {100, 200, 300, 400};
            return get(arr);
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 100))
    }

    /// Test that byte stores use w-form registers (strb wN, not strb xN).
    func testIRByteStore() {
        let source = """
        void set(char *p, char v) { *p = v; }
        int main() {
            char buf[4] = {0, 0, 0, 0};
            set(buf + 2, 42);
            return buf[2];
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 42))
    }

    // MARK: - Control flow correctness

    /// Test that constant folding doesn't incorrectly fold branches at merge points.
    func testIRControlFlowMerge() {
        let source = """
        int main() {
            int r;
            int x = 1;
            if (x > 0) {
                r = 1;
            } else {
                r = 0;
            }
            if (r) return 42;
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 42))
    }

    /// Test that zero-initialized variables and conditional branches work.
    func testIRZeroInitBranch() {
        let source = """
        int main() {
            int r = 0;
            if (r) return 1;
            return 42;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 42))
    }

    /// Test goto patterns that create control flow merge points.
    func testIRGotoMerge() {
        let source = """
        int main() {
            int i = 0;
            int sum = 0;
        loop:
            sum += i;
            i++;
            if (i < 10) goto loop;
            return sum;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 45))
    }

    // MARK: - Struct and array operations

    /// Test struct copy patterns that use w16 temp register.
    func testIRStructCopy() {
        let source = """
        struct Pair { int a; int b; };
        int main() {
            struct Pair p = {3, 4};
            struct Pair q = p;
            return q.a + q.b;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 7))
    }

    /// Test struct passed by value.
    func testIRStructByValue() {
        let source = """
        struct Point { int x; int y; };
        int sum(struct Point p) { return p.x + p.y; }
        int main() {
            struct Point pt = {20, 22};
            return sum(pt);
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 42))
    }

    /// Test array access patterns.
    func testIRArrayAccess() {
        let source = """
        int main() {
            int arr[5] = {10, 20, 30, 40, 50};
            int sum = 0;
            for (int i = 0; i < 5; i++) sum += arr[i];
            return sum;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 150))
    }

    // MARK: - Floating point

    /// Test that FP register copies use fmov, not mov.
    func testIRFloatCopy() {
        let source = """
        double add(double a, double b) { return a + b; }
        int main() {
            double x = 1.5;
            double y = 2.5;
            double z = add(x, y);
            if (z > 3.0) return 42;
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 42))
    }

    /// Test float comparison and branching.
    func testIRFloatCompare() {
        let source = """
        int main() {
            float f = 3.14;
            if (f > 3.0) return 1;
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 1))
    }

    // MARK: - Comparison patterns

    /// Test that cmp with immediate works correctly (no out-of-range immediates).
    func testIRLargeCmpImmediate() {
        let source = """
        int main() {
            long x = 1000000;
            if (x == 1000000) return 42;
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 42))
    }

    /// Test signed comparison with negative values.
    func testIRNegativeCompare() {
        let source = """
        int main() {
            int x = -1;
            if (x < 0) return 42;
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 42))
    }

    // MARK: - Variadic functions

    /// Test variadic function with many stack arguments (exercises push/sp cancel).
    func testIRVariadic() {
        let source = """
        int f(int a, int b, int c, int d, int e, int f, int g, int h, int i, int j) {
            return a + b + c + d + e + f + g + h + i + j;
        }
        int main() { return f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10); }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 55))
    }

    // MARK: - Sign extension

    /// Test that sign extension is not incorrectly eliminated.
    func testIRSignExtension() {
        let source = """
        int main() {
            int x = -1;
            long y = (long)x;
            if (y < 0) return 42;
            return 0;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 42))
    }

    /// Test that ldrsw fusion produces correct results.
    func testIRLdrswFusion() {
        let source = """
        int main() {
            int x = -42;
            long y = (long)x;
            return (int)y;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: -42 & 0xFF))
    }

    // MARK: - Store/load patterns

    /// Test store-then-load forwarding doesn't corrupt values.
    func testIRStoreLoadForward() {
        let source = """
        int main() {
            int x = 42;
            int y = x;
            return y;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 42))
    }

    /// Test that storePre cancellation produces correct stack layout.
    func testIRStorePreCancellation() {
        let source = """
        int f(int a, int b, int c, int d, int e, int f, int g, int h, int i, int j) {
            return a + b + c + d + e + f + g + h + i + j;
        }
        int main() { return f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10); }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 55))
    }

    // MARK: - Complex patterns

    /// Test a function with many locals (exercises register allocation).
    func testIRManyLocals() {
        let source = """
        int main() {
            int a = 1, b = 2, c = 3, d = 4, e = 5;
            int f = 6, g = 7, h = 8, i = 9, j = 10;
            return a + b + c + d + e + f + g + h + i + j;
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 55))
    }

    /// Test nested function calls (exercises call/return correctness).
    func testIRNestedCalls() {
        let source = """
        int add(int a, int b) { return a + b; }
        int mul(int a, int b) { return a * b; }
        int main() {
            return add(mul(3, 4), mul(5, 6));
        }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 42))
    }

    /// Test switch statement (exercises branch patterns).
    func testIRSwitch() {
        let source = """
        int classify(int x) {
            switch (x) {
                case 1: return 10;
                case 2: return 20;
                case 3: return 30;
                default: return 42;
            }
        }
        int main() { return classify(5); }
        """
        XCTAssertTrue(Harness.runViaOurCompilerIR(source, expectedExit: 42))
    }
}
