#!/bin/bash
# R16: a plugin built against NotchKit 1.0 still loads with the current SDK and has no tile.
#
# Builds the plugin template twice, against NotchKit 1.0 in a temporary worktree at <commit> and
# against this tree, then runs SDKCompatibilityTests in NotchKitTests on both bundles. The tests load
# them with the current notchkit-probe: the current PluginLoader in a process that holds the single
# shared libNotchKit.dylib, as the app does. The test process itself links NotchKit statically, so a
# plugin loaded there would bind to a second copy. Nothing it builds is kept.
#
# Usage: SDK/NotchKit/Tests/sdk-compat-test.sh [<commit with NotchKit 1.0>]   (default: 3b95c39)
# Requires bash 3.2 or later.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd -P)
BASE=${1:-3b95c39}
CLT="/Library/Developer/CommandLineTools/Library/Developer"
WORK=$(mktemp -d)
WORK=$(cd "$WORK" && pwd -P)
LEGACY_TREE="$WORK/sdk-1.0"

say() {
    printf 'sdk-compat-test: %s\n' "$*"
}

fail() {
    say "$*"
    exit 1
}

cleanup() {
    if [ -d "$LEGACY_TREE" ]; then
        git -C "$ROOT" worktree remove --force "$LEGACY_TREE" || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

say "NotchKit 1.0 트리를 임시 작업 트리로 꺼내요: $BASE"
git -C "$ROOT" worktree add --detach "$LEGACY_TREE" "$BASE"
grep -q 'SDKVersion(major: 1, minor: 0)' "$LEGACY_TREE/SDK/NotchKit/Sources/NotchKit/SDKVersion.swift" \
    || fail "$BASE의 NotchKit이 1.0이 아니에요."
"$LEGACY_TREE/scripts/new-plugin.sh" Legacy --dir "$WORK"
legacy=$("$LEGACY_TREE/scripts/build-plugin.sh" "$WORK/Legacy" --out "$WORK/sdk-1.0-out")
git -C "$ROOT" worktree remove --force "$LEGACY_TREE"
say "NotchKit 1.0으로 빌드했어요: $legacy"

"$ROOT/scripts/new-plugin.sh" Current --dir "$WORK"
current=$("$ROOT/scripts/build-plugin.sh" "$WORK/Current" --out "$WORK/current-out")
probe="$(swift build -c release --package-path "$ROOT/SDK/NotchKit/Probe" --show-bin-path)/notchkit-probe"
say "지금 NotchKit으로 빌드했어요: $current"

flags=()
if [ -d "$CLT/Frameworks/Testing.framework" ]; then
    flags=(
        -Xswiftc -F -Xswiftc "$CLT/Frameworks"
        -Xlinker -rpath -Xlinker "$CLT/Frameworks"
        -Xlinker -rpath -Xlinker "$CLT/usr/lib"
    )
fi
status=0
output=$(NOTCHKIT_COMPAT_SDK10_BUNDLE=$legacy NOTCHKIT_COMPAT_CURRENT_BUNDLE=$current NOTCHKIT_PROBE=$probe \
    swift test --package-path "$ROOT/SDK/NotchKit" ${flags[@]+"${flags[@]}"} --filter SDKCompatibilityTests 2>&1) || status=$?
printf '%s\n' "$output"
[ "$status" -eq 0 ] || fail "SDKCompatibilityTests가 실패했어요 (종료 코드 $status)."
case "$output" in
    *skipped*) fail "SDKCompatibilityTests가 실행되지 않고 건너뛰어졌어요." ;;
esac
case "$output" in
    *"Test run with 2 tests"*) ;;
    *) fail "SDKCompatibilityTests 2개가 모두 실행되지 않았어요." ;;
esac
say "NotchKit 1.0으로 빌드한 플러그인을 지금 SDK로 불러왔고 타일이 없어요."
