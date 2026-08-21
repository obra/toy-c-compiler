import CCommon

/// C token kinds.
public enum TokenKind: Equatable, Sendable {
    case identifier
    case keyword
    case integerLiteral
    case floatLiteral
    case charLiteral
    case stringLiteral
    case punct   // operator or punctuator
    case eof
}

/// A single C token.
public struct Token: Equatable, Sendable {
    public let kind: TokenKind
    public let spelling: String
    public let loc: SourceLoc
    /// Hide set for blue-painting: names that should NOT be expanded for this token.
    public let hideSet: Set<String>

    public init(kind: TokenKind, spelling: String, loc: SourceLoc, hideSet: Set<String> = []) {
        self.kind = kind
        self.spelling = spelling
        self.loc = loc
        self.hideSet = hideSet
    }

    /// Create a copy of this token with an expanded hide set.
    public func withHideSet(_ newHideSet: Set<String>) -> Token {
        return Token(kind: kind, spelling: spelling, loc: loc, hideSet: newHideSet)
    }
}
