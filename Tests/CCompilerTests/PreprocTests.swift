import XCTest
@testable import CPreproc
@testable import CCommon

final class PreprocTests: XCTestCase {

    private func preprocess(_ source: String, includePaths: [String] = [], predefines: [String: String] = [:]) -> [Token] {
        let sm = SourceManager()
        let fileId = sm.register(name: "test.c", contents: source)
        let pp = Preprocessor(sm, includePaths: includePaths, predefines: predefines)
        do {
            return try pp.preprocess(fileId)
        } catch {
            XCTFail("preprocessing failed: \(error)")
            return []
        }
    }

    // Helper: get token spellings (excluding EOF)
    private func spellings(_ tokens: [Token]) -> [String] {
        return tokens.filter { $0.kind != .eof }.map { $0.spelling }
    }

    // MARK: - 1. Object-like macro

    func testObjectLikeMacro() {
        let tokens = preprocess("#define X 1\nint y = X;")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "y", "=", "1", ";"])
    }

    func testObjectLikeMacroMultiToken() {
        let tokens = preprocess("#define ADD(a) (a)\nint x = ADD(5);")
        let spells = spellings(tokens)
        // ADD(5) → (5)
        XCTAssertEqual(spells, ["int", "x", "=", "(", "5", ")", ";"])
    }

    // MARK: - 2. Function-like macro

    func testFunctionLikeMacro() {
        let tokens = preprocess("#define SQUARE(x) ((x) * (x))\nint y = SQUARE(5);")
        let spells = spellings(tokens)
        // SQUARE(5) → ((5) * (5))
        XCTAssertEqual(spells, ["int", "y", "=", "(", "(", "5", ")", "*", "(", "5", ")", ")", ";"])
    }

    func testFunctionLikeMacroNoArgs() {
        let tokens = preprocess("#define FOO() 42\nint x = FOO();")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "x", "=", "42", ";"])
    }

    // MARK: - 3. #undef

    func testUndef() {
        let tokens = preprocess("#define X 1\n#undef X\nint y = X;")
        let spells = spellings(tokens)
        // X should NOT be expanded after #undef
        XCTAssertEqual(spells, ["int", "y", "=", "X", ";"])
    }

    // MARK: - 4. #ifdef / #ifndef / #endif

    func testIfdefTrue() {
        let tokens = preprocess("#define X 1\n#ifdef X\nint y = 1;\n#endif")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "y", "=", "1", ";"])
    }

    func testIfdefFalse() {
        let tokens = preprocess("#ifdef X\nint y = 1;\n#endif\nint z = 2;")
        let spells = spellings(tokens)
        // The #ifdef body should be skipped
        XCTAssertEqual(spells, ["int", "z", "=", "2", ";"])
    }

    func testIfndefTrue() {
        let tokens = preprocess("#ifndef X\nint y = 1;\n#endif")
        let spells = spellings(tokens)
        // X is not defined, so body is included
        XCTAssertEqual(spells, ["int", "y", "=", "1", ";"])
    }

    func testIfndefFalse() {
        let tokens = preprocess("#define X 1\n#ifndef X\nint y = 1;\n#endif\nint z = 2;")
        let spells = spellings(tokens)
        // X is defined, so #ifndef body is skipped
        XCTAssertEqual(spells, ["int", "z", "=", "2", ";"])
    }

    // MARK: - 5. #if / #else / #elif

    func testIfTrue() {
        let tokens = preprocess("#if 1\nint y = 1;\n#endif")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "y", "=", "1", ";"])
    }

    func testIfFalse() {
        let tokens = preprocess("#if 0\nint y = 1;\n#endif\nint z = 2;")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "z", "=", "2", ";"])
    }

    func testIfElse() {
        let tokens = preprocess("#if 0\nint y = 1;\n#else\nint z = 2;\n#endif")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "z", "=", "2", ";"])
    }

    func testIfElifElse() {
        let tokens = preprocess("#if 0\nint a = 1;\n#elif 1\nint b = 2;\n#else\nint c = 3;\n#endif")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "b", "=", "2", ";"])
    }

    func testIfDefined() {
        let tokens = preprocess("#define X 1\n#if defined(X)\nint y = 1;\n#endif")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "y", "=", "1", ";"])
    }

    func testIfNotDefined() {
        let tokens = preprocess("#if !defined(X)\nint y = 1;\n#endif")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "y", "=", "1", ";"])
    }

    // MARK: - 6. Nested conditionals

    func testNestedConditionals() {
        let src = """
        #if 1
        #if 0
        int a = 1;
        #else
        int b = 2;
        #endif
        #endif
        """
        let tokens = preprocess(src)
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "b", "=", "2", ";"])
    }

    // MARK: - 7. # stringize

    func testStringize() {
        let tokens = preprocess("#define STR(x) #x\nchar *s = STR(hello);")
        let spells = spellings(tokens)
        // STR(hello) → "hello"
        XCTAssertEqual(spells, ["char", "*", "s", "=", "\"hello\"", ";"])
    }

    // MARK: - 8. ## paste

    func testTokenPaste() {
        let tokens = preprocess("#define CONCAT(a,b) a##b\nint xy = CONCAT(x, y);")
        let spells = spellings(tokens)
        // CONCAT(x, y) → xy
        XCTAssertEqual(spells, ["int", "xy", "=", "xy", ";"])
    }

    // MARK: - 9. Variadic macros

    func testVariadicMacro() {
        let tokens = preprocess("#define LOG(...) __VA_ARGS__\nint x = LOG(1 + 2);")
        let spells = spellings(tokens)
        // LOG(1 + 2) → 1 + 2
        XCTAssertEqual(spells, ["int", "x", "=", "1", "+", "2", ";"])
    }

    // MARK: - 10. Macro rescanning

    func testMacroRescanning() {
        // A → B, B → 42, so A should expand to 42
        let tokens = preprocess("#define A B\n#define B 42\nint x = A;")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "x", "=", "42", ";"])
    }

    // MARK: - 11. Blue-painting (no infinite recursion)

    func testBluePainting() {
        // A → A should not loop infinitely; the blue-painted A is left as-is
        let tokens = preprocess("#define A A\nint x = A;")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "x", "=", "A", ";"])
    }

    // MARK: - 12. Predefined macros

    func testPredefinedMacros() {
        let tokens = preprocess("int x = __STDC__;")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "x", "=", "1", ";"])
    }

    func testUserPredefine() {
        let tokens = preprocess("int x = FOO;", predefines: ["FOO": "42"])
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "x", "=", "42", ";"])
    }

    // MARK: - 13. #include

    func testInclude() throws {
        let tmpDir = NSTemporaryDirectory()
        let headerPath = "\(tmpDir)test_header_\(UUID().uuidString).h"
        try "int val = 42;".write(toFile: headerPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: headerPath) }

        let tokens = preprocess("#include \"\(headerPath)\"\nint x = val;", includePaths: [tmpDir])
        let spells = spellings(tokens)
        // Should include the header content + the main file
        XCTAssertTrue(spells.contains("val"))
        XCTAssertTrue(spells.contains("42"))
    }

    // MARK: - 14. Constant expression in #if

    func testIfArithmetic() {
        let tokens = preprocess("#if 2 + 3 == 5\nint y = 1;\n#endif")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "y", "=", "1", ";"])
    }

    func testIfLogicalAnd() {
        let tokens = preprocess("#if 1 && 1\nint y = 1;\n#endif")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "y", "=", "1", ";"])
    }

    func testIfLogicalOr() {
        let tokens = preprocess("#if 0 || 1\nint y = 1;\n#endif")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "y", "=", "1", ";"])
    }

    // MARK: - Edge cases

    func testEmptyPreprocess() {
        let tokens = preprocess("")
        XCTAssertEqual(tokens.count, 1) // just EOF
        XCTAssertEqual(tokens[0].kind, .eof)
    }

    func testNoDirectives() {
        let tokens = preprocess("int main() { return 0; }")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "main", "(", ")", "{", "return", "0", ";", "}"])
    }

    func testPragmaTolerated() {
        let tokens = preprocess("#pragma once\nint x = 1;")
        let spells = spellings(tokens)
        XCTAssertEqual(spells, ["int", "x", "=", "1", ";"])
    }
}
