#!/bin/bash
# R03: scripts/check-plugin-deps.sh rejects plugins that depend on anything but NotchKit: through
# the manifest (package and target dependencies, unsafeFlags) or through any module the compiler
# loads while it builds the plugin, whatever the import form (attributes, access levels, kinds,
# backticks, several statements on a line), the `#if` condition that enables it (canImport, a target
# define, the language mode, a debug or a release build) or the text around it. Text that only looks
# like an import, in comments and in string or regex literals, is none, and a plugin that does not
# build fails. A plugin reaches no module that another plugin built. Helper products (executables and
# dynamic libraries other than the plugin's own, D-23) are built and traced as well: a helper may load
# only SDK and toolchain modules and the package targets its own build compiled, never NotchKit
# (D-29), and reaches no module that another build of its package built. Every built binary's dylib
# load commands are read as well, so a library linked through linker settings alone counts: the plugin's
# product may link system libraries, NotchKit and the package's helper libraries, a helper the same but
# NotchKit. The repository's Plugins/ pass, and the check leaves them untouched.
#
# Every checker run builds NotchKit in release and in debug, so all fixtures sit in one plugins folder
# that the checker reads once. A fixture reaches a fake NotchTheRock (standing for the app) or Other
# (standing for another plugin) module through `unsafeFlags(["-I", ...])`, so that it builds and the
# build's module trace has something to name; the unsafeFlags rule fails it as well. A fixture links a
# fake libNotchTheRock.dylib the same way, through `unsafeFlags(["-L", ...])`.
# Requires bash 3.2 or later, swift, xcrun and python3 (Command Line Tools).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)
PLUGINS="$WORK/plugins"
FAKE="$WORK/fake-modules"
REACH_FAKE=", swiftSettings: [.unsafeFlags([\"-I\", \"$FAKE\"])]"
FAKE_LIBS="$WORK/fake-libs"
LINK_FAKE=", linkerSettings: [.linkedLibrary(\"NotchTheRock\"), .unsafeFlags([\"-L\", \"$FAKE_LIBS\"])]"
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

# reported <plugin> <message>: the checker printed a line starting with "<plugin>: <message>".
reported() {
    contains $'\n'"$OUTPUT" $'\n'"$1: $2"
}

# loads <plugin> <target> <configurations> <module>: the trace line for a module the target loaded.
loads() {
    reported "$1" "타깃 $2의 $3 빌드가 NotchKit이 아닌 모듈을 불러와요: $4 ("
}

# make_fake_module <Name> <source>: a Swift module in $FAKE that no plugin declares, built for the
# plugins' deployment target and with testing enabled so that `@testable import` accepts it.
make_fake_module() {
    mkdir -p "$FAKE"
    printf '%s\n' "$2" >"$WORK/$1.swift"
    xcrun swiftc -emit-module -parse-as-library -enable-testing -module-name "$1" \
        -target "$(uname -m)-apple-macosx14.0" -o "$FAKE/$1.swiftmodule" "$WORK/$1.swift" \
        || { printf 'could not build the fake module %s\n' "$1"; exit 1; }
}

# write_fixture <Name> <extra package dependency or ""> <extra target dependency or ""> <source>
#   [<extra arguments of target Name>] [<extra package arguments>]
# A plugin package in $PLUGINS whose product <Name> holds target <Name> (NotchKit and <Name>Core)
# and the own target <Name>Core. <source> follows `import NotchKit` in Sources/<Name>/<Name>.swift.
write_fixture() {
    local dir="$PLUGINS/$1"
    mkdir -p "$dir/Sources/$1" "$dir/Sources/$1Core"
    cat >"$dir/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "$1",
    platforms: [.macOS(.v14)],
    products: [.library(name: "$1", type: .dynamic, targets: ["$1"])],
    dependencies: [.package(path: "$ROOT/SDK/NotchKit")$2],
    targets: [
        .target(name: "$1Core"),
        .target(name: "$1", dependencies: [.product(name: "NotchKit", package: "NotchKit"), "$1Core"$3]${5:-}),
    ]${6:-}
)
EOF
    printf 'import NotchKit\n%s\n' "$4" >"$dir/Sources/$1/$1.swift"
    printf 'let core = 1\n' >"$dir/Sources/$1Core/$1Core.swift"
}

# write_helpers <Name> <helper products> <helper targets>: a plugin package like write_fixture's (product
# <Name> of target <Name>, which depends on NotchKit and <Name>Core) whose manifest also lists the given
# products and targets. The caller writes the helper targets' sources.
write_helpers() {
    write_fixture "$1" "" "" ""
    cat >"$PLUGINS/$1/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "$1",
    platforms: [.macOS(.v14)],
    products: [.library(name: "$1", type: .dynamic, targets: ["$1"])$2],
    dependencies: [.package(path: "$ROOT/SDK/NotchKit")],
    targets: [
        .target(name: "$1Core"),
        .target(name: "$1", dependencies: [.product(name: "NotchKit", package: "NotchKit"), "$1Core"]),
$3
    ]
)
EOF
}

# write_source <plugin> <target> <path in the target> <source>
write_source() {
    mkdir -p "$(dirname "$PLUGINS/$1/Sources/$2/$3")"
    printf '%s\n' "$4" >"$PLUGINS/$1/Sources/$2/$3"
}

# One target of the Forms fixture per import form the compiler accepts: <name> <module it imports>
# <source>. Target Forms<name> holds <name>.swift and must be named on its own. Globals of a regex or
# function type are `nonisolated(unsafe)` and `!` gets an overload for regexes, because the build
# type-checks in Swift 6 mode; the text before each import stays as it was.
FORMS=(
    Internal NotchTheRock 'internal import NotchTheRock'
    Semicolon NotchTheRock 'import NotchKit; import NotchTheRock'
    Public NotchTheRock 'public import NotchTheRock'
    PackageLevel NotchTheRock 'package import NotchTheRock'
    Fileprivate NotchTheRock 'fileprivate import NotchTheRock'
    Private NotchTheRock 'private import NotchTheRock'
    Testable NotchTheRock '@testable import NotchTheRock'
    ImplementationOnly NotchTheRock '@_implementationOnly import NotchTheRock'
    Preconcurrency NotchTheRock '@preconcurrency import NotchTheRock'
    Combined NotchTheRock $'@preconcurrency @_spi(Host)\ninternal import NotchTheRock'
    KindStruct NotchTheRock 'import struct NotchTheRock.NotchHostModel'
    KindFunc NotchTheRock 'import func NotchTheRock.makeHost'
    Backticks NotchTheRock 'import `NotchTheRock`'
    OtherPlugin Other 'import NotchKit; @testable internal import Other'
    # A quote inside a regex literal opens no string that could hide the next line.
    AfterExtendedRegex NotchTheRock $'nonisolated(unsafe) let pattern = #/"""/#\nimport NotchTheRock'
    AfterBareRegex NotchTheRock $'nonisolated(unsafe) let quote = /"""/\nimport NotchTheRock'
    AfterPrefixedRegex NotchTheRock $'prefix func ! (regex: Regex<Substring>) -> Regex<Substring> { regex }\nnonisolated(unsafe) let negated = !/"""/\nimport NotchTheRock'
    # A `/` that Swift reads as an operator starts no regex literal that could hide an import.
    AfterDivision NotchTheRock 'let width = 4; let half = width/2; import NotchTheRock; let third = width/3'
    AfterOperatorFunction NotchTheRock $'struct Ratio {}\nfunc /(a: Ratio, b: Ratio) -> Ratio { a }; import NotchTheRock; let q = 4/2'
    AfterOperatorDeclaration NotchTheRock 'infix operator /+; import NotchTheRock; let a = 4/2'
    AfterOperatorReference NotchTheRock 'nonisolated(unsafe) let divide: (Int, Int) -> Int = (/); import NotchTheRock; let z = 4/2'
    # Review round 019: a backtick right after `import`, and an extended regex literal whose opening
    # delimiter is followed by a space before the line ends, with quotes inside it.
    BacktickAfterImport NotchTheRock 'import`NotchTheRock`'
    AfterSpacedExtendedRegex NotchTheRock $'nonisolated(unsafe) let r = #/ \n"""\n/#\nimport NotchTheRock\nlet s = """\nexample\n"""'
    # Imports that only one build configuration compiles.
    DebugOnly NotchTheRock $'#if DEBUG\nimport NotchTheRock\n#endif'
    ReleaseOnly NotchTheRock $'#if DEBUG\n#else\nimport NotchTheRock\n#endif'
)

# The configurations whose build compiles the import of a form.
form_configurations() {
    case "$1" in
        DebugOnly) printf 'debug' ;;
        ReleaseOnly) printf 'release' ;;
        *) printf 'release, debug' ;;
    esac
}

write_forms() {
    local dir="$PLUGINS/Forms" index form targets="" names=""
    for ((index = 0; index < ${#FORMS[@]}; index += 3)); do
        form=${FORMS[index]}
        mkdir -p "$dir/Sources/Forms$form"
        printf '%s\n' "${FORMS[index + 2]}" >"$dir/Sources/Forms$form/$form.swift"
        targets="$targets        .target(name: \"Forms$form\", dependencies: [.product(name: \"NotchKit\", package: \"NotchKit\")]$REACH_FAKE),"$'\n'
        names="$names, \"Forms$form\""
    done
    mkdir -p "$dir/Sources/Forms"
    printf 'import NotchKit\n' >"$dir/Sources/Forms/Forms.swift"
    cat >"$dir/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Forms",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Forms", type: .dynamic, targets: ["Forms"])],
    dependencies: [.package(path: "$ROOT/SDK/NotchKit")],
    targets: [
$targets        .target(name: "Forms", dependencies: [.product(name: "NotchKit", package: "NotchKit")$names]),
    ]
)
EOF
}

make_fake_module NotchTheRock $'public struct NotchHostModel { public init() {} }\npublic func makeHost() {}'
make_fake_module Other 'public struct Thing {}'
mkdir -p "$WORK/fake-package/NotchTheRock/Sources/NotchTheRock"
cat >"$WORK/fake-package/NotchTheRock/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "NotchTheRock",
    products: [.library(name: "NotchTheRock", targets: ["NotchTheRock"])],
    targets: [.target(name: "NotchTheRock")]
)
EOF
printf 'public struct NotchHostModel {}\n' >"$WORK/fake-package/NotchTheRock/Sources/NotchTheRock/NotchTheRock.swift"
# A dynamic library standing for the app's own code, linked as @rpath/libNotchTheRock.dylib.
mkdir -p "$FAKE_LIBS"
printf 'int notchtherock_host(void) { return 1; }\n' >"$WORK/host.c"
xcrun clang -dynamiclib -target "$(uname -m)-apple-macosx14.0" -install_name @rpath/libNotchTheRock.dylib \
    -o "$FAKE_LIBS/libNotchTheRock.dylib" "$WORK/host.c" || { printf 'could not build the fake library\n'; exit 1; }

# Plugins that must pass.
write_fixture Good "" "" ""
write_fixture Quoted "" "" ""
cat >>"$PLUGINS/Quoted/Sources/Quoted/Quoted.swift" <<'EOF'
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
write_fixture Clean "" "" ""
cat >"$PLUGINS/Clean/Sources/Clean/Regex.swift" <<'EOF'
prefix func ! (regex: Regex<Substring>) -> Regex<Substring> { regex }
nonisolated(unsafe) let multiline = #/
  import NotchTheRock
/#
nonisolated(unsafe) let bare = /x; import NotchTheRock/
nonisolated(unsafe) let escaped = /a\/; import NotchTheRock/
nonisolated(unsafe) let extended = #/x; import NotchTheRock/#
nonisolated(unsafe) let doubled = ##/a/#; import NotchTheRock/##
nonisolated(unsafe) let prefixed = !/x; import NotchTheRock/
nonisolated(unsafe) let grouped = (/x; import NotchTheRock/)
nonisolated(unsafe) let r = /[(]; import NotchTheRock/
EOF
cat >"$PLUGINS/Clean/Sources/Clean/Quotes.swift" <<'EOF'
nonisolated(unsafe) let pattern = #/"""/#
let text = """
import NotchTheRock
"""
nonisolated(unsafe) let quote = /"""/
let more = """
import NotchTheRock
"""
EOF
cat >"$PLUGINS/Clean/Sources/Clean/Text.swift" <<'EOF'
// import NotchKit; import NotchTheRock
/* internal import NotchTheRock */
let plain = "import NotchKit; import NotchTheRock"
let raw = #"x"; @testable import NotchTheRock"#
let ratio = 4 / 2 // ; import NotchTheRock
EOF

# Plugins that must fail. SwiftPM names a path dependency after its folder, so the app package is
# referred to by that name.
write_fixture UsesApp ", .package(path: \"$ROOT\")" ", .product(name: \"NotchTheRock\", package: \"$(basename "$ROOT")\")" ""
write_fixture UsesPlugin ", .package(path: \"../Good\")" ", .product(name: \"Good\", package: \"Good\")" ""
write_fixture ImportsApp "" "" "import NotchTheRock"
# Real imports right after a string with an interpolation and after a line comment.
write_fixture Sneaky "" "" "" "$REACH_FAKE"
cat >>"$PLUGINS/Sneaky/Sources/Sneaky/Sneaky.swift" <<'EOF'
let text = "\("a" + "\"") /* not a comment"
import NotchTheRock
// a /* in a line comment opens nothing
import Other
EOF
write_forms
# A Swift module has no submodules, so this import does not build even with NotchTheRock reachable.
write_fixture Submodule "" "" 'import NotchTheRock.Window' "$REACH_FAKE"
write_fixture Broken "" "" ""
printf 'let x = (\nimport NotchKit\n' >"$PLUGINS/Broken/Sources/Broken/Syntax.swift"
# Review round 023: imports that only the build's own settings enable.
write_fixture CanImportDep ", .package(path: \"$WORK/fake-package/NotchTheRock\")" \
    ", .product(name: \"NotchTheRock\", package: \"NotchTheRock\")" $'#if canImport(NotchKit)\nimport NotchTheRock\n#endif'
write_fixture CanImportFlags "" "" $'#if canImport(NotchKit)\nimport NotchTheRock\n#endif' "$REACH_FAKE"
write_fixture HostBridge "" "" $'#if HOST_BRIDGE\nimport NotchTheRock\n#endif' \
    ", swiftSettings: [.define(\"HOST_BRIDGE\"), .unsafeFlags([\"-I\", \"$FAKE\"])]"
write_fixture SwiftFive "" "" $'#if swift(<6)\nimport NotchTheRock\n#endif' "$REACH_FAKE" $',\n    swiftLanguageModes: [.v5]'
# Review round 030: Earlier builds the module Earlier. Later, checked after it, imports Earlier in its
# library and declares an unbuilt test target of that name (the fifth argument closes target Later
# and adds the test target), but depends on nothing that builds it.
write_fixture Earlier "" "" ""
write_fixture Later "" "" 'import Earlier' '), .testTarget(name: "Earlier"'
mkdir -p "$PLUGINS/Later/Tests/Earlier"
printf 'let unused = 1\n' >"$PLUGINS/Later/Tests/Earlier/Earlier.swift"
# Helper products (D-23). HelperApp's helpers import the app module, reachable only for app-hook, and
# the plugin's own HelperAppCore, which stray-hook does not depend on.
write_helpers HelperApp \
    ', .executable(name: "app-hook", targets: ["AppHook"]), .library(name: "AppBridge", type: .dynamic, targets: ["AppBridge"]), .executable(name: "stray-hook", targets: ["StrayHook"])' \
    "        .executableTarget(name: \"AppHook\"$REACH_FAKE), .target(name: \"AppBridge\"), .executableTarget(name: \"StrayHook\"),"
write_source HelperApp AppHook main.swift $'import NotchTheRock\nprint("hook")'
write_source HelperApp AppBridge AppBridge.swift 'import NotchTheRock'
write_source HelperApp StrayHook main.swift $'import HelperAppCore\nprint("stray")'
# A helper that depends on NotchKit, which only the app process carries (D-29).
write_helpers HelperKit ', .executable(name: "kit-hook", targets: ["KitHook"])' \
    '        .executableTarget(name: "KitHook", dependencies: [.product(name: "NotchKit", package: "NotchKit")]),'
write_source HelperKit KitHook main.swift $'import NotchKit\nprint(NotchKitSDK.version)'
# Clean helpers: a Swift executable on Foundation and the plugin's own HelperCleanCore, which the
# plugin's product builds as well, a C dynamic library, and a static library that is no helper.
write_helpers HelperClean \
    ', .executable(name: "clean-hook", targets: ["CleanHook"]), .library(name: "Greeter", type: .dynamic, targets: ["Greeter"]), .library(name: "GreeterStatic", type: .static, targets: ["Greeter"])' \
    '        .executableTarget(name: "CleanHook", dependencies: ["HelperCleanCore"]), .target(name: "Greeter"),'
write_source HelperClean CleanHook main.swift $'import Foundation\nimport HelperCleanCore\nprint(ProcessInfo.processInfo.processIdentifier)'
write_source HelperClean Greeter include/greeter.h 'int greeter_answer(void);'
write_source HelperClean Greeter greeter.c $'#include "greeter.h"\nint greeter_answer(void) { return 42; }'
# Review round 043: libraries linked through linker settings alone, which no module trace shows. LinksApp's
# product links the fake app library. HelperLink's C helper AppLink and Swift helper app-link link it too,
# and AppLinkUnreached asks for it without unsafeFlags, so the linker does not find it. HelperKitLink's
# helpers link NotchKit, which the linker finds in the build folder, without unsafeFlags or an import.
write_fixture LinksApp "" "" "" "$LINK_FAKE"
write_helpers HelperLink \
    ', .library(name: "AppLink", type: .dynamic, targets: ["AppLink"]), .executable(name: "app-link", targets: ["AppLinkSwift"]), .library(name: "AppLinkUnreached", type: .dynamic, targets: ["AppLinkUnreached"])' \
    "        .target(name: \"AppLink\"$LINK_FAKE), .executableTarget(name: \"AppLinkSwift\"$LINK_FAKE), .target(name: \"AppLinkUnreached\", linkerSettings: [.linkedLibrary(\"NotchTheRock\")]),"
write_source HelperLink AppLink include/app_link.h 'int app_link_answer(void);'
write_source HelperLink AppLink app_link.c $'#include "app_link.h"\nint app_link_answer(void) { return 42; }'
write_source HelperLink AppLinkSwift main.swift 'print("link")'
write_source HelperLink AppLinkUnreached include/app_link_unreached.h 'int app_link_unreached_answer(void);'
write_source HelperLink AppLinkUnreached app_link_unreached.c $'#include "app_link_unreached.h"\nint app_link_unreached_answer(void) { return 42; }'
write_helpers HelperKitLink \
    ', .library(name: "KitLink", type: .dynamic, targets: ["KitLink"]), .executable(name: "kit-link", targets: ["KitLinkSwift"])' \
    '        .target(name: "KitLink", linkerSettings: [.linkedLibrary("NotchKit")]), .executableTarget(name: "KitLinkSwift", linkerSettings: [.linkedLibrary("NotchKit")]),'
write_source HelperKitLink KitLink include/kit_link.h 'int kit_link_answer(void);'
write_source HelperKitLink KitLink kit_link.c $'#include "kit_link.h"\nint kit_link_answer(void) { return 42; }'
write_source HelperKitLink KitLinkSwift main.swift 'print("kit link")'

OUTPUT=$("$ROOT/scripts/check-plugin-deps.sh" "$PLUGINS" 2>&1)
STATUS=$?
printf '%s\n(exit %s)\n' "$OUTPUT" "$STATUS"

R03__check_plugin_deps_accepts_clean_plugins() {
    current=${FUNCNAME[0]}
    local output status plugin marker="$WORK/before-real-plugins"
    touch "$marker"
    sleep 1
    output=$("$ROOT/scripts/check-plugin-deps.sh" 2>&1)
    status=$?
    printf '%s\n(exit %s)\n' "$output" "$status"
    [ "$status" -eq 0 ] || fail "check-plugin-deps.sh failed on the repository's Plugins/"
    contains "$output" "모두 NotchKit만 의존해요" || fail "no summary that every plugin passed"
    [ -z "$(find "$ROOT/Plugins" -newer "$marker" -print)" ] || fail "the check wrote into Plugins/: $(find "$ROOT/Plugins" -newer "$marker" -print | head -n 3)"
    for plugin in Good Quoted Clean HelperClean; do
        ! reported "$plugin" "" || fail "the clean plugin $plugin was reported"
    done
    contains "$OUTPUT" "플러그인 22개 중 17개가 검사를 통과하지 못했어요" || fail "not exactly the 17 failing fixtures failed"
}

R03__check_plugin_deps_rejects_app_and_plugin_dependencies() {
    current=${FUNCNAME[0]}
    [ "$STATUS" -ne 0 ] || fail "check-plugin-deps.sh passed plugins that depend on the app or another plugin"
    reported UsesApp "패키지 의존성은 NotchKit만 쓸 수 있어요" || fail "UsesApp is not named"
    ! reported UsesApp "Package.swift" || fail "UsesApp fixture manifest is invalid, so the dependency rule was not exercised"
    reported UsesApp "NotchKit 말고 다른 패키지를 의존해서 빌드하지 않았어요" || fail "UsesApp was built or the skipped build is not said"
    reported UsesPlugin "패키지 의존성은 NotchKit만 쓸 수 있어요" || fail "UsesPlugin is not named"
    # The app module is not reachable from a plugin build, so importing it is a build failure.
    reported ImportsApp "release 빌드에 실패해서" || fail "ImportsApp is not named as a build failure"
    contains "$OUTPUT" "no such module 'NotchTheRock'" || fail "the build error of ImportsApp is not shown"
}

R03__check_plugin_deps_ignores_imports_in_comments_and_strings() {
    current=${FUNCNAME[0]}
    ! reported Quoted "" || fail "imports inside comments or strings were treated as dependencies"
    loads Sneaky Sneaky "release, debug" NotchTheRock || fail "the import after the string literal is not named"
    loads Sneaky Sneaky "release, debug" Other || fail "the import after the line comment is not named"
}

R03__check_plugin_deps_rejects_every_import_form() {
    current=${FUNCNAME[0]}
    local index form
    for ((index = 0; index < ${#FORMS[@]}; index += 3)); do
        form=${FORMS[index]}
        loads Forms "Forms$form" "$(form_configurations "$form")" "${FORMS[index + 1]}" || fail "Forms$form ($form.swift) is not reported"
    done
    ! loads Forms FormsDebugOnly "release, debug" NotchTheRock || fail "the debug-only import was reported for release"
    ! loads Forms FormsReleaseOnly "release, debug" NotchTheRock || fail "the release-only import was reported for debug"
    ! reported Forms "타깃 Forms의" || fail "the target importing only NotchKit was reported"
    reported Forms "타깃 FormsInternal의 설정에 unsafeFlags가 있어요" || fail "the unsafeFlags that reach the fake module are not named"
    reported Submodule "release 빌드에 실패해서" || fail "the submodule import is not named as a build failure"
}

R03__check_plugin_deps_ignores_imports_in_regex_literals() {
    current=${FUNCNAME[0]}
    ! reported Clean "" || fail "text inside regex literals, comments or strings was treated as an import"
}

# A plugin that does not build cannot be shown to be free of imports, so it fails the check and the
# compiler's error names the file.
R03__check_plugin_deps_fails_on_a_file_the_compiler_cannot_parse() {
    current=${FUNCNAME[0]}
    reported Broken "release 빌드에 실패해서" || fail "the plugin that does not build is not named"
    contains "$OUTPUT" "Broken/Syntax.swift:" || fail "the file that does not parse is not named"
    ! contains "$OUTPUT" "Broken/Broken.swift:" || fail "the file that parses was reported"
}

# Review round 023: imports behind `#if canImport(NotchKit)`, a target define and `#if swift(<6)` in
# a package that selects Swift 5 all count, because the build decides them.
R03__check_plugin_deps_sees_imports_the_build_settings_enable() {
    current=${FUNCNAME[0]}
    reported CanImportDep "패키지 의존성은 NotchKit만 쓸 수 있어요" || fail "the dependency on a NotchTheRock package is not named"
    reported CanImportDep "타깃 CanImportDep은 NotchKit과 자기 타깃만 의존할 수 있어요" || fail "the target dependency on NotchTheRock is not named"
    reported CanImportFlags "타깃 CanImportFlags의 설정에 unsafeFlags가 있어요 (swift): -I $FAKE" || fail "the unsafeFlags of CanImportFlags are not named"
    loads CanImportFlags CanImportFlags "release, debug" NotchTheRock || fail "the import behind canImport(NotchKit) is not in the trace"
    loads HostBridge HostBridge "release, debug" NotchTheRock || fail "the import behind the HOST_BRIDGE define is not in the trace"
    loads SwiftFive SwiftFive "release, debug" NotchTheRock || fail "the import behind swift(<6) in Swift 5 mode is not in the trace"
}

# Review round 030: every plugin builds in a scratch folder that holds only NotchKit and its own build.
# In the folder the plugins once shared, Later found the module Earlier that the Earlier plugin had
# built there and passed, because the declared test target made the name its own. In its own folder
# the import of Earlier does not build, so Later fails as a build failure.
R03__check_plugin_deps_builds_each_plugin_on_its_own() {
    current=${FUNCNAME[0]}
    ! reported Earlier "" || fail "the clean plugin Earlier was reported"
    reported Later "release 빌드에 실패해서" || fail "Later passed with the module that the Earlier plugin built"
    contains "$OUTPUT" "no such module 'Earlier'" || fail "the build error of Later does not name the module Earlier"
}

# helper_checked <plugin> <helper>: the checker said it built and checked the helper product.
helper_checked() {
    contains "$OUTPUT" "check-plugin-deps: 도우미를 빌드해서 확인해요: $1 $2"$'\n'
}

# D-23, D-29: every executable and extra dynamic library product is built and traced like the plugin's
# own product. A helper loads only SDK and toolchain modules and the targets its own build compiled:
# the app module, reached or not, and NotchKit fail and name the helper; a Swift helper on Foundation
# and an own target, and a C helper, pass. A static library is no helper and is not built.
R03__check_plugin_deps_checks_helper_products() {
    current=${FUNCNAME[0]}
    reported HelperApp "도우미 app-hook: 타깃 AppHook의 release, debug 빌드가 도우미가 쓸 수 없는 모듈을 불러와요: NotchTheRock (" \
        || fail "the helper app-hook that imports the app module is not named"
    reported HelperApp "도우미 AppBridge: release 빌드에 실패해서" || fail "the helper AppBridge that does not build is not named"
    contains "$OUTPUT" "AppBridge.swift:1:8: error: no such module 'NotchTheRock'" || fail "the build error of AppBridge is not shown"
    # Each configuration has a NotchKit build of its own, so each is named with its path.
    reported HelperKit "도우미 kit-hook: 타깃 KitHook의 release 빌드가 NotchKit을 불러와요 (" \
        || fail "the helper kit-hook that imports NotchKit is not named for release"
    reported HelperKit "도우미 kit-hook: 타깃 KitHook의 debug 빌드가 NotchKit을 불러와요 (" \
        || fail "the helper kit-hook that imports NotchKit is not named for debug"
    ! reported HelperApp "타깃 HelperApp의" || fail "the plugin product of HelperApp was reported"
    ! reported HelperKit "타깃 HelperKit의" || fail "the plugin product of HelperKit was reported"
    ! reported HelperClean "" || fail "the clean helpers of HelperClean were reported"
    helper_checked HelperClean clean-hook || fail "the Swift helper clean-hook was not checked"
    helper_checked HelperClean Greeter || fail "the C helper Greeter was not checked"
    ! helper_checked HelperClean GreeterStatic || fail "the static library GreeterStatic was checked as a helper"
    ! helper_checked HelperClean HelperClean || fail "the plugin's own product was checked as a helper"
}

# Every helper builds in a scratch folder of its own, restored from NotchKit's build: stray-hook does
# not reach HelperAppCore, which the plugin's product build compiles, and clean-hook compiles the
# HelperCleanCore it shares with the plugin's product itself, so its trace names it.
R03__check_plugin_deps_builds_each_helper_on_its_own() {
    current=${FUNCNAME[0]}
    reported HelperApp "도우미 stray-hook: release 빌드에 실패해서" || fail "stray-hook passed with a module another build left"
    contains "$OUTPUT" "no such module 'HelperAppCore'" || fail "the build error of stray-hook does not name HelperAppCore"
    ! reported HelperClean "도우미 clean-hook" || fail "clean-hook was refused the own target it shares with the plugin"
}

# Review round 043: a library linked through linker settings alone fails, named with the product, the
# configurations and its install name. Without unsafeFlags the linker searches only the SDK and the build
# folder, which holds NotchKit's build and the package's own products: the app library is not found there,
# so AppLinkUnreached does not build, and NotchKit is, so the helpers that link it fail by their load
# commands. A plugin's product may link NotchKit; HelperClean's helpers link only system libraries.
R03__check_plugin_deps_checks_linked_libraries() {
    current=${FUNCNAME[0]}
    reported LinksApp "제품 LinksApp의 release, debug 빌드가 NotchKit이 아닌 라이브러리를 링크해요: @rpath/libNotchTheRock.dylib" \
        || fail "the plugin product LinksApp that links the app library is not named"
    reported HelperLink "도우미 AppLink: release, debug 빌드가 도우미가 쓸 수 없는 라이브러리를 링크해요: @rpath/libNotchTheRock.dylib" \
        || fail "the C helper AppLink that links the app library is not named"
    reported HelperLink "도우미 app-link: release, debug 빌드가 도우미가 쓸 수 없는 라이브러리를 링크해요: @rpath/libNotchTheRock.dylib" \
        || fail "the Swift helper app-link that links the app library is not named"
    reported HelperLink "도우미 AppLinkUnreached: release 빌드에 실패해서" || fail "AppLinkUnreached linked the app library without unsafeFlags"
    contains "$OUTPUT" "ld: library 'NotchTheRock' not found" || fail "the link error of AppLinkUnreached does not name the library"
    reported HelperKitLink "도우미 KitLink: release, debug 빌드가 NotchKit을 링크해요 (@rpath/libNotchKit.dylib). " \
        || fail "the C helper KitLink that links NotchKit is not named"
    reported HelperKitLink "도우미 kit-link: release, debug 빌드가 NotchKit을 링크해요 (@rpath/libNotchKit.dylib). " \
        || fail "the Swift helper kit-link that links NotchKit is not named"
    ! reported HelperKitLink "제품 HelperKitLink의" || fail "the plugin product's link to NotchKit was reported"
    ! reported HelperClean "" || fail "the clean helpers of HelperClean were reported"
}

R03__check_plugin_deps_accepts_clean_plugins
R03__check_plugin_deps_rejects_app_and_plugin_dependencies
R03__check_plugin_deps_ignores_imports_in_comments_and_strings
R03__check_plugin_deps_rejects_every_import_form
R03__check_plugin_deps_ignores_imports_in_regex_literals
R03__check_plugin_deps_fails_on_a_file_the_compiler_cannot_parse
R03__check_plugin_deps_sees_imports_the_build_settings_enable
R03__check_plugin_deps_builds_each_plugin_on_its_own
R03__check_plugin_deps_checks_helper_products
R03__check_plugin_deps_builds_each_helper_on_its_own
R03__check_plugin_deps_checks_linked_libraries

if [ "$failures" -ne 0 ]; then
    printf '%d check(s) failed\n' "$failures"
    exit 1
fi
printf 'all R03 check-plugin-deps.sh checks passed\n'
