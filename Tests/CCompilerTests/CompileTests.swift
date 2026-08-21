import XCTest
@testable import CCommon
@testable import CPreproc
@testable import CParser
@testable import CSema
@testable import CCodegen
@testable import CDriver

final class CompileTests: XCTestCase {
    func testSourceManagerRegister() {
        let sm = SourceManager()
        let id = sm.register(name: "test.c", contents: "int main() { return 0; }")
        XCTAssertEqual(sm.contents(of: id), Array("int main() { return 0; }".utf8))
        XCTAssertEqual(sm.name(of: id), "test.c")
    }

    func testSourceManagerLineCol() {
        let sm = SourceManager()
        let id = sm.register(name: "test.c", contents: "ab\ncd\nef")
        let (line, col) = sm.lineCol(SourceLoc(fileId: id, offset: 4)) // 'd' on line 2
        XCTAssertEqual(line, 2)
        XCTAssertEqual(col, 2)
    }

    func testDiagnosticEngine() {
        let diags = DiagnosticEngine()
        XCTAssertFalse(diags.hasErrors)
        diags.error("test error", at: .unknown)
        XCTAssertTrue(diags.hasErrors)
        XCTAssertEqual(diags.diagnostics.count, 1)
    }
}
