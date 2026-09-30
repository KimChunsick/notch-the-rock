#!/bin/bash
# Runs the swift-testing suites of SDK/NotchKit, the app (repository root) and every package under
# Plugins/, prints one line per package with its test count, and exits 1 naming each package whose
# tests failed or ran no test at all.
#
# Usage: scripts/test.sh [<package-dir>...]     (default: SDK/NotchKit, the root, Plugins/*/)
#
# Under Command Line Tools (no Xcode) SwiftPM passes the swift-testing framework directory with -I
# instead of -F. A bare `swift test` then either fails with "no such module 'Testing'" or, when the
# test target adds the flags itself (the root package does), builds a test runner that cannot import
# Testing and exits 0 without running a single test. This script adds the framework search path and
# runtime paths the packages document, and treats a run with zero tests as a failure.
# Requires bash 3.2 or later.
set -euo pipefail
shopt -s nullglob

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
CLT="/Library/Developer/CommandLineTools/Library/Developer"

say() {
    printf 'test.sh: %s\n' "$*"
}

flags=()
if [ -d "$CLT/Frameworks/Testing.framework" ]; then
    flags=(
        -Xswiftc -F -Xswiftc "$CLT/Frameworks"
        -Xlinker -rpath -Xlinker "$CLT/Frameworks"
        -Xlinker -rpath -Xlinker "$CLT/usr/lib"
    )
fi

packages=("$@")
if [ ${#packages[@]} -eq 0 ]; then
    packages=("$ROOT/SDK/NotchKit" "$ROOT")
    for manifest in "$ROOT"/Plugins/*/Package.swift; do
        packages+=("$(dirname "$manifest")")
    done
fi

logs=$(mktemp -d)
trap 'rm -rf "$logs"' EXIT
failed=()
index=0
for package in "${packages[@]}"; do
    index=$((index + 1))
    [ -f "$package/Package.swift" ] || { say "$package — Package.swift가 없어요."; failed+=("$package"); continue; }
    package=$(cd "$package" && pwd -P)
    case "$package" in
        "$ROOT") label="NotchTheRock (루트)" ;;
        "$ROOT"/*) label=${package#"$ROOT"/} ;;
        *) label=$package ;;
    esac
    log="$logs/$index.log"
    status=0
    swift test --package-path "$package" ${flags[@]+"${flags[@]}"} >"$log" 2>&1 || status=$?
    # swift-testing ends with "Test run with <N> test(s) in <M> suite(s) passed|failed ...".
    count=$(sed -n 's/.*Test run with \([0-9][0-9]*\) tests\{0,1\} .*/\1/p' "$log" | tail -n 1)
    if [ "$status" -ne 0 ]; then
        say "$label — 실패했어요 (종료 코드 $status). 마지막 출력:"
        tail -n 40 "$log" | sed 's/^/    /'
        failed+=("$label")
    elif [ -z "$count" ] || [ "$count" -eq 0 ]; then
        say "$label — 실행된 테스트가 0개예요. 테스트가 없거나 Testing 모듈을 불러오지 못했어요."
        failed+=("$label")
    else
        say "$label — 테스트 ${count}개 통과"
    fi
done

if [ ${#failed[@]} -ne 0 ]; then
    say "패키지 ${#packages[@]}개 중 ${#failed[@]}개가 실패했어요: $(printf '%s, ' "${failed[@]}" | sed 's/, $//')"
    exit 1
fi
say "패키지 ${#packages[@]}개 모두 통과했어요."
