import CCommon
import CPreproc

/// Parser: converts a token stream into an AST.
public final class Parser {
    private let tokens: [Token]
    private var pos = 0

    public init(_ tokens: [Token]) {
        self.tokens = tokens
    }

    /// Parse the token stream into a list of top-level declarations.
    public func parse() throws -> [Decl] {
        // Placeholder — implemented in Task 6
        return []
    }
}
