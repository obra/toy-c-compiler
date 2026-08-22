#!/bin/bash
# c-testsuite runner for our C compiler
CDRIVER="/Users/jesse/git/c-compiler/.build/arm64-apple-macosx/debug/CDriver"
TESTDIR="/tmp/c-testsuite/tests/single-exec"
TMPDIR="/tmp/ctestsuite_run"
mkdir -p "$TMPDIR"

PASS=0
FAIL=0
FAILED_TESTS=()

for testfile in "$TESTDIR"/*.c; do
    basename=$(basename "$testfile" .c)
    expected_file="$TESTDIR/${basename}.c.expected"
    asmfile="$TMPDIR/${basename}.s"
    objfile="$TMPDIR/${basename}.o"
    exefile="$TMPDIR/${basename}"
    
    timeout 10 $CDRIVER "$testfile" -o "$asmfile" 2>/dev/null
    if [ $? -ne 0 ]; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$basename (compile error)")
        continue
    fi
    
    timeout 10 as -o "$objfile" "$asmfile" 2>/dev/null
    if [ $? -ne 0 ]; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$basename (assemble error)")
        continue
    fi
    
    timeout 10 clang -o "$exefile" "$objfile" -rdynamic 2>/dev/null
    if [ $? -ne 0 ]; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$basename (link error)")
        continue
    fi
    
    actual=$(timeout 5 "$exefile" 2>&1)
    exit_code=$?
    
    if [ ! -f "$expected_file" ]; then
        continue
    fi
    
    expected=$(cat "$expected_file")
    
    if [ "$actual" == "$expected" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$basename (exit=$exit_code got='${actual:0:60}' exp='${expected:0:60}')")
    fi
done

echo "=== Results ==="
echo "Pass: $PASS"
echo "Fail: $FAIL"
echo "Total: $((PASS + FAIL))"
echo ""
echo "=== Failed tests ==="
for t in "${FAILED_TESTS[@]}"; do
    echo "  $t"
done
