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
            FileHandle.standardError.write("usage: c-compiler <file.c> [-o output.s] [-S] [-I path]\n".data(using: .utf8)!)
            exit(1)
        }

        var inputPath: String? = nil
        var outputPath: String? = nil
        var emitAssembly = false
        var includePaths: [String] = []
        var predefines: [String: String] = [:]

        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-o":
                i += 1
                if i < args.count { outputPath = args[i] }
            case "-S":
                emitAssembly = true
            case "-I":
                i += 1
                if i < args.count { includePaths.append(args[i]) }
            case "-D":
                i += 1
                if i < args.count {
                    let parts = args[i].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    let name = String(parts[0])
                    let value = parts.count > 1 ? String(parts[1]) : "1"
                    predefines[name] = value
                }
            default:
                if arg.hasPrefix("-D") && arg.count > 2 {
                    // Combined form: -Dname=value or -Dname
                    let def = String(arg.dropFirst(2))
                    let parts = def.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    let name = String(parts[0])
                    let value = parts.count > 1 ? String(parts[1]) : "1"
                    predefines[name] = value
                } else if !arg.hasPrefix("-") {
                    inputPath = arg
                }
            }
            i += 1
        }

        // Always include our own headers
        let ourIncludeDir = findOurIncludeDir()
        if let dir = ourIncludeDir {
            includePaths.insert(dir, at: 0)
        }

        guard let input = inputPath else {
            FileHandle.standardError.write("error: no input file\n".data(using: .utf8)!)
            exit(1)
        }

        let sm = SourceManager()
        let diags = DiagnosticEngine()

        do {
            let fileId = try sm.load(input)
            let preprocessor = Preprocessor(sm, includePaths: includePaths, predefines: predefines)
            let t0 = DispatchTime.now()
            let tokens = try preprocessor.preprocess(fileId)
            let t1 = DispatchTime.now()

            let parser = Parser(tokens, diags: diags)
            let decls = try parser.parse()
            let t2 = DispatchTime.now()
            let sema = Sema(diags)
            let tast = try sema.analyze(decls)
            let t3 = DispatchTime.now()
            let codegen = Codegen(enumConstants: sema.enumConstants)
            let asm = codegen.generate(tast)
            let t4 = DispatchTime.now()

            let ppMs = Double(t1.uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            let parseMs = Double(t2.uptimeNanoseconds - t1.uptimeNanoseconds) / 1_000_000
            let semaMs = Double(t3.uptimeNanoseconds - t2.uptimeNanoseconds) / 1_000_000
            let cgMs = Double(t4.uptimeNanoseconds - t3.uptimeNanoseconds) / 1_000_000
            let totalMs = Double(t4.uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            FileHandle.standardError.write("timing: preprocess=\(ppMs)ms parse=\(parseMs)ms sema=\(semaMs)ms codegen=\(cgMs)ms total=\(totalMs)ms tokens=\(tokens.count) decls=\(decls.count)\n".data(using: .utf8)!)

            if diags.hasErrors {
                for d in diags.diagnostics {
                    let (line, col) = sm.lineCol(d.loc)
                    let fname = d.loc.fileId >= 0 ? sm.name(of: d.loc.fileId) : "<unknown>"
                    FileHandle.standardError.write("\(fname):\(line):\(col): \(d.description)\n".data(using: .utf8)!)
                }
                exit(1)
            }

            // Output assembly
            if let outPath = outputPath {
                try asm.write(toFile: outPath, atomically: true, encoding: .utf8)
            } else if emitAssembly {
                FileHandle.standardOutput.write(asm.data(using: .utf8)!)
            } else {
                // Default: write to stdout (harness redirects)
                FileHandle.standardOutput.write(asm.data(using: .utf8)!)
            }
        } catch {
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    /// Find the include directory for our headers.
    private static func findOurIncludeDir() -> String? {
        // Try relative to executable, then common paths
        let candidates = [
            "include",
            "../include",
            "../../include",
        ]
        for c in candidates {
            if FileManager.default.fileExists(atPath: c) {
                return FileManager.default.currentDirectoryPath + "/" + c
            }
        }
        return nil
    }
}
