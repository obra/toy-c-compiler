# Codegen → IR Conversion Guide

This document maps every pattern in the existing ARM64 codegen
(`Sources/CCodegen/Codegen.swift`, ~12,800 lines) to the structured IR
defined in `Sources/CIR/IR.swift`. It is organized by category. Each table
has columns: **Existing Pattern**, **Context**, **IR Instruction**,
**VReg Mapping**, and **Special Handling**.

## Foundational Mappings

Before the per-category tables, here are the cross-cutting mappings that
apply throughout.

### Register Allocation

| Existing Pattern | IR Equivalent |
|---|---|
| `regAlloc.alloc() ?? .x9` | `IRFunction.newVReg(kind: .gp)` — returns a `VReg(id:, kind: .gp)` |
| `regAlloc.allocCalleeSaved()` | `IRFunction.newVReg(kind: .gp)` — the IR allocator decides spilling; no distinct pool |
| `regAlloc.free(reg)` | *(nothing)* — the IR register allocator handles liveness; VRegs are not manually freed |
| `regAlloc.reset()` (between statements, after if/while/for conditions) | *(eliminated)* — in the IR approach, VRegs have function-wide live ranges; statement boundaries no longer reset the allocator. The lowering pass runs a real liveness analysis instead. |
| `allocReg()` helper (tries scratch then callee-saved) | `IRFunction.newVReg(kind: .gp)` — single path, no fallback to `.x9` |

**Key insight:** The existing codegen uses `regAlloc.reset()` at every
statement boundary (after expressions, after if/while/for conditions, after
switch cases). This is because the simple allocator has no liveness tracking
—it just returns the first free scratch register and the pool is manually
reset to avoid exhaustion. In the IR approach, `newVReg()` allocates a fresh
VReg with a monotonically increasing id. The lowering pass assigns physical
registers via liveness analysis. `reset()` calls are eliminated entirely.

### emitExpr Return Value → VReg

| Existing Pattern | IR Equivalent |
|---|---|
| `let reg = emitExpr(expr); return reg` (ARM64Reg) | `let v = irFunc.newVReg(kind: ...); emit IRInst producing v; return v` |
| `emitExpr` returns `.x9` as fallback | VReg with a fresh id — never reuses a fixed register |
| Result in `x0` after a call | `call`/`callIndirect` IRInst; result is a new VReg (lowering moves x0→assigned reg) |
| Result in `s0`/`d0` after a call (FP) | `call`/`callIndirect`; result is a new VReg with `kind: .fp` |
| FP value in `sN`/`dN` (float/double) | VReg with `kind: .fp`; the `.float` vs `.double` distinction is carried by the `Width` or a type annotation, not by the VReg itself |

The existing codegen overloads integer registers to hold FP register
*numbers* (e.g., `emitExpr` returns `.x9` but the FP value is in `s9`/`d9`).
In the IR, `VReg.kind` distinguishes `.gp` from `.fp` from `.pflag`.

### Local Variables → Slot Operands

| Existing Pattern | IR Equivalent |
|---|---|
| `localVarOffsets[name] = offset` (x29-relative, negative) | `Operand.slot(offset)` — the frame-relative offset |
| `emitLoadFromFrame(reg, offset, type)` | `IRInst.load(dst: vreg, addr: .vreg(fp), offset: offset, width: Width, signed: Bool)` where `fp` is the VReg assigned to x29 |
| `storeLocal(name, reg, type)` / `emitStoreFP(reg.x, offset)` | `IRInst.store(src: .vreg(v), addr: .vreg(fp), offset: offset, width: Width)` |
| `add reg, x29, #offset` (address of local) | `IRInst.addrr(dst: v, base: .vreg(fp), offset: offset)` or `Operand.slot(offset)` used directly when the IR supports slot-addressing |

The existing `localVarTypes[name]` dict maps names to `CType`. In the IR
approach, this becomes metadata on the slot: the `Width` and `signed` flag
for loads/stores are derived from the `CType`.

### String Literals and Global Variables → Global Operands

| Existing Pattern | IR Equivalent |
|---|---|
| `adrp reg, label@PAGE` + `add reg, reg, label@PAGEOFF` (string literal) | `IRInst.adrp(dst: v, symbol: label)` + `IRInst.addSymbol(dst: v, base: .vreg(v), symbol: label)` — or a combined `Operand.global(label)` when only the address is needed |
| `adrp reg, _name@PAGE` + `add reg, reg, _name@PAGEOFF` (defined global) | `IRInst.adrp(dst: v, symbol: "_name")` + `IRInst.addSymbol(...)` or `Operand.global("_name")` |
| `adrp reg, _name@GOTPAGE` + `ldr reg, [reg, _name@GOTPAGEOFF]` (extern global) | `IRInst.adrp(dst: v, symbol: "_name@GOT")` + `IRInst.load(dst: v2, addr: .vreg(v), offset: 0, width: .dword, signed: false)` — GOT indirection |
| `addStringLiteral(value)` returns a label | `Operand.global(label)` |

### Labels → Label Operands

| Existing Pattern | IR Equivalent |
|---|---|
| `newLabel()` → `"L_func_N"` | `Operand.label("L_func_N")` — label generation is unchanged |
| `emitLine("\(label):")` | `IRInst.label("L_func_N")` — marks a basic block boundary |
| `breakLabels`/`continueLabels` stacks | Resolved to `Operand.label(...)` at the point of `break`/`continue` emission |

---

## 1. Integer Arithmetic

| Existing Pattern | Context | IR Instruction | VReg Mapping | Special Handling |
|---|---|---|---|---|
| `add leftReg.x, leftReg.x, rightReg.x` | 64-bit add (long/pointer result) | `add(dst, .vreg(left), .vreg(right))` | dst = leftReg's VReg (result written back to left) | Result overwrites left operand register |
| `add leftReg.w, leftReg.w, rightReg.w` | 32-bit add (int/uint result, `is32BitOperand`) | `add(dst, .vreg(left), .vreg(right))` | dst = leftReg's VReg | Width=word; lowering uses `w` form. Result truncated to 32 bits by `w` register usage. |
| `add reg, reg, #imm` (pre/post inc/dec) | Increment/decrement by constant | `add(dst, .vreg(reg), .imm(Int64(imm)))` | dst = reg's VReg | |
| `add baseReg, baseReg, indexReg, lsl #N` | Array subscript address (elemSize=2^N) | `add(dst, .vreg(base), .vreg(index))` + shift encoded as `lsl` or folded into addressing | dst = base VReg | The `lsl #N` is part of the add; may need an `lsl` IRInst or an addressing-mode flag |
| `add reg, x29, #offset` | Address of local variable / frame temp | `addrr(dst, base: .vreg(fp), offset: offset)` | dst = new VReg | |
| `sub leftReg.x, leftReg.x, rightReg.x` | 64-bit subtraction | `sub(dst, .vreg(left), .vreg(right))` | dst = left VReg | |
| `sub leftReg.w, leftReg.w, rightReg.w` | 32-bit subtraction | `sub(dst, .vreg(left), .vreg(right))` | dst = left VReg | Width=word |
| `sub reg, reg, #1` | Pre/post decrement | `sub(dst, .vreg(reg), .imm(1))` | dst = reg VReg | |
| `mul leftReg.x, leftReg.x, rightReg.x` | 64-bit multiply | `mul(dst, .vreg(left), .vreg(right))` | dst = left VReg | |
| `mul leftReg.w, leftReg.w, rightReg.w` | 32-bit multiply | `mul(dst, .vreg(left), .vreg(right))` | dst = left VReg | Width=word |
| `mul reg, reg, x16` | Pointer scaling (non-power-of-2 elemSize) | `mul(dst, .vreg(reg), .vreg(scratch))` | dst = reg VReg | x16 is a scratch VReg holding elemSize |
| `sdiv leftReg.x, leftReg.x, rightReg.x` | Signed 64-bit division | `sdiv(dst, .vreg(left), .vreg(right))` | dst = left VReg | |
| `sdiv leftReg.w, leftReg.w, rightReg.w` | Signed 32-bit division | `sdiv(dst, .vreg(left), .vreg(right))` | dst = left VReg | Width=word |
| `udiv leftReg.x, leftReg.x, rightReg.x` | Unsigned 64-bit division | `udiv(dst, .vreg(left), .vreg(right))` | dst = left VReg | |
| `udiv leftReg.w, leftReg.w, rightReg.w` | Unsigned 32-bit division | `udiv(dst, .vreg(left), .vreg(right))` | dst = left VReg | Width=word |
| `sdiv x16, leftReg, rightReg` + `msub leftReg, x16, rightReg, leftReg` | Modulo (signed): `left % right = left - (left/right)*right` | `sdiv(tmp, .vreg(left), .vreg(right))` + `msub(dst, .vreg(tmp), .vreg(right), .vreg(left))` | dst = left VReg; tmp = fresh scratch VReg | Needs a scratch VReg for the division result. x16 is used as scratch in existing codegen. |
| `udiv x16, leftReg, rightReg` + `msub leftReg, x16, rightReg, leftReg` | Modulo (unsigned) | `udiv(tmp, ...)` + `msub(dst, ...)` | dst = left VReg; tmp = scratch VReg | |
| `madd baseReg, indexReg, x16, baseReg` | Address computation (non-power-of-2 elemSize): `base + index * elemSize` | `madd(dst, .vreg(index), .vreg(elemSize), .vreg(base))` | dst = base VReg | |
| `neg reg.x, reg.x` | Unary negation (64-bit) | `sub(dst, .imm(0), .vreg(reg))` or a dedicated `neg` — IR has no `neg` case; use `sub(dst, .imm(0), .vreg(src))` | dst = src VReg | **Gap:** IR.swift has no `neg` case. Map to `sub(dst, .imm(0), .vreg(src))`. |
| `neg reg.w, reg.w` | Unary negation (32-bit) | `sub(dst, .imm(0), .vreg(src))` | dst = src VReg | Width=word. Followed by `sxtw` for signed 32-bit. |
| `adds`/`subs` + `adc`/`sbc` | __int128 add/sub (multi-word carry) | Not directly representable — see §15 __int128 handling | | **Gap:** IR has no multi-word add-with-carry. |

**Width determination:** The codegen chooses `w` vs `x` register forms
based on `resultType.sizeInBytes == 4` (32-bit) vs 8 (64-bit). In the IR,
the `Width` enum (`.word`/`.dword`) drives the lowering. The IR `add`/`sub`/
`mul`/`sdiv`/`udiv` cases do not carry a Width — the lowering pass must
infer it from the VReg's type annotation or from explicit width metadata.
**This is a design consideration:** either add Width to arithmetic IRInst
cases, or attach type info to VRegs.

---

## 2. Floating-Point Arithmetic

| Existing Pattern | Context | IR Instruction | VReg Mapping | Special Handling |
|---|---|---|---|---|
| `fadd sReg, sReg, sReg` | Float addition (both operands float) | `fadd(dst, .vreg(left), .vreg(right))` | dst, left, right = VReg(kind: .fp) | `s` prefix = float (32-bit). VReg.kind=.fp. Width or FP type annotation determines s vs d. |
| `fadd dReg, dReg, dReg` | Double addition | `fadd(dst, .vreg(left), .vreg(right))` | dst = left VReg (.fp) | `d` prefix = double (64-bit) |
| `fsub dReg, dReg, dReg` | Float/double subtraction | `fsub(dst, .vreg(left), .vreg(right))` | dst = left VReg | |
| `fmul dReg, dReg, dReg` | Float/double multiply | `fmul(dst, .vreg(left), .vreg(right))` | dst = left VReg | |
| `fdiv dReg, dReg, dReg` | Float/double division | `fdiv(dst, .vreg(left), .vreg(right))` | dst = left VReg | |
| `fneg sReg, sReg` / `fneg dReg, dReg` | Unary FP negation | `fneg(dst, .vreg(src))` | dst = src VReg (.fp) | |
| `fcvt dReg, sReg` | Float → double promotion | `fcvt(dst, .vreg(src), fromDouble: false)` | dst = src VReg (.fp) | `fromDouble: false` means source is float (s→d) |
| `fcvt sReg, dReg` | Double → float demotion | `fcvt(dst, .vreg(src), fromDouble: true)` | dst = src VReg (.fp) | `fromDouble: true` means source is double (d→s) |
| `fmov sReg, #0.0` / `fmov dReg, #0.0` | FP zero (e.g., `__imag__` on non-complex) | `loadFImm(dst, 0.0, isFloat: Bool)` or `fmov(dst, .immF(0.0))` | dst = new VReg (.fp) | |
| `fmov sN, wN` / `fmov dN, xN` | Transfer int reg bit pattern to FP reg (float literal loading) | `fmov(dst, .vreg(src))` — but this is int→FP register move, not a pure FP copy | dst = VReg(.fp), src = VReg(.gp) | **Special:** This crosses register banks (gp→fp). The IR `fmov` case needs to handle cross-bank moves or a separate `fmovFromInt` case may be needed. |
| `scvtf sReg, reg.x` / `scvtf dReg, reg.x` | Signed int → float/double | **Gap:** No `scvtf` IRInst case. Needs a new case like `cvtf(dst, .vreg(src), fromDouble: false, signed: true)` or `scvtf(dst, .vreg(src))` | dst = VReg(.fp), src = VReg(.gp) | **Gap:** IR.swift has no int↔float conversion instruction. |
| `ucvtf sReg, reg.x` | Unsigned int → float/double | Same gap — needs `ucvtf` | dst = VReg(.fp) | **Gap** |
| `fcvtzs wReg, sReg` / `fcvtzs xReg, dReg` | Float/double → signed int | **Gap:** needs `fcvtzs` IRInst | dst = VReg(.gp), src = VReg(.fp) | **Gap** |
| `fcvtzu wReg, sReg` / `fcvtzu xReg, dReg` | Float/double → unsigned int | **Gap:** needs `fcvtzu` IRInst | dst = VReg(.gp), src = VReg(.fp) | **Gap** |
| `fmov s0, sN` / `fmov d0, dN` | Move FP result to return register | `fmov(dst, .vreg(src))` | dst = VReg(.fp) mapped to s0/d0 | |

**FP register bank issue:** The existing codegen uses integer register
numbers to name FP registers (e.g., `emitExpr` returns `.x9`, FP value in
`s9`/`d9`). The IR's `VReg.kind = .fp` cleanly separates this. All FP
operations use `VReg(kind: .fp)`.

**Float vs Double distinction:** The IR does not currently distinguish
single vs double precision in VReg or in `fadd`/`fsub`/etc. The lowering
pass needs type information (from `CType`) to choose `s` vs `d` mnemonics.
Consider adding a `precision` field or relying on VReg type metadata.

---

## 3. Logical Operations

| Existing Pattern | Context | IR Instruction | VReg Mapping | Special Handling |
|---|---|---|---|---|
| `and leftReg.w, leftReg.w, rightReg.w` | 32-bit bitwise AND | `and(dst, .vreg(left), .vreg(right))` | dst = left VReg | Width=word |
| `and leftReg.x, leftReg.x, rightReg.x` | 64-bit bitwise AND | `and(dst, .vreg(left), .vreg(right))` | dst = left VReg | Width=dword |
| `and reg.x, reg.x, #mask` | Bitfield masking (immediate AND) | `and(dst, .vreg(reg), .imm(Int64(mask)))` | dst = reg VReg | Only for masks ≤ 255 (immediate encodable). Larger masks need `loadImm` into scratch + `and`. |
| `and reg.x, reg.x, x16` | Bitfield masking (large mask in scratch) | `and(dst, .vreg(reg), .vreg(scratch))` | dst = reg VReg; scratch = temp VReg | |
| `orr leftReg.w, leftReg.w, rightReg.w` | 32-bit bitwise OR | `orr(dst, .vreg(left), .vreg(right))` | dst = left VReg | |
| `orr leftReg.x, leftReg.x, rightReg.x` | 64-bit bitwise OR | `orr(dst, .vreg(left), .vreg(right))` | dst = left VReg | |
| `orr unitReg, unitReg, valReg` | Bitfield insert (OR new value into cleared unit) | `orr(dst, .vreg(unit), .vreg(val))` | dst = unit VReg | Part of bitfield read-modify-write |
| `eor leftReg.w, leftReg.w, rightReg.w` | 32-bit XOR | `eor(dst, .vreg(left), .vreg(right))` | dst = left VReg | |
| `eor leftReg.x, leftReg.x, rightReg.x` | 64-bit XOR | `eor(dst, .vreg(left), .vreg(right))` | dst = left VReg | |
| `mvn reg.w, reg.w` | 32-bit bitwise NOT | `mvn(dst, .vreg(src))` | dst = src VReg | Followed by `sxtw` for signed 32-bit types |
| `mvn reg.x, reg.x` | 64-bit bitwise NOT | `mvn(dst, .vreg(src))` | dst = src VReg | |
| `cmp reg.x, #0` + `cset reg.x, eq` | Logical NOT (`!expr`) | `cmp(.vreg(reg), .imm(0))` + `cset(dst, .eq)` | dst = reg VReg; pflag VReg implicit | Two IRInst: cmp sets flags, cset reads them. May need a `pflag` VReg to connect them, or rely on ordering. |

---

## 4. Shifts

| Existing Pattern | Context | IR Instruction | VReg Mapping | Special Handling |
|---|---|---|---|---|
| `lsl leftReg.w, leftReg.w, rightReg.w` | 32-bit left shift | `lsl(dst, .vreg(left), .vreg(right))` | dst = left VReg | Width=word |
| `lsl leftReg.x, leftReg.x, rightReg.x` | 64-bit left shift | `lsl(dst, .vreg(left), .vreg(right))` | dst = left VReg | Width=dword |
| `lsl reg.x, reg.x, #N` | Left shift by immediate (pointer scaling: `lsl #1/2/3`) | `lsl(dst, .vreg(reg), .imm(Int64(N)))` | dst = reg VReg | Used for elemSize 2/4/8 scaling |
| `lsr leftReg.w, leftReg.w, rightReg.w` | 32-bit logical right shift (unsigned) | `lsr(dst, .vreg(left), .vreg(right))` | dst = left VReg | Used when `shiftIsSigned == false` (unsigned result type) |
| `lsr leftReg.x, leftReg.x, rightReg.x` | 64-bit logical right shift | `lsr(dst, .vreg(left), .vreg(right))` | dst = left VReg | |
| `lsr reg.x, reg.x, #N` | Right shift by immediate | `lsr(dst, .vreg(reg), .imm(Int64(N)))` | dst = reg VReg | |
| `asr leftReg.w, leftReg.w, rightReg.w` | 32-bit arithmetic right shift (signed) | `asr(dst, .vreg(left), .vreg(right))` | dst = left VReg | Used when `shiftIsSigned == true` |
| `asr leftReg.x, leftReg.x, rightReg.x` | 64-bit arithmetic right shift | `asr(dst, .vreg(left), .vreg(right))` | dst = left VReg | |
| `asr reg.x, reg.x, #63` | Sign-extend to 128-bit hi half (int128) | `asr(dst, .vreg(reg), .imm(63))` | dst = reg VReg | Used in `emitInt128Expr` for sign extension |

**Signedness determination:** For `>>`, the codegen checks the promoted
left operand's signedness (`intPromote(leftType).isSigned`). This logic
moves to the IR builder; the choice between `asr` and `lsr` IRInst is made
at build time.

---

## 5. Comparisons

| Existing Pattern | Context | IR Instruction | VReg Mapping | Special Handling |
|---|---|---|---|---|
| `cmp leftReg.w, rightReg.w` | 32-bit integer comparison | `cmp(.vreg(left), .vreg(right))` | Sets implicit pflag VReg | Width=word (w registers) |
| `cmp leftReg.x, rightReg.x` | 64-bit integer comparison | `cmp(.vreg(left), .vreg(right))` | Sets implicit pflag VReg | Width=dword (x registers) |
| `cmp reg.x, #0` | Comparison with zero (e.g., `!expr`) | `cmp(.vreg(reg), .imm(0))` | pflag VReg | |
| `cset leftReg.x, eq` | Set result to 1 if equal | `cset(dst, .eq)` | dst = left VReg (result overwrites left operand) | Reads the pflag set by preceding `cmp` |
| `cset leftReg.x, ne` | Set result to 1 if not equal | `cset(dst, .ne)` | dst = left VReg | |
| `cset leftReg.x, lt` / `cset leftReg.x, lo` | Signed/unsigned less-than | `cset(dst, .lt)` / `cset(dst, .lo)` | dst = left VReg | Condition depends on `isUnsignedCmp` |
| `cset leftReg.x, le` / `cset leftReg.x, ls` | Signed/unsigned less-or-equal | `cset(dst, .le)` / `cset(dst, .ls)` | dst = left VReg | |
| `cset leftReg.x, gt` / `cset leftReg.x, hi` | Signed/unsigned greater-than | `cset(dst, .gt)` / `cset(dst, .hi)` | dst = left VReg | |
| `cset leftReg.x, ge` / `cset leftReg.x, hs` | Signed/unsigned greater-or-equal | `cset(dst, .ge)` / `cset(dst, .hs)` | dst = left VReg | |
| `csetm reg.x, eq` | Set all bits (0 or -1) — vector comparisons | `csetm(dst, .eq)` | dst = reg VReg | Used in vector element-wise comparisons |
| `fcmp sReg, sReg` / `fcmp dReg, dReg` | Float/double comparison | `fcmp(.vreg(left), .vreg(right))` | pflag VReg (.fp operands) | |
| `fcmp fpReg, #0.0` | FP comparison with zero (if/while conditions) | `fcmp(.vreg(reg), .immF(0.0))` — **Gap:** fcmp takes Operand, but `#0.0` is an immediate. May need `fcmpImm` or use `fmov` to a zero reg first. | pflag VReg | **Gap:** `fcmp` src2 is `Operand`; `#0.0` needs `immF` operand support in fcmp or a separate case. |

**pflag VReg:** The `cmp`/`fcmp` instructions set condition flags. In the
IR, a `VReg(kind: .pflag)` represents the flag state. `cset`/`csetm` read
this pflag VReg. The lowering pass ensures `cmp` and `cset` are adjacent
(no intervening flag-clobbering instructions). The IR builder should
thread the pflag VReg from `cmp` to `cset`.

**Signed vs unsigned condition codes:** The codegen computes
`isUnsignedCmp` based on type promotion rules (C99 6.3.1.8). This
determines whether `lt`/`le`/`gt`/`ge` (signed) or `lo`/`ls`/`hi`/`hs`
(unsigned) are used. This decision is made at IR build time.

**32-bit signed comparison special case:** For `.le` with 32-bit signed
operands, the codegen emits `sxtw` on both operands before `cmp` in x
form, to handle the case where one is unsigned 32-bit and the other signed
32-bit (promoted to unsigned). The IR builder must replicate this logic.

---

## 6. Data Movement

| Existing Pattern | Context | IR Instruction | VReg Mapping | Special Handling |
|---|---|---|---|---|
| `mov reg.x, reg2.x` | 64-bit register copy | `mov(dst, .vreg(src))` | dst, src = VReg(.gp) | |
| `mov reg.w, reg2.w` | 32-bit register copy (truncates) | `mov(dst, .vreg(src))` | dst, src = VReg(.gp) | Width=word. `mov w` zero-extends to 64 bits. |
| `mov reg.x, #imm` | Small immediate load (≤0xFFFF) | `mov(dst, .imm(Int64(imm)))` or `loadImm(dst, Int64(imm))` | dst = new VReg | For values fitting in a single `mov`/`movn` |
| `movz reg, #imm` + `movk reg, #imm, lsl #16/32/48` | Large immediate load (via `emitLoadImm`) | `loadImm(dst, Int64(value))` | dst = new VReg | The lowering pass expands to movz+movk sequence. |
| `movn reg, #imm` | Negative immediate (single 16-bit chunk of ~v) | `loadImm(dst, Int64(value))` | dst = new VReg | Lowering chooses `movn` when beneficial |
| `mov x16, #value` (scratch immediate load) | Loading elemSize, offset, mask into scratch | `loadImm(dst, Int64(value))` | dst = scratch VReg | x16/x17 are unmanaged scratch in existing codegen; in IR they become fresh VRegs |
| `mov reg, #0` | Zero a register | `mov(dst, .imm(0))` | dst = VReg | |
| `mov reg, sp` | Capture stack pointer (alloca, VLA) | `mov(dst, .vreg(spVReg))` — **Gap:** no `sp` operand. May need `Operand.vreg(spVReg)` or a special case. | dst = VReg | **Gap:** sp is not a VReg in the current IR. |
| `mov x29, sp` | Prologue: set frame pointer | `mov(dst, .vreg(spVReg))` | dst = fp VReg | |
| `mov x20, x18` | Nested function: save static chain | `mov(dst, .vreg(x18VReg))` | dst = VReg for x20 | |
| `mov x18, x29` | Call to nested function: pass parent fp | `mov(dst, .vreg(fpVReg))` | dst = VReg for x18 | |
| `mov w0, reg.w` / `mov x0, reg.x` | Move result to return register | `mov(dst, .vreg(src))` | dst = VReg mapped to x0 | |
| `fmov sN, sM` / `fmov dN, dM` | FP register copy | `fmov(dst, .vreg(src))` | dst, src = VReg(.fp) | |
| `fmov s0, sN` / `fmov d0, dN` | Move FP result to return register | `fmov(dst, .vreg(src))` | dst = VReg(.fp) mapped to s0/d0 | |
| `fmov sN, #1.0` | Load FP immediate 1.0 (pre/post inc/dec FP) | `loadFImm(dst, 1.0, isFloat: true)` | dst = VReg(.fp) | |
| `fmov w16, sN` / `fmov x16, dN` | FP→int bit pattern move (signbit, copysign) | **Gap:** `fmov` crosses banks (fp→gp). Needs `fmovToInt(dst_gp, .vreg(src_fp))` | dst = VReg(.gp), src = VReg(.fp) | **Gap:** IR `fmov` doesn't distinguish direction of cross-bank move. |

**Immediate encoding:** `emitLoadImm` is the most-called helper (line
12321). It handles the mov/movn/movz/movk decision. In the IR, `loadImm`
is a single IRInst; the lowering pass performs the same encoding
optimization. All call sites that currently use `emitLoadImm(reg, value)`
become `loadImm(dst, Int64(value))`.

---

## 7. Sign/Zero Extension

| Existing Pattern | Context | IR Instruction | VReg Mapping | Special Handling |
|---|---|---|---|---|
| `sxtw reg.x, reg.w` | Sign-extend 32-bit to 64-bit (signed int/enum) | `sxtw(dst, .vreg(src))` | dst = src VReg | Most common extension; used when 32-bit signed int meets 64-bit context |
| `sxtb reg.x, reg.w` | Sign-extend byte (signed char) | `sxtb(dst, .vreg(src))` | dst = src VReg | After `ldrb` of signed char |
| `sxth reg.x, reg.w` | Sign-extend halfword (signed short) | `sxth(dst, .vreg(src))` | dst = src VReg | After `ldrh` of signed short |
| `uxtb reg.x, reg.w` | Zero-extend byte | `uxtb(dst, .vreg(src))` | dst = src VReg | **Gap:** Used in return narrowing (`uxtb w0, w0`); less common |
| `uxth reg.x, reg.w` | Zero-extend halfword | `uxth(dst, .vreg(src))` | dst = src VReg | **Gap:** Used in return narrowing |
| `mov wReg, wReg` | Zero-extend 32→64 (unsigned int): `mov wN, wN` clears upper 32 bits | `mov(dst, .vreg(src))` with Width=word | dst = src VReg | Implicit zero-extension via `w` register write |
| `sbfx reg.x, reg.x, #0, #width` | Sign-extend from bitfield width (signed bitfield read) | `sbfx(dst, .vreg(src), lsb: 0, width: bitWidth)` | dst = src VReg | Used in `emitMemberExpr` bitfield read and `storeExprResult` bitfield write |
| `lsr reg.x, reg.x, #bitOffset` | Shift bitfield to bit 0 (bitfield read) | `lsr(dst, .vreg(src), .imm(Int64(bitOffset)))` | dst = src VReg | Part of bitfield extraction sequence |

**Implicit extension in loads:** `emitLoad` and `emitLoadFromFrame` emit
`ldrb`+`sxtb` (signed char) or `ldrb` (unsigned char) etc. The sign/zero
extension is part of the load sequence. In the IR, the `load` IRInst has a
`signed: Bool` parameter that drives this: `load(dst, addr, offset,
width: .byte, signed: true)` → `ldrsb`; `signed: false` → `ldrb`.

---

## 8. Memory Access

| Existing Pattern | Context | IR Instruction | VReg Mapping | Special Handling |
|---|---|---|---|---|
| `ldr reg.x, [reg.x]` | 64-bit load (dword, pointer) | `load(dst, .vreg(addr), offset: 0, width: .dword, signed: false)` | dst = VReg, addr = VReg | |
| `ldr reg.w, [reg.x]` | 32-bit load (int/uint) | `load(dst, .vreg(addr), offset: 0, width: .word, signed: false)` | dst, addr = VReg | No sign extension for 32-bit (upper bits undefined, cleared by w usage) |
| `ldrb reg.w, [reg.x]` | Unsigned byte load | `load(dst, .vreg(addr), 0, .byte, signed: false)` | dst, addr = VReg | |
| `ldrsb reg.w, [reg.x]` | Signed byte load (sign-extends to 32) | `load(dst, .vreg(addr), 0, .byte, signed: true)` | dst, addr = VReg | Codegen follows with `sxtb reg.x, reg.w` for 64-bit context |
| `ldrh reg.w, [reg.x]` | Unsigned halfword load | `load(dst, .vreg(addr), 0, .halfword, signed: false)` | dst, addr = VReg | |
| `ldrsh reg.w, [reg.x]` | Signed halfword load | `load(dst, .vreg(addr), 0, .halfword, signed: true)` | dst, addr = VReg | Followed by `sxth` if needed |
| `ldr sN, [reg.x]` | Float load (32-bit FP) | `load(dst, .vreg(addr), 0, .word, signed: false)` | dst = VReg(.fp) | Width=word but FP register. **Consider:** FP loads may need distinct handling or a `width: .float` case. |
| `ldr dN, [reg.x]` | Double load (64-bit FP) | `load(dst, .vreg(addr), 0, .dword, signed: false)` | dst = VReg(.fp) | Width=dword but FP register |
| `ldr reg.x, [x29, #offset]` | Load from frame (small offset) | `load(dst, .vreg(fp), offset, width, signed)` | dst = VReg, fp = frame pointer VReg | |
| `ldr reg.x, [x29, x16]` | Load from frame (large offset, via scratch) | `load(dst, .vreg(fp), offset, width, signed)` | dst = VReg; lowering handles large offset via scratch | The IR load carries the integer offset; lowering decides immediate vs scratch |
| `ldr reg.x, [reg.x, #offset]` | Load with displacement | `load(dst, .vreg(addr), offset, width, signed)` | dst, addr = VReg | |
| `str reg.x, [reg.x]` | 64-bit store | `store(.vreg(src), .vreg(addr), offset: 0, width: .dword)` | src, addr = VReg | |
| `str reg.w, [reg.x]` | 32-bit store | `store(.vreg(src), .vreg(addr), 0, .word)` | src, addr = VReg | |
| `strb reg.w, [reg.x]` | Byte store | `store(.vreg(src), .vreg(addr), 0, .byte)` | src, addr = VReg | |
| `strh reg.w, [reg.x]` | Halfword store | `store(.vreg(src), .vreg(addr), 0, .halfword)` | src, addr = VReg | |
| `str sN, [reg.x]` / `str dN, [reg.x]` | FP store | `store(.vreg(src), .vreg(addr), 0, width)` | src = VReg(.fp) | FP width |
| `str reg.x, [x29, #offset]` | Store to frame (small offset) | `store(.vreg(src), .vreg(fp), offset, width)` | src = VReg, fp = fp VReg | |
| `str reg.x, [sp, #-16]!` | Push to stack (pre-index) | `store(.vreg(src), .vreg(sp), offset: -16, width: .dword)` + implicit sp adjust | src = VReg; sp = VReg | **Special:** Pre-indexed store updates sp. The IR `store` has a fixed offset; sp adjustment must be separate. Consider adding `push`/`pop` pseudo-ops or modeling sp updates explicitly. |
| `ldr reg.x, [sp], #16` | Pop from stack (post-index) | `load(dst, .vreg(sp), 0, .dword, false)` + sp adjust | dst = VReg; sp = VReg | Post-index; sp adjustment separate |
| `str reg.x, [sp, #offset]` | Store to sp-relative temp | `store(.vreg(src), .vreg(sp), offset, .dword)` | src = VReg; sp = VReg | Used for arg temp saves |
| `ldr reg.x, [sp, #offset]` | Load from sp-relative temp | `load(dst, .vreg(sp), offset, .dword, false)` | dst = VReg; sp = VReg | |
| `str wzr, [reg.x, #offset]` | Store zero (zero-fill array init) | `store(.imm(0), .vreg(addr), offset, .byte)` | addr = VReg | wzr → `.imm(0)` |
| `ldrh w16, [reg, #offset]` / `strh w16, [reg, #offset]` | 2-byte load/store (struct copy remainder) | `load`/`store` with `.halfword` | | |
| `ldrb w16, [reg, #offset]` / `strb w16, [reg, #offset]` | 1-byte load/store (struct copy remainder) | `load`/`store` with `.byte` | | |

**FP load/store width issue:** The `Width` enum maps to integer load/store
sizes (byte/halfword/word/dword). FP loads (`ldr sN`/`ldr dN`) use the same
mnemonics as integer loads but target FP registers. The IR `load`/`store`
cases produce `ldr`/`str` which are correct mnemonics; the register bank
(gp vs fp) is determined by the VReg's `kind`. The lowering must use `sN`/
`dN` when `dst.kind == .fp`.

**Stack push/pop modeling:** The existing codegen heavily uses
`str [sp, #-16]!` (push) and `ldr [sp], #16` (pop) for saving values across
calls and subexpressions. The IR `store`/`load` have fixed offsets and
don't model pre/post-indexing. The IR builder should emit explicit
`addrr(sp, sp, -16)` + `store(val, sp, 0)` for pushes, and
`load(val, sp, 0)` + `addrr(sp, sp, 16)` for pops. Alternatively, add
`push`/`pop` pseudo-IRInst cases.

---

## 9. Address Computation

| Existing Pattern | Context | IR Instruction | VReg Mapping | Special Handling |
|---|---|---|---|---|
| `add reg, x29, #offset` | Address of local variable (small offset, ≤4095) | `addrr(dst, base: .vreg(fp), offset: offset)` | dst = new VReg | |
| `emitLoadImm("x17", offset)` + `add reg, x29, x17` | Address of local (large offset >4095) | `addrr(dst, base: .vreg(fp), offset: offset)` | dst = new VReg; lowering handles large offset | The IR addrr carries the integer offset; lowering uses scratch if needed |
| `add reg, x20, #offset` | Parent local (nested function, via x20) | `addrr(dst, base: .vreg(parentFp), offset: offset)` | dst = new VReg | parentFp = VReg for x20 |
| `adrp reg, label@PAGE` + `add reg, reg, label@PAGEOFF` | String literal / global address | `adrp(dst, symbol: label)` + `addSymbol(dst, base: .vreg(dst), symbol: label)` | dst = new VReg | Two IRInst; could be combined into `Operand.global(label)` when only address is needed |
| `adrp reg, _name@PAGE` + `add reg, reg, _name@PAGEOFF` | Defined global variable address | `adrp(dst, "_name")` + `addSymbol(dst, .vreg(dst), "_name")` | dst = new VReg | |
| `adrp reg, _name@GOTPAGE` + `ldr reg, [reg, _name@GOTPAGEOFF]` | External global via GOT | `adrp(dst, "_name@GOT")` + `load(dst2, .vreg(dst), 0, .dword, false)` | dst2 = new VReg | Two-step: adrp + load from GOT |
| `adr reg, label` | Computed goto (&&label) | `adr(dst, symbol: label)` | dst = new VReg | PC-relative address of a local label |
| `add baseReg, baseReg, indexReg, lsl #N` | Array subscript: base + index << N (elemSize = 2^N) | `add(dst, .vreg(base), .vreg(index))` with shift, or `addrr` if index already scaled | dst = baseReg VReg | **Gap:** The `add reg, reg, reg, lsl #N` form (shifted register operand) is not directly representable in `add` IRInst which takes plain Operands. Needs either a `lsl` IRInst before the `add`, or an `addShifted` case. |
| `add baseReg, baseReg, indexReg` | Array subscript (elemSize = 1) | `add(dst, .vreg(base), .vreg(index))` | dst = base VReg | |
| `mov x16, #elemSize` + `madd baseReg, indexReg, x16, baseReg` | Array subscript (non-power-of-2 elemSize) | `loadImm(tmp, Int64(elemSize))` + `madd(dst, .vreg(index), .vreg(tmp), .vreg(base))` | dst = base VReg; tmp = scratch VReg | |
| `add reg, reg, #memberOffset` | Member access offset (small) | `addrr(dst, base: .vreg(base), offset: memberOffset)` or `add(dst, .vreg(base), .imm(Int64(offset)))` | dst = base VReg | |
| `emitLoadImm("x16", offset)` + `add reg, reg, x16` | Member access offset (large) | `addrr(dst, .vreg(base), offset: offset)` | dst = base VReg | Lowering uses scratch for large offsets |

**Shifted register in `add`:** The ARM64 `add` instruction supports a
shifted second operand (`add x0, x1, x2, lsl #3`). This is used extensively
for array subscript address computation. The IR `add` case takes plain
`Operand`s and cannot represent the shift. Options:
1. Emit an `lsl` IRInst before the `add` (extra instruction, but simple)
2. Add an `addShifted(dst, src1, src2, shiftAmount)` case to IRInst
3. Let the lowering pass pattern-match `lsl` + `add` and fuse them

---

## 10. Control Flow

| Existing Pattern | Context | IR Instruction | VReg Mapping | Special Handling |
|---|---|---|---|---|
| `b label` | Unconditional branch (if end, loop back, switch default) | `b(label: "L_...")` | — | Terminator of a basic block |
| `b.eq label` / `b.ne label` / `b.lt label` etc. | Conditional branch (switch case comparison) | `bcond(cond: .eq/.ne/.lt/..., label: "L_...")` | — | Used in switch case comparisons |
| `cbz reg, label` | Compare and branch if zero (if/while/for condition) | `cbz(.vreg(reg), label: "L_...")` | src = VReg | Most common control flow pattern |
| `cbnz reg, label` | Compare and branch if not zero (do-while, logicOr) | `cbnz(.vreg(reg), label: "L_...")` | src = VReg | |
| `tbz reg, #bit, label` | Test bit and branch if zero (__builtin_mul_overflow_p sign check) | `tbz(.vreg(reg), bit: bit, label: "L_...")` | src = VReg | |
| `tbnz reg, #bit, label` | Test bit and branch if not zero | `tbnz(.vreg(reg), bit: bit, label: "L_...")` | src = VReg | |
| `ret` | Function return (epilogue) | `ret` | — | Terminator |
| `bl _funcName` | Direct function call | `call(target: "funcName", args: [Operand])` | Result in new VReg (mapped to x0/s0/d0 by lowering) | |
| `blr reg` | Indirect function call (function pointer) | `callIndirect(target: .vreg(funcPtr), args: [Operand])` | Result in new VReg | |
| `bl _abort` | Builtin trap / abort | `call(target: "abort", args: [])` | | |
| `"L_func_N:"` (label emission) | Basic block start | `label("L_func_N")` | — | Marks basic block boundary; not a real instruction |

**fcmp + b.eq for FP conditions:** When the condition is floating-point,
the codegen emits `fcmp fpReg, #0.0` + `b.eq elseLabel` instead of `cbz`.
In the IR, this is `fcmp(.vreg(fpReg), .immF(0.0))` + `bcond(.eq, elseLabel)`.

**Basic block construction:** The IR builder should create a new
`BasicBlock` at each `label` IRInst and at each branch target. Branch
instructions are block terminators. The `preds`/`succs` lists are
populated during construction or in a post-pass.

---

## 11. Prologue/Epilogue

| Existing Pattern | Context | IR Instruction | VReg Mapping | Special Handling |
|---|---|---|---|---|
| `stp x29, x30, [sp, #-16]!` | Prologue: save fp, lr (non-nested) | `stp(src1: .vreg(fp), src2: .vreg(lr), addr: .vreg(sp), offset: -16)` | fp, lr = VRegs mapped to x29, x30; sp = VReg | Pre-indexed store pair; sp decremented by 16 |
| `stp x29, x30, [sp, #-32]!` + `str x18, [sp, #16]` | Prologue: nested function (save fp, lr, x18) | `stp(...)` + `store(.vreg(x18), .vreg(sp), 16, .dword)` | x18 = VReg | Extra 16 bytes for x18 (static chain) |
| `mov x29, sp` | Prologue: set frame pointer | `mov(dst: .vreg(fp), src: .vreg(sp))` | fp = VReg | |
| `sub sp, sp, #frameSize` | Prologue: allocate frame (patched) | `addrr(dst: .vreg(sp), base: .vreg(sp), offset: -frameSize)` or a dedicated `frameAlloc` | sp = VReg | Frame size patched after body emission; in IR, `IRFunction.frameSize` is known after building |
| `str x8, [x29, #offset]` | Prologue: save indirect return pointer (x8) | `store(.vreg(x8), .vreg(fp), offset, .dword)` | x8 = VReg | For functions returning >16-byte non-HFA structs |
| `mov x16, sp` + `str x16, [x29, #offset]` | Prologue: save post-frame sp for VLA deallocation | `mov(dst: tmp, src: .vreg(sp))` + `store(.vreg(tmp), .vreg(fp), offset, .dword)` | tmp = scratch VReg | |
| `str argReg, [x29, #offset]` | Prologue: store parameter to local slot | `store(.vreg(argVReg), .vreg(fp), offset, width)` | argVReg = VReg for x0-x7/d0-d7 | Parameters arrive in arg registers, stored to frame |
| `mov sp, x29` | Epilogue: restore sp from fp | `mov(dst: .vreg(sp), src: .vreg(fp))` | sp, fp = VReg | |
| `ldp x29, x30, [sp], #16` | Epilogue: restore fp, lr (non-nested) | `ldp(dst1: .vreg(fp), dst2: .vreg(lr), addr: .vreg(sp), offset: 0)` + sp adjust | fp, lr = VReg; sp = VReg | Post-indexed load pair; sp incremented by 16 |
| `ldr x18, [sp, #16]` + `ldp x29, x30, [sp], #32` | Epilogue: nested function (restore x18, fp, lr) | `load(.vreg(x18), .vreg(sp), 16, .dword, false)` + `ldp(...)` + sp adjust | x18 = VReg | Extra 16 bytes |
| `ret` | Epilogue: return | `ret` | — | |
| `mov w0, #0` + epilogue | Default return (fallthrough) | `mov(dst: .vreg(x0), .imm(0))` + `ret` | x0 = VReg | |

**Callee-saved register save/restore:** When `regAlloc.allocCalleeSaved()`
is used, the codegen saves/restores those registers in the
prologue/epilogue. The `calleeSavedSaveOffsets` array tracks which
registers need saving. In the IR, `IRFunction.usedCalleeSaved` records
this set. The lowering pass emits `stp`/`ldp` pairs for callee-saved
registers that the allocator assigned.

**Frame size patching:** The existing codegen emits a placeholder
`sub sp, sp, #0 ; FRAME_SIZE_PLACEHOLDER` and patches it after the body.
In the IR, `IRFunction.frameSize` is set after building all blocks, and
the lowering pass emits the prologue with the final size.

**Parameter spilling:** Parameters arrive in x0-x7 (integer) or d0-d7
(FP). The codegen stores them to frame slots at function entry. In the IR,
`IRFunction.args` holds `(VReg, Width, Bool)` tuples. The prologue lowering
emits `store` IRInsts for each parameter from its arg VReg to its slot.
HFA parameters use multiple FP registers; __int128 uses two GP registers.

---

## 12. Struct/Aggregate Handling

| Existing Pattern | Context | IR Instruction | VReg Mapping | Special Handling |
|---|---|---|---|---|
| `ldr x16, [src, #off]` + `str x16, [dst, #off]` (loop, 8 bytes at a time) | Struct copy (bulk copy via 8-byte chunks) | Sequence of `load` + `store` IRInsts with `.dword` width | src, dst = VReg (addresses); x16 = scratch VReg | `emitStructCopyToField` does this loop. In IR, emit N load/store pairs. |
| `ldr w16, [src, #off]` + `str w16, [dst, #off]` | Struct copy (4-byte remainder) | `load` + `store` with `.word` | | |
| `ldrh w16, [src, #off]` + `strh w16, [dst, #off]` | Struct copy (2-byte remainder) | `load` + `store` with `.halfword` | | |
| `ldrb w16, [src, #off]` + `strb w16, [dst, #off]` | Struct copy (1-byte remainder) | `load` + `store` with `.byte` | | |
| `str x0, [dst]` + `str x1, [dst, #8]` | Small struct return (≤16 bytes, in x0/x1) | `store(.vreg(x0), .vreg(dst), 0, .dword)` + `store(.vreg(x1), .vreg(dst), 8, .dword)` | x0, x1 = VReg; dst = address VReg | |
| `str sN, [dst, #memberOff]` / `str dN, [dst, #memberOff]` | HFA return (store s0-s3/d0-d3 to dest) | `store(.vreg(fpN), .vreg(dst), memberOff, .word/.dword)` | fpN = VReg(.fp) | |
| `ldr sN, [src, #memberOff]` / `ldr dN, [src, #memberOff]` | HFA arg passing / return loading | `load(.vreg(fpN), .vreg(src), memberOff, .word/.dword, false)` | fpN = VReg(.fp) | |
| `add x8, x29, #offset` (indirect return buffer) | Large struct return (>16 bytes, non-HFA) | `addrr(dst: .vreg(x8), base: .vreg(fp), offset: offset)` | x8 = VReg | Caller allocates temp, passes address in x8 |
| `ldr x0, [srcAddr]` / `ldr x1, [srcAddr, #8]` | Return large struct: copy from src to x8 buffer | `load` + `store` sequence | | Same as struct copy, dst = x8 buffer |
| `sub sp, sp, #alignedSize+16` + `str x19, [sp, #alignedSize]` + `mov x19, sp` | Temp struct storage for call-returning-struct used as value | `addrr(sp, sp, -(size+16))` + `store(.vreg(x19), .vreg(sp), size, .dword)` + `mov(.vreg(x19), .vreg(sp))` | x19 = callee-saved VReg | Used in `emitAddr` for call-returning-struct, `emitMemberExpr` for `fr().member` |

**HFA (Homogeneous Floating-point Aggregate):** Structs with 1-4 float or
double members are passed/returned in FP registers (s0-s3/d0-d3). The
codegen's `isHFA()` function detects this. In the IR, this is metadata on
the struct type. The IR builder must emit `load`/`store` IRInsts for each
HFA member when passing/returning.

**Struct by-value argument passing:** Small structs (≤8 bytes) are loaded
into a single GP register. Medium structs (9-16 bytes) use two GP
registers. Large structs (>16 bytes) are copied to the stack. The IR
builder must replicate this ABI logic when building `call`/`callIndirect`
argument lists.

---

## 13. Complex Type Handling

Complex types (`_Complex float`, `_Complex double`, `_Complex int`) are
stored as two consecutive parts (real at offset 0, imaginary at offset
partSize). They cannot fit in a single register, so `emitExpr` returns the
*address* of the complex value (like structs).

| Existing Pattern | Context | IR Instruction | VReg Mapping | Special Handling |
|---|---|---|---|---|
| `ldr realReg, [addr]` + `ldr imagReg, [addr, #partSize]` | Load complex real/imag parts | `load(dst1, .vreg(addr), 0, width, signed)` + `load(dst2, .vreg(addr), partSize, width, signed)` | dst1, dst2 = VReg (real, imag) | partSize = 4 (float) or 8 (double/int) |
| `str realReg, [addr]` + `str imagReg, [addr, #partSize]` | Store complex parts | `store(.vreg(real), .vreg(addr), 0, width)` + `store(.vreg(imag), .vreg(addr), partSize, width)` | real, imag = VReg | |
| `fneg fpReal, fpReal` + `fneg fpImag, fpImag` | Complex negation (`-c`) | `fneg(dst_real, .vreg(real))` + `fneg(dst_imag, .vreg(imag))` | dst_real, dst_imag = VReg(.fp) | Both parts negated |
| `fneg fpImag, fpImag` | Complex conjugate (`~c`) | `fneg(dst_imag, .vreg(imag))` | dst_imag = VReg(.fp) | Only imaginary part negated |
| `neg realReg, realReg` + `neg imagReg, imagReg` | Integer complex negation | `sub(dst_real, .imm(0), .vreg(real))` + `sub(dst_imag, .imm(0), .vreg(imag))` | | Integer complex uses `neg` (→ `sub` from 0) |
| `neg imagReg, imagReg` | Integer complex conjugate | `sub(dst_imag, .imm(0), .vreg(imag))` | | Only imaginary |
| `fadd/fsub/fmul/fdiv` on real and imag parts | Complex arithmetic (element-wise for add/sub, cross for mul/div) | Multiple `fadd`/`fsub`/`fmul`/`fdiv` IRInsts | | Complex multiply: (a+bi)(c+di) = (ac-bd)+(ad+bc)i requires 4 muls + 1 sub + 1 add. Complex divide requires denominator computation. |
| `ldr partReg, [x29, #partOff]` | `__real__` / `__imag__` on local complex | `load(dst, .vreg(fp), partOff, width, signed)` | dst = VReg | partOff = baseOff + (imagPart ? partSize : 0) |
| `ldr partReg, [addrReg]` / `ldr partReg, [addrReg, #partSize]` | `__real__` / `__imag__` on addressable complex | `load(dst, .vreg(addr), 0/partSize, width, signed)` | dst = VReg | |
| `fmov fpN, #0.0` / `mov reg, #0` | `__imag__` on non-complex (returns 0) | `loadFImm(dst, 0.0, isFloat)` or `mov(dst, .imm(0))` | dst = VReg | |

**Complex as HFA:** FP complex types are HFAs with 2 members. They are
passed/returned in 2 FP registers (s0-s1/d0-d1). Integer complex types
are passed as small structs in GP registers.

---

## 14. Vector Type Handling

Vector types (`vector_size(N)`) are arrays of elements operated on
element-wise. Like structs, `emitExpr` returns the *address* of the
vector data.

| Existing Pattern | Context | IR Instruction | VReg Mapping | Special Handling |
|---|---|---|---|---|
| Element-wise loop: `ldr elem, [src, #i*elemSize]` + op + `str result, [dst, #i*elemSize]` | Vector op Vector (element-wise binary) | Sequence of `load` + arith + `store` per element | src, dst = VReg (addresses); elem = scratch VReg | The loop is unrolled at build time. Each element is a separate load-op-store sequence. |
| `fadd arithReg, ldReg17, ldReg` | Vector element FP add | `fadd(dst, .vreg(left_elem), .vreg(right_elem))` | dst = scratch VReg(.fp) | |
| `add arithReg, ldReg17, ldReg` | Vector element integer add | `add(dst, .vreg(left_elem), .vreg(right_elem))` | dst = scratch VReg | |
| `sdiv`/`udiv`/`msub` per element | Vector integer div/mod | `sdiv`/`udiv`/`msub` IRInsts per element | | |
| `cmp elem, elem` + `csetm result, cond` | Vector comparison (produces mask: 0 or all-1s) | `cmp` + `csetm` per element | | Vector comparisons use `csetm` (all bits), not `cset` (0/1) |
| `fcmp elem, elem` + `csetm result, cond` | Vector FP comparison | `fcmp` + `csetm` per element | | |
| `ldrsb/ldrsh/ldr/ldr` per element (signed) | Signed element load | `load(dst, addr, offset, width, signed: true)` | | elemType.isSigned determines load signedness |
| `ldrb/ldrh/ldr/ldr` per element (unsigned) | Unsigned element load | `load(dst, addr, offset, width, signed: false)` | | |
| Scalar broadcast: load scalar once, apply to all elements | Vector op Scalar | `load` scalar + per-element op with scalar operand | scalar = VReg; broadcast by reusing same operand | |
| `neg`/`mvn` per element | Vector unary negation/bitwise-NOT | `sub(dst, .imm(0), .vreg(elem))` / `mvn(dst, .vreg(elem))` per element | | |
| `add resultReg, x29, #offset` | Allocate vector result in local frame | `addrr(dst, .vreg(fp), offset)` | dst = VReg (result address) | Vectors are allocated in the frame, not on the dynamic stack |

**__int128 vector elements:** When `elemSize == 16` and op is `==`/`!=`,
special comparison logic compares both lo and hi halves, producing a
16-byte mask. This is a complex sequence of `ldr` + `cmp` + `cset` +
`orr`/`and` + `csetm` per element. The IR builder must replicate this.

**Register pressure in vector loops:** The element-wise loops save
addresses on the stack (`str [sp, #-16]!`) and use x9/x16/x17 as scratch
within the loop. In the IR, these become fresh VRegs per use, and the
allocator handles assignment.

---

## 15. __int128 Handling

`__int128` and `unsigned __int128` are 16-byte values stored in two
consecutive 8-byte slots (lo at offset 0, hi at offset 8). `emitExpr`
returns the *address* of the int128 value (like structs/complex).

| Existing Pattern | Context | IR Instruction | VReg Mapping | Special Handling |
|---|---|---|---|---|
| `ldr x16, [src]` + `str x16, [dst]` + `ldr x16, [src, #8]` + `str x16, [dst, #8]` | Int128 copy (lo + hi) | `load(tmp, .vreg(src), 0, .dword, false)` + `store(.vreg(tmp), .vreg(dst), 0, .dword)` × 2 | tmp = scratch VReg; src, dst = address VRegs | |
| `ldr lo, [src]` + `ldr hi, [src, #8]` | Load int128 parts | `load(lo, .vreg(src), 0, .dword, false)` + `load(hi, .vreg(src), 8, .dword, false)` | lo, hi = VReg | |
| `adds lo, lo, rhs_lo` + `adc hi, hi, rhs_hi` | Int128 add (with carry) | **Gap:** No `adds`/`adc` in IR. Needs `addCC`/`adc` or a combined `add128` case. | lo, hi = VReg | **Gap:** Multi-word arithmetic with carry is not representable. |
| `subs lo, lo, rhs_lo` + `sbc hi, hi, rhs_hi` | Int128 sub (with borrow) | **Gap:** No `subs`/`sbc` in IR. | | **Gap** |
| `mul t1, lo_a, lo_b` + `umulh t1, lo_a, lo_b` + `madd t1, hi_a, lo_b, t1` + `madd t1, lo_a, hi_b, t1` | Int128 multiply (4 muls + adds) | `mul` + `umulh` + `madd` + `madd` | **Gap:** `umulh` (unsigned multiply high) not in IR. | **Gap:** Need `umulh` and `smulh` IRInst cases. |
| `and`/`orr`/`eor` on lo and hi halves | Int128 bitwise ops | `and`/`orr`/`eor` × 2 (one per half) | | Straightforward |
| `mvn lo, lo` + `mvn hi, hi` | Int128 bitwise NOT | `mvn` × 2 | | |
| `asr lo, lo, #63` + `mov hi, xzr` | Sign/zero-extend to 128 bits (hi = sign bit replicated or 0) | `asr(dst, .vreg(lo), .imm(63))` for signed, `mov(dst, .imm(0))` for unsigned | | |
| `cmp hi_a, hi_b` + `b.ne` + `cmp lo_a, lo_b` + `b.eq` | Int128 comparison (compare hi first, then lo) | `cmp` + `bcond` + `cmp` + `bcond` sequence | | Two-level comparison |
| `str x0, [tmpOff]` + `str x1, [tmpOff+8]` (return) | Int128 return (x0=lo, x1=hi) | `store(.vreg(x0), .vreg(tmp), 0, .dword)` + `store(.vreg(x1), .vreg(tmp), 8, .dword)` | x0, x1 = VReg | |
| `emitInt128ShiftLeft` / `emitInt128ShiftRight` | Int128 shifts (complex multi-instruction sequences) | **Gap:** No 128-bit shift in IR. Would be a sequence of `lsl`/`lsr`/`asr` + `orr` with temporaries. | | **Gap:** Complex lowering sequences for 128-bit shifts. |

**Gaps for __int128:** The IR currently lacks:
- `adds`/`subs` (add/subtract with carry flag output)
- `adc`/`sbc` (add/subtract with carry input)
- `umulh`/`smulh` (unsigned/signed multiply high)

These are needed to faithfully lower __int128 arithmetic. Alternatively,
int128 operations could be represented as macro/sequence markers in the IR
that the lowering pass expands.

---

## Cross-Cutting: Implicit Conversions

The codegen performs many implicit type conversions inline. These are not
separate emitLine calls but rather modify the instruction choice. In the
IR approach, these become explicit conversion IRInsts.

| Conversion | Existing Pattern | IR Representation |
|---|---|---|
| int → float/double | `scvtf sN, reg.x` / `ucvtf dN, reg.x` (preceded by `sxtw` if signed 32-bit) | `sxtw` + `scvtf`/`ucvtf` IRInsts (**Gap: needs cvtf cases**) |
| float/double → int | `fcvtzs wN, sN` / `fcvtzu xN, dN` | `fcvtzs`/`fcvtzu` IRInsts (**Gap**) |
| float → double | `fcvt dN, sN` | `fcvt(dst, src, fromDouble: false)` |
| double → float | `fcvt sN, dN` | `fcvt(dst, src, fromDouble: true)` |
| int → wider int (signed) | `sxtw`/`sxth`/`sxtb` | `sxtw`/`sxth`/`sxtb` IRInsts |
| int → wider int (unsigned) | `mov wN, wN` (zero-extend) or implicit via `w` write | `mov(dst, .vreg(src))` with word width |
| 64-bit → 32-bit (truncation) | Implicit via `w` register write (no explicit instruction) | Implicit in width; or `mov(dst, .vreg(src))` with word width |

---

## Summary of IR Gaps

The following ARM64 instructions/patterns are emitted by the codegen but
have **no direct representation** in the current `IRInst` enum:

1. **`neg`** — map to `sub(dst, .imm(0), .vreg(src))`
2. **`scvtf`/`ucvtf`** — int→float conversion (needs new IRInst cases)
3. **`fcvtzs`/`fcvtzu`** — float→int conversion (needs new IRInst cases)
4. **`adds`/`subs`** — add/subtract with carry flag (needed for __int128)
5. **`adc`/`sbc`** — add/subtract with carry (needed for __int128)
6. **`umulh`/`smulh`** — multiply high (needed for __int128 multiply)
7. **`fmov` crossing register banks** (int↔fp bit pattern move) — `fmov wN, sN` / `fmov dN, xN`
8. **`sp` as an operand** — stack pointer is not currently a VReg or Operand
9. **Pre/post-indexed load/store** (`[sp, #-16]!` / `[sp], #16`) — push/pop patterns
10. **Shifted register in `add`** (`add x0, x1, x2, lsl #3`) — array subscript addressing
11. **`fcmp` with immediate** (`fcmp sN, #0.0`) — fcmp src2 is Operand, needs `immF` support
12. **`ldrsw`** — sign-extend word load (covered by `load(signed: true, width: .word)` in the Width.loadSignedMnemonic, but the `load` IRInst uses `signed: Bool` which maps correctly)

**Recommendation:** Add the following to `IRInst`:
- `neg(dst: VReg, src: Operand)` (or document `sub(0, src)` convention)
- `scvtf(dst: VReg, src: Operand, toFloat: Bool, signed: Bool)`
- `ucvtf(dst: VReg, src: Operand, toFloat: Bool)`
- `fcvtzs(dst: VReg, src: Operand, fromDouble: Bool, width: Width)`
- `fcvtzu(dst: VReg, src: Operand, fromDouble: Bool, width: Width)`
- `adds(dst: VReg, src1: Operand, src2: Operand)` / `adc(dst: VReg, src1: Operand, src2: Operand)`
- `subs(dst: VReg, src1: Operand, src2: Operand)` / `sbc(dst: VReg, src1: Operand, src2: Operand)`
- `umulh(dst: VReg, src1: Operand, src2: Operand)` / `smulh(dst: VReg, src1: Operand, src2: Operand)`
- `fmovFromInt(dst: VReg, src: Operand, isFloat: Bool)` / `fmovToInt(dst: VReg, src: Operand, isFloat: Bool)`

Or alternatively, use a more open `IRInst.raw(String, [Operand])` escape
hatch for instructions not yet modeled, and gradually promote them to
typed cases.

---

## Appendix: Helper Function Mapping

| Existing Helper | What It Does | IR Equivalent |
|---|---|---|
| `emitLoadImm(reg, value)` | Load 64-bit immediate (mov/movn/movz/movk) | `IRInst.loadImm(dst, value)` — lowering handles encoding |
| `emitLoadFromFrame(reg, offset, type)` | Type-aware load from [x29, #offset] | `IRInst.load(dst, .vreg(fp), offset, width, signed)` |
| `emitLoad(reg, type)` | Type-aware load from [reg] | `IRInst.load(dst, .vreg(addr), 0, width, signed)` |
| `emitStoreToAddr(addrReg, valReg, type)` | Type-aware store to [addrReg] | `IRInst.store(.vreg(val), .vreg(addr), 0, width)` |
| `emitStoreFP(reg, offset)` | Store to [x29, #offset] (handles large offsets) | `IRInst.store(.vreg(val), .vreg(fp), offset, .dword)` |
| `emitLoadFP(reg, offset)` | Load from [x29, #offset] (handles large offsets) | `IRInst.load(dst, .vreg(fp), offset, .dword, false)` |
| `emitStoreSP(reg, offset)` | Store to [sp, #offset] | `IRInst.store(.vreg(val), .vreg(sp), offset, .dword)` |
| `emitLoadSP(reg, offset)` | Load from [sp, #offset] | `IRInst.load(dst, .vreg(sp), offset, .dword, false)` |
| `emitAddSP(value)` | `add sp, sp, #value` (handles large values) | `IRInst.addrr(.vreg(sp), .vreg(sp), value)` |
| `emitStructCopyToField(dst, src, size)` | Bulk copy N bytes via ldr/str loop | Sequence of `load` + `store` IRInsts (8/4/2/1 byte chunks) |
| `truncateReg(reg, type)` | Truncate to type width (sxtb/sxth/sxtw or uxtb/uxth) | `sxtb`/`sxth`/`sxtw`/`uxtb`/`uxth` IRInsts or implicit via width |
| `convertFloat(reg, from, to)` | float↔double conversion | `IRInst.fcvt(dst, src, fromDouble:)` |
| `newLabel()` | Generate unique assembly label | Label string (unchanged); used in `Operand.label(...)` |
| `emitLine(s)` | Append raw assembly line | `IRInst` construction (replaced entirely) |
| `allocReg()` | Allocate scratch or callee-saved register | `IRFunction.newVReg(kind: .gp)` |
| `storeLocal(name, reg, type)` | Store reg to local's frame slot | `IRInst.store(.vreg(val), .vreg(fp), offset, width)` |
| `ensureLocalSpace(size)` / `ensureTempSpace(size)` | Allocate frame space | Updates `IRFunction.frameSize`; slots become `Operand.slot(offset)` |
