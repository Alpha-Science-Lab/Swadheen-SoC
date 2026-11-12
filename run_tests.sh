#!/usr/bin/env bash
# Runs every self-checking simulation test and exits non-zero if any fails.
# The harness counts one deliberate "initial test" failure, so the exit code of
# the simulator is not enough: a test passes only if it prints "All tests passed".
set -u
cd "$(dirname "$0")"

LOG_DIR=$(mktemp -d)
# Private build dirs so stale dependency files in build/ cannot affect the result
BUILD=build_test
M_BUILD=build_mext
pass=0
fail=0

cleanup() {
    rm -rf "$BUILD" "$M_BUILD"
    [ "$fail" -eq 0 ] && rm -rf "$LOG_DIR"
}
trap cleanup EXIT
rm -rf "$BUILD" "$M_BUILD"

check() {
    local name=$1 log=$2 rc=$3

    if [ "$rc" -eq 0 ] && grep -qi "all tests passed" "$log" \
        && ! grep -qE "Some test|Inital test|Simulation timeout|%Error" "$log"; then
        printf '  PASS  %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL  %s (rc=%s, log: %s)\n' "$name" "$rc" "$log"
        tail -n 12 "$log" | sed 's/^/        /'
        fail=$((fail + 1))
    fi
}

run() {
    local name=$1; shift
    local log="$LOG_DIR/$(echo "$name" | tr '/' '_').log"

    timeout 300 make "$@" > "$log" 2>&1
    check "$name" "$log" $?
}

echo "Assembly tests (RV32I)"
for src in test/asm/*.s; do
    t=${src%.s}
    case $(basename "$t") in
        mext*) continue ;;
    esac
    run "$t" BUILD_DIR="$BUILD" "$t"
done

echo "Assembly tests (RV32IM, M_EXT=1)"
for src in test/asm/mext*.s; do
    t=${src%.s}
    run "$t (M_EXT=1)" M_EXT=1 BUILD_DIR="$M_BUILD" "$t"
done

echo "SystemVerilog testbenches"
for src in test/sv/*.sv; do
    t=${src%.sv}
    run "$t" BUILD_DIR="$BUILD" "$t"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
