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

    public init(_ table: MacroTable, _ diags: DiagnosticEngine) {
        self.table = table
        self.diags = diags
    }

    /// Expand all macros in the given token list, returning the fully expanded token list.
    /// Uses hide sets on tokens for blue-painting (prevents infinite recursion).
    public func expand(_ tokens: [Token]) -> [Token] {
        var input = tokens
        var output: [Token] = []
        var i = 0

        while i < input.count {
            let token = input[i]

            guard token.kind == .identifier else {
                output.append(token)
                i += 1
                continue
            }

            // Blue-painting: if the token's hide set contains its own name, don't expand
            if token.hideSet.contains(token.spelling) {
                output.append(token)
                i += 1
                continue
            }

            guard let macro = table.lookup(token.spelling) else {
                output.append(token)
                i += 1
                continue
            }

            if macro.isFunctionLike {
                // Look for opening paren
                var j = i + 1
                while j < input.count && input[j].kind == .eof {
                    j += 1
                }
                if j < input.count && input[j].kind == .punct && input[j].spelling == "(" {
                    guard let (args, nextIdx) = parseArgs(input, from: j) else {
                        output.append(token)
                        i += 1
                        continue
                    }
                    // Compute the hide set: intersection of macro name token's hide set
                    // and the closing paren token's hide set, plus the macro name itself.
                    var newHideSet = token.hideSet
                    if nextIdx > 0 && nextIdx <= input.count {
                        // nextIdx - 1 is the closing paren
                        let closeParen = input[nextIdx - 1]
                        newHideSet = newHideSet.intersection(closeParen.hideSet)
                    }
                    newHideSet.insert(macro.name)

                    let expanded = expandFunctionLike(macro, args: args, invocationLoc: token.loc, hideSet: newHideSet)
                    // Replace input[i..<nextIdx] with expanded, rescan from i
                    var newInput = Array(input[0..<i])
                    newInput.append(contentsOf: expanded)
                    if nextIdx < input.count {
                        newInput.append(contentsOf: input[nextIdx...])
                    }
                    input = newInput
                    // Don't advance i — rescan from current position
                } else {
                    // Function-like macro without parens — not expanded
                    output.append(token)
                    i += 1
                    continue
                }
            } else {
                // Object-like macro
                var newHideSet = token.hideSet
                newHideSet.insert(macro.name)

                let expanded = expandObjectLike(macro, invocationLoc: token.loc, hideSet: newHideSet)
                // Replace input[i] with expanded, rescan from i
                var newInput = Array(input[0..<i])
                newInput.append(contentsOf: expanded)
                if i + 1 < input.count {
                    newInput.append(contentsOf: input[(i+1)...])
                }
                input = newInput
                // Don't advance i — rescan from current position
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
                    let left = result.removeLast()
                    let pasted = pasteTokens(left, rightToken, args: args, params: params, hideSet: hideSet)
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
            if i > 0 {
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
                             params: [String]?, hideSet: Set<String>) -> Token {
        var rightSpelling = right.spelling

        // If right is a parameter, use its raw first token spelling
        if right.kind == .identifier && params != nil && params!.contains(right.spelling) {
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
