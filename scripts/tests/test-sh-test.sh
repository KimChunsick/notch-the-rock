#!/bin/bash
# R01: scripts/test.sh runs each package's swift-testing suites, prints one line per package with
# its test count, and exits non-zero naming the package when its tests fail or when no test ran
# (the false pass of a bare `swift test` under Command Line Tools). Builds three tiny scratch
# packages. Requires bash 3.2 or later.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)
failures=0
current=""

fail() {
    printf 'FAIL %s: %s\n' "$current" "$*"
    failures=$((failures + 1))
}

# contains <text> <fixed-string>. Outputs are captured before matching because `cmd | grep -q`
# fails under pipefail when grep exits before cmd has written everything.
contains() {
    case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac
}

# write_package <name> <test body>: a package with one library target and one test target.
write_package() {
    local dir="$WORK/$1"
    mkdir -p "$dir/Sources/$1" "$dir/Tests/${1}Tests"
    cat >"$dir/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "$1",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "$1"),
        .testTarget(name: "${1}Tests", dependencies: ["$1"]),
    ]
)
EOF
    printf 'public let answer = 2\n' >"$dir/Sources/$1/$1.swift"
    printf 'import Testing\n@testable import %s\n\n%s\n' "$1" "$2" >"$dir/Tests/${1}Tests/${1}Tests.swift"
}

write_package Passing '@Test func adds() { #expect(answer == 2) }'
write_package Failing '@Test func adds() { #expect(answer == 3) }'
write_package Empty '// No tests: swift test builds and exits 0 without running anything.'

# run_test_sh <package-dir>...: sets `output` and `status`.
run_test_sh() {
    output=$("$ROOT/scripts/test.sh" "$@" 2>&1)
    status=$?
    printf '%s\n(exit %s)\n' "$output" "$status"
}

R01__test_sh_passes_and_prints_test_count() {
    current=${FUNCNAME[0]}
    run_test_sh "$WORK/Passing"
    [ "$status" -eq 0 ] || fail "a passing package made test.sh exit $status"
    contains "$output" "$WORK/Passing — 테스트 1개 통과" || fail "no summary line with the test count for Passing"
}

R01__test_sh_fails_and_names_failing_package() {
    current=${FUNCNAME[0]}
    run_test_sh "$WORK/Passing" "$WORK/Failing"
    [ "$status" -ne 0 ] || fail "a failing package did not make test.sh fail"
    contains "$output" "$WORK/Passing — 테스트 1개 통과" || fail "the passing package has no summary line"
    contains "$output" "$WORK/Failing — 실패했어요" || fail "the failing package is not named as failed"
}

R01__test_sh_fails_when_no_test_runs() {
    current=${FUNCNAME[0]}
    run_test_sh "$WORK/Empty"
    [ "$status" -ne 0 ] || fail "a package that ran zero tests made test.sh exit 0"
    contains "$output" "$WORK/Empty — 실행된 테스트가 0개예요" || fail "the zero-test package is not named"
}

R01__test_sh_passes_and_prints_test_count
R01__test_sh_fails_and_names_failing_package
R01__test_sh_fails_when_no_test_runs

if [ "$failures" -ne 0 ]; then
    printf '%d check(s) failed\n' "$failures"
    exit 1
fi
printf 'all R01 test.sh checks passed\n'
