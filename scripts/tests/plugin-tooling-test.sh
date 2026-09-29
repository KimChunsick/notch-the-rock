#!/bin/bash
# R03: a plugin scaffolded by new-plugin.sh builds with build-plugin.sh into a .notchplugin that
# links the shared NotchKit exactly once, carries its SwiftPM resources where the installed plugin
# finds them, notchkit-probe loads it and rejects a wrong SDK major, and check-plugin-deps.sh rejects
# plugins that depend on anything but NotchKit, ignoring imports inside comments and strings.
# Requires bash 3.2 or later.
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

# write_fixture <plugins-dir> <Name> <extra package dependency or ""> <extra target dependency or ""> <import or "">
write_fixture() {
    local dir="$1/$2"
    mkdir -p "$dir/Sources/$2"
    cat >"$dir/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "$2",
    platforms: [.macOS(.v14)],
    products: [.library(name: "$2", type: .dynamic, targets: ["$2"])],
    dependencies: [.package(path: "$ROOT/SDK/NotchKit")$3],
    targets: [
        .target(name: "$2Core"),
        .target(name: "$2", dependencies: [.product(name: "NotchKit", package: "NotchKit"), "$2Core"$4]),
    ]
)
EOF
    printf 'import NotchKit\n%s\n' "$5" >"$dir/Sources/$2/$2.swift"
}

R03__check_plugin_deps_accepts_clean_plugins() {
    current=${FUNCNAME[0]}
    "$ROOT/scripts/check-plugin-deps.sh" || fail "check-plugin-deps.sh failed on the repository's Plugins/"
    write_fixture "$WORK/good" Good "" "" ""
    "$ROOT/scripts/check-plugin-deps.sh" "$WORK/good" || fail "check-plugin-deps.sh rejected a NotchKit-only plugin"
}

R03__check_plugin_deps_rejects_app_and_plugin_dependencies() {
    current=${FUNCNAME[0]}
    local output status
    write_fixture "$WORK/bad" Good "" "" ""
    # SwiftPM names a path dependency after its folder, so the app package is referred to by that name.
    write_fixture "$WORK/bad" UsesApp ", .package(path: \"$ROOT\")" ", .product(name: \"NotchTheRock\", package: \"$(basename "$ROOT")\")" ""
    write_fixture "$WORK/bad" UsesPlugin ", .package(path: \"../Good\")" ", .product(name: \"Good\", package: \"Good\")" ""
    write_fixture "$WORK/bad" ImportsApp "" "" "import NotchTheRock"
    output=$("$ROOT/scripts/check-plugin-deps.sh" "$WORK/bad" 2>&1)
    status=$?
    printf '%s\n(exit %s)\n' "$output" "$status"
    [ "$status" -ne 0 ] || fail "check-plugin-deps.sh passed plugins that depend on the app or another plugin"
    contains "$output" 'UsesApp' || fail "UsesApp is not named"
    ! contains "$output" "UsesApp: Package.swift" || fail "UsesApp fixture manifest is invalid, so the dependency rule was not exercised"
    contains "$output" 'UsesPlugin' || fail "UsesPlugin is not named"
    contains "$output" 'ImportsApp' || fail "ImportsApp is not named"
    ! contains "$output" 'Good:' || fail "the clean plugin was reported"
}

R03__check_plugin_deps_ignores_imports_in_comments_and_strings() {
    current=${FUNCNAME[0]}
    local output status
    write_fixture "$WORK/quoted" Quoted "" "" ""
    cat >>"$WORK/quoted/Quoted/Sources/Quoted/Quoted.swift" <<'EOF'
/*
import NotchTheRock
/* a nested comment
import NotchTheRock
*/
import NotchTheRock
*/
let example = """
import NotchTheRock
"""
let raw = #"""
"\(not an interpolation)"
import NotchTheRock
"""#
EOF
    "$ROOT/scripts/check-plugin-deps.sh" "$WORK/quoted" || fail "imports inside comments or strings were treated as dependencies"
    # Real imports right after a string with an interpolation and after a line comment still count.
    write_fixture "$WORK/quoted-bad" Other "" "" ""
    write_fixture "$WORK/quoted-bad" Sneaky "" "" ""
    cat >>"$WORK/quoted-bad/Sneaky/Sources/Sneaky/Sneaky.swift" <<'EOF'
let text = "\("a" + "\"") /* not a comment"
import NotchTheRock
// a /* in a line comment opens nothing
import Other
EOF
    output=$("$ROOT/scripts/check-plugin-deps.sh" "$WORK/quoted-bad" 2>&1)
    status=$?
    printf '%s\n(exit %s)\n' "$output" "$status"
    [ "$status" -ne 0 ] || fail "real imports after a string and a line comment were missed"
    contains "$output" ': NotchTheRock' || fail "the import after the string literal is not named"
    contains "$output" ': Other' || fail "the import after the line comment is not named"
}

R03__new_plugin_scaffolds_and_builds
R03__plugin_links_single_shared_notchkit
R03__probe_loads_plugin_with_one_notchkit
R03__probe_rejects_wrong_major_sdk
R03__installed_plugin_finds_its_resources
R03__check_plugin_deps_accepts_clean_plugins
R03__check_plugin_deps_rejects_app_and_plugin_dependencies
R03__check_plugin_deps_ignores_imports_in_comments_and_strings

if [ "$failures" -ne 0 ]; then
    printf '%d check(s) failed\n' "$failures"
    exit 1
fi
printf 'all R03 tooling checks passed\n'
