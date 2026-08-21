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

    public init(kind: TokenKind, spelling: String, loc: SourceLoc) {
        self.kind = kind
        self.spelling = spelling
        self.loc = loc
    }
}
