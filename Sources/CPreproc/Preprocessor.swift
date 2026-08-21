import CCommon

/// Preprocessor: handles #include, #define, conditionals, macro expansion.
public final class Preprocessor {
    private let sm: SourceManager
    private let includePaths: [String]
    private let predefines: [String: String]

    public init(_ sm: SourceManager, includePaths: [String], predefines: [String: String]) {
        self.sm = sm
        self.includePaths = includePaths
        self.predefines = predefines
    }

    /// Preprocess the given file and return the expanded token stream.
    public func preprocess(_ fileId: Int) throws -> [Token] {
        // Placeholder — implemented in Task 4
        let bytes = sm.contents(of: fileId)
        let lexer = Lexer(bytes, fileId: fileId)
        return lexer.tokenize()
    }
}
