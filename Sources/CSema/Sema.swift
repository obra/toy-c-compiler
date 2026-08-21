import CCommon

/// Semantic analysis: type-checks the AST and produces a typed AST.
public final class Sema {
    private let diags: DiagnosticEngine

    public init(_ diags: DiagnosticEngine) {
        self.diags = diags
    }

    /// Analyze declarations and return a typed AST.
    public func analyze(_ decls: [Decl]) throws -> [Decl] {
        // Placeholder — implemented in Task 7
        return decls
    }
}
