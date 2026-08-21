# ARM64 C Compiler — Critical Path to Hello World (P0–P4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a working C compiler in Swift that emits ARM64 assembly, links against libSystem, and can compile and run a `hello world` C program — the first end-to-end milestone.

**Architecture:** A multi-stage pipeline (Driver → Preproc/Lexer → Parser → Sema → Codegen) as Swift modules sharing common types. Each stage is a pure transform. The compiler emits `.s` text and invokes system `as`/`clang` for assembling and linking.

**Tech Stack:** Swift 6.3 (SwiftPM), XCTest, system `as`/`clang`/`ld` on macOS arm64.

**Spec:** `docs/superpowers/specs/2026-08-20-arm64-c-compiler-design.md`

## Global Constraints

- Host == target == arm64-apple-macosx. Swift 6.3.
- Output is ARM64 `.s` assembly text; assemble with system `as`/`clang -c`; link with `clang` against libSystem.
- Pragmatic C99 subset; no VLAs, no `_Generic`, no C11 atomics/threads.
- Errors never crash the compiler — accumulate diagnostics.
- TDD: write failing tests, implement to pass, commit frequently.
- Each module is a SwiftPM target under `Sources/`.

---

## File Structure

```
Package.swift
Sources/
  CCommon/
    SourceManager.swift      # file ownership, offset→(file,line,col), #line tracking
    Diagnostic.swift         # Diagnostic, DiagnosticEngine, severity
    Token.swift              # TokenKind, Token, token spelling/literals
    CType.swift              # C type representation
    AST.swift                # Decl, Stmt, Expr AST nodes
  CDriver/
    Driver.swift             # CLI parsing, orchestration, external tools
    Compiler.swift           # ties stages together
  CPreproc/
    Lexer.swift              # raw bytes → preprocessing tokens
    Preprocessor.swift       # directives, macros, #include, conditionals
    Macro.swift              # macro table, expansion engine
  CParser/
    Parser.swift             # token stream → AST (recursive descent)
  CSema/
    Sema.swift               # AST → TAST, scopes, types, conversions
    TypeChecker.swift        # expression/statement/decl type checking
  CCodegen/
    Codegen.swift            # TAST → ARM64 assembly text
    ARM64.swift              # instruction emission helpers, ABI constants
    RegAlloc.swift           # simple register allocator
include/
  stdio.h stdlib.h string.h stdint.h stddef.h stdarg.h
Tests/
  CCompilerTests/            # XCTest unit tests per module
  Harness/
    Harness.swift            # compile→assemble→link→run→check
tests/
  *.c / *.expected           # golden end-to-end corpus
```

---

## Task 1: SwiftPM Project Skeleton & Build

**Files:**
- Create: `Package.swift`
- Create: `Sources/CCommon/SourceManager.swift`
- Create: `Sources/CCommon/Diagnostic.swift`
- Create: `Sources/CDriver/main.swift` (or `Driver.swift` with `@main`)
- Create: `Tests/CCompilerTests/CompileTests.swift`

**Interfaces:**
- Produces: a buildable SwiftPM project with all module targets; `SourceManager`, `Diagnostic`, `DiagnosticEngine` types.

- [ ] **Step 1: Create `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "c-compiler",
    targets: [
        .target(name: "CCommon", dependencies: []),
        .target(name: "CPreproc", dependencies: ["CCommon"]),
        .target(name: "CParser", dependencies: ["CCommon", "CPreproc"]),
        .target(name: "CSema", dependencies: ["CCommon", "CParser"]),
        .target(name: "CCodegen", dependencies: ["CCommon", "CSema"]),
        .target(name: "CDriver", dependencies: ["CCommon", "CPreproc", "CParser", "CSema", "CCodegen"]),
        .testTarget(name: "CCompilerTests", dependencies: ["CCommon", "CPreproc", "CParser", "CSema", "CCodegen", "CDriver"]),
    ]
)
```

- [ ] **Step 2: Create `SourceManager.swift`** — owns file contents as `[UInt8]`, maps byte offsets to (file,line,col). API: `func load(_ path: String) throws -> Int` (returns fileId), `func contents(of fileId: Int) -> [UInt8]`, `func loc(_ offset: Int, in fileId: Int) -> (line:Int, col:Int)`.

- [ ] **Step 3: Create `Diagnostic.swift`** — `enum Severity { case error, warning, note }`, `struct Diagnostic { var severity: Severity; var message: String; var loc: SourceLoc }`, `final class DiagnosticEngine { var diagnostics: [Diagnostic] = []; func error(_ msg: String, at loc: SourceLoc); func hasErrors: Bool }`. `SourceLoc` = `(fileId: Int, offset: Int)`.

- [ ] **Step 4: Create driver entry** — reads a file path from `CommandLine.arguments`, prints "compiling <path>" and exits 0.

- [ ] **Step 5: Build and verify**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/ Tests/
git commit -m "P0: SwiftPM project skeleton with CCommon types and driver entry"
```

---

## Task 2: End-to-End Test Harness

**Files:**
- Create: `Tests/Harness/Harness.swift` (or inline in `CCompilerTests`)
- Create: `tests/00_baseline.c`
- Create: `tests/00_baseline.expected`

**Interfaces:**
- Produces: `Harness` with `static func runCompile(_ cSource: String, expectedExit: Int, expectedStdout: String) -> Bool`. Initially the harness uses system `clang` to compile the C, establishing a baseline; later it will call our compiler.

- [ ] **Step 1: Write the harness** — takes a C source string, writes to temp `.c`, compiles via `clang`, runs the binary, captures stdout and exit code, compares to expected.

- [ ] **Step 2: Write baseline test** — `tests/00_baseline.c` = `int main() { return 0; }`, expected exit 0, stdout "".

- [ ] **Step 3: Write a print test** — `tests/01_hello.c` = `#include <stdio.h>\nint main() { printf("hello\\n"); return 0; }`, expected stdout "hello\n".

- [ ] **Step 4: Write XCTest wrapper** calling the harness with the baseline and print tests.

- [ ] **Step 5: Run tests via `swift test` — verify baseline passes.**

- [ ] **Step 6: Commit**

---

## Task 3: Lexer (C Tokenizer)

**Files:**
- Create: `Sources/CPreproc/Lexer.swift`
- Test: `Tests/CCompilerTests/LexerTests.swift`

**Interfaces:**
- Consumes: `[UInt8]` (file contents from `SourceManager`), starting `SourceLoc`.
- Produces: `[Token]`. `Token` = `(kind: TokenKind, spelling: String, loc: SourceLoc)`.
- `TokenKind` covers: identifiers, keywords (full C99 set), integer literals (decimal/hex/oct/binary + suffixes), float literals, char literals (with escapes), string literals (with escapes), all C punctuators (`->`, `++`, `<<=`, `##`, etc.), `eof`.

- [ ] **Step 1: Write failing tests** — tokenize `int x = 42;` → 5 tokens (keyword `int`, ident `x`, punct `=`, int `42`, punct `;`, eof). Test `//` and `/* */` comments are skipped. Test char literal `'\n'`. Test string `"hello\n"`. Test hex `0xFF`, suffix `42UL`.

- [ ] **Step 2: Run tests — verify they fail.**

- [ ] **Step 3: Implement `Lexer`** — scan bytes → tokens. Handle all C punctuators (longest-match), numeric literals with suffixes, string/char escapes, comments. Emit `eof` at end.

- [ ] **Step 4: Run tests — verify pass.**

- [ ] **Step 5: Commit**

---

## Task 4: Preprocessor — Directives & #include

**Files:**
- Create: `Sources/CPreproc/Preprocessor.swift`
- Create: `Sources/CPreproc/Macro.swift`
- Test: `Tests/CCompilerTests/PreprocTests.swift`

**Interfaces:**
- Consumes: `SourceManager`, list of include paths (`-I`), predefined macros (`-D`).
- Produces: `[Token]` — the expanded token stream ready for the parser.
- API: `final class Preprocessor { init(_ sm: SourceManager, includePaths: [String], predefines: [String:String]); func preprocess(_ fileId: Int) throws -> [Token] }`.

- [ ] **Step 1: Write failing tests** — `#define X 1` then `int y = X;` → `X` expands to `1`. `#include "foo.h"` includes a file. `#ifdef X / #endif` conditional. `#undef`.

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement directives** — `#include` (both `""` and `<>`), `#define` (object-like and function-like, incl. variadic `__VA_ARGS__`), `#undef`, `#if/#ifdef/#ifndef/#elif/#else/#endif` with constant-expression eval, `#` stringize, `##` paste, `#pragma` (tolerated), `#line`. Predefined macros: `__STDC__`, `__LINE__`, `__FILE__`, etc.

- [ ] **Step 4: Implement macro expansion engine** — with correct rescanning and blue-painting (hide-set tracking) per the C standard algorithm.

- [ ] **Step 5: Run — verify pass.**

- [ ] **Step 6: Commit**

---

## Task 5: AST & CType Common Types

**Files:**
- Create: `Sources/CCommon/CType.swift`
- Create: `Sources/CCommon/AST.swift`
- Test: `Tests/CCompilerTests/TypeTests.swift`

**Interfaces:**
- Produces: `CType` (enum: void, bool, char, schar, uchar, short, ushort, int, uint, long, ulong, longlong, ulonglong, float, double, pointer(to), array(of, count), function(params, ret, variadic), struct(name, members), union(...), enum(name, cases), qualified(base, const, volatile, restrict), typedef(name, base)). `AST` types: `Decl` (var, func, typedef, struct/union/enum decls), `Stmt` (expr, compound, if, while, for, do, switch, case, default, break, continue, goto, label, return, decl), `Expr` (binary, unary, assign, call, member, subscript, cast, cond/ternary, index, literal, ident, sizeof, etc.).

- [ ] **Step 1: Write failing tests** — construct `CType.pointer(.int)` and verify equality; `CType.array(.char, 10)`.

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement `CType` and `AST` types.**

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit**

---

## Task 6: Parser (C Grammar → AST)

**Files:**
- Create: `Sources/CParser/Parser.swift`
- Test: `Tests/CCompilerTests/ParserTests.swift`

**Interfaces:**
- Consumes: `[Token]` from preprocessor.
- Produces: `[Decl]` (top-level declarations = a translation unit).
- API: `final class Parser { init(_ tokens: [Token]); func parse() throws -> [Decl] }`.

- [ ] **Step 1: Write failing tests** — parse `int main() { return 0; }` → a `FuncDecl` named "main" with a `CompoundStmt` containing `ReturnStmt(0)`. Parse `int x;`, `int x = 5;`, `struct S { int a; };`, `typedef int Int;`, `int f(int a, int b);`.

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement recursive-descent parser** — declarations, type specifiers/qualifiers, struct/union/enum specs, declarators (including function and array declarators), initializers, statements, full expression grammar with correct precedence, the typedef-name ambiguity (lexer hack: sema feeds typedef names back to the parser's identifier classification).

- [ ] **Step 4: Run — verify pass on focused snippets.**

- [ ] **Step 5: Commit**

---

## Task 7: Semantic Analysis

**Files:**
- Create: `Sources/CSema/Sema.swift`
- Create: `Sources/CSema/TypeChecker.swift`
- Test: `Tests/CCompilerTests/SemaTests.swift`

**Interfaces:**
- Consumes: `[Decl]` (AST).
- Produces: `[Decl]` (typed AST — same shapes, expressions carry resolved `CType`, references resolved), plus diagnostics.
- API: `final class Sema { init(_ diags: DiagnosticEngine); func analyze(_ decls: [Decl]) throws -> [Decl] }`.

- [ ] **Step 1: Write failing tests** — `int x = "string";` should produce a diagnostic. `int x = 1 + 2;` resolves to `CType.int`. `struct S { int a; }; struct S s; s.a` resolves to `int`. Function call arg count/type checking.

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement** — scope stack (file, block, struct), symbol lookup, type construction from declaration specifiers + declarators, usual arithmetic conversions, lvalue analysis, integer constant expression folding, function-call checking, member access type resolution.

- [ ] **Step 4: Run — verify pass.**

- [ ] **Step 5: Commit**

---

## Task 8: ARM64 Codegen — Hello World

**Files:**
- Create: `Sources/CCodegen/ARM64.swift`
- Create: `Sources/CCodegen/Codegen.swift`
- Create: `Sources/CCodegen/RegAlloc.swift`
- Test: `Tests/CCompilerTests/CodegenTests.swift`, plus end-to-end tests in `tests/`

**Interfaces:**
- Consumes: `[Decl]` (typed AST from sema).
- Produces: `String` (ARM64 assembly text).
- API: `final class Codegen { func generate(_ decls: [Decl]) -> String }`.

- [ ] **Step 1: Write failing e2e test** — `tests/10_return.c` = `int main() { return 42; }` → exit code 42. Use the harness but with our compiler instead of clang.

- [ ] **Step 2: Run — verify fail.**

- [ ] **Step 3: Implement codegen for `return <int literal>`** — emit a minimal function: `.text`, `.globl _main`, `_main:`, `mov w0, #42`, `ret`. Wire driver to emit `.s`, invoke `clang -c` then `clang` to link.

- [ ] **Step 4: Run — verify `return 42` exits 42.**

- [ ] **Step 5: Add arithmetic e2e tests** — `int main() { int a = 20; int b = 22; return a + b; }` → 42. Implement local variables (stack slots), `add`/`sub`/`mul`/`div`.

- [ ] **Step 6: Add control flow e2e tests** — if/else, while loop returning a computed value. Implement branches.

- [ ] **Step 7: Add `printf` e2e test** — `#include <stdio.h>\nint main() { printf("hello\\n"); return 0; }`. Implement function calls (AAPCS64: args in x0–x7, ret in x0), string literal emission in `.section __TEXT,__cstring`.

- [ ] **Step 8: Run full test suite — verify hello world prints.**

- [ ] **Step 9: Commit**

---

## Self-Review Notes

- **Spec coverage**: P0 (Tasks 1–2), P1 (Tasks 3–4), P2 (Tasks 5–6), P3 (Task 7), P4 (Task 8). Covers the critical path to the first end-to-end milestone. P5–P7 (initialization, libSystem headers at scale, SQLite) will get follow-up plans.
- **Type consistency**: `Token`, `TokenKind`, `CType`, `Decl/Stmt/Expr` defined in CCommon, used consistently across modules. `SourceLoc = (fileId, offset)`.
- **Placeholders**: none; each task specifies files, interfaces, tests, and acceptance.
