#!/bin/bash
# R03: a plugin scaffolded by new-plugin.sh builds with build-plugin.sh into a .notchplugin that
# links the shared NotchKit exactly once, carries its SwiftPM resources where the installed plugin
# finds them, and notchkit-probe loads it and rejects a wrong SDK major. check-plugin-deps.sh has
# its own checks in check-plugin-deps-test.sh. Requires bash 3.2 or later.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)
BUNDLE="$WORK/out/Sample.notchplugin"
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

probe() {
    "$(swift build -c release --package-path "$ROOT/SDK/NotchKit/Probe" --show-bin-path)/notchkit-probe" "$@"
}

R03__new_plugin_scaffolds_and_builds() {
    current=${FUNCNAME[0]}
    local built
    "$ROOT/scripts/new-plugin.sh" Sample --dir "$WORK" || { fail "new-plugin.sh failed"; return; }
    built=$("$ROOT/scripts/build-plugin.sh" "$WORK/Sample" --out "$WORK/out") || { fail "build-plugin.sh failed"; return; }
    [ "$built" = "$BUNDLE" ] || fail "build-plugin.sh printed '$built', expected '$BUNDLE'"
    [ -f "$BUNDLE/Contents/MacOS/Sample" ] || fail "missing Contents/MacOS/Sample"
    [ -d "$BUNDLE/Contents/Resources" ] || fail "missing Contents/Resources"
    local plist="$BUNDLE/Contents/Info.plist"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "com.example.sample" ] || fail "CFBundleIdentifier is not com.example.sample"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :NotchKitSDKVersion' "$plist")" = "1.0" ] || fail "NotchKitSDKVersion is not 1.0"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :NotchPluginEntry' "$plist")" = "notchkit_plugin_entry" ] || fail "NotchPluginEntry is not notchkit_plugin_entry"
    codesign --verify --strict "$BUNDLE" || fail "bundle signature does not verify"
}

R03__plugin_links_single_shared_notchkit() {
    current=${FUNCNAME[0]}
    [ -f "$BUNDLE/Contents/MacOS/Sample" ] || { fail "no bundle to inspect"; return; }
    local references rpaths frameworks
    references=$(otool -L "$BUNDLE/Contents/MacOS/Sample" | awk '/NotchKit/ { print $1 }')
    [ "$references" = "@rpath/libNotchKit.dylib" ] || fail "NotchKit references are '$references', expected exactly @rpath/libNotchKit.dylib"
    rpaths=$(otool -l "$BUNDLE/Contents/MacOS/Sample" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }')
    printf 'rpaths:\n%s\n' "$rpaths"
    contains "$rpaths" '@loader_path/../../../../Frameworks' || fail "rpath to the host's Frameworks is missing"
    ! contains $'\n'"$rpaths"$'\n' $'\n@loader_path\n' || fail "rpath @loader_path would find a NotchKit copy next to the plugin"
    [ -z "$(find "$BUNDLE" -name '*NotchKit*')" ] || fail "the bundle ships its own NotchKit"
    # In an app, Contents/PlugIns/X.notchplugin/Contents/MacOS/../../../../Frameworks is Contents/Frameworks.
    mkdir -p "$WORK/Host.app/Contents/Frameworks" "$WORK/Host.app/Contents/PlugIns"
    cp -R "$BUNDLE" "$WORK/Host.app/Contents/PlugIns/"
    frameworks=$(cd "$WORK/Host.app/Contents/PlugIns/Sample.notchplugin/Contents/MacOS/../../../../Frameworks" && pwd -P)
    [ "$frameworks" = "$WORK/Host.app/Contents/Frameworks" ] || fail "rpath resolves to $frameworks inside an app"
}

R03__probe_loads_plugin_with_one_notchkit() {
    current=${FUNCNAME[0]}
    local output status loaded
    output=$(DYLD_PRINT_LIBRARIES=1 probe "$BUNDLE" 2>&1)
    status=$?
    # Show the probe's own lines and the non-system images it loaded.
    printf '%s\n' "$output" | grep -vE 'dyld\[[0-9]+\]: (move|<[^>]*> /(usr|System)/)'
    [ "$status" -eq 0 ] || { fail "notchkit-probe exited $status"; return; }
    contains "$output" 'id: com.example.sample' || fail "probe did not print the manifest"
    contains "$output" 'expandedTab: Sample' || fail "probe did not find the expanded tab"
    loaded=$(printf '%s\n' "$output" | grep -c 'libNotchKit.dylib$')
    [ "$loaded" = "1" ] || fail "libNotchKit.dylib was loaded $loaded times"
}

R03__probe_rejects_wrong_major_sdk() {
    current=${FUNCNAME[0]}
    local output status
    cp -R "$BUNDLE" "$WORK/Wrong.notchplugin"
    /usr/libexec/PlistBuddy -c 'Set :NotchKitSDKVersion 2.0' "$WORK/Wrong.notchplugin/Contents/Info.plist"
    output=$(probe "$WORK/Wrong.notchplugin" 2>&1)
    status=$?
    printf '%s\n(exit %s)\n' "$output" "$status"
    [ "$status" -ne 0 ] || fail "probe accepted a bundle built for SDK 2.0"
    contains "$output" '2.0' || fail "reason does not name the bundle's SDK version"
    contains "$output" '주 버전' || fail "reason does not say the major version differs"
}

R03__installed_plugin_finds_its_resources() {
    current=${FUNCNAME[0]}
    local built output status installed="$WORK/Installed/Plugins/Sample.notchplugin"
    local source="$WORK/Sample/Sources/Sample/SamplePlugin.swift"
    [ -d "$WORK/Sample" ] || { fail "no Sample package to add a resource to"; return; }
    # A SwiftPM resource that the plugin reads the way the docs tell plugin authors to: through its
    # context, from the installed bundle. The tab title shows what it read.
    mkdir -p "$WORK/Sample/Sources/Sample/Resources"
    printf 'greeting-from-resources\n' >"$WORK/Sample/Sources/Sample/Resources/greeting.txt"
    perl -pi -e 's/(\.product\(name: "NotchKit", package: "NotchKit"\)\])\)/$1, resources: [.copy("Resources\/greeting.txt")])/' "$WORK/Sample/Package.swift"
    perl -pi -e 's/PluginTab\(title: "Sample"/PluginTab(title: greeting/' "$source"
    cat >>"$source" <<'EOF'

extension SamplePlugin {
    var greeting: String {
        guard let url = context.resourceBundle(named: "Sample_Sample")?.url(forResource: "greeting", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "resource missing" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
EOF
    built=$("$ROOT/scripts/build-plugin.sh" "$WORK/Sample" --out "$WORK/resources-out") || { fail "build-plugin.sh failed on a plugin with resources"; return; }
    (cd "$built" && find . -path './Contents/Resources*' -print)
    [ -f "$built/Contents/Resources/Sample_Sample.bundle/greeting.txt" ] || fail "the resource bundle is not in Contents/Resources"
    codesign --verify --deep --strict "$built" || fail "bundle with resources does not verify"
    # Installed on its own: the package and its build folder, where Bundle.module would look, are gone.
    mkdir -p "$(dirname "$installed")"
    cp -R "$built" "$installed"
    rm -rf "$WORK/Sample" "$WORK/resources-out"
    output=$(probe "$installed" 2>&1)
    status=$?
    printf '%s\n(exit %s)\n' "$output" "$status"
    [ "$status" -eq 0 ] || { fail "notchkit-probe exited $status"; return; }
    contains "$output" 'expandedTab: greeting-from-resources' || fail "the installed plugin did not read its resource"
}

R03__new_plugin_scaffolds_and_builds
R03__plugin_links_single_shared_notchkit
R03__probe_loads_plugin_with_one_notchkit
R03__probe_rejects_wrong_major_sdk
R03__installed_plugin_finds_its_resources

if [ "$failures" -ne 0 ]; then
    printf '%d check(s) failed\n' "$failures"
    exit 1
fi
printf 'all R03 tooling checks passed\n'
