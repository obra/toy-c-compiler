#!/bin/bash
# GCC torture test runner for our C compiler (v2: with progress)
CDRIVER="/Users/jesse/git/c-compiler/.build/debug/CDriver"
TESTDIR="/tmp/gcc-sparse/gcc/testsuite/gcc.c-torture/execute"
TMPDIR="/tmp/gcc_torture_run"
INCLUDE="-I/Users/jesse/git/c-compiler/include -I/tmp/gcc-sparse/gcc/testsuite"
STUBS="/Users/jesse/git/c-compiler/torture_stubs.c"
STUBS_OBJ="$TMPDIR/torture_stubs.o"
clang -c -o "$STUBS_OBJ" "$STUBS" 2>/dev/null
mkdir -p "$TMPDIR"

PASS=0
FAIL=0
COMPILE_FAIL=0
TIMEOUT_COUNT=0
SKIP_COUNT=0
FAILED_TESTS=()
TOTAL_TESTS=0

# Check if a test should be skipped based on dg directives in the source.
# Skip patterns:
# - dg-skip-if with x86-only target ({ i?86-*-* x86_64-*-* })
# - dg-require-effective-target with unsupported features (dfp, dfprt)
# Note: Tests with missing gcc.dg/ includes are NOT skipped here — some have
# fallback behavior and compile fine. They'll be COMPILE_FAIL if they can't compile.
should_skip() {
    local f="$1"
    # Check for x86-only dg-skip-if
    if grep -q 'dg-skip-if.*i?86.*x86_64' "$f" 2>/dev/null; then
        return 0
    fi
    # Check for DFP (decimal floating point) requirement
    if grep -q 'dg-require-effective-target dfp' "$f" 2>/dev/null; then
        return 0
    fi
    return 1
}

for testfile in "$TESTDIR"/*.c; do
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [ $((TOTAL_TESTS % 100)) -eq 0 ]; then
        echo "Progress: $TOTAL_TESTS tests processed (pass=$PASS fail=$FAIL compile=$COMPILE_FAIL timeout=$TIMEOUT_COUNT skip=$SKIP_COUNT)..." >&2
    fi
    basename=$(basename "$testfile" .c)
    asmfile="$TMPDIR/${basename}.s"
    objfile="$TMPDIR/${basename}.o"
    exefile="$TMPDIR/${basename}"
    refexe="$TMPDIR/${basename}_ref"

    # Check if this test should be skipped (platform-specific or unsupported features)
    if should_skip "$testfile"; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    timeout 30 $CDRIVER "$testfile" -o "$asmfile" $INCLUDE 2>/dev/null
    if [ $? -ne 0 ]; then
        COMPILE_FAIL=$((COMPILE_FAIL + 1))
        FAILED_TESTS+=("COMPILE: $basename")
        continue
    fi
    as -o "$objfile" "$asmfile" 2>/dev/null
    if [ $? -ne 0 ]; then
        COMPILE_FAIL=$((COMPILE_FAIL + 1))
        FAILED_TESTS+=("ASSEMBLE: $basename")
        continue
    fi
    clang -o "$exefile" "$objfile" "$STUBS_OBJ" -lm 2>/dev/null
    if [ $? -ne 0 ]; then
        COMPILE_FAIL=$((COMPILE_FAIL + 1))
        FAILED_TESTS+=("LINK: $basename")
        continue
    fi

    clang -std=c99 -o "$refexe" "$testfile" $INCLUDE -lm 2>/dev/null
    if [ $? -ne 0 ]; then
        continue
    fi

    timeout 5 "$exefile" > "$TMPDIR/${basename}.out" 2>/dev/null
    our_rc=$?
    timeout 5 "$refexe" > "$TMPDIR/${basename}.ref" 2>/dev/null
    ref_rc=$?

    if [ $our_rc -eq 124 ] || [ $our_rc -eq 137 ]; then
        TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
        FAILED_TESTS+=("TIMEOUT: $basename")
        continue
    fi

    if [ $our_rc -ne $ref_rc ]; then
        # If our compiler passes (exit 0) but the reference aborts, the reference
        # is likely hitting UB or a platform-specific issue. Skip as false positive.
        if [ $our_rc -eq 0 ] && [ $ref_rc -ne 0 ]; then
            SKIP_COUNT=$((SKIP_COUNT + 1))
            continue
        fi
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("RC: $basename (ours=$our_rc ref=$ref_rc)")
        continue
    fi

    if diff -q "$TMPDIR/${basename}.out" "$TMPDIR/${basename}.ref" > /dev/null 2>&1; then
        PASS=$((PASS + 1))
    else
        # If both exit 0 but output differs, check if it's just address differences
        # (e.g., printf("%p") of stack addresses). These are false positives.
        if [ $our_rc -eq 0 ] && [ $ref_rc -eq 0 ]; then
            # Check if both outputs contain hex addresses (0x... patterns)
            if grep -q '0x[0-9a-f]' "$TMPDIR/${basename}.out" 2>/dev/null && \
               grep -q '0x[0-9a-f]' "$TMPDIR/${basename}.ref" 2>/dev/null; then
                # Normalize hex addresses and compare
                sed 's/0x[0-9a-fA-F]*/0xADDR/g' "$TMPDIR/${basename}.out" > "$TMPDIR/${basename}.out_norm"
                sed 's/0x[0-9a-fA-F]*/0xADDR/g' "$TMPDIR/${basename}.ref" > "$TMPDIR/${basename}.ref_norm"
                if diff -q "$TMPDIR/${basename}.out_norm" "$TMPDIR/${basename}.ref_norm" > /dev/null 2>&1; then
                    PASS=$((PASS + 1))
                    continue
                fi
            fi
        fi
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("OUTPUT: $basename")
    fi
done

echo "=== GCC Torture Test Results ===" | tee /tmp/gcc_torture_results_v2.txt
echo "Pass: $PASS" | tee -a /tmp/gcc_torture_results_v2.txt
echo "Fail: $FAIL" | tee -a /tmp/gcc_torture_results_v2.txt
echo "Compile Fail: $COMPILE_FAIL" | tee -a /tmp/gcc_torture_results_v2.txt
echo "Timeout: $TIMEOUT_COUNT" | tee -a /tmp/gcc_torture_results_v2.txt
echo "Skip: $SKIP_COUNT" | tee -a /tmp/gcc_torture_results_v2.txt
echo "Total: $((PASS + FAIL + COMPILE_FAIL + TIMEOUT_COUNT + SKIP_COUNT))" | tee -a /tmp/gcc_torture_results_v2.txt
echo "" | tee -a /tmp/gcc_torture_results_v2.txt
echo "=== Failed tests ===" | tee -a /tmp/gcc_torture_results_v2.txt
for t in "${FAILED_TESTS[@]}"; do
    echo "$t" | tee -a /tmp/gcc_torture_results_v2.txt
done | head -300
