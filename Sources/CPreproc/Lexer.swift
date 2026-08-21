import CCommon

/// Lexer: converts raw bytes into a sequence of C tokens.
public final class Lexer {
    private let bytes: [UInt8]
    private let fileId: Int
    private var pos: Int = 0
    private let startPos: Int

    public init(_ bytes: [UInt8], fileId: Int, startOffset: Int = 0) {
        self.bytes = bytes
        self.fileId = fileId
        self.pos = startOffset
        self.startPos = startOffset
    }

    public func tokenize() -> [Token] {
        // Placeholder — implemented in Task 3
        return [Token(kind: .eof, spelling: "", loc: SourceLoc(fileId: fileId, offset: bytes.count))]
    }
}
