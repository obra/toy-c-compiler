import Foundation

/// A position in a source file.
public struct SourceLoc: Equatable, Hashable, Sendable {
    public let fileId: Int
    public let offset: Int

    public init(fileId: Int, offset: Int) {
        self.fileId = fileId
        self.offset = offset
    }

    /// An invalid/unknown location.
    public static let unknown = SourceLoc(fileId: -1, offset: -1)
}

/// Owns source file contents and maps byte offsets to line/column positions.
public final class SourceManager {
    private var files: [(name: String, contents: [UInt8])] = []

    public init() {}

    /// Load a file from disk and return its fileId.
    public func load(_ path: String) throws -> Int {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let fileId = files.count
        files.append((name: path, contents: Array(data)))
        return fileId
    }

    /// Register in-memory contents (for testing / synthetic input).
    public func register(name: String, contents: [UInt8]) -> Int {
        let fileId = files.count
        files.append((name: name, contents: contents))
        return fileId
    }

    /// Register in-memory contents from a String.
    public func register(name: String, contents: String) -> Int {
        return register(name: name, contents: Array(contents.utf8))
    }

    public func contents(of fileId: Int) -> [UInt8] {
        return files[fileId].contents
    }

    public func name(of fileId: Int) -> String {
        return files[fileId].name
    }

    /// Convert a byte offset within a file to (line, column), both 1-based.
    public func lineCol(_ loc: SourceLoc) -> (line: Int, col: Int) {
        guard loc.fileId >= 0 && loc.fileId < files.count else {
            return (0, 0)
        }
        let contents = files[loc.fileId].contents
        var line = 1
        var col = 1
        for i in 0..<min(loc.offset, contents.count) {
            if contents[i] == 0x0A { // '\n'
                line += 1
                col = 1
            } else {
                col += 1
            }
        }
        return (line, col)
    }

    /// Get the full line text containing the given location.
    public func lineText(_ loc: SourceLoc) -> String {
        guard loc.fileId >= 0 && loc.fileId < files.count else { return "" }
        let contents = files[loc.fileId].contents
        var start = loc.offset
        while start > 0 && contents[start - 1] != 0x0A { start -= 1 }
        var end = loc.offset
        while end < contents.count && contents[end] != 0x0A { end += 1 }
        return String(bytes: contents[start..<end], encoding: .utf8) ?? ""
    }

    /// Extract a substring from the given range.
    public func slice(_ from: SourceLoc, _ to: SourceLoc) -> String {
        guard from.fileId == to.fileId && from.fileId >= 0 else { return "" }
        let contents = files[from.fileId].contents
        let s = max(0, from.offset)
        let e = min(contents.count, to.offset)
        guard s <= e else { return "" }
        return String(bytes: contents[s..<e], encoding: .utf8) ?? ""
    }
}
