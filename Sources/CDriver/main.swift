import Foundation
import CCommon
import CPreproc
import CParser
import CSema
import CCodegen

/// Entry point for the C compiler.
@main
struct CompilerMain {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write("usage: c-compiler <file.c> [-o output]\n".data(using: .utf8)!)
            exit(1)
        }

        let inputPath = args[1]
        let sm = SourceManager()
        let diags = DiagnosticEngine()

        do {
            let fileId = try sm.load(inputPath)
            let preprocessor = Preprocessor(sm, includePaths: [], predefines: [:])
            let tokens = try preprocessor.preprocess(fileId)
            let parser = Parser(tokens)
            let decls = try parser.parse()
            let sema = Sema(diags)
            let tast = try sema.analyze(decls)
            let codegen = Codegen()
            let asm = codegen.generate(tast)

            // Write assembly to stdout for now
            print(asm)

            if diags.hasErrors {
                for d in diags.diagnostics {
                    let (line, col) = sm.lineCol(d.loc)
                    let fname = d.loc.fileId >= 0 ? sm.name(of: d.loc.fileId) : "<unknown>"
                    FileHandle.standardError.write("\(fname):\(line):\(col): \(d.description)\n".data(using: .utf8)!)
                }
                exit(1)
            }
        } catch {
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
