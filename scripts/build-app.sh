#!/bin/bash
# Builds NotchKit, the app and every built-in plugin with SwiftPM (Command Line Tools only, no
# Xcode), then assembles and signs build/NotchTheRock.app and prints its path.
#
# Usage: scripts/build-app.sh
#
# Bundle layout:
#   Contents/MacOS/NotchTheRock              app executable (hardened runtime + entitlements)
#   Contents/Frameworks/libNotchKit.dylib    the single NotchKit copy every plugin binds to
#   Contents/PlugIns/<Name>.notchplugin      built-in plugins, packaged by scripts/build-plugin.sh
#   Contents/Info.plist                      from Resources/Info.plist
# Everything is signed inside-out with the identity from scripts/signing-identity.sh, so the
# designated requirement stays the same across rebuilds. Safe to run again.
# Requires bash 3.2 or later.
set -euo pipefail
shopt -s nullglob

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/NotchTheRock.app"
PLUGIN_OUT="$BUILD_DIR/plugins"

say() {
    printf 'build-app: %s\n' "$*" >&2
}

fail() {
    say "$*"
    exit 1
}

# sign [codesign options...] <path>
sign() {
    local output target
    for target; do :; done
    output=$(codesign --force --timestamp=none --sign "$IDENTITY" "$@" 2>&1) \
        || fail "서명하지 못했어요: $target"$'\n'"$output"
}

say "서명 인증서를 확인해요."
IDENTITY=$("$ROOT/scripts/signing-identity.sh") || fail "서명 인증서를 준비하지 못했어요."

say "NotchKit과 앱을 빌드해요 (release)."
swift build -c release --package-path "$ROOT" >&2 || fail "앱을 빌드하지 못했어요."
BIN_DIR=$(swift build -c release --package-path "$ROOT" --show-bin-path)
# Ship the NotchKit dylib the app was linked against; plugins bind to this copy at run time.
NOTCHKIT_DYLIB="$BIN_DIR/libNotchKit.dylib"
[ -f "$NOTCHKIT_DYLIB" ] || fail "빌드 결과에 libNotchKit.dylib가 없어요: $BIN_DIR"
[ -f "$BIN_DIR/Modules/NotchKit.swiftinterface" ] || fail "NotchKit이 라이브러리 진화 모드로 빌드되지 않았어요."

rm -rf "$PLUGIN_OUT"
plugins=()
for package in "$ROOT"/Plugins/*/Package.swift; do
    plugin_dir=$(dirname "$package")
    say "플러그인을 빌드해요: $(basename "$plugin_dir")"
    plugins+=("$("$ROOT/scripts/build-plugin.sh" "$plugin_dir" --out "$PLUGIN_OUT")") \
        || fail "플러그인을 빌드하지 못했어요: $plugin_dir"
done

say "앱 번들을 만들어요: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/PlugIns" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' >"$APP/Contents/PkgInfo"
cp "$BIN_DIR/NotchTheRock" "$APP/Contents/MacOS/NotchTheRock"
cp "$NOTCHKIT_DYLIB" "$APP/Contents/Frameworks/libNotchKit.dylib"
for plugin in ${plugins[@]+"${plugins[@]}"}; do
    cp -R "$plugin" "$APP/Contents/PlugIns/"
done

say "안쪽부터 서명해요."
sign "$APP/Contents/Frameworks/libNotchKit.dylib"
for plugin in "$APP"/Contents/PlugIns/*.notchplugin; do
    sign "$plugin"
done
sign --options runtime --entitlements "$ROOT/Resources/NotchTheRock.entitlements" "$APP"
codesign --verify --deep --strict "$APP" || fail "서명 검증에 실패했어요: $APP"

printf '%s\n' "$APP"
