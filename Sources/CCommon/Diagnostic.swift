import Foundation

/// Diagnostic severity levels.
public enum DiagnosticSeverity: Int, Sendable, Comparable {
    case note = 0
    case warning = 1
    case error = 2

    public static func < (lhs: DiagnosticSeverity, rhs: DiagnosticSeverity) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

/// A single diagnostic message.
public struct Diagnostic: Equatable {
    public let severity: DiagnosticSeverity
    public let message: String
    public let loc: SourceLoc

    public init(severity: DiagnosticSeverity, message: String, loc: SourceLoc) {
        self.severity = severity
        self.message = message
        self.loc = loc
    }

    public var description: String {
        return "\(severity): \(message)"
    }
}

/// Collects diagnostics during compilation.
public final class DiagnosticEngine {
    public var diagnostics: [Diagnostic] = []
    public var maxErrors: Int = 20
    private var errorCount = 0

    public init() {}

    public var hasErrors: Bool { errorCount > 0 }

    public func error(_ message: String, at loc: SourceLoc) {
        guard errorCount < maxErrors else { return }
        diagnostics.append(Diagnostic(severity: .error, message: message, loc: loc))
        errorCount += 1
    }

    public func warning(_ message: String, at loc: SourceLoc) {
        diagnostics.append(Diagnostic(severity: .warning, message: message, loc: loc))
    }

    public func note(_ message: String, at loc: SourceLoc) {
        diagnostics.append(Diagnostic(severity: .note, message: message, loc: loc))
    }

    public func clear() {
        diagnostics.removeAll()
        errorCount = 0
    }
}
