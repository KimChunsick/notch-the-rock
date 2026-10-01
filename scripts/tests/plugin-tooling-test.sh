#!/bin/bash
# R03: a plugin scaffolded by new-plugin.sh builds with build-plugin.sh into a .notchplugin that
# links the shared NotchKit exactly once, carries its SwiftPM resources where the installed plugin
# finds them, and notchkit-probe loads it and rejects a wrong SDK major. check-plugin-deps.sh has
# its own checks in check-plugin-deps-test.sh. R16: the built plugin records the SDK version written
# in SDKVersion.swift (1.1 added the tile API), read from the source rather than repeated here.
# Helpers (R05 notch-hook, R08 the MediaRemote library): the package's executable and extra dynamic
# library products land signed in Contents/Helpers, run and load from there, and a helper that links
# NotchKit is refused. Requires bash 3.2 or later.
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

# Prints NotchKitSDK.version as major.minor from SDKVersion.swift, the one place it is written, or
# nothing when the declaration no longer has that shape.
source_sdk_version() {
    sed -n 's/.*static var version: SDKVersion { SDKVersion(major: \([0-9][0-9]*\), minor: \([0-9][0-9]*\)) }.*/\1.\2/p' \
        "$ROOT/SDK/NotchKit/Sources/NotchKit/SDKVersion.swift"
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
    [ "$(/usr/libexec/PlistBuddy -c 'Print :NotchPluginEntry' "$plist")" = "notchkit_plugin_entry" ] || fail "NotchPluginEntry is not notchkit_plugin_entry"
    codesign --verify --strict "$BUNDLE" || fail "bundle signature does not verify"
}

R16__plugin_records_sdk_version_from_source() {
    current=${FUNCNAME[0]}
    local expected stamped
    [ -f "$BUNDLE/Contents/Info.plist" ] || { fail "no bundle to inspect"; return; }
    expected=$(source_sdk_version)
    [ -n "$expected" ] || { fail "could not read NotchKitSDK.version from SDKVersion.swift"; return; }
    stamped=$(/usr/libexec/PlistBuddy -c 'Print :NotchKitSDKVersion' "$BUNDLE/Contents/Info.plist")
    printf 'SDKVersion.swift: %s, Info.plist NotchKitSDKVersion: %s\n' "$expected" "$stamped"
    [ "$stamped" = "$expected" ] || fail "NotchKitSDKVersion is '$stamped', SDKVersion.swift says '$expected'"
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

# signing_authority <path>: the signer lines of a signature ("Authority=..." or "Signature=adhoc").
signing_authority() {
    local details
    details=$(codesign -dvv "$1" 2>&1)
    printf '%s\n' "$details" | grep -E '^(Authority=|Signature=adhoc)'
}

# A plugin package with an executable helper, a dynamic library helper and a static library product,
# all small C targets. Written in full so the fixture does not follow template edits.
write_helper_fixture() {
    local dir="$WORK/Helped"
    "$ROOT/scripts/new-plugin.sh" Helped --dir "$WORK" >/dev/null || return 1
    mkdir -p "$dir/Sources/HelloHelper" "$dir/Sources/Greeter/include"
    cat >"$dir/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Helped",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Helped", type: .dynamic, targets: ["Helped"]),
        .executable(name: "hello-helper", targets: ["HelloHelper"]),
        .library(name: "Greeter", type: .dynamic, targets: ["Greeter"]),
        .library(name: "GreeterStatic", type: .static, targets: ["Greeter"]),
    ],
    dependencies: [.package(path: "$ROOT/SDK/NotchKit")],
    targets: [
        .target(name: "Helped", dependencies: [.product(name: "NotchKit", package: "NotchKit")]),
        .executableTarget(name: "HelloHelper"),
        .target(name: "Greeter"),
    ]
)
EOF
    printf '#include <stdio.h>\nint main(void) { puts("hello from helper"); return 0; }\n' >"$dir/Sources/HelloHelper/main.c"
    printf 'int greeter_answer(void);\n' >"$dir/Sources/Greeter/include/greeter.h"
    printf '#include "greeter.h"\nint greeter_answer(void) { return 42; }\n' >"$dir/Sources/Greeter/greeter.c"
}

R03__build_plugin_ships_helper_products() {
    current=${FUNCNAME[0]}
    local built helpers output plugin_signer signer helper references
    [ -d "$BUNDLE/Contents" ] || { fail "no Sample bundle to inspect"; return; }
    [ ! -e "$BUNDLE/Contents/Helpers" ] || fail "a package without helper products got Contents/Helpers"
    write_helper_fixture || { fail "could not write the helper fixture"; return; }
    built=$("$ROOT/scripts/build-plugin.sh" "$WORK/Helped" --out "$WORK/helped-out") || { fail "build-plugin.sh failed on a plugin with helpers"; return; }
    helpers=$(cd "$built/Contents" && find Helpers MacOS -print 2>&1 | sort)
    printf 'bundle code:\n%s\n' "$helpers"
    [ "$helpers" = $'Helpers\nHelpers/hello-helper\nHelpers/libGreeter.dylib\nMacOS\nMacOS/Helped' ] \
        || fail "expected Helpers/hello-helper and Helpers/libGreeter.dylib next to MacOS/Helped, and no static library"
    # The plugin's own binary is packaged as before: the probe loads it the way the app does.
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$built/Contents/Info.plist")" = "Helped" ] || fail "CFBundleExecutable is not Helped"
    references=$(otool -L "$built/Contents/MacOS/Helped" | awk '/NotchKit/ { print $1 }')
    [ "$references" = "@rpath/libNotchKit.dylib" ] || fail "plugin NotchKit references are '$references'"
    output=$(probe "$built" 2>&1) || fail "notchkit-probe did not load the plugin with helpers: $output"
    contains "$output" 'id: com.example.helped' || fail "probe did not print the manifest"
    # The executable runs from the bundle; /usr/bin/perl, the NowPlaying host process, loads the library.
    output=$("$built/Contents/Helpers/hello-helper" 2>&1) || fail "hello-helper exited non-zero: $output"
    [ "$output" = "hello from helper" ] || fail "hello-helper printed '$output'"
    output=$(/usr/bin/perl -MDynaLoader -e 'my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error(), "\n"; DynaLoader::dl_find_symbol($lib, "greeter_answer") or die "greeter_answer not found\n"; print "loaded\n"' "$built/Contents/Helpers/libGreeter.dylib" 2>&1)
    [ "$output" = "loaded" ] || fail "/usr/bin/perl could not load libGreeter.dylib: $output"
    # Helpers carry the bundle's signer, and the bundle seals them.
    plugin_signer=$(signing_authority "$built")
    printf 'bundle signer:\n%s\n' "$plugin_signer"
    for helper in "$built/Contents/Helpers/hello-helper" "$built/Contents/Helpers/libGreeter.dylib"; do
        codesign --verify --strict "$helper" || fail "$(basename "$helper") is not validly signed"
        signer=$(signing_authority "$helper")
        [ "$signer" = "$plugin_signer" ] || fail "$(basename "$helper") is signed by '$signer', the bundle by '$plugin_signer'"
    done
    codesign --verify --deep --strict "$built" || fail "bundle with helpers does not verify"
    # build-app.sh signs the copied bundle again with the app identity; the helpers' signatures stay sealed.
    mkdir -p "$WORK/HelperHost.app/Contents/PlugIns"
    cp -R "$built" "$WORK/HelperHost.app/Contents/PlugIns/"
    signer=$("$ROOT/scripts/signing-identity.sh" --find) || signer=-
    codesign --force --timestamp=none --sign "$signer" "$WORK/HelperHost.app/Contents/PlugIns/Helped.notchplugin" \
        || fail "re-signing the bundle with helpers failed"
    codesign --verify --deep --strict "$WORK/HelperHost.app/Contents/PlugIns/Helped.notchplugin" \
        || fail "re-signed bundle with helpers does not verify"
}

R03__build_plugin_refuses_helper_linking_notchkit() {
    current=${FUNCNAME[0]}
    local output status
    [ -f "$WORK/Helped/Package.swift" ] || { fail "no helper fixture to extend"; return; }
    # A helper runs in its own process, outside the app that holds the only NotchKit copy.
    mkdir -p "$WORK/Helped/Sources/KitHelper"
    printf 'import NotchKit\nprint(NotchKitSDK.version)\n' >"$WORK/Helped/Sources/KitHelper/main.swift"
    perl -pi -e 's/(\.executable\(name: "hello-helper")/.executable(name: "kit-helper", targets: ["KitHelper"]),\n        $1/; s/(\.executableTarget\(name: "HelloHelper"\),)/$1\n        .executableTarget(name: "KitHelper", dependencies: [.product(name: "NotchKit", package: "NotchKit")]),/' "$WORK/Helped/Package.swift"
    output=$("$ROOT/scripts/build-plugin.sh" "$WORK/Helped" --out "$WORK/kit-out" 2>&1)
    status=$?
    printf '%s\n(exit %s)\n' "$(printf '%s\n' "$output" | grep '^build-plugin:')" "$status"
    [ "$status" -ne 0 ] || fail "build-plugin.sh accepted a helper that links NotchKit"
    contains "$output" 'kit-helper' || fail "the refusal does not name the helper"
    [ ! -e "$WORK/kit-out/Helped.notchplugin" ] || fail "a refused build left a bundle behind"
}

R03__new_plugin_scaffolds_and_builds
R16__plugin_records_sdk_version_from_source
R03__plugin_links_single_shared_notchkit
R03__probe_loads_plugin_with_one_notchkit
R03__probe_rejects_wrong_major_sdk
R03__installed_plugin_finds_its_resources
R03__build_plugin_ships_helper_products
R03__build_plugin_refuses_helper_linking_notchkit

if [ "$failures" -ne 0 ]; then
    printf '%d check(s) failed\n' "$failures"
    exit 1
fi
printf 'all R03 and R16 tooling checks passed\n'
