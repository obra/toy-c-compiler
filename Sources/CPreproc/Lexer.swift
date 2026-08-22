import CCommon
import Foundation

/// C99 keywords.
private let cKeywords: Set<String> = [
    "auto", "break", "case", "char", "const", "continue",
    "default", "do", "double", "else", "enum", "extern",
    "float", "for", "goto", "if", "inline", "int", "long",
    "register", "restrict", "return", "short", "signed",
    "sizeof", "static", "struct", "switch", "typedef",
    "union", "unsigned", "void", "volatile", "while",
    "_Bool", "_Complex", "_Imaginary", "_Alignas",
    "_Alignof", "_Atomic", "_Generic", "_Noreturn",
    "_Static_assert", "_Thread_local",
    "__asm", "__asm__", "__attribute__", "__attribute",
    "__typeof", "__typeof__", "__extension__", "__inline",
    "__inline__", "__const", "__const__", "__volatile",
    "__volatile__", "__restrict", "__restrict__", "__signed",
    "__signed__", "__unaligned",
]

/// Lexer: converts raw bytes into a sequence of C tokens.
public final class Lexer {
    private let bytes: [UInt8]
    private let fileId: Int
    private var pos: Int
    private var tokens: [Token] = []
    private var pendingSpace = false

    public init(_ bytes: [UInt8], fileId: Int, startOffset: Int = 0) {
        self.bytes = bytes
        self.fileId = fileId
        self.pos = startOffset
    }

    /// Tokenize the entire input and return the token array (ending with .eof).
    public func tokenize() -> [Token] {
        while pos < bytes.count {
            let b = bytes[pos]

            // Line continuation: backslash-newline → skip both
            if b == 0x5C && pos + 1 < bytes.count && bytes[pos + 1] == 0x0A {
                pos += 2
                pendingSpace = true
                continue
            }
            // Also handle \r\n
            if b == 0x5C && pos + 2 < bytes.count && bytes[pos + 1] == 0x0D && bytes[pos + 2] == 0x0A {
                pos += 3
                pendingSpace = true
                continue
            }

            // Skip whitespace
            if isWhitespace(b) {
                pos += 1
                pendingSpace = true
                continue
            }

            // Skip line comment
            if b == 0x2F && pos + 1 < bytes.count && bytes[pos + 1] == 0x2F { // //
                skipLineComment()
                pendingSpace = true
                continue
            }

            // Skip block comment
            if b == 0x2F && pos + 1 < bytes.count && bytes[pos + 1] == 0x2A { // /*
                skipBlockComment()
                pendingSpace = true
                continue
            }

            // Prefixed char/string literal: L' u' U' L" u" U" (but NOT u8)
            // Check before identifier so L'a' isn't split into ident 'L' + char 'a'
            if isLiteralPrefix(b) && pos + 1 < bytes.count {
                let next = bytes[pos + 1]
                if next == 0x27 { // '
                    lexCharLiteral()
                    continue
                }
                if next == 0x22 { // "
                    lexStringLiteral()
                    continue
                }
            }

            // Identifier or keyword
            if isIdentStart(b) {
                lexIdentifier()
                continue
            }

            // Number (integer or float)
            if isDigit(b) || (b == 0x2E && pos + 1 < bytes.count && isDigit(bytes[pos + 1])) { // digit or .digit
                lexNumber()
                continue
            }

            // Char literal (without prefix — prefixed ones handled above)
            if b == 0x27 { // '
                lexCharLiteral()
                continue
            }

            // String literal (without prefix — prefixed ones handled above)
            if b == 0x22 { // "
                lexStringLiteral()
                continue
            }

            // Punctuator
            lexPunctuator()
        }

        tokens.append(Token(kind: .eof, spelling: "", loc: SourceLoc(fileId: fileId, offset: pos), hasLeadingSpace: pendingSpace))
        return tokens
    }

    // MARK: - Helpers

    private func consumeSpace() -> Bool {
        let s = pendingSpace
        pendingSpace = false
        return s
    }

    private func currentLoc() -> SourceLoc {
        return SourceLoc(fileId: fileId, offset: pos)
    }

    private func isWhitespace(_ b: UInt8) -> Bool {
        return b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C
    }

    private func isDigit(_ b: UInt8) -> Bool {
        return b >= 0x30 && b <= 0x39
    }

    private func isHexDigit(_ b: UInt8) -> Bool {
        return (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
    }

    private func isIdentStart(_ b: UInt8) -> Bool {
        return (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F
    }

    private func isIdentCont(_ b: UInt8) -> Bool {
        return isIdentStart(b) || isDigit(b)
    }

    /// Check if byte is a literal prefix character: L, u, U (not u8 for now).
    private func isLiteralPrefix(_ b: UInt8) -> Bool {
        return b == 0x4C || b == 0x75 || b == 0x55 // L u U
    }

    // MARK: - Comment skipping

    private func skipLineComment() {
        pos += 2 // skip //
        while pos < bytes.count && bytes[pos] != 0x0A {
            pos += 1
        }
    }

    private func skipBlockComment() {
        pos += 2 // skip /*
        while pos < bytes.count {
            if bytes[pos] == 0x2A && pos + 1 < bytes.count && bytes[pos + 1] == 0x2F {
                pos += 2
                return
            }
            pos += 1
        }
        // Unterminated comment: just stop (return EOF)
    }

    // MARK: - Identifier / keyword

    private func lexIdentifier() {
        let start = pos
        while pos < bytes.count && isIdentCont(bytes[pos]) {
            pos += 1
        }
        let spelling = bytesToString(start, pos)
        let kind: TokenKind = cKeywords.contains(spelling) ? .keyword : .identifier
        tokens.append(Token(kind: kind, spelling: spelling, loc: SourceLoc(fileId: fileId, offset: start), hasLeadingSpace: consumeSpace()))
    }

    // MARK: - Number (integer or float)

    private func lexNumber() {
        let start = pos

        // Check for hex/binary prefix
        if bytes[pos] == 0x30 && pos + 1 < bytes.count {
            let next = bytes[pos + 1]
            if next == 0x78 || next == 0x58 { // 0x or 0X — hex number
                pos += 2
                // Hex integer or hex float
                lexHexNumber(start: start)
                return
            }
            if next == 0x62 || next == 0x42 { // 0b or 0B — binary
                pos += 2
                while pos < bytes.count && (bytes[pos] == 0x30 || bytes[pos] == 0x31) {
                    pos += 1
                }
                lexIntegerSuffix()
                tokens.append(Token(kind: .integerLiteral, spelling: bytesToString(start, pos),
                                    loc: SourceLoc(fileId: fileId, offset: start), hasLeadingSpace: consumeSpace()))
                return
            }
        }

        // Check for hex float prefix (already handled above if 0x)

        // Decimal / octal number
        var isFloat = false

        // Integer part
        while pos < bytes.count && isDigit(bytes[pos]) {
            pos += 1
        }

        // Fractional part
        if pos < bytes.count && bytes[pos] == 0x2E { // .
            isFloat = true
            pos += 1
            while pos < bytes.count && isDigit(bytes[pos]) {
                pos += 1
            }
        }

        // Exponent
        if pos < bytes.count && (bytes[pos] == 0x65 || bytes[pos] == 0x45) { // e or E
            isFloat = true
            pos += 1
            if pos < bytes.count && (bytes[pos] == 0x2B || bytes[pos] == 0x2D) { // + or -
                pos += 1
            }
            while pos < bytes.count && isDigit(bytes[pos]) {
                pos += 1
            }
        }

        if isFloat {
            // Float suffix: f F l L, and imaginary suffix: i I j J (C99/GNU)
            if pos < bytes.count && (bytes[pos] == 0x66 || bytes[pos] == 0x46 || bytes[pos] == 0x6C || bytes[pos] == 0x4C) {
                // f F l L
                pos += 1
                // Optional imaginary suffix after f/l: fi, Fi, li, Li, etc.
                if pos < bytes.count && (bytes[pos] == 0x69 || bytes[pos] == 0x49 || bytes[pos] == 0x6A || bytes[pos] == 0x4A) {
                    pos += 1
                }
            } else if pos < bytes.count && (bytes[pos] == 0x69 || bytes[pos] == 0x49 || bytes[pos] == 0x6A || bytes[pos] == 0x4A) {
                // i I j J — imaginary suffix
                pos += 1
            }
            tokens.append(Token(kind: .floatLiteral, spelling: bytesToString(start, pos),
                                loc: SourceLoc(fileId: fileId, offset: start), hasLeadingSpace: consumeSpace()))
        } else {
            // Integer suffix
            lexIntegerSuffix()
            tokens.append(Token(kind: .integerLiteral, spelling: bytesToString(start, pos),
                                loc: SourceLoc(fileId: fileId, offset: start), hasLeadingSpace: consumeSpace()))
        }
    }

    /// Handle hex number after 0x prefix.
    private func lexHexNumber(start: Int) {
        var isFloat = false

        // Hex digits
        while pos < bytes.count && isHexDigit(bytes[pos]) {
            pos += 1
        }

        // Hex float: fractional part
        if pos < bytes.count && bytes[pos] == 0x2E { // .
            isFloat = true
            pos += 1
            while pos < bytes.count && isHexDigit(bytes[pos]) {
                pos += 1
            }
        }

        // Hex float: exponent (p or P)
        if pos < bytes.count && (bytes[pos] == 0x70 || bytes[pos] == 0x50) { // p or P
            isFloat = true
            pos += 1
            if pos < bytes.count && (bytes[pos] == 0x2B || bytes[pos] == 0x2D) { // + or -
                pos += 1
            }
            while pos < bytes.count && isDigit(bytes[pos]) {
                pos += 1
            }
        }

        if isFloat {
            // Float suffix: f F l L, and imaginary suffix: i I j J (C99/GNU)
            if pos < bytes.count && (bytes[pos] == 0x66 || bytes[pos] == 0x46 || bytes[pos] == 0x6C || bytes[pos] == 0x4C) {
                // f F l L
                pos += 1
                // Optional imaginary suffix after f/l: fi, Fi, li, Li, etc.
                if pos < bytes.count && (bytes[pos] == 0x69 || bytes[pos] == 0x49 || bytes[pos] == 0x6A || bytes[pos] == 0x4A) {
                    pos += 1
                }
            } else if pos < bytes.count && (bytes[pos] == 0x69 || bytes[pos] == 0x49 || bytes[pos] == 0x6A || bytes[pos] == 0x4A) {
                // i I j J — imaginary suffix
                pos += 1
            }
            tokens.append(Token(kind: .floatLiteral, spelling: bytesToString(start, pos),
                                loc: SourceLoc(fileId: fileId, offset: start), hasLeadingSpace: consumeSpace()))
        } else {
            // Integer suffix
            lexIntegerSuffix()
            tokens.append(Token(kind: .integerLiteral, spelling: bytesToString(start, pos),
                                loc: SourceLoc(fileId: fileId, offset: start), hasLeadingSpace: consumeSpace()))
        }
    }

    /// Consume an integer suffix (U, L, UL, LL, ULL, etc., case-insensitive, any order).
    private func lexIntegerSuffix() {
        var sawU = false
        var sawL = 0
        while pos < bytes.count {
            let b = bytes[pos]
            if (b == 0x55 || b == 0x75) && !sawU { // U or u
                sawU = true
                pos += 1
            } else if (b == 0x4C || b == 0x6C) && sawL < 2 { // L or l
                sawL += 1
                pos += 1
            } else {
                break
            }
        }
    }

    // MARK: - Char literal

    private func lexCharLiteral() {
        let start = pos
        // Skip prefix (L, u, U) if present
        if bytes[pos] == 0x4C || bytes[pos] == 0x75 || bytes[pos] == 0x55 { // L u U
            pos += 1
        }
        // Opening quote
        if pos < bytes.count && bytes[pos] == 0x27 { // '
            pos += 1
        }
        // Content: skip until closing quote, handling escapes
        while pos < bytes.count && bytes[pos] != 0x27 { // not '
            if bytes[pos] == 0x5C && pos + 1 < bytes.count { // backslash escape
                pos += 2
            } else {
                pos += 1
            }
        }
        // Closing quote
        if pos < bytes.count && bytes[pos] == 0x27 {
            pos += 1
        }
        tokens.append(Token(kind: .charLiteral, spelling: bytesToString(start, pos),
                            loc: SourceLoc(fileId: fileId, offset: start), hasLeadingSpace: consumeSpace()))
    }

    // MARK: - String literal

    private func lexStringLiteral() {
        let start = pos
        // Skip prefix (L, u, U) if present
        if bytes[pos] == 0x4C || bytes[pos] == 0x75 || bytes[pos] == 0x55 { // L u U
            pos += 1
        }
        // Opening quote
        if pos < bytes.count && bytes[pos] == 0x22 { // "
            pos += 1
        }
        // Content: skip until closing quote, handling escapes
        while pos < bytes.count && bytes[pos] != 0x22 { // not "
            if bytes[pos] == 0x5C && pos + 1 < bytes.count { // backslash escape
                pos += 2
            } else {
                pos += 1
            }
        }
        // Closing quote
        if pos < bytes.count && bytes[pos] == 0x22 {
            pos += 1
        }
        tokens.append(Token(kind: .stringLiteral, spelling: bytesToString(start, pos),
                            loc: SourceLoc(fileId: fileId, offset: start), hasLeadingSpace: consumeSpace()))
    }

    // MARK: - Punctuator

    /// Multi-char punctuators sorted by length (longest first).
    private static let multiCharPuncts: [String] = [
        // 3-char
        "<<=", ">>=", "...", ":::",
        // 2-char
        "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=",
        "&&", "||", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "##", "::",
    ]

    private func lexPunctuator() {
        let start = pos

        // Try longest match (3-char, then 2-char, then 1-char)
        if pos + 3 <= bytes.count {
            let three = bytesToString(pos, pos + 3)
            if Lexer.multiCharPuncts.contains(three) {
                pos += 3
                tokens.append(Token(kind: .punct, spelling: three,
                                    loc: SourceLoc(fileId: fileId, offset: start), hasLeadingSpace: consumeSpace()))
                return
            }
        }
        if pos + 2 <= bytes.count {
            let two = bytesToString(pos, pos + 2)
            if Lexer.multiCharPuncts.contains(two) {
                pos += 2
                tokens.append(Token(kind: .punct, spelling: two,
                                    loc: SourceLoc(fileId: fileId, offset: start), hasLeadingSpace: consumeSpace()))
                return
            }
        }

        // Single character
        let ch = bytesToString(pos, pos + 1)
        pos += 1
        tokens.append(Token(kind: .punct, spelling: ch,
                            loc: SourceLoc(fileId: fileId, offset: start), hasLeadingSpace: consumeSpace()))
    }

    // MARK: - Utility

    private func bytesToString(_ from: Int, _ to: Int) -> String {
        return String(bytes: bytes[from..<to], encoding: .utf8) ?? ""
    }
}
