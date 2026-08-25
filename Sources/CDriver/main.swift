import Foundation
import CCommon
import CPreproc
import CParser
import CSema
import CCodegen
import CIR

/// Build a register map that maps VReg IDs to physical register names.
/// ID 0-30 → x0-x30, ID 31 → sp, ID 32 → xzr, FP IDs → d registers.
private func identityRegMap(_ insts: [IRInst]) -> [VReg: String] {
    var map: [VReg: String] = [:]
    for inst in insts {
        for v in allVRegs(in: inst) {
            if v.kind == .gp {
                switch v.id {
                case 0...30: map[v] = "x\(v.id)"
                case 31: map[v] = "sp"
                case 32: map[v] = "xzr"
                default: map[v] = "x\(v.id)"
                }
            } else if v.kind == .fp {
                map[v] = "d\(v.id)"
            }
        }
    }
    return map
}

private func allVRegs(in inst: IRInst) -> [VReg] {
    switch inst {
    case .add(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .addShifted(let d, let s1, let s2, _, _): return [d] + vregsIn(s1) + vregsIn(s2)
    case .sub(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .mul(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .sdiv(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .udiv(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .madd(let d, let s1, let s2, let s3): return [d] + vregsIn(s1) + vregsIn(s2) + vregsIn(s3)
    case .msub(let d, let s1, let s2, let s3): return [d] + vregsIn(s1) + vregsIn(s2) + vregsIn(s3)
    case .fadd(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .fsub(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .fmul(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .fdiv(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .fneg(let d, let s): return [d] + vregsIn(s)
    case .and(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .orr(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .eor(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .mvn(let d, let s): return [d] + vregsIn(s)
    case .lsl(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .lsr(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .asr(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .cmp(let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .fcmp(let s1, let s2): return vregsIn(s1) + vregsIn(s2)
    case .cset(let d, _): return [d]
    case .csetm(let d, _): return [d]
    case .mov(let d, let s): return [d] + vregsIn(s)
    case .fmov(let d, let s): return [d] + vregsIn(s)
    case .neg(let d, let s): return [d] + vregsIn(s)
    case .sxtw(let d, let s): return [d] + vregsIn(s)
    case .sxtb(let d, let s): return [d] + vregsIn(s)
    case .sxth(let d, let s): return [d] + vregsIn(s)
    case .uxtb(let d, let s): return [d] + vregsIn(s)
    case .uxth(let d, let s): return [d] + vregsIn(s)
    case .load(let d, let a, _, _, _): return [d] + vregsIn(a)
    case .store(let s, let a, _, _): return vregsIn(s) + vregsIn(a)
    case .ldp(let d1, let d2, let a, _): return [d1, d2] + vregsIn(a)
    case .stp(let s1, let s2, let a, _): return vregsIn(s1) + vregsIn(s2) + vregsIn(a)
    case .ldpPre(let d1, let d2, let a, _): return [d1, d2] + vregsIn(a)
    case .stpPre(let s1, let s2, let a, _): return vregsIn(s1) + vregsIn(s2) + vregsIn(a)
    case .ldpPost(let d1, let d2, let a, _): return [d1, d2] + vregsIn(a)
    case .stpPost(let s1, let s2, let a, _): return vregsIn(s1) + vregsIn(s2) + vregsIn(a)
    case .addrr(let d, let b, _): return [d] + vregsIn(b)
    case .adr(let d, _): return [d]
    case .adrp(let d, _): return [d]
    case .addSymbol(let d, let b, _): return [d] + vregsIn(b)
    case .loadImm(let d, _): return [d]
    case .loadFImm(let d, _, _): return [d]
    case .b: return []
    case .bcond: return []
    case .cbz(let s, _): return vregsIn(s)
    case .cbnz(let s, _): return vregsIn(s)
    case .tbz(let s, _, _): return vregsIn(s)
    case .tbnz(let s, _, _): return vregsIn(s)
    case .call: return []
    case .callIndirect(let t, _): return vregsIn(t)
    case .ret: return []
    case .clz(let d, let s): return [d] + vregsIn(s)
    case .rbit(let d, let s): return [d] + vregsIn(s)
    case .rev(let d, let s): return [d] + vregsIn(s)
    case .rev16(let d, let s): return [d] + vregsIn(s)
    case .sbfx(let d, let s, _, _): return [d] + vregsIn(s)
    case .fcvt(let d, let s, _): return [d] + vregsIn(s)
    case .dmb: return []
    case .mrs(let d, _): return [d]
    case .scvtf(let d, let s, _): return [d] + vregsIn(s)
    case .ucvtf(let d, let s, _): return [d] + vregsIn(s)
    case .fcvtzs(let d, let s, _, _): return [d] + vregsIn(s)
    case .fcvtzu(let d, let s, _, _): return [d] + vregsIn(s)
    case .fmovFromInt(let d, let s, _): return [d] + vregsIn(s)
    case .fmovToInt(let d, let s, _): return [d] + vregsIn(s)
    case .adds(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .subs(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .adc(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .sbc(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .umulh(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .smulh(let d, let s1, let s2): return [d] + vregsIn(s1) + vregsIn(s2)
    case .addSP(let d, _): return [d]
    case .subSP(let d, _): return [d]
    case .loadPre(let d, let a, _, _): return [d] + vregsIn(a)
    case .storePre(let s, let a, _, _): return vregsIn(s) + vregsIn(a)
    case .loadPost(let d, let a, _, _): return [d] + vregsIn(a)
    case .storePost(let s, let a, _, _): return vregsIn(s) + vregsIn(a)
    case .label: return []
    case .comment: return []
    case .raw: return []
    }
}

private func vregsIn(_ op: Operand) -> [VReg] {
    if case .vreg(let v) = op { return [v] }
    return []
}

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
        var useIR = false

        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-o":
                i += 1
                if i < args.count { outputPath = args[i] }
            case "-S":
                emitAssembly = true
            case "--ir":
                useIR = true
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
            var asm = codegen.generate(tast)
            let t4 = DispatchTime.now()

            // If --ir flag, run the assembly through IR round-trip:
            // parse to IR → run peephole → lower back to assembly
            if useIR {
                let asmLines = asm.split(separator: "\n").map { String($0) }
                let ir = parseAssembly(asmLines)
                let regMap = identityRegMap(ir)
                let lowered = lowerIR(ir, regMap: regMap)
                asm = lowered.joined(separator: "\n") + "\n"
            }

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
