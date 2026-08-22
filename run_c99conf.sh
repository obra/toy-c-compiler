#!/bin/bash
# C99 conformance test suite - tests all major C99 features
CDRIVER="/Users/jesse/git/c-compiler/.build/arm64-apple-macosx/debug/CDriver"
TESTDIR="/tmp/c99conformance"
TMPDIR="/tmp/c99conf_run"
INCLUDE="-I/Users/jesse/git/c-compiler/include"
mkdir -p "$TMPDIR"

PASS=0
FAIL=0
FAILED_TESTS=()

for testfile in "$TESTDIR"/*.c; do
    basename=$(basename "$testfile" .c)
    asmfile="$TMPDIR/${basename}.s"
    objfile="$TMPDIR/${basename}.o"
    exefile="$TMPDIR/${basename}"
    refexe="$TMPDIR/${basename}_ref"

    # Build with our compiler
    timeout 10 $CDRIVER "$testfile" -o "$asmfile" 2>"$TMPDIR/${basename}.err"
    if [ $? -ne 0 ]; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$basename (compile error: $(head -1 $TMPDIR/${basename}.err))")
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

    # Build reference with clang
    timeout 10 clang -std=c99 -o "$refexe" "$testfile" $INCLUDE -lm 2>/dev/null
    if [ $? -ne 0 ]; then
        # If clang can't compile it either, skip
        continue
    fi

    actual=$(timeout 5 "$exefile" 2>&1)
    refresult=$(timeout 5 "$refexe" 2>&1)

    if [ "$actual" == "$refresult" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$basename (got='${actual:0:80}' exp='${refresult:0:80}')")
    fi
done

echo "=== C99 Conformance Results ==="
echo "Pass: $PASS"
echo "Fail: $FAIL"
echo "Total: $((PASS + FAIL))"
echo ""
echo "=== Failed tests ==="
for t in "${FAILED_TESTS[@]}"; do
    echo "  $t"
done
