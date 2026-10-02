#!/bin/bash
# R16: a plugin built against NotchKit 1.0 still loads with the current SDK and has no tile.
# R48: a plugin built against NotchKit 1.3 with a settings view of its own still opens it, without a
# description.
#
# Builds the plugin template three times: against NotchKit 1.0 and against NotchKit 1.3 (with a
# settingsView added), each in a temporary worktree at its commit, and against this tree. Then runs
# SDKCompatibilityTests in NotchKitTests on the three bundles. The tests load them with the current
# notchkit-probe: the current PluginLoader in a process that holds the single shared
# libNotchKit.dylib, as the app does. The test process itself links NotchKit statically, so a plugin
# loaded there would bind to a second copy. Nothing it builds is kept.
#
# Usage: SDK/NotchKit/Tests/sdk-compat-test.sh [<commit with NotchKit 1.0> [<commit with NotchKit 1.3>]]
#        (defaults: 3b95c39, be2db36)
# Requires bash 3.2 or later.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd -P)
BASE=${1:-3b95c39}
BASE13=${2:-be2db36}
CLT="/Library/Developer/CommandLineTools/Library/Developer"
WORK=$(mktemp -d)
WORK=$(cd "$WORK" && pwd -P)
LEGACY_TREE="$WORK/sdk-1.0"
LEGACY13_TREE="$WORK/sdk-1.3"

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
    if [ -d "$LEGACY13_TREE" ]; then
        git -C "$ROOT" worktree remove --force "$LEGACY13_TREE" || true
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

say "NotchKit 1.3 트리를 임시 작업 트리로 꺼내요: $BASE13"
git -C "$ROOT" worktree add --detach "$LEGACY13_TREE" "$BASE13"
grep -q 'SDKVersion(major: 1, minor: 3)' "$LEGACY13_TREE/SDK/NotchKit/Sources/NotchKit/SDKVersion.swift" \
    || fail "$BASE13의 NotchKit이 1.3이 아니에요."
"$LEGACY13_TREE/scripts/new-plugin.sh" Legacy13 --dir "$WORK"
# The 1.3 template has no settings view; this one has its own, as a 1.3 plugin's page did.
cat >"$WORK/Legacy13/Sources/Legacy13/Legacy13Settings.swift" <<'SWIFT'
import NotchKit
import SwiftUI

extension Legacy13Plugin {
    public var settingsView: AnyView? {
        AnyView(Toggle("Legacy13 설정", isOn: .constant(true)))
    }
}
SWIFT
legacy13=$("$LEGACY13_TREE/scripts/build-plugin.sh" "$WORK/Legacy13" --out "$WORK/sdk-1.3-out")
git -C "$ROOT" worktree remove --force "$LEGACY13_TREE"
say "NotchKit 1.3으로 설정 화면이 있는 플러그인을 빌드했어요: $legacy13"

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
output=$(NOTCHKIT_COMPAT_SDK10_BUNDLE=$legacy NOTCHKIT_COMPAT_SDK13_BUNDLE=$legacy13 \
    NOTCHKIT_COMPAT_CURRENT_BUNDLE=$current NOTCHKIT_PROBE=$probe \
    swift test --package-path "$ROOT/SDK/NotchKit" ${flags[@]+"${flags[@]}"} --filter SDKCompatibilityTests 2>&1) || status=$?
printf '%s\n' "$output"
[ "$status" -eq 0 ] || fail "SDKCompatibilityTests가 실패했어요 (종료 코드 $status)."
case "$output" in
    *skipped*) fail "SDKCompatibilityTests가 실행되지 않고 건너뛰어졌어요." ;;
esac
case "$output" in
    *"Test run with 3 tests"*) ;;
    *) fail "SDKCompatibilityTests 3개가 모두 실행되지 않았어요." ;;
esac
say "NotchKit 1.0으로 빌드한 플러그인을 지금 SDK로 불러왔고 타일이 없어요."
say "NotchKit 1.3으로 빌드한 플러그인은 설명 없이 자기 설정 화면을 그대로 보여줘요."
