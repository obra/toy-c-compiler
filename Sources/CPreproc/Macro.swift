import CCommon
import Foundation

// MARK: - Macro Definition

/// Represents a preprocessor macro definition.
public struct Macro: Equatable {
    public let name: String
    public let isFunctionLike: Bool
    public let isVariadic: Bool
    public let params: [String]      // parameter names (empty for object-like)
    public let body: [Token]         // replacement tokens
    public let loc: SourceLoc

    public init(name: String, isFunctionLike: Bool, isVariadic: Bool,
                params: [String], body: [Token], loc: SourceLoc) {
        self.name = name
        self.isFunctionLike = isFunctionLike
        self.isVariadic = isVariadic
        self.params = params
        self.body = body
        self.loc = loc
    }
}

// MARK: - Macro Table

/// Manages a collection of defined macros.
public final class MacroTable {
    private var macros: [String: Macro] = [:]
    /// Names currently being expanded (blue-painting / hide sets).
    private var expansionStack: [String] = []
    /// Stack for #pragma push_macro / pop_macro
    private var pragmaMacroStack: [String: [Macro?]] = [:]

    public init() {}

    public func define(_ macro: Macro) {
        macros[macro.name] = macro
    }

    public func undef(_ name: String) {
        macros.removeValue(forKey: name)
    }

    public func isDefined(_ name: String) -> Bool {
        return macros[name] != nil
    }

    public func lookup(_ name: String) -> Macro? {
        return macros[name]
    }

    public func pushMacro(_ name: String) {
        pragmaMacroStack[name, default: []].append(macros[name])
    }

    public func popMacro(_ name: String) {
        guard var stack = pragmaMacroStack[name], !stack.isEmpty else { return }
        let saved = stack.removeLast()
        pragmaMacroStack[name] = stack
        if let macro = saved {
            macros[name] = macro
        } else {
            macros.removeValue(forKey: name)
        }
    }

    public func pushExpansion(_ name: String) {
        expansionStack.append(name)
    }

    public func popExpansion() {
        expansionStack.removeLast()
    }

    public func isExpanding(_ name: String) -> Bool {
        return expansionStack.contains(name)
    }

    public func clear() {
        macros.removeAll()
        expansionStack.removeAll()
    }
}

// MARK: - Macro Expansion Engine

/// Expands macros in a token stream following C99 rules (rescanning + blue-painting).
/// Uses a mutable index-based approach for correct rescanning.
public final class MacroExpander {
    private let table: MacroTable
    private let diags: DiagnosticEngine
    private weak var sm: SourceManager?

    public init(_ table: MacroTable, _ diags: DiagnosticEngine, sm: SourceManager? = nil) {
        self.table = table
        self.diags = diags
        self.sm = sm
    }

    /// Format current date as "Mmm dd yyyy" for __DATE__
    private func formatCurrentDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var result = formatter.string(from: Date())
        // Single-digit day: pad with leading space (e.g. "Jul  4 2024")
        let parts = result.split(separator: " ")
        if parts.count == 3, parts[1].count == 1 {
            result = "\(parts[0])  \(parts[1]) \(parts[2])"
        }
        return result
    }

    /// Format current time as "HH:MM:SS" for __TIME__
    private func formatCurrentTime() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    /// Expand all macros in the given token list, returning the fully expanded token list.
    /// Uses hide sets for blue-painting. Optimized with pending buffer.
    public func expand(_ tokens: [Token]) -> [Token] {
        var output: [Token] = []
        // pending: tokens to be processed (LIFO for rescanning). We reverse-insert.
        var pending: [Token] = []
        var input = tokens[...]
        var pendingReversed: [Token] = []  // reversed pending for O(1) pop from end

        func nextToken() -> Token? {
            if !pendingReversed.isEmpty {
                return pendingReversed.removeLast()
            }
            if !pending.isEmpty {
                // Move from pending to reversed for efficient pop
                pendingReversed = pending.reversed()
                pending.removeAll(keepingCapacity: true)
                return pendingReversed.removeLast()
            }
            if !input.isEmpty {
                let t = input[input.startIndex]
                input = input.dropFirst()
                return t
            }
            return nil
        }

        /// Peek at the next non-eof token without consuming it.
        func peekToken() -> Token? {
            // Check pendingReversed (from end)
            if let idx = pendingReversed.lastIndex(where: { $0.kind != .eof }) {
                return pendingReversed[idx]
            }
            // Check pending (from start, since we haven't reversed yet)
            if let idx = pending.firstIndex(where: { $0.kind != .eof }) {
                return pending[idx]
            }
            // Check input
            if let idx = input.firstIndex(where: { $0.kind != .eof }) {
                return input[idx]
            }
            return nil
        }

        /// Consume tokens until we've consumed the matching ) for a function-like macro call.
        /// Returns the argument token lists and the closing paren's hideSet, or nil if not a valid call.
        func parseFunctionCallArgs() -> (args: [[Token]], closingHideSet: Set<String>)? {
            // First, consume the opening (
            guard let first = nextToken(), first.kind == .punct, first.spelling == "(" else {
                return nil
            }

            var args: [[Token]] = []
            var current: [Token] = []
            var depth = 0

            while let t = nextToken() {
                if t.kind == .eof { continue }
                if t.kind == .punct {
                    if t.spelling == "(" {
                        depth += 1
                        current.append(t)
                    } else if t.spelling == ")" {
                        if depth == 0 {
                            if !current.isEmpty || !args.isEmpty {
                                args.append(current)
                            }
                            return (args, t.hideSet)
                        }
                        depth -= 1
                        current.append(t)
                    } else if t.spelling == "," && depth == 0 {
                        args.append(current)
                        current = []
                    } else {
                        current.append(t)
                    }
                } else {
                    current.append(t)
                }
            }
            return nil // Unterminated
        }

        while let token = nextToken() {
            guard token.kind == .identifier else {
                output.append(token)
                continue
            }

            // Handle __LINE__ and __FILE__ specially (context-dependent macros)
            if token.spelling == "__LINE__" {
                let line = sm.flatMap { $0.lineCol(token.loc).0 } ?? 0
                output.append(Token(kind: .integerLiteral, spelling: "\(line)", loc: token.loc))
                continue
            }
            if token.spelling == "__FILE__" {
                let fname = sm.flatMap { token.loc.fileId >= 0 ? $0.name(of: token.loc.fileId) : nil } ?? ""
                output.append(Token(kind: .stringLiteral, spelling: "\"\(fname)\"", loc: token.loc))
                continue
            }
            if token.spelling == "__DATE__" {
                let dateStr = formatCurrentDate()
                output.append(Token(kind: .stringLiteral, spelling: "\"\(dateStr)\"", loc: token.loc))
                continue
            }
            if token.spelling == "__TIME__" {
                let timeStr = formatCurrentTime()
                output.append(Token(kind: .stringLiteral, spelling: "\"\(timeStr)\"", loc: token.loc))
                continue
            }

            if token.hideSet.contains(token.spelling) {
                output.append(token)
                continue
            }

            guard let macro = table.lookup(token.spelling) else {
                output.append(token)
                continue
            }

            if macro.isFunctionLike {
                // Peek for opening paren
                guard let peek = peekToken(), peek.kind == .punct, peek.spelling == "(" else {
                    output.append(token)
                    continue
                }
                // Consume the ( and parse arguments
                guard let callResult = parseFunctionCallArgs() else {
                    output.append(token)
                    continue
                }
                let args = callResult.args
                // HideSet = intersection of macro name's hideSet and closing paren's hideSet, plus macro name
                var newHideSet = token.hideSet.intersection(callResult.closingHideSet)
                newHideSet.insert(macro.name)
                let expanded = expandFunctionLike(macro, args: args, invocationLoc: token.loc, hideSet: newHideSet)
                // Prepend expanded for rescanning (reverse into pendingReversed)
                for t in expanded.reversed() {
                    pendingReversed.append(t)
                }
            } else {
                var newHideSet = token.hideSet
                newHideSet.insert(macro.name)
                let expanded = expandObjectLike(macro, invocationLoc: token.loc, hideSet: newHideSet)
                for t in expanded.reversed() {
                    pendingReversed.append(t)
                }
            }
        }

        return output
    }

    // MARK: - Argument parsing

    /// Parse function-like macro arguments starting at the `(` token.
    /// Returns (list of argument token lists, index after closing paren).
    private func parseArgs(_ tokens: [Token], from parenIdx: Int) -> (args: [[Token]], nextIdx: Int)? {
        var args: [[Token]] = []
        var current: [Token] = []
        var depth = 0
        var i = parenIdx + 1 // skip the (

        while i < tokens.count {
            let token = tokens[i]

            if token.kind == .eof {
                return nil
            }

            if token.kind == .punct {
                if token.spelling == "(" {
                    depth += 1
                    current.append(token)
                } else if token.spelling == ")" {
                    if depth == 0 {
                        // End of args
                        if !current.isEmpty || !args.isEmpty {
                            args.append(current)
                        }
                        return (args, i + 1)
                    }
                    depth -= 1
                    current.append(token)
                } else if token.spelling == "," && depth == 0 {
                    // Argument separator
                    args.append(current)
                    current = []
                } else {
                    current.append(token)
                }
            } else {
                current.append(token)
            }
            i += 1
        }

        // Unterminated — return what we have
        if !current.isEmpty || !args.isEmpty {
            args.append(current)
        }
        return (args, i)
    }

    // MARK: - Object-like expansion

    private func expandObjectLike(_ macro: Macro, invocationLoc: SourceLoc, hideSet: Set<String>) -> [Token] {
        let result = substitute(macro.body, params: nil, args: nil, macro: macro,
                                invocationLoc: invocationLoc, hideSet: hideSet)
        return result
    }

    // MARK: - Function-like expansion

    private func expandFunctionLike(_ macro: Macro, args: [[Token]], invocationLoc: SourceLoc,
                                     hideSet: Set<String>) -> [Token] {

        // Validate argument count (allow empty args for 0-param macros)
        if !macro.isVariadic && args.count != macro.params.count {
            if !(args.count == 1 && args[0].count == 0 && macro.params.count == 0) {
                diags.error("macro '\(macro.name)' requires \(macro.params.count) arguments, but \(args.count) given", at: invocationLoc)
            }
        }

        var argMap: [String: [Token]] = [:]
        for (idx, param) in macro.params.enumerated() {
            if idx < args.count {
                argMap[param] = args[idx]
            } else {
                argMap[param] = []
            }
        }

        // Variadic: __VA_ARGS__ gets all remaining args
        if macro.isVariadic {
            var vaArgs: [Token] = []
            for idx in macro.params.count..<args.count {
                if !vaArgs.isEmpty {
                    vaArgs.append(Token(kind: .punct, spelling: ",", loc: invocationLoc))
                }
                vaArgs.append(contentsOf: args[idx])
            }
            argMap["__VA_ARGS__"] = vaArgs
        }

        let result = substitute(macro.body, params: macro.params, args: argMap, macro: macro,
                                invocationLoc: invocationLoc, hideSet: hideSet)
        return result
    }

    // MARK: - Substitution + # and ## processing

    /// Substitute parameters in the macro body, process # (stringize) and ## (paste).
    /// All output tokens get the macro's hide set applied (blue-painting).
    private func substitute(_ body: [Token], params: [String]?, args: [String: [Token]]?,
                             macro: Macro, invocationLoc: SourceLoc, hideSet: Set<String>) -> [Token] {
        var result: [Token] = []
        var i = 0

        while i < body.count {
            let token = body[i]

            // # operator (stringize) — only in function-like macros
            if token.kind == .punct && token.spelling == "#" && macro.isFunctionLike {
                if i + 1 < body.count {
                    let nextToken = body[i + 1]
                    if nextToken.kind == .identifier && args != nil && args![nextToken.spelling] != nil {
                        let stringized = stringize(args![nextToken.spelling] ?? [])
                        result.append(Token(kind: .stringLiteral, spelling: stringized, loc: invocationLoc, hideSet: hideSet))
                        i += 2
                        continue
                    } else if nextToken.kind == .identifier && nextToken.spelling == "__VA_ARGS__" && macro.isVariadic {
                        let stringized = stringize(args?["__VA_ARGS__"] ?? [])
                        result.append(Token(kind: .stringLiteral, spelling: stringized, loc: invocationLoc, hideSet: hideSet))
                        i += 2
                        continue
                    }
                }
            }

            // ## operator (token paste)
            if token.kind == .punct && token.spelling == "##" {
                if i + 1 < body.count && !result.isEmpty {
                    let rightToken = body[i + 1]
                    // Handle ##__VA_ARGS__ (GNU extension)
                    if rightToken.kind == .identifier && rightToken.spelling == "__VA_ARGS__" && macro.isVariadic {
                        let vaArgs = args?["__VA_ARGS__"] ?? []
                        if vaArgs.isEmpty {
                            // Empty __VA_ARGS__: GNU extension removes preceding comma
                            let left = result.removeLast()
                            if left.kind == .punct && left.spelling == "," {
                                // Drop the comma
                            } else {
                                result.append(left)
                            }
                            i += 2
                            continue
                        } else {
                            // Non-empty __VA_ARGS__: keep left token, substitute __VA_ARGS__ normally
                            // (don't paste — just skip the ## and let __VA_ARGS__ be handled below)
                            i += 1
                            continue
                        }
                    }
                    let left = result.removeLast()
                    let pasted = pasteTokens(left, rightToken, args: args, params: params, hideSet: hideSet, isVariadic: macro.isVariadic)
                    result.append(pasted)
                    i += 2
                    continue
                }
            }

            // Check if the NEXT token is ## — if so, don't expand the current parameter (use raw arg)
            if token.kind == .identifier && params != nil && params!.contains(token.spelling) {
                if i + 1 < body.count && body[i + 1].kind == .punct && body[i + 1].spelling == "##" {
                    // Use raw (unexpanded) arg tokens
                    let argTokens = args?[token.spelling] ?? []
                    if argTokens.isEmpty {
                        // Placemarker — skip; the ## handler will deal with empty side
                        i += 1
                        continue
                    }
                    for t in argTokens {
                        result.append(t.withHideSet(t.hideSet.union(hideSet)))
                    }
                    i += 1
                    continue
                }
            }

            // Parameter substitution (expand the argument before substitution)
            if token.kind == .identifier && params != nil && params!.contains(token.spelling) {
                let argTokens = args?[token.spelling] ?? []
                // Fully expand the argument before substitution
                let expanded = expand(argTokens)
                for t in expanded {
                    result.append(t.withHideSet(t.hideSet.union(hideSet)))
                }
                i += 1
                continue
            }

            // __VA_ARGS__ substitution
            if token.kind == .identifier && token.spelling == "__VA_ARGS__" && macro.isVariadic {
                let argTokens = args?["__VA_ARGS__"] ?? []
                let expanded = expand(argTokens)
                for t in expanded {
                    result.append(t.withHideSet(t.hideSet.union(hideSet)))
                }
                i += 1
                continue
            }

            // Regular token — copy through with hide set applied
            result.append(token.withHideSet(token.hideSet.union(hideSet)))
            i += 1
        }

        return result
    }

    // MARK: - Stringize (#)

    /// Convert a list of tokens to a string literal spelling.
    private func stringize(_ tokens: [Token]) -> String {
        var s = "\""
        for (i, token) in tokens.enumerated() {
            // Insert a space only if the original source had whitespace before this token.
            // The first token never gets a leading space.
            if i > 0 && token.hasLeadingSpace {
                s += " "
            }
            // Escape backslashes and quotes inside string/char literals
            if token.kind == .stringLiteral || token.kind == .charLiteral {
                s += token.spelling.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
            } else {
                s += token.spelling
            }
        }
        s += "\""
        return s
    }

    // MARK: - Token paste (##)

    /// Paste two tokens together.
    private func pasteTokens(_ left: Token, _ right: Token, args: [String: [Token]]?,
                             params: [String]?, hideSet: Set<String>, isVariadic: Bool = false) -> Token {
        var rightSpelling = right.spelling

        // If right is __VA_ARGS__, use its raw first token spelling
        if right.kind == .identifier && right.spelling == "__VA_ARGS__" && isVariadic {
            let argTokens = args?["__VA_ARGS__"] ?? []
            if argTokens.isEmpty {
                // Placemarker: pasting with empty gives the left token
                return left.withHideSet(left.hideSet.union(hideSet))
            }
            rightSpelling = argTokens.first!.spelling
        }
        // If right is a parameter, use its raw first token spelling
        else if right.kind == .identifier && params != nil && params!.contains(right.spelling) {
            let argTokens = args?[right.spelling] ?? []
            if argTokens.isEmpty {
                // Placemarker: pasting with empty gives the left token
                return left.withHideSet(left.hideSet.union(hideSet))
            }
            rightSpelling = argTokens.first!.spelling
        }

        let pasted = left.spelling + rightSpelling
        // Determine kind of pasted token
        let kind: TokenKind
        if cKeywords.contains(pasted) {
            kind = .keyword
        } else if left.kind == .integerLiteral && right.kind == .integerLiteral {
            kind = .integerLiteral
        } else if left.kind == .floatLiteral || right.kind == .floatLiteral {
            kind = .floatLiteral
        } else if left.kind == .punct && right.kind == .punct {
            kind = .punct
        } else {
            kind = .identifier
        }
        return Token(kind: kind, spelling: pasted, loc: left.loc, hideSet: left.hideSet.union(hideSet))
    }
}

// MARK: - C keywords (shared for paste classification)
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
]
