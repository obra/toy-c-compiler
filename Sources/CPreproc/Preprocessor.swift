import CCommon
import Foundation

// MARK: - Preprocessor Error

public enum PreprocessorError: Error {
    case fileNotFound(String)
    case includeFailed(String)
}

// MARK: - Preprocessor

/// Preprocessor: handles #include, #define, conditionals, macro expansion.
/// Takes raw source bytes → produces an expanded C token stream.
public final class Preprocessor {
    private let sm: SourceManager
    private let includePaths: [String]
    private var predefines: [String: String]
    private let diags: DiagnosticEngine
    private let macroTable: MacroTable
    private let expander: MacroExpander

    // Predefined macros
    private static let predefinedMacros: [String: String] = [
        "__STDC__": "1",
        "__STDC_VERSION__": "199901L",
        "__STDC_HOSTED__": "1",
        "__APPLE__": "1",
        "__MACH__": "1",
        "__arm64__": "1",
        "__aarch64__": "1",
        "__LITTLE_ENDIAN__": "1",
        "__arm__": "1",
        "__APPLE_CC__": "1",
        "__SIZEOF_INT__": "4",
        "__SIZEOF_LONG__": "8",
        "__SIZEOF_LONG_LONG__": "8",
        "__SIZEOF_SHORT__": "2",
        "__SIZEOF_CHAR__": "1",
        "__SIZEOF_FLOAT__": "4",
        "__SIZEOF_DOUBLE__": "8",
        "__SIZEOF_POINTER__": "8",
        "__SIZEOF_SIZE_T__": "8",
        "__SIZEOF_LONG_DOUBLE__": "8",
        "__ORDER_LITTLE_ENDIAN__": "1234",
        "__BYTE_ORDER__": "__ORDER_LITTLE_ENDIAN__",
        "__INT_MAX__": "2147483647",
        "__LONG_MAX__": "9223372036854775807L",
        "__LONG_LONG_MAX__": "9223372036854775807LL",
        "__DARWIN_C_LEVEL": "900000",
        "__DARWIN_C_FULL": "900000",
        "__DARWIN_C_ANSI": "900000",
        "_POSIX_C_SOURCE": "200809L",
        "_DARWIN_FEATURE_CLOCK_GETTIME": "0",
        "_DARWIN_C_ANSI": "1",
        "__STDC_NO_ATOMICS__": "1",
        "__STDC_NO_THREADS__": "1",
        "__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__": "140000",
        "__DARWIN_C_SOURCE": "1",
        "_DARWIN_C_SOURCE": "1",
        "_DARWIN_UNLIMITED_SELECT": "1",
    ]

    public init(_ sm: SourceManager, includePaths: [String], predefines: [String: String],
                diags: DiagnosticEngine = DiagnosticEngine()) {
        self.sm = sm
        self.includePaths = includePaths
        self.predefines = predefines
        self.diags = diags
        self.macroTable = MacroTable()
        self.expander = MacroExpander(macroTable, diags, sm: sm)

        // Install predefined macros
        for (name, value) in Preprocessor.predefinedMacros {
            let loc = SourceLoc.unknown
            let tokens = lexTokens(value, fileId: -1, startOffset: 0).filter { $0.kind != .eof }
            macroTable.define(Macro(name: name, isFunctionLike: false, isVariadic: false,
                                   params: [], body: tokens, loc: loc))
        }
        // Install user predefines (-D)
        for (name, value) in predefines {
            let tokens = lexTokens(value, fileId: -1, startOffset: 0).filter { $0.kind != .eof }
            macroTable.define(Macro(name: name, isFunctionLike: false, isVariadic: false,
                                   params: [], body: tokens, loc: SourceLoc.unknown))
        }
    }

    /// Preprocess the given file and return the expanded token stream.
    public func preprocess(_ fileId: Int) throws -> [Token] {
        let bytes = sm.contents(of: fileId)
        let rawTokens = lexTokens(Array(bytes), fileId: fileId, startOffset: 0)
        let result = try processTokens(rawTokens, currentFileId: fileId)
        return result
    }

    /// Check if a macro is defined (for debugging).
    public func isMacroDefined(_ name: String) -> Bool {
        return macroTable.isDefined(name)
    }

    // MARK: - Token processing (directives + expansion)

    /// Conditional compilation state.
    private struct CondState {
        var parentActive: Bool    // is the enclosing conditional active?
        var anyBranchTaken: Bool  // has any branch of this #if been included?
        var currentActive: Bool   // is the current branch active?
        var seenElse: Bool         // has #else been seen?
    }

    /// Process a raw token stream: handle preprocessor directives and expand macros.
    private func processTokens(_ tokens: [Token], currentFileId: Int) throws -> [Token] {
        var output: [Token] = []
        var i = 0
        var condStack: [CondState] = []

        // Helper: is the current conditional context active (all levels must be active)?
        func isActive() -> Bool {
            return condStack.allSatisfy { $0.currentActive }
        }

        while i < tokens.count {
            let token = tokens[i]

            // Preprocessor directive: # at start of line
            if token.kind == .punct && token.spelling == "#" && isAtLineStart(output, tokens, i) {
                let (directiveTokens, nextI) = collectDirectiveTokens(tokens, from: i + 1)
                let dirName = directiveTokens.first?.spelling ?? ""

                switch dirName {
                case "if":
                    let rest = Array(directiveTokens.dropFirst())
                    let parentActive = isActive()
                    if parentActive {
                        // Process `defined(X)` / `defined X` before macro expansion,
                        // replacing with 1 or 0 literal.
                        let preprocessed = processDefined(rest)
                        let expanded = expander.expand(preprocessed)
                        let value = evalConstExpr(expanded)
                        condStack.append(CondState(parentActive: parentActive, anyBranchTaken: value != 0, currentActive: value != 0, seenElse: false))
                    } else {
                        condStack.append(CondState(parentActive: false, anyBranchTaken: true, currentActive: false, seenElse: false))
                    }
                case "ifdef":
                    let rest = Array(directiveTokens.dropFirst())
                    let parentActive = isActive()
                    let defined = rest.first?.kind == .identifier && macroTable.isDefined(rest.first!.spelling)
                    condStack.append(CondState(parentActive: parentActive, anyBranchTaken: defined, currentActive: parentActive && defined, seenElse: false))
                case "ifndef":
                    let rest = Array(directiveTokens.dropFirst())
                    let parentActive = isActive()
                    let defined = rest.first?.kind == .identifier && macroTable.isDefined(rest.first!.spelling)
                    condStack.append(CondState(parentActive: parentActive, anyBranchTaken: !defined, currentActive: parentActive && !defined, seenElse: false))
                case "elif":
                    if !condStack.isEmpty {
                        var state = condStack.last!
                        if state.parentActive && !state.anyBranchTaken && !state.seenElse {
                            let rest = Array(directiveTokens.dropFirst())
                            let preprocessed = processDefined(rest)
                            let expanded = expander.expand(preprocessed)
                            let value = evalConstExpr(expanded)
                            state.currentActive = value != 0
                            if value != 0 { state.anyBranchTaken = true }
                        } else {
                            state.currentActive = false
                        }
                        condStack[condStack.count - 1] = state
                    }
                case "else":
                    if !condStack.isEmpty {
                        var state = condStack.last!
                        if state.parentActive && !state.anyBranchTaken && !state.seenElse {
                            state.currentActive = true
                            state.anyBranchTaken = true
                        } else {
                            state.currentActive = false
                        }
                        state.seenElse = true
                        condStack[condStack.count - 1] = state
                    }
                case "endif":
                    if !condStack.isEmpty {
                        condStack.removeLast()
                    }
                case "define", "undef", "include", "pragma", "line", "error", "warning":
                    // Only process these directives if the current conditional is active
                    if isActive() {
                        try processDirective(directiveTokens, currentFileId: currentFileId, output: &output)
                    }
                default:
                    // Unknown directive — ignore (or process if active)
                    if isActive() {
                        try processDirective(directiveTokens, currentFileId: currentFileId, output: &output)
                    }
                }

                i = nextI
                continue
            }

            // Non-directive token — collect a batch until the next directive, then expand.
            if isActive() {
                var batch: [Token] = []
                while i < tokens.count {
                    let t = tokens[i]
                    // Check if this is a directive (# at line start)
                    if t.kind == .punct && t.spelling == "#" && isAtLineStart(output, tokens, i) {
                        break
                    }
                    batch.append(t)
                    i += 1
                }
                if !batch.isEmpty {
                    let expanded = expander.expand(batch)
                    output.append(contentsOf: expanded)
                }
                continue  // don't increment i — the outer loop handles the directive
            } else {
                i += 1
            }
        }

        return output
    }

    /// Check if the # token is at the start of a line (only whitespace/newlines before it on this line).
    private func isAtLineStart(_ output: [Token], _ tokens: [Token], _ idx: Int) -> Bool {
        // If it's the first token, it's at line start
        if idx == 0 { return true }
        // Check if the previous token was on a different line
        // Since our lexer doesn't track newlines as tokens, we need to check if there's
        // a newline between the previous token and this one in the source.
        let prevToken = tokens[idx - 1]
        let currToken = tokens[idx]
        // Check the source bytes between prevToken end and currToken start for a newline
        if prevToken.loc.fileId != currToken.loc.fileId { return true }
        if prevToken.loc.fileId < 0 { return true }

        let contents = sm.contents(of: prevToken.loc.fileId)
        let prevEnd = prevToken.loc.offset + prevToken.spelling.utf8.count
        let currStart = currToken.loc.offset
        if prevEnd >= contents.count || currStart > contents.count { return true }
        // Check for newline that is NOT preceded by backslash (line continuation)
        var i = prevEnd
        while i < currStart {
            if contents[i] == 0x0A {
                // Check if preceded by backslash
                if i > 0 && contents[i - 1] == 0x5C {
                    // Line continuation — skip
                    i += 1
                    continue
                }
                return true
            }
            i += 1
        }
        // Also true if it's the very first non-whitespace token on the line
        // Check backwards from current position to last newline
        var pos = currToken.loc.offset - 1
        while pos >= 0 {
            if contents[pos] == 0x0A { return true }
            if contents[pos] != 0x20 && contents[pos] != 0x09 && contents[pos] != 0x0D {
                return false
            }
            pos -= 1
        }
        return true // start of file
    }

    /// Collect all tokens on the same line as a directive (until newline or EOF).
    private func collectDirectiveTokens(_ tokens: [Token], from startIdx: Int) -> ([Token], Int) {
        var result: [Token] = []
        var i = startIdx
        // Collect tokens until we hit EOF or a token that starts on a new line
        while i < tokens.count && tokens[i].kind != .eof {
            result.append(tokens[i])
            i += 1
            // Check if next token is on a new line
            if i < tokens.count && tokens[i].kind != .eof {
                if i > startIdx {
                    let prevEnd = result.last!.loc.offset + result.last!.spelling.utf8.count
                    let currStart = tokens[i].loc.offset
                    if currStart > prevEnd && result.last!.loc.fileId == tokens[i].loc.fileId {
                        let contents = sm.contents(of: result.last!.loc.fileId)
                        if prevEnd < contents.count && currStart <= contents.count {
                            // Check for newline NOT preceded by backslash
                            var j = prevEnd
                            while j < currStart {
                                if contents[j] == 0x0A {
                                    if j > 0 && contents[j - 1] == 0x5C {
                                        j += 1
                                        continue
                                    }
                                    return (result, i) // real newline — directive ends
                                }
                                j += 1
                            }
                        }
                    }
                }
            }
        }
        return (result, i)
    }

    // MARK: - Directive processing

    private func processDirective(_ tokens: [Token], currentFileId: Int, output: inout [Token]) throws {
        guard let first = tokens.first else { return }

        // Empty directive (#)
        if first.kind == .eof || first.kind == .punct && first.spelling == "#" {
            return
        }

        guard first.kind == .identifier else {
            // Unknown directive — ignore (could warn)
            return
        }

        let directive = first.spelling
        let rest = Array(tokens.dropFirst())

        switch directive {
        case "define":
            processDefine(rest)
        case "undef":
            processUndef(rest)
        case "include":
            try processInclude(rest, currentFileId: currentFileId, output: &output)
        case "if", "ifdef", "ifndef", "elif", "else", "endif":
            // Conditionals are handled in processTokens before reaching here
            break
        case "pragma":
            // Tolerate pragmas — most are ignored
            break
        case "line":
            // Tolerate #line
            break
        case "error":
            let msg = rest.map { $0.spelling }.joined(separator: " ")
            diags.error("#error \(msg)", at: first.loc)
        case "warning":
            let msg = rest.map { $0.spelling }.joined(separator: " ")
            diags.warning("#warning \(msg)", at: first.loc)
        default:
            // Unknown directive — ignore
            break
        }
    }

    private func processDefine(_ tokens: [Token]) {
        guard let nameToken = tokens.first, nameToken.kind == .identifier else { return }

        var rest = Array(tokens.dropFirst())
        var isFunctionLike = false
        var isVariadic = false
        var params: [String] = []

        // Check for function-like macro: ( immediately after name (no space)
        if let next = rest.first, next.kind == .punct && next.spelling == "(" {
            // Check there's no space between name and (
            let nameEnd = nameToken.loc.offset + nameToken.spelling.utf8.count
            if next.loc.offset == nameEnd {
                isFunctionLike = true
                rest = Array(rest.dropFirst()) // skip (

                // Parse parameters
                while !rest.isEmpty {
                    let t = rest[0]
                    if t.kind == .punct && t.spelling == ")" {
                        rest = Array(rest.dropFirst())
                        break
                    }
                    if t.kind == .punct && t.spelling == "," {
                        rest = Array(rest.dropFirst())
                        continue
                    }
                    if t.kind == .punct && t.spelling == "..." {
                        isVariadic = true
                        rest = Array(rest.dropFirst())
                        // Next should be )
                        if !rest.isEmpty && rest[0].kind == .punct && rest[0].spelling == ")" {
                            rest = Array(rest.dropFirst())
                        }
                        break
                    }
                    if t.kind == .identifier {
                        // Check for named variadic: args...
                        params.append(t.spelling)
                        rest = Array(rest.dropFirst())
                        // Check if next is ... (named variadic)
                        if !rest.isEmpty && rest[0].kind == .punct && rest[0].spelling == "..." {
                            isVariadic = true
                            // Use the param name as __VA_ARGS__ alias
                            rest = Array(rest.dropFirst())
                            if !rest.isEmpty && rest[0].kind == .punct && rest[0].spelling == ")" {
                                rest = Array(rest.dropFirst())
                            }
                            break
                        }
                    } else {
                        rest = Array(rest.dropFirst())
                    }
                }
            }
        }

        let macro = Macro(name: nameToken.spelling, isFunctionLike: isFunctionLike,
                          isVariadic: isVariadic, params: params, body: rest, loc: nameToken.loc)
        macroTable.define(macro)
    }

    // MARK: - #undef

    private func processUndef(_ tokens: [Token]) {
        guard let nameToken = tokens.first, nameToken.kind == .identifier else { return }
        macroTable.undef(nameToken.spelling)
    }

    // MARK: - #include

    private func processInclude(_ tokens: [Token], currentFileId: Int, output: inout [Token]) throws {
        guard let first = tokens.first else { return }

        // System include: <foo.h>
        if first.kind == .punct && first.spelling == "<" {
            // Collect tokens until >
            var pathParts: [String] = []
            var i = 1
            while i < tokens.count && !(tokens[i].kind == .punct && tokens[i].spelling == ">") {
                pathParts.append(tokens[i].spelling)
                i += 1
            }
            let path = pathParts.joined()
            try includeFile(path, isSystem: true, currentFileId: currentFileId, output: &output)
            return
        }

        // User include: "foo.h"
        if first.kind == .stringLiteral {
            // Strip quotes
            var path = first.spelling
            if path.hasPrefix("\"") { path = String(path.dropFirst()) }
            if path.hasSuffix("\"") { path = String(path.dropLast()) }
            try includeFile(path, isSystem: false, currentFileId: currentFileId, output: &output)
            return
        }

        // Macro-expanded include (should expand the token list first)
        // For now, try expanding and re-processing
        let expanded = expander.expand(tokens)
        if let firstExpanded = expanded.first {
            if firstExpanded.kind == .stringLiteral {
                var path = firstExpanded.spelling
                if path.hasPrefix("\"") { path = String(path.dropFirst()) }
                if path.hasSuffix("\"") { path = String(path.dropLast()) }
                try includeFile(path, isSystem: false, currentFileId: currentFileId, output: &output)
                return
            }
        }
    }

    private func includeFile(_ path: String, isSystem: Bool, currentFileId: Int, output: inout [Token]) throws {
        // Try to find the file
        var resolvedPath: String? = nil

        // If it's an absolute path, try it directly
        if path.hasPrefix("/") {
            if FileManager.default.fileExists(atPath: path) {
                resolvedPath = path
            }
        }

        if resolvedPath == nil && !isSystem {
            // For user includes, try relative to current file first
            let currentDir = URL(fileURLWithPath: sm.name(of: currentFileId)).deletingLastPathComponent().path
            let candidate = "\(currentDir)/\(path)"
            if FileManager.default.fileExists(atPath: candidate) {
                resolvedPath = candidate
            }
        }

        // Try include paths
        if resolvedPath == nil {
            for incPath in includePaths {
                let candidate = "\(incPath)/\(path)"
                if FileManager.default.fileExists(atPath: candidate) {
                    resolvedPath = candidate
                    break
                }
            }
        }

        // For system includes, only use our own include paths (not system SDK paths).
        // This avoids pulling in complex system headers we can't parse yet.
        // Our include/ directory provides minimal declarations for needed functions.
        if resolvedPath == nil && isSystem {
            // Silently skip — we provide our own headers for needed functions.
            return
        }

        guard let filePath = resolvedPath else {
            // If not found, just skip (many system headers we don't need)
            // For our own headers, we should find them. But for system headers we don't
            // have, silently skip to avoid blocking compilation.
            return
        }

        let fileId = try sm.load(filePath)
        let bytes = sm.contents(of: fileId)
        let rawTokens = lexTokens(Array(bytes), fileId: fileId, startOffset: 0)
        let processed = try processTokens(rawTokens, currentFileId: fileId)
        // Strip EOF tokens from included file — only the main file should have one
        output.append(contentsOf: processed.filter { $0.kind != .eof })
    }

    // MARK: - Constant expression evaluation (for #if)

    /// Process `defined(X)` / `defined X` in a #if expression, replacing with 1 or 0.
    /// Must be done before macro expansion, per C99.
    private func processDefined(_ tokens: [Token]) -> [Token] {
        var result: [Token] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            // Handle __has_feature(...) and __has_extension(...) → 0
            if token.kind == .identifier &&
               (token.spelling == "__has_feature" || token.spelling == "__has_extension" ||
                token.spelling == "__has_builtin" || token.spelling == "__has_attribute") {
                i += 1
                // Skip the ( ... ) if present
                if i < tokens.count && tokens[i].kind == .punct && tokens[i].spelling == "(" {
                    var depth = 0
                    while i < tokens.count {
                        if tokens[i].kind == .punct && tokens[i].spelling == "(" { depth += 1 }
                        else if tokens[i].kind == .punct && tokens[i].spelling == ")" { depth -= 1; if depth == 0 { i += 1; break } }
                        i += 1
                    }
                }
                result.append(Token(kind: .integerLiteral, spelling: "0", loc: token.loc))
                continue
            }
            if token.kind == .identifier && token.spelling == "defined" {
                i += 1
                if i < tokens.count && tokens[i].kind == .punct && tokens[i].spelling == "(" {
                    i += 1
                    if i < tokens.count && tokens[i].kind == .identifier {
                        let name = tokens[i].spelling
                        i += 1
                        if i < tokens.count && tokens[i].kind == .punct && tokens[i].spelling == ")" {
                            i += 1
                        }
                        let value = macroTable.isDefined(name) ? "1" : "0"
                        result.append(Token(kind: .integerLiteral, spelling: value, loc: token.loc))
                        continue
                    }
                } else if i < tokens.count && tokens[i].kind == .identifier {
                    let name = tokens[i].spelling
                    i += 1
                    let value = macroTable.isDefined(name) ? "1" : "0"
                    result.append(Token(kind: .integerLiteral, spelling: value, loc: token.loc))
                    continue
                }
                // Malformed defined — just output 0
                result.append(Token(kind: .integerLiteral, spelling: "0", loc: token.loc))
                continue
            }
            result.append(token)
            i += 1
        }
        return result
    }

    /// Evaluate a preprocessor constant expression to an integer value.
    private func evalConstExpr(_ tokens: [Token]) -> Int64 {
        // Simple recursive descent evaluator for #if expressions
        var pos = 0
        return parseConditionalExpr(tokens, &pos)
    }

    private func parseConditionalExpr(_ tokens: [Token], _ pos: inout Int) -> Int64 {
        let left = parseLogicalOrExpr(tokens, &pos)
        if pos < tokens.count && tokens[pos].kind == .punct && tokens[pos].spelling == "?" {
            pos += 1
            let mid = parseConditionalExpr(tokens, &pos)
            if pos < tokens.count && tokens[pos].kind == .punct && tokens[pos].spelling == ":" {
                pos += 1
            }
            let right = parseConditionalExpr(tokens, &pos)
            return left != 0 ? mid : right
        }
        return left
    }

    private func parseLogicalOrExpr(_ tokens: [Token], _ pos: inout Int) -> Int64 {
        var left = parseLogicalAndExpr(tokens, &pos)
        while pos < tokens.count && tokens[pos].kind == .punct && tokens[pos].spelling == "||" {
            pos += 1
            let right = parseLogicalAndExpr(tokens, &pos)
            left = (left != 0 || right != 0) ? 1 : 0
        }
        return left
    }

    private func parseLogicalAndExpr(_ tokens: [Token], _ pos: inout Int) -> Int64 {
        var left = parseBitwiseOrExpr(tokens, &pos)
        while pos < tokens.count && tokens[pos].kind == .punct && tokens[pos].spelling == "&&" {
            pos += 1
            let right = parseBitwiseOrExpr(tokens, &pos)
            left = (left != 0 && right != 0) ? 1 : 0
        }
        return left
    }

    private func parseBitwiseOrExpr(_ tokens: [Token], _ pos: inout Int) -> Int64 {
        var left = parseBitwiseXorExpr(tokens, &pos)
        while pos < tokens.count && tokens[pos].kind == .punct && tokens[pos].spelling == "|" {
            pos += 1
            let right = parseBitwiseXorExpr(tokens, &pos)
            left |= right
        }
        return left
    }

    private func parseBitwiseXorExpr(_ tokens: [Token], _ pos: inout Int) -> Int64 {
        var left = parseBitwiseAndExpr(tokens, &pos)
        while pos < tokens.count && tokens[pos].kind == .punct && tokens[pos].spelling == "^" {
            pos += 1
            let right = parseBitwiseAndExpr(tokens, &pos)
            left ^= right
        }
        return left
    }

    private func parseBitwiseAndExpr(_ tokens: [Token], _ pos: inout Int) -> Int64 {
        var left = parseEqualityExpr(tokens, &pos)
        while pos < tokens.count && tokens[pos].kind == .punct && tokens[pos].spelling == "&" {
            pos += 1
            let right = parseEqualityExpr(tokens, &pos)
            left &= right
        }
        return left
    }

    private func parseEqualityExpr(_ tokens: [Token], _ pos: inout Int) -> Int64 {
        var left = parseRelationalExpr(tokens, &pos)
        while pos < tokens.count && tokens[pos].kind == .punct &&
              (tokens[pos].spelling == "==" || tokens[pos].spelling == "!=") {
            let op = tokens[pos].spelling
            pos += 1
            let right = parseRelationalExpr(tokens, &pos)
            left = op == "==" ? (left == right ? 1 : 0) : (left != right ? 1 : 0)
        }
        return left
    }

    private func parseRelationalExpr(_ tokens: [Token], _ pos: inout Int) -> Int64 {
        var left = parseShiftExpr(tokens, &pos)
        while pos < tokens.count && tokens[pos].kind == .punct &&
              ["<", ">", "<=", ">="].contains(tokens[pos].spelling) {
            let op = tokens[pos].spelling
            pos += 1
            let right = parseShiftExpr(tokens, &pos)
            switch op {
            case "<": left = left < right ? 1 : 0
            case ">": left = left > right ? 1 : 0
            case "<=": left = left <= right ? 1 : 0
            case ">=": left = left >= right ? 1 : 0
            default: break
            }
        }
        return left
    }

    private func parseShiftExpr(_ tokens: [Token], _ pos: inout Int) -> Int64 {
        var left = parseAddExpr(tokens, &pos)
        while pos < tokens.count && tokens[pos].kind == .punct &&
              (tokens[pos].spelling == "<<" || tokens[pos].spelling == ">>") {
            let op = tokens[pos].spelling
            pos += 1
            let right = parseAddExpr(tokens, &pos)
            if op == "<<" { left <<= right } else { left >>= right }
        }
        return left
    }

    private func parseAddExpr(_ tokens: [Token], _ pos: inout Int) -> Int64 {
        var left = parseMulExpr(tokens, &pos)
        while pos < tokens.count && tokens[pos].kind == .punct &&
              (tokens[pos].spelling == "+" || tokens[pos].spelling == "-") {
            let op = tokens[pos].spelling
            pos += 1
            let right = parseMulExpr(tokens, &pos)
            if op == "+" { left += right } else { left -= right }
        }
        return left
    }

    private func parseMulExpr(_ tokens: [Token], _ pos: inout Int) -> Int64 {
        var left = parseUnaryExpr(tokens, &pos)
        while pos < tokens.count && tokens[pos].kind == .punct &&
              ["*", "/", "%"].contains(tokens[pos].spelling) {
            let op = tokens[pos].spelling
            pos += 1
            let right = parseUnaryExpr(tokens, &pos)
            switch op {
            case "*": left *= right
            case "/": left = right != 0 ? left / right : 0
            case "%": left = right != 0 ? left % right : 0
            default: break
            }
        }
        return left
    }

    private func parseUnaryExpr(_ tokens: [Token], _ pos: inout Int) -> Int64 {
        if pos >= tokens.count { return 0 }

        let token = tokens[pos]
        if token.kind == .punct {
            switch token.spelling {
            case "!":
                pos += 1
                return parseUnaryExpr(tokens, &pos) != 0 ? 0 : 1
            case "~":
                pos += 1
                return ~parseUnaryExpr(tokens, &pos)
            case "-":
                pos += 1
                return -parseUnaryExpr(tokens, &pos)
            case "+":
                pos += 1
                return parseUnaryExpr(tokens, &pos)
            default:
                break
            }
        }

        // defined(name) or defined name
        if token.kind == .identifier && token.spelling == "defined" {
            pos += 1
            if pos < tokens.count && tokens[pos].kind == .punct && tokens[pos].spelling == "(" {
                pos += 1
                if pos < tokens.count && tokens[pos].kind == .identifier {
                    let name = tokens[pos].spelling
                    pos += 1
                    if pos < tokens.count && tokens[pos].kind == .punct && tokens[pos].spelling == ")" {
                        pos += 1
                    }
                    return macroTable.isDefined(name) ? 1 : 0
                }
            } else if pos < tokens.count && tokens[pos].kind == .identifier {
                let name = tokens[pos].spelling
                pos += 1
                return macroTable.isDefined(name) ? 1 : 0
            }
            return 0
        }

        return parsePrimary(tokens, &pos)
    }

    private func parsePrimary(_ tokens: [Token], _ pos: inout Int) -> Int64 {
        if pos >= tokens.count { return 0 }
        let token = tokens[pos]
        pos += 1

        if token.kind == .punct && token.spelling == "(" {
            let val = parseConditionalExpr(tokens, &pos)
            if pos < tokens.count && tokens[pos].kind == .punct && tokens[pos].spelling == ")" {
                pos += 1
            }
            return val
        }

        if token.kind == .integerLiteral {
            return parseIntLiteral(token.spelling)
        }

        if token.kind == .charLiteral {
            return Int64(parseCharLiteralValue(token.spelling))
        }

        if token.kind == .identifier {
            // In #if, undefined identifiers evaluate to 0
            if token.spelling == "true" { return 1 }
            return 0
        }

        return 0
    }

    /// Parse a char literal spelling (e.g. "'A'", "'\\n'", "'\\301'") to its integer value.
    private func parseCharLiteralValue(_ spelling: String) -> Int {
        var s = spelling
        // Strip prefix (L, u, U)
        if s.hasPrefix("L") || s.hasPrefix("u") || s.hasPrefix("U") { s = String(s.dropFirst()) }
        guard s.hasPrefix("'") && s.hasSuffix("'") else { return 0 }
        s = String(s.dropFirst().dropLast())
        if s.isEmpty { return 0 }
        if s.hasPrefix("\\") {
            return parseEscapeSeq(String(s.dropFirst()))
        }
        return Int(Array(s.utf8).first ?? 0)
    }

    /// Parse a C escape sequence (the part after the backslash) to its integer value.
    private func parseEscapeSeq(_ s: String) -> Int {
        if s.isEmpty { return 0 }
        let chars = Array(s)
        switch chars[0] {
        case "n": return 10
        case "t": return 9
        case "r": return 13
        case "0", "1", "2", "3", "4", "5", "6", "7":
            // Octal escape: up to 3 octal digits
            var result = 0
            var i = 0
            while i < 3 && i < chars.count {
                let d = chars[i].asciiValue ?? 0
                if d < 0x30 || d > 0x37 { break }  // not an octal digit
                result = result * 8 + Int(d - 0x30)
                i += 1
            }
            return result
        case "x":
            // Hex escape: \x followed by hex digits
            var result = 0
            var i = 1
            while i < chars.count {
                let c = chars[i]
                let val: Int
                if c >= "0" && c <= "9" { val = Int(c.asciiValue! - 0x30) }
                else if c >= "a" && c <= "f" { val = Int(c.asciiValue! - 0x61) + 10 }
                else if c >= "A" && c <= "F" { val = Int(c.asciiValue! - 0x41) + 10 }
                else { break }
                result = result * 16 + val
                i += 1
            }
            return result
        case "\\": return 0x5C
        case "'": return 0x27
        case "\"": return 0x22
        case "0": return 0
        case "a": return 7
        case "b": return 8
        case "f": return 12
        case "v": return 11
        case "e": return 27
        default: return Int(chars[0].asciiValue ?? 0)
        }
    }

    /// Parse an integer literal string to Int64.
    private func parseIntLiteral(_ spelling: String) -> Int64 {
        var s = spelling
        // Strip suffixes
        while s.hasSuffix("u") || s.hasSuffix("U") || s.hasSuffix("l") || s.hasSuffix("L") {
            s = String(s.dropLast())
        }
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            return Int64(s.dropFirst(2), radix: 16) ?? 0
        }
        if s.hasPrefix("0b") || s.hasPrefix("0B") {
            return Int64(s.dropFirst(2), radix: 2) ?? 0
        }
        if s.hasPrefix("0") && s.count > 1 {
            return Int64(s.dropFirst(), radix: 8) ?? 0
        }
        return Int64(s) ?? 0
    }

    // MARK: - Lexing helper

    private func lexTokens(_ bytes: [UInt8], fileId: Int, startOffset: Int) -> [Token] {
        let lexer = Lexer(bytes, fileId: fileId, startOffset: startOffset)
        return lexer.tokenize()
    }

    private func lexTokens(_ string: String, fileId: Int, startOffset: Int) -> [Token] {
        return lexTokens(Array(string.utf8), fileId: fileId, startOffset: startOffset)
    }
}
