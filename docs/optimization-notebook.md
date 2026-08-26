# Optimization Engineering Notebook

## Baseline (before IR optimizations)
- Original assembly: 562,433 instructions
- Target: beat clang -O3 (currently ~2.93x of clang -O0)

## Instruction breakdown (SQLite, original)
```
141601 ldr      ← biggest target: redundant reloads
 87220 str      ← dead stores
 81331 add      ← address computations
 75406 mov      ← register copies
 29980 b        ← branches (hard to reduce)
 18115 sxtw     ← sign extensions (many dead)
 13099 bl       ← calls
 12724 cmp
  7416 cbz
  5685 sub
  5347 movn
  5137 ret
  5137 ldp
  4932 and
  4649 ldrb
```

## Optimization Log

### 1. Simple DCE + copy prop + constant folding (commit 7d7e891)
- Result: 562,433 → 560,985 (1,448 removed, 0.26%)
- What went well: removed 2,576 dead stp (callee-saved saves for unused registers)
- What went bad: copy propagation created self-references (mov x, x) — fixed by checking
- What went bad: movk instructions left as comments — fixed by DCE removing them
- What went bad: VReg isWord caused x9/w9 to be treated as different registers — fixed with NormalizedReg

### 2. Cross-block DCE with liveness analysis (commit c2b5139)
- Result: 562,433 → 538,494 (23,939 removed, 4.3%)
- What went well: liveness analysis found 5,810 dead sxtw, 4,339 dead mov, 3,460 dead add
- What went bad: labels dropped from empty blocks — fixed by preserving empty label-only blocks
- What went bad: initial simple DCE didn't account for ABI implicit uses (x0-x7 for calls, x0 for ret) — fixed
- 16x more effective than simple DCE

### Next: Analyze most common reducible patterns

### 3. Load forwarding (commit 4406fe0)
- Result: 538,494 → 537,624 (870 net removed, but 4,981 ldr→mov conversions)
- What went well: 4,981 fewer memory loads (ldr → register mov)
- What went bad: net instruction count barely changed because movs replace ldrs
- But the movs are cheaper than ldrs at runtime (register vs memory)
- Cache invalidated at calls, branches, labels, pre/post-indexed ops

### Analysis of remaining opportunities (after load forwarding)
- 66 unconditional branches to immediately following label (redundant)
- 434 ldr w + sxtw pairs (could use ldrsw — needs type info)
- 0 dead stores (single-pass codegen doesn't produce them)
- 0 mov x0 before ret (peephole already handles)
- 0 mov swap patterns (peephole already handles)

### 4. Redundant branch elimination (commit b8a41f2)
- Result: 537,558 instructions (66 branches removed)
- What went well: simple pattern match, no issues

### 5. Stack adjustment merging (commit fa7a197)
- Result: 539,560 instructions (before push-pop/call fix — needs re-benchmark)
- Analysis: 18,671 mergeable add sp,sp,#N instructions
- What went bad: first version crashed — didn't flush pending sp adjustment
  when sp was referenced by mov sp,x29 or other instructions. Fixed by
  flushing on any sp reference (refsSP check).
- What went bad: didn't flush on x29 (frame pointer) references. Stack
  merge moved `sub sp,sp,#16` past frame setup, breaking stack layout.
  Fixed by flushing on x29 references too.

### 6. Push-pop elimination (commit 705a1a6)
- Replaces str [sp,#-16]! + ldr [sp,#0] with str + mov (keeps store for alignment)
- What went bad: first version removed both store AND load → broke stack
  alignment → segfault. Fixed by keeping the store.
- What went bad: copy propagation didn't invalidate caller-saved regs on
  calls → mov x0,#5 before call was forwarded to mov w9,w0 after call,
  giving wrong return value (factorial(5)=5 instead of 120). Fixed by
  invalidating x0-x18 on call instructions.
- What went bad: copy prop and constant folding used VReg (with isWord) as
  keys, not NormalizedReg → sub w9,w9,w10 didn't invalidate x9 copy map
  entry. Fixed by using NormalizedReg everywhere.

### 7. Address folding (commit d3fef78, fix 3ed5c9b)
- Folds addrr xN,x29,#N into load/store [x29,#N] when xN is used exactly once
- What went bad: findSingleUse returned Int? but code accessed .idx member
  → compile error. Fixed by using the Int directly.
- Analysis: 10,025 foldable patterns in SQLite

### 8. Zero store elimination (commit 33503cc, fix 93136a7)
- Replaces mov reg,#0 + str reg,[addr] with str wzr,[addr]
- What went bad: first version only looked at adjacent instructions. Many
  patterns have sxtw between mov #0 and str (mov #0 + sxtw of zero + str).
  Fixed by looking through sxtw.
- What went bad: didn't handle storePre (str [sp,#-16]!) pattern. Added.
- 4,108 patterns found (after sxtw fix)

### 9. Compare-to-branch folding (commit bf0f16c)
- Replaces cmp reg,#0 + b.eq/ne label with cbz/cbnz reg, label
- Eliminates the cmp instruction
- 689 patterns found in SQLite
- No issues encountered

## Summary (as of commit 1656f6f)
- Original: 562,433 instructions
- Latest: 524,720 instructions (6.7% reduction, 37,713 removed)
- All 164 tests pass

### 17. Mov-store fusion (commit b4be1b5)
- mov xN,xM + str xN,[addr] → str xM,[addr] when xN is dead
- mov: 72,674 → 71,673 (1,001 eliminated)

### 18. usedAfter fix (commit 1656f6f)
- Fixed usedAfter() to return false at ret (registers are dead at function exit)
- Enables load-target folding at function returns
- mov: 71,673 → 70,541 (1,132 eliminated)
- What went bad: usedAfter was returning true at ret, preventing load-target
  folding from working on ldr+mov patterns at function exits.

### 11. Dead sign extension elimination (commit ff86f76, extended 7133693)
- Removes sxtw/sxtb/sxth/uxtb/uxth when extended form is never used
- sxtw: 18,115 → 10,761 (7,354 eliminated)
- sxtb: 1,475 → 774 (701 eliminated)
- sxth: 1,192 → 727 (465 eliminated)
- Total: 8,520 sign extensions eliminated
- What went bad: initially only handled sxtw. Extended to all variants.

### 12. Store-source copy propagation (ATTEMPTED, DISABLED)
- Attempted to replace store source with copy-propagated register
- What went bad: caused incorrect results. `str x0, [x29, #-8]` was
  rewritten to `str w9, [x29, #-8]` due to stale copy map entries.
  Also created `str #5, [sp, #-16]!` (immediate as store source — invalid).
- Disabled. Needs proper liveness analysis.

### 13. Load-target folding (commit fcee8db)
- Folds ldr xN, [addr] + mov xP, xN → ldr xP, [addr] when xN is dead
- 857 patterns found in SQLite
- No issues encountered

### 14. SP restore elimination (commit N/A — no effect)
- Attempted to eliminate redundant `mov sp, x29` in epilogues
- All functions modify sp, so no redundant SP restores found
- No effect

### 15. Mov-store fusion (commit N/A)
- Fuses mov xN, xM + str xN, [addr] → str xM, [addr] when xN is dead after store
- Also handles mov xN, xM + str xN, [sp, #-16]! → str xM, [sp, #-16]!
- ~235 mov+str patterns found; some fused

### 16. storePre cancellation in stackAdjustmentMerge
- Pattern: add sp, #N + str x, [sp, #-M]! → str x, [sp, #(N-M)] + adjust sp by (N-M)
- When N == M (exact cancel): str x, [sp] with no sp change, saving 1 instruction
- When N > M (partial cancel): plain store at offset + smaller sp adjustment
  enables further merging with adjacent adjustments
- 3,893 exact cancellations + 3,141 partial cancellations in SQLite
- Result: 524,509 → 515,883 instructions (8,626 saved, 1.6% reduction)
- Total from original: 562,433 → 515,883 (8.3% total reduction)
- No issues encountered. 164/164 tests pass.

### 17. Pair coalescing (commit c090a4c)
- Coalesces consecutive str+str [base, #off] and [base, #off+8] → stp
- Also ldr+ldr → ldp. Normalizes zero register width (wzr→xzr) for stp.
- 3,655 stp pairs + 137 ldp pairs in SQLite
- 515,883 → 512,345 (3,538 saved)

### 18. storePre cancellation in stackAdjustmentMerge (commit 56f6642)
- add sp, #N + str x, [sp, #-M]! → str x, [sp, #(N-M)] + adjust sp by (N-M)
- 3,893 exact + 3,141 partial cancellations
- 524,509 → 515,883 (8,626 saved)

### 19. Constant folding for cmp and cbz/cbnz (commit 80e8e9b, ab0df89)
- Folds known constant register values into cmp operands
- Folds cbz/cbnz with known-zero/nonzero sources
- Clears constValues at labels/branches/ret for control flow correctness
- 512,345 → 499,743 (12,602 saved)
- What went bad: initial version didn't clear constants at control flow merge
  points, causing incorrect cbz elimination when different branches set
  different values to same register. Fixed by clearing at labels/branches/ret.
- Total from original: 562,433 → 499,743 (11.1% reduction)
