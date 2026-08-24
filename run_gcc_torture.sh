#!/bin/bash
# GCC torture test runner for our C compiler
# Runs the "execute" subset of gcc.c-torture tests
CDRIVER="/Users/jesse/git/c-compiler/.build/debug/CDriver"
TESTDIR="/tmp/gcc-sparse/gcc/testsuite/gcc.c-torture/execute"
TMPDIR="/tmp/gcc_torture_run"
INCLUDE="-I/Users/jesse/git/c-compiler/include -I/tmp/gcc-sparse/gcc/testsuite"
STUBS="/Users/jesse/git/c-compiler/torture_stubs.c"
STUBS_OBJ="$TMPDIR/torture_stubs.o"
# Compile stubs once
clang -c -o "$STUBS_OBJ" "$STUBS" 2>/dev/null
mkdir -p "$TMPDIR"

PASS=0
FAIL=0
COMPILE_FAIL=0
TIMEOUT_COUNT=0
FAILED_TESTS=()

for testfile in "$TESTDIR"/*.c; do
    basename=$(basename "$testfile" .c)
    asmfile="$TMPDIR/${basename}.s"
    objfile="$TMPDIR/${basename}.o"
    exefile="$TMPDIR/${basename}"
    refexe="$TMPDIR/${basename}_ref"

    # Build with our compiler (timeout 30s, memory limit 1GB)
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

    # Build reference with clang
    clang -std=c99 -o "$refexe" "$testfile" $INCLUDE -lm 2>/dev/null
    if [ $? -ne 0 ]; then
        # Can't build reference, skip
        continue
    fi

    # Run both and compare
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
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("RC: $basename (ours=$our_rc ref=$ref_rc)")
        continue
    fi

    if diff -q "$TMPDIR/${basename}.out" "$TMPDIR/${basename}.ref" > /dev/null 2>&1; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("OUTPUT: $basename")
    fi
done

echo "=== GCC Torture Test Results ===" | tee /tmp/gcc_torture_results.txt
echo "Pass: $PASS" | tee -a /tmp/gcc_torture_results.txt
echo "Fail: $FAIL" | tee -a /tmp/gcc_torture_results.txt
echo "Compile Fail: $COMPILE_FAIL" | tee -a /tmp/gcc_torture_results.txt
echo "Timeout: $TIMEOUT_COUNT" | tee -a /tmp/gcc_torture_results.txt
echo "Total: $((PASS + FAIL + COMPILE_FAIL + TIMEOUT_COUNT))" | tee -a /tmp/gcc_torture_results.txt
echo "" | tee -a /tmp/gcc_torture_results.txt
echo "=== Failed tests ===" | tee -a /tmp/gcc_torture_results.txt
for t in "${FAILED_TESTS[@]}"; do
    echo "$t" | tee -a /tmp/gcc_torture_results.txt
done | head -200
