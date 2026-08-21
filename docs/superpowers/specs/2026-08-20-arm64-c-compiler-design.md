# ARM64 C Compiler in Swift — Design

**Target**: A working C compiler, written in Swift, that compiles and runs SQLite on macOS/arm64.
**Output**: ARM64 `.s` assembly text, assembled and linked with system `as`/`clang` against libSystem.
**Language**: Pragmatic C99 subset (the surface real C programs — especially SQLite — use).
**Host/Target**: macOS, arm64 (Apple Silicon). Swift 6.3.

## 1. Scope

### In scope (C99 subset)

- Full preprocessor: `#include` (system and user), object- and function-like macros (incl. variadic), `#if/#ifdef/#ifndef/#elif/#else/#endif` with constant-expression evaluation, `#undef`, `#` stringize, `##` paste, predefined macros, `#pragma` tolerated, `#line`.
- Lexer: C99 tokens, `//` and `/* */` comments, all punctuators, string/char literals with escapes, integer/float literals with suffixes, identifiers, keywords.
- Parser: full C99 grammar → AST. Declarations (mixed decls in blocks), functions (prototype + definition), structs/unions/enums with tags and members, bitfields, function pointers, arrays (incl. multi-dim), pointers, all type qualifiers and storage classes, `typedef`, initializers (scalar, aggregate, designated, compound literals), statements (all forms incl. `goto`, labeled, `switch`, `for`-loop init-decl), expressions (full operator set with precedence).
- Semantic analysis: symbol tables / scopes, type system (arithmetic, pointer, array, function, struct/union/enum, _Bool), usual arithmetic conversions, lvalue analysis, integer constant expression evaluation (for `#if`, array dimensions, enum values, switch labels, static initializer constants), function-call argument type checking, diagnostics.
- Code generation: ARM64 (AAPCS64) assembly. Integer + FP arithmetic, memory loads/stores, control flow (branches, loops, switch via jump table or comparison chain), function calls (including varargs), prologue/epilogue, stack frame, simple register allocator. Constant and dynamic initializers for globals/statics. String literals.
- Link: emit `.s`, invoke system `as` (or `clang -c`) to produce `.o`, then `clang` to link against libSystem.

### Deferred (explicit non-goals for now)

- VLAs (`int n = ...; int a[n];`). SQLite can build without these.
- `_Generic`, `_Atomic`, C11 threads/`_Thread_local`, complex numbers.
- Bit-precise integers (`_BitInt`).
- Full `<tgmath.h>`.
- A bundled libc / our own runtime: we link system libSystem and ship our own headers.
- An integrated assembler/linker: we emit `.s` and use system tools.
- Cross-compilation: host == target == arm64-macos only.

### Tolerated (parsed and ignored or handled minimally)

- `__attribute__((...))`: parsed, most attributes ignored; `noreturn`, `aligned`, `packed` honored where cheap.
- `#pragma`: recognized; `#pragma once`, `#pragma pack` honored or ignored; others ignored with no error.
- `__builtin_...`: a small set handled (e.g., `__builtin_va_*`); others treated as undeclared extern calls to a symbol of that name (linker resolves or fails).
- `inline`/`_Inline` semantics: C99 rules approximated.

## 2. Architecture

```
┌─────────┐  ┌──────────┐  ┌────────┐  ┌────────┐  ┌────────┐  ┌──────────┐
│ Driver  │→ │ Preproc/ │→ │ Parser │→ │ Sema   │→ │ Codegen│→ │ .s text  │
│ (CLI)   │  │ Lexer    │  │ → AST  │  │ → TAST │  │ → Asm  │  │ (as/ld)  │
└─────────┘  └──────────┘  └────────┘  └────────┘  └────────┘  └──────────┘
```

Pipeline stages, each a pure transform over immutable data where practical:

1. **Driver** (`Sources/CDriver`): CLI parsing (`-c`, `-o`, `-S`, `-E`, `-I`, `-D`, `-U`, `--version`, `-v`), orchestrates stages, error reporting, invokes external assembler/linker.
2. **Preprocessor + Lexer** (`Sources/CPreproc`): raw bytes → preprocessing tokens → (after directive processing & macro expansion) → final C tokens. Owns `#include` resolution, macro tables, conditional skipping, line/file tracking.
3. **Parser** (`Sources/CParser`): C tokens → AST. Recursive descent, with the typedef-name ambiguity resolved by a lexer hack (the parser tells the lexer which identifiers are currently typedef-names).
4. **Semantic analysis** (`Sources/CSema`): AST → typed AST (TAST) + symbol table + diagnostics. Type construction, conversion, constant folding, scope management.
5. **Code generation** (`Sources/CCodegen`): TAST → ARM64 assembly text. Register allocation, instruction selection, frame layout, emission.
6. **Common** (`Sources/CCommon`): shared types — `Token`, `Type`, `Diagnostic`, `SourceLoc`, `SourceManager`, error infrastructure.
7. **Headers** (`include/`): our own minimal C library headers declaring libSystem functions.
8. **Tests** (`Tests/`): Swift unit tests + a `Harness` for end-to-end compile→link→run→check tests.

## 3. Data structures (key types, in CCommon)

- `SourceManager`: owns file contents as `[UInt8]`, maps offsets → (file, line, col), tracks `#line` directives.
- `Diagnostic`: severity + message + SourceLoc; collected in a `DiagnosticEngine` with configurable max-errors.
- `Token`: kind + spelling + SourceLoc; kinds cover C punctuators, keywords, literals, identifiers, eof.
- `Type`: a pure Swift representation of C types (enum/struct with indirect cases for recursive types). Kinds: `void`, `bool`, `char`, `short`, `int`, `long`, `long long`, `float`, `double`, `long double` (approximated as double), pointer, array, function, struct/union (by reference to a `RecordType`), enum (by reference to an `EnumType`), typedef (resolved), qualified (const/volatile/restrict).
- `AST`: declarations (`Decl`), statements (`Stmt`), expressions (`Expr`) — all with SourceLoc.
- `TAST`: typed AST — same shapes but expressions carry a resolved `Type` and resolved references.

## 4. Pipeline contracts

- **Preproc → Parser**: a flat `[Token]` (or a token stream with a one-token lookahead interface). Tokens carry the expanded spelling and a `SourceLoc` pointing to the expansion site (with a backtrace to the definition site for diagnostics).
- **Parser → Sema**: an AST = a list of top-level `Decl`s.
- **Sema → Codegen**: a TAST = the same `Decl`s, with all references resolved and types attached; plus a module-level symbol table.
- **Codegen → output**: a `String` of ARM64 assembly, plus optional symbol/debug info.

## 5. Error handling

- Errors never crash the compiler. Every stage returns a `Result` or accumulates `Diagnostic`s.
- After each stage, if error count > 0, the driver reports and exits non-zero (unless `-frecover` semantics desired).
- Internal invariants use Swift `assert`/`fatalError` (debug only); user errors use diagnostics.

## 6. Testing strategy

- **Unit tests** (XCTest, in `Tests/...`): each module tested in isolation with golden outputs (lexer token streams, parser ASTs, sema types, codegen assembly snippets).
- **End-to-end harness** (`Tests/Harness`): for a `.c` file, run the full pipeline → assemble → link → execute → compare exit code and stdout to expected. Used for every milestone.
- **Golden corpus**: a growing `tests/` directory of `.c` files paired with `.expected` stdout/exit-code. Categorized by feature.
- **SQLite as the ultimate test**: compile progressively larger SQLite pieces; the amalgamation `sqlite3.c` is the final gate.

## 7. Phases (verifiable milestones)

- **P0 — Skeleton & harness.** SwiftPM project; CLI driver reads a file and exits 0 on empty input; harness compiles a trivial known-good file via system `clang` as a baseline. Gate: `swift build` green; `swift test` green with one baseline e2e test.
- **P1 — Preprocessor + lexer.** Full preprocessor + lexer. Gate: preprocesses our headers and a curated set of real C; golden token-stream tests pass; can emit `-E` output matching `clang -E` on simple files.
- **P2 — Parser.** Full C99 grammar → AST. Gate: parses real C translation units (including chunks of SQLite) without crashing; golden-AST tests on focused snippets.
- **P3 — Sema.** Scopes, types, conversions, constant folding. Gate: type-checks real TUs; rejects malformed code with diagnostics; passes typed-AST golden tests.
- **P4 — Codegen (hello world).** Direct-to-assembly, simple allocator, AAPCS64. Gate: `int main(){ ... }` programs with arithmetic, control flow, and `printf` compile, link, run, and produce correct output.
- **P5 — Initialization.** Static + dynamic initializers, aggregates, designators. Gate: globals/statics initialize correctly; runs with `printf` of initialized aggregates.
- **P6 — libSystem headers + real programs.** Our headers; growing corpus of real C programs. Gate: a non-trivial real program (e.g., a small interpreter, a sort benchmark) compiles and runs correctly.
- **P7 — SQLite.** Compile and run SQLite. Gate: the SQLite amalgamation compiles and links; `sqlite3` smoke test (open in-memory DB, create table, insert, select) passes.

## 8. Repository layout

```
c-compiler/
├── Package.swift
├── README.md
├── docs/superpowers/specs/
├── Sources/
│   ├── CCommon/        # shared types: SourceManager, Diagnostics, Token, Type, AST
│   ├── CDriver/        # CLI + orchestration + external tool invocation
│   ├── CPreproc/       # preprocessor + lexer
│   ├── CParser/        # parser → AST
│   ├── CSema/          # semantic analysis → TAST
│   └── CCodegen/       # ARM64 assembly codegen
├── include/            # our own C library headers (stdio.h, stdlib.h, ...)
├── Tests/
│   ├── CCompilerTests/ # XCTest unit tests per module
│   └── Harness/        # end-to-end compile→link→run→check runner
└── tests/              # golden corpus: .c + .expected
```
