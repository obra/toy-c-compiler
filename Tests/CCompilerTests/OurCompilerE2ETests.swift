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
}
