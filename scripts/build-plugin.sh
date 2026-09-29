#!/bin/bash
# Builds a plugin's SwiftPM package (release) and wraps its dylib as <Name>.notchplugin, then prints
# the bundle path. The app's built-in plugins and third-party plugins are packaged the same way.
#
# Usage: scripts/build-plugin.sh <plugin-package-dir> [--out <dir>]
#   <Name> is the package folder name; the package must have a dynamic library product <Name>
#   that depends on NotchKit. --out defaults to <plugin-package-dir>/build.
#
# Bundle layout:
#   <Name>.notchplugin/Contents/Info.plist      derived from the plugin's PluginManifest
#   <Name>.notchplugin/Contents/MacOS/<Name>    the plugin dylib
#   <Name>.notchplugin/Contents/Resources/      SwiftPM resource bundles (<package>_<target>.bundle)
# Bundle.module looks next to the app and in the build folder, never in the installed plugin, so
# plugins open their resource bundles with NotchContext.resourceBundle(named:).
# The dylib links NotchKit only as @rpath/libNotchKit.dylib and finds it in the host app's
# Contents/Frameworks (@loader_path/../../../../Frameworks from Contents/PlugIns/<Name>.notchplugin/
# Contents/MacOS); the bundle never carries its own NotchKit. It is signed with the local identity
# from signing-identity.sh when one exists, otherwise ad-hoc.
# Requires bash 3.2 or later.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
PROBE_PACKAGE="$ROOT/SDK/NotchKit/Probe"
NOTCHKIT_REFERENCE="@rpath/libNotchKit.dylib"
HOST_FRAMEWORKS_RPATH="@loader_path/../../../../Frameworks"
ENTRY_SYMBOL="notchkit_plugin_entry"

say() {
    printf 'build-plugin: %s\n' "$*" >&2
}

fail() {
    say "$*"
    exit 1
}

usage() {
    printf '사용법: %s <plugin-package-dir> [--out <dir>]\n' "$0" >&2
    exit 2
}

package=""
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out) [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
        -*) usage ;;
        *) [ -z "$package" ] || usage; package=$1; shift ;;
    esac
done
[ -n "$package" ] || usage
[ -f "$package/Package.swift" ] || fail "Package.swift가 없어요: $package"
package=$(cd "$package" && pwd -P)
name=$(basename "$package")
[ -n "$out" ] || out="$package/build"
mkdir -p "$out"
out=$(cd "$out" && pwd -P)

# has_rpath <binary> <path>. The otool output is captured first: `otool | grep -q` fails under
# pipefail when grep exits early.
has_rpath() {
    local rpaths
    rpaths=$(otool -l "$1" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }')
    case $'\n'"$rpaths"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; *) return 1 ;; esac
}

say "빌드해요: $name (release)"
swift build -c release --package-path "$package" --product "$name" >&2 || fail "플러그인 패키지를 빌드하지 못했어요: $package"
bin_path=$(swift build -c release --package-path "$package" --show-bin-path)
dylib="$bin_path/lib$name.dylib"
[ -f "$dylib" ] || fail "동적 라이브러리를 찾지 못했어요: $dylib. Package.swift에 .library(name: \"$name\", type: .dynamic, ...)가 있어야 해요."

# Single-copy rule: exactly one NotchKit reference, and it must be the shared @rpath dylib.
references=$(otool -L "$dylib" | awk 'NR > 1 && $1 ~ /(^|\/)libNotchKit\.dylib$/ { print $1 }')
[ "$references" = "$NOTCHKIT_REFERENCE" ] \
    || fail "플러그인은 NotchKit을 한 번만 동적 링크해야 해요. 필요한 참조: $NOTCHKIT_REFERENCE, 지금 참조: ${references:-없음}"

say "PlugIns 번들 모양으로 묶어요."
stage=$(mktemp -d "$out/.build-plugin.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/$name.notchplugin"
binary="$bundle/Contents/MacOS/$name"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$dylib" "$binary"
# SwiftPM writes each target's resources, including those of the plugin's dependencies, as a
# <package>_<target>.bundle next to the dylib.
for resources in "$bin_path"/*.bundle; do
    [ -d "$resources" ] || continue
    cp -R "$resources" "$bundle/Contents/Resources/"
done
# @loader_path would pick up a NotchKit copy placed next to the plugin; the host's copy is the only one.
if has_rpath "$binary" '@loader_path'; then
    install_name_tool -delete_rpath '@loader_path' "$binary" 2>/dev/null
fi
if ! has_rpath "$binary" "$HOST_FRAMEWORKS_RPATH"; then
    install_name_tool -add_rpath "$HOST_FRAMEWORKS_RPATH" "$binary" 2>/dev/null
fi
# install_name_tool invalidated the linker signature; arm64 refuses to load unsigned code.
codesign --force --sign - "$binary" 2>/dev/null || fail "플러그인 실행 파일에 임시 서명을 하지 못했어요."

say "notchkit-probe로 PluginManifest를 읽어요."
swift build -c release --package-path "$PROBE_PACKAGE" >&2 || fail "notchkit-probe를 빌드하지 못했어요."
probe="$(swift build -c release --package-path "$PROBE_PACKAGE" --show-bin-path)/notchkit-probe"
manifest=$("$probe" --manifest "$binary" "$ENTRY_SYMBOL") || fail "PluginManifest를 읽지 못했어요."
field() {
    printf '%s\n' "$manifest" | sed -n "s/^$1=//p"
}
plugin_id=$(field id)
plugin_name=$(field name)
plugin_version=$(field version)
sdk_version=$(field sdk)

plist="$bundle/Contents/Info.plist"
cat >"$plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
EOF
plist_set() {
    plutil -insert "$1" -string "$2" "$plist" || fail "Info.plist에 $1 값을 쓰지 못했어요."
}
plist_set CFBundleIdentifier "$plugin_id"
plist_set CFBundleName "$plugin_name"
plist_set CFBundleExecutable "$name"
plist_set CFBundlePackageType BNDL
plist_set CFBundleInfoDictionaryVersion 6.0
plist_set CFBundleShortVersionString "$plugin_version"
plist_set CFBundleVersion "$plugin_version"
plist_set LSMinimumSystemVersion 14.0
plist_set NotchKitSDKVersion "$sdk_version"
plist_set NotchPluginEntry "$ENTRY_SYMBOL"

if identity=$("$ROOT/scripts/signing-identity.sh" --find); then
    codesign --force --timestamp=none --sign "$identity" "$bundle" 2>/dev/null || fail "로컬 인증서로 서명하지 못했어요."
else
    say "로컬 서명 인증서가 없어서 임시 서명(ad-hoc)으로 서명해요. 앱에 넣을 때 build-app.sh가 다시 서명해요."
    codesign --force --sign - "$bundle" 2>/dev/null || fail "번들에 임시 서명을 하지 못했어요."
fi

rm -rf "$out/$name.notchplugin"
mv "$bundle" "$out/$name.notchplugin"
printf '%s\n' "$out/$name.notchplugin"
