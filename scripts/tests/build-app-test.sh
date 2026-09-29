#!/bin/bash
# R01: scripts/build-app.sh assembles and signs build/NotchTheRock.app, and a second build keeps the
# same designated requirement. Runs two full release builds. Requires bash 3.2 or later.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
APP="$ROOT/build/NotchTheRock.app"
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

R01__build_app_twice_keeps_designated_requirement() {
    current=${FUNCNAME[0]}
    local first second
    "$ROOT/scripts/build-app.sh" || { fail "first build-app.sh run failed"; return; }
    first=$(codesign -d -r- "$APP" 2>&1)
    printf 'first build:\n%s\n' "$first"
    "$ROOT/scripts/build-app.sh" || { fail "second build-app.sh run failed"; return; }
    second=$(codesign -d -r- "$APP" 2>&1)
    printf 'second build:\n%s\n' "$second"
    codesign --verify --deep --strict "$APP" || fail "codesign --verify --deep --strict failed"
    [ "$first" = "$second" ] || fail "designated requirement changed between builds"
    contains "$first" 'certificate leaf = H"' || fail "designated requirement is not tied to the signing certificate (ad-hoc?)"
}

R01__app_bundle_layout() {
    current=${FUNCNAME[0]}
    local plist="$APP/Contents/Info.plist" executable="$APP/Contents/MacOS/NotchTheRock" copies
    [ -x "$executable" ] || { fail "missing $executable"; return; }
    [ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$plist" 2>&1)" = "true" ] || fail "LSUIElement is not true"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>&1)" = "14.0" ] || fail "LSMinimumSystemVersion is not 14.0"
    [ -f "$APP/Contents/Frameworks/libNotchKit.dylib" ] || fail "Contents/Frameworks/libNotchKit.dylib is missing"
    copies=$(find "$APP" -name 'libNotchKit.dylib' | wc -l | tr -d ' ')
    [ "$copies" = "1" ] || fail "expected exactly one libNotchKit.dylib in the app, found $copies"
    contains "$(otool -L "$executable")" '@rpath/libNotchKit.dylib' || fail "app does not link @rpath/libNotchKit.dylib"
    contains "$(otool -l "$executable")" '@executable_path/../Frameworks' || fail "app has no @executable_path/../Frameworks rpath"
    contains "$(codesign -d --entitlements - "$APP" 2>&1)" 'com.apple.security.cs.disable-library-validation' \
        || fail "entitlement com.apple.security.cs.disable-library-validation is missing"
    contains "$(codesign -dv "$APP" 2>&1)" '(runtime)' || fail "hardened runtime flag is missing"
    codesign --verify --strict "$APP/Contents/Frameworks/libNotchKit.dylib" || fail "libNotchKit.dylib is not validly signed"
}

R01__build_app_twice_keeps_designated_requirement
R01__app_bundle_layout

if [ "$failures" -ne 0 ]; then
    printf '%d check(s) failed\n' "$failures"
    exit 1
fi
printf 'all R01 checks passed\n'
