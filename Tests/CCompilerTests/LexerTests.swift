import XCTest
@testable import CPreproc
@testable import CCommon

final class LexerTests: XCTestCase {

    /// Tokenize a source string with fileId 0 and startOffset 0.
    private func lex(_ source: String) -> [Token] {
        let bytes = Array(source.utf8)
        let lexer = Lexer(bytes, fileId: 0)
        return lexer.tokenize()
    }

    // MARK: - 1. Basic statement

    func testBasicStatement() {
        let tokens = lex("int x = 42;")
        XCTAssertEqual(tokens.count, 6)
        XCTAssertEqual(tokens[0].kind, .keyword)
        XCTAssertEqual(tokens[0].spelling, "int")
        XCTAssertEqual(tokens[1].kind, .identifier)
        XCTAssertEqual(tokens[1].spelling, "x")
        XCTAssertEqual(tokens[2].kind, .punct)
        XCTAssertEqual(tokens[2].spelling, "=")
        XCTAssertEqual(tokens[3].kind, .integerLiteral)
        XCTAssertEqual(tokens[3].spelling, "42")
        XCTAssertEqual(tokens[4].kind, .punct)
        XCTAssertEqual(tokens[4].spelling, ";")
        XCTAssertEqual(tokens[5].kind, .eof)
        XCTAssertEqual(tokens[5].spelling, "")
    }

    // MARK: - 2. Comments

    func testLineComment() {
        let tokens = lex("int x; // a comment\nint y;")
        // int x ; int y ; eof = 7 tokens
        XCTAssertEqual(tokens.count, 7)
        XCTAssertEqual(tokens[0].spelling, "int")
        XCTAssertEqual(tokens[1].spelling, "x")
        XCTAssertEqual(tokens[2].spelling, ";")
        XCTAssertEqual(tokens[3].spelling, "int")
        XCTAssertEqual(tokens[4].spelling, "y")
        XCTAssertEqual(tokens[5].spelling, ";")
        XCTAssertEqual(tokens[6].kind, .eof)
    }

    func testBlockComment() {
        let tokens = lex("int x; /* block \n comment */ int y;")
        XCTAssertEqual(tokens.count, 7)
        XCTAssertEqual(tokens[0].spelling, "int")
        XCTAssertEqual(tokens[1].spelling, "x")
        XCTAssertEqual(tokens[2].spelling, ";")
        XCTAssertEqual(tokens[3].spelling, "int")
        XCTAssertEqual(tokens[4].spelling, "y")
        XCTAssertEqual(tokens[5].spelling, ";")
        XCTAssertEqual(tokens[6].kind, .eof)
    }

    // MARK: - 3. Char literal

    func testCharLiteral() {
        let tokens = lex("'\\n'")
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].kind, .charLiteral)
        XCTAssertEqual(tokens[0].spelling, "'\\n'")
        XCTAssertEqual(tokens[1].kind, .eof)
    }

    func testCharLiteralSimple() {
        let tokens = lex("'a'")
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].kind, .charLiteral)
        XCTAssertEqual(tokens[0].spelling, "'a'")
    }

    func testCharLiteralEscapes() {
        for s in ["'\\\\'", "'\\''", "'\\0'", "'\\x41'", "'\\101'", "'\\t'"] {
            let tokens = lex(s)
            XCTAssertEqual(tokens.count, 2, "for \(s)")
            XCTAssertEqual(tokens[0].kind, .charLiteral, "for \(s)")
            XCTAssertEqual(tokens[0].spelling, s, "for \(s)")
        }
    }

    func testWideCharLiteral() {
        let tokens = lex("L'a'")
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].kind, .charLiteral)
        XCTAssertEqual(tokens[0].spelling, "L'a'")
    }

    // MARK: - 4. String literal

    func testStringLiteral() {
        let tokens = lex("\"hello\\n\"")
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].kind, .stringLiteral)
        XCTAssertEqual(tokens[0].spelling, "\"hello\\n\"")
    }

    func testStringLiteralSimple() {
        let tokens = lex("\"hello\"")
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].kind, .stringLiteral)
        XCTAssertEqual(tokens[0].spelling, "\"hello\"")
    }

    func testWideStringLiteral() {
        let tokens = lex("L\"hello\"")
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].kind, .stringLiteral)
        XCTAssertEqual(tokens[0].spelling, "L\"hello\"")
    }

    // MARK: - 5. Hex integer

    func testHexInteger() {
        let tokens = lex("0xFF")
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].kind, .integerLiteral)
        XCTAssertEqual(tokens[0].spelling, "0xFF")
    }

    func testHexIntegerLowercase() {
        let tokens = lex("0x1a")
        XCTAssertEqual(tokens[0].kind, .integerLiteral)
        XCTAssertEqual(tokens[0].spelling, "0x1a")
    }

    // MARK: - 6. Integer suffixes

    func testIntegerSuffix() {
        for s in ["42UL", "42ull", "42LLU", "42u", "42L", "42ll", "42lu"] {
            let tokens = lex(s)
            XCTAssertEqual(tokens.count, 2, "for \(s)")
            XCTAssertEqual(tokens[0].kind, .integerLiteral, "for \(s)")
            XCTAssertEqual(tokens[0].spelling, s, "for \(s)")
        }
    }

    func testOctalInteger() {
        for s in ["077", "0123"] {
            let tokens = lex(s)
            XCTAssertEqual(tokens[0].kind, .integerLiteral, "for \(s)")
            XCTAssertEqual(tokens[0].spelling, s, "for \(s)")
        }
    }

    func testBinaryInteger() {
        let tokens = lex("0b1010")
        XCTAssertEqual(tokens[0].kind, .integerLiteral)
        XCTAssertEqual(tokens[0].spelling, "0b1010")
    }

    // MARK: - 7. Float literals

    func testFloatLiteral() {
        for s in ["3.14", ".5", "1.", "1e10", "1.5E-3", "1.5e+3", "3.14f", "1.0L"] {
            let tokens = lex(s)
            XCTAssertEqual(tokens.count, 2, "for \(s)")
            XCTAssertEqual(tokens[0].kind, .floatLiteral, "for \(s)")
            XCTAssertEqual(tokens[0].spelling, s, "for \(s)")
        }
    }

    func testHexFloat() {
        let tokens = lex("0x1.8p3")
        XCTAssertEqual(tokens[0].kind, .floatLiteral)
        XCTAssertEqual(tokens[0].spelling, "0x1.8p3")
    }

    // MARK: - 8. Multi-char punctuators

    func testMultiCharPunctuators() {
        let puncts = ["->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=",
                      "&&", "||", "+=", "-=", "*=", "/=", "%=", "<<=", ">>=",
                      "&=", "|=", "^=", "##", "...", "::"]
        for p in puncts {
            let tokens = lex(p)
            XCTAssertEqual(tokens.count, 2, "for \(p)")
            XCTAssertEqual(tokens[0].kind, .punct, "for \(p)")
            XCTAssertEqual(tokens[0].spelling, p, "for \(p)")
        }
    }

    func testSingleCharPunctuators() {
        let puncts: [String] = ["+", "-", "*", "/", "%", "&", "|", "^", "~",
                                "!", "<", ">", "=", ".", ",", ";", ":", "?",
                                "(", ")", "[", "]", "{", "}", "#"]
        for p in puncts {
            let tokens = lex(p)
            XCTAssertEqual(tokens.count, 2, "for \(p)")
            XCTAssertEqual(tokens[0].kind, .punct, "for \(p)")
            XCTAssertEqual(tokens[0].spelling, p, "for \(p)")
        }
    }

    // MARK: - 9. Keywords vs identifiers

    func testKeyword() {
        let tokens = lex("int")
        XCTAssertEqual(tokens[0].kind, .keyword)
        XCTAssertEqual(tokens[0].spelling, "int")
    }

    func testIdentifier() {
        let tokens = lex("myInt")
        XCTAssertEqual(tokens[0].kind, .identifier)
        XCTAssertEqual(tokens[0].spelling, "myInt")
    }

    func testAllKeywords() {
        let keywords = ["auto", "break", "case", "char", "const", "continue",
                        "default", "do", "double", "else", "enum", "extern",
                        "float", "for", "goto", "if", "inline", "int", "long",
                        "register", "restrict", "return", "short", "signed",
                        "sizeof", "static", "struct", "switch", "typedef",
                        "union", "unsigned", "void", "volatile", "while",
                        "_Bool", "_Complex", "_Imaginary", "_Alignas",
                        "_Alignof", "_Atomic", "_Generic", "_Noreturn",
                        "_Static_assert", "_Thread_local"]
        for kw in keywords {
            let tokens = lex(kw)
            XCTAssertEqual(tokens[0].kind, .keyword, "for \(kw)")
            XCTAssertEqual(tokens[0].spelling, kw, "for \(kw)")
        }
    }

    func testUnderscoreIdentifier() {
        let tokens = lex("_foo")
        XCTAssertEqual(tokens[0].kind, .identifier)
        XCTAssertEqual(tokens[0].spelling, "_foo")
    }

    // MARK: - 10. Adjacent string literals

    func testAdjacentStringLiterals() {
        let tokens = lex("\"a\" \"b\"")
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(tokens[0].kind, .stringLiteral)
        XCTAssertEqual(tokens[0].spelling, "\"a\"")
        XCTAssertEqual(tokens[1].kind, .stringLiteral)
        XCTAssertEqual(tokens[1].spelling, "\"b\"")
        XCTAssertEqual(tokens[2].kind, .eof)
    }

    // MARK: - Edge cases

    func testEmpty() {
        let tokens = lex("")
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].kind, .eof)
    }

    func testWhitespace() {
        let tokens = lex("   \t\n  ")
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].kind, .eof)
    }

    func testUnknownCharacter() {
        let tokens = lex("@")
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].kind, .punct)
        XCTAssertEqual(tokens[0].spelling, "@")
    }

    func testUnterminatedString() {
        let tokens = lex("\"abc")
        // Should not crash; should produce a string token (or at least not crash)
        XCTAssertEqual(tokens.last?.kind, .eof)
    }

    func testUnterminatedChar() {
        let tokens = lex("'a")
        XCTAssertEqual(tokens.last?.kind, .eof)
    }

    func testUnterminatedBlockComment() {
        let tokens = lex("/* not closed")
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].kind, .eof)
    }

    func testTokenLocations() {
        let tokens = lex("int x;")
        XCTAssertEqual(tokens[0].loc.offset, 0)
        XCTAssertEqual(tokens[1].loc.offset, 4)
        XCTAssertEqual(tokens[2].loc.offset, 5)
    }

    func testEofLocation() {
        let source = "int x;"
        let tokens = lex(source)
        let eof = tokens.last!
        XCTAssertEqual(eof.kind, .eof)
        XCTAssertEqual(eof.loc.offset, source.utf8.count)
    }

    func testMixOfTokens() {
        let tokens = lex("a = 1 + 2;")
        XCTAssertEqual(tokens.count, 7)
        XCTAssertEqual(tokens.map { $0.spelling }, ["a", "=", "1", "+", "2", ";", ""])
    }

    func testNumberThenIdentifier() {
        let tokens = lex("123abc")
        // Should split: integer 123 then identifier abc
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(tokens[0].kind, .integerLiteral)
        XCTAssertEqual(tokens[0].spelling, "123")
        XCTAssertEqual(tokens[1].kind, .identifier)
        XCTAssertEqual(tokens[1].spelling, "abc")
    }

    func testFloatThenIdentifier() {
        let tokens = lex("1.5f x")
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(tokens[0].kind, .floatLiteral)
        XCTAssertEqual(tokens[0].spelling, "1.5f")
        XCTAssertEqual(tokens[1].kind, .identifier)
        XCTAssertEqual(tokens[1].spelling, "x")
    }

    func testPPDirective() {
        let tokens = lex("#include <stdio.h>")
        // # include < stdio . h >
        XCTAssertEqual(tokens[0].kind, .punct)
        XCTAssertEqual(tokens[0].spelling, "#")
        XCTAssertEqual(tokens[1].kind, .identifier)
        XCTAssertEqual(tokens[1].spelling, "include")
    }
}
