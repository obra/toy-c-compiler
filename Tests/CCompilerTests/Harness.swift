import Foundation
import XCTest

/// End-to-end test harness: compiles C source, runs the binary, checks exit code and stdout.
/// Currently uses system `clang` as the reference compiler to establish baseline tests.
/// Later phases will switch to our compiler.
public struct Harness {
    /// Compile C source using system clang, run it, and check the result.
    /// - Parameters:
    ///   - source: C source code as a string
    ///   - expectedExit: Expected exit code (default 0)
    ///   - expectedStdout: Expected stdout output (default "")
    ///   - extraArgs: Extra arguments to pass to clang (e.g., ["-Iinclude"])
    /// - Returns: true if the program compiled, ran, and matched expectations
    public static func runViaClang(_ source: String, expectedExit: Int = 0,
                                   expectedStdout: String = "",
                                   extraArgs: [String] = []) -> Bool {
        let tmpDir = NSTemporaryDirectory()
        let baseName = "harness_\(UUID().uuidString)"
        let cFile = "\(tmpDir)\(baseName).c"
        let binFile = "\(tmpDir)\(baseName)"

        do {
            try source.write(toFile: cFile, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        defer {
            try? FileManager.default.removeItem(atPath: cFile)
            try? FileManager.default.removeItem(atPath: binFile)
        }

        // Compile with system clang
        let compileResult = runProcess("/usr/bin/clang", args: [cFile, "-o", binFile] + extraArgs)
        guard compileResult.exitCode == 0 else {
            print("Harness: clang compile failed:\n\(compileResult.stderr)")
            return false
        }

        // Run the binary
        let runResult = runProcess(binFile, args: [])
        if runResult.exitCode != expectedExit {
            print("Harness: exit code mismatch: got \(runResult.exitCode), expected \(expectedExit)")
            print("stdout: \(runResult.stdout)")
            print("stderr: \(runResult.stderr)")
            return false
        }
        if runResult.stdout != expectedStdout {
            print("Harness: stdout mismatch: got '\(runResult.stdout)', expected '\(expectedStdout)'")
            return false
        }
        return true
    }

    /// Compile C source using OUR compiler, run it, and check the result.
    /// Uses our compiler binary (assumed at `.build/debug/CDriver`) to emit .s,
    /// then assembles and links with system clang.
    public static func runViaOurCompiler(_ source: String, expectedExit: Int = 0,
                                         expectedStdout: String = "",
                                         extraArgs: [String] = []) -> Bool {
        let tmpDir = NSTemporaryDirectory()
        let baseName = "our_\(UUID().uuidString)"
        let cFile = "\(tmpDir)\(baseName).c"
        let sFile = "\(tmpDir)\(baseName).s"
        let binFile = "\(tmpDir)\(baseName)"

        do {
            try source.write(toFile: cFile, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        defer {
            try? FileManager.default.removeItem(atPath: cFile)
            try? FileManager.default.removeItem(atPath: sFile)
            try? FileManager.default.removeItem(atPath: binFile)
        }

        // Find our compiler binary
        let ourCompiler = findOurCompiler()
        guard let compiler = ourCompiler else {
            print("Harness: could not find our compiler binary")
            return false
        }

        // Compile with our compiler → .s
        let compileResult = runProcess(compiler, args: [cFile] + extraArgs, stdoutFile: sFile)
        guard compileResult.exitCode == 0 else {
            print("Harness: our compiler failed:\n\(compileResult.stderr)")
            return false
        }

        // Assemble and link with clang
        let linkResult = runProcess("/usr/bin/clang", args: [sFile, "-o", binFile])
        guard linkResult.exitCode == 0 else {
            print("Harness: link failed:\n\(linkResult.stderr)")
            return false
        }

        // Run the binary
        let runResult = runProcess(binFile, args: [])
        if runResult.exitCode != expectedExit {
            print("Harness: exit code mismatch: got \(runResult.exitCode), expected \(expectedExit)")
            return false
        }
        if runResult.stdout != expectedStdout {
            print("Harness: stdout mismatch: got '\(runResult.stdout)', expected '\(expectedStdout)'")
            return false
        }
        return true
    }

    // MARK: - Private helpers

    private struct ProcessResult {
        let exitCode: Int
        let stdout: String
        let stderr: String
    }

    /// Compile C source using OUR compiler with --ir optimization, assemble with clang,
    /// and verify it assembles correctly. Returns the assembly error count (0 = success).
    /// Also runs the binary if assembly succeeds.
    public static func runViaOurCompilerIR(_ source: String, expectedExit: Int = 0,
                                             expectedStdout: String = "",
                                             extraArgs: [String] = []) -> Bool {
        let tmpDir = NSTemporaryDirectory()
        let baseName = "ir_\(UUID().uuidString)"
        let cFile = "\(tmpDir)\(baseName).c"
        let sFile = "\(tmpDir)\(baseName).s"
        let binFile = "\(tmpDir)\(baseName)"

        do {
            try source.write(toFile: cFile, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        defer {
            try? FileManager.default.removeItem(atPath: cFile)
            try? FileManager.default.removeItem(atPath: sFile)
            try? FileManager.default.removeItem(atPath: binFile)
        }

        let ourCompiler = findOurCompiler()
        guard let compiler = ourCompiler else {
            print("Harness: could not find our compiler binary")
            return false
        }

        // Compile with our compiler --ir → .s
        let compileResult = runProcess(compiler, args: [cFile, "--ir"] + extraArgs, stdoutFile: sFile)
        guard compileResult.exitCode == 0 else {
            print("Harness: our compiler --ir failed:\n\(compileResult.stderr)")
            return false
        }

        // Assemble with clang — this catches invalid instructions
        let linkResult = runProcess("/usr/bin/clang", args: [sFile, "-o", binFile])
        guard linkResult.exitCode == 0 else {
            print("Harness: IR assembly FAILED:\n\(linkResult.stderr)")
            return false
        }

        // Run the binary
        let runResult = runProcess(binFile, args: [])
        if runResult.exitCode != expectedExit {
            print("Harness: IR exit code mismatch: got \(runResult.exitCode), expected \(expectedExit)")
            return false
        }
        if runResult.stdout != expectedStdout {
            print("Harness: IR stdout mismatch: got '\(runResult.stdout)', expected '\(expectedStdout)'")
            return false
        }
        return true
    }

    private static func runProcess(_ executable: String, args: [String],
                                   stdoutFile: String? = nil) -> ProcessResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: "failed to launch: \(error)")
        }

        proc.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        // If a stdoutFile was specified, write the captured stdout to it
        if let stdoutFile = stdoutFile {
            do {
                try stdout.write(toFile: stdoutFile, atomically: true, encoding: .utf8)
            } catch {
                return ProcessResult(exitCode: -1, stdout: "", stderr: "failed to write stdout file: \(error)")
            }
        }

        return ProcessResult(exitCode: Int(proc.terminationStatus), stdout: stdout, stderr: stderr)
    }

    private static func findOurCompiler() -> String? {
        // Look for the built CDriver binary in common locations
        let candidates = [
            ".build/debug/CDriver",
            ".build/release/CDriver",
            ".build/arm64-apple-macosx/debug/CDriver",
        ]
        for c in candidates {
            if FileManager.default.fileExists(atPath: c) {
                return c
            }
        }
        return nil
    }
}
