# toy-c-compiler

A single-pass C99 compiler with AArch64 (ARM64) code generation, written in Swift.

## What It Does

Compiles C99 source code to ARM64 assembly, targeting macOS on Apple Silicon.
The output is standard assembly that is assembled with `as` and linked with
`clang`/`ld` against system libc.

- **Frontend:** Lexer → Preprocessor → Parser → Semantic analysis
- **Backend:** Direct AST-to-ARM64-assembly code generation with a peephole optimizer
- **No intermediate representation** — the codegen walks the AST and emits
  assembly text in a single pass

## Architecture

```
Source → CPreproc → CParser → CSema → CCodegen → ARM64 .s
         (lexer,     (recursive   (scope,    (AST → asm,
          macro       descent     type        peephole
          expansion)  parser)     checking)   optimizer)
```

| Module | Lines | Responsibility |
|--------|-------|----------------|
| CCommon | 1,306 | AST, CType, Diagnostic, SourceManager |
| CPreproc | 2,173 | Lexer, Preprocessor, Macro expansion |
| CParser | 3,311 | Recursive descent C99 parser |
| CSema | 794 | Scope management, type checking, constant folding |
| CCodegen | 12,918 | ARM64 code generation + peephole optimizer |
| CDriver | 136 | CLI entry point |
| **Total** | **~20,600** | |

## Building

```bash
swift build -c release      # optimized build
swift build                # debug build
```

## Usage

```bash
.build/release/CDriver input.c -o output.s -Iinclude
as -o output.o output.s
clang -o output output.o -lm
```

The `-I` flag adds header search paths. The `include/` directory provides
system headers (stdio.h, stdlib.h, string.h, math.h, stdint.h, etc.)
implemented as declarations that call through to libc.

## Testing

```bash
swift test                 # 159 unit tests (lexer, parser, sema, codegen, e2e)
```

GCC torture test suite (requires the testsuite locally):
```bash
bash run_gcc_torture_v2.sh
```

## Supported C Features

- Full C99 preprocessor: `#include`, `#define` (object/function-like/variadic),
  `#if`/`#ifdef`/`#elif`/`#else`, `#` stringize, `##` paste, hide sets
- All C99 types: integers, floats, double, long double, pointers, arrays,
  structs, unions, enums, bitfields, function pointers
- `_Complex` (float/double/long double + integer complex types)
- `__attribute__((vector_size(N)))` SIMD vector types
- `__int128` / `unsigned __int128`
- VLAs (variable-length arrays) and `alloca`
- Nested functions with static chains (GNU extension)
- Computed goto (`&&label`) and `__label__` nonlocal goto
- K&R-style function definitions
- `typeof`, compound literals, designated initializers
- GNU inline assembly
- `__builtin_va_arg`, `__builtin_overflow`, `__builtin_mul_overflow`

## Code Generation

The codegen targets AAPCS64 (ARM64 ABI):
- Arguments in x0–x7, return in x0
- Stack frame with x29 (frame pointer) and x30 (link register)
- Scratch registers x9–x15, callee-saved x19/x21–x28
- HFAs (homogeneous floating-point aggregates) for struct/complex returns
- x8 indirect return buffer for large (>16 byte) struct/vector returns
- Variadic ABI for printf-style functions

Peephole optimizations include:
- Store-to-load forwarding (str + ldr → mov/fmov)
- `movn` for negative constants
- `cset` + `cbz`/`cbnz` → direct conditional branches
- Dead code elimination after `ret`
- Duplicate `mov` elimination
- `wzr` for zero stores and zero-initialization
- Round-trip `mov` elimination (mov a,b + mov b,a)

## Real-World Validation

Compiles and runs the SQLite 3.46.0 amalgamation (~255K lines of C):
- In-memory database operations (open, create table, insert, select)
- Full VDBE execution engine
- Passes the GCC torture test suite with 1367+ tests passing
