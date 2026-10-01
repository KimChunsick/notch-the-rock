#!/bin/bash
# R03: scripts/check-plugin-deps.sh rejects plugins that depend on anything but NotchKit: through
# the manifest (package and target dependencies, unsafeFlags) or through any module the compiler
# loads while it builds the plugin, whatever the import form (attributes, access levels, kinds,
# backticks, several statements on a line), the `#if` condition that enables it (canImport, a target
# define, the language mode, a debug or a release build) or the text around it. Text that only looks
# like an import, in comments and in string or regex literals, is none, and a plugin that does not
# build fails. The repository's Plugins/ pass, and the check leaves them untouched.
#
# Every checker run builds NotchKit in release and in debug, so all fixtures sit in one plugins folder
# that the checker reads once. A fixture reaches a fake NotchTheRock (standing for the app) or Other
# (standing for another plugin) module through `unsafeFlags(["-I", ...])`, so that it builds and the
# build's module trace has something to name; the unsafeFlags rule fails it as well.
# Requires bash 3.2 or later, swift, xcrun and python3 (Command Line Tools).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)
PLUGINS="$WORK/plugins"
FAKE="$WORK/fake-modules"
REACH_FAKE=", swiftSettings: [.unsafeFlags([\"-I\", \"$FAKE\"])]"
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
    for plugin in Good Quoted Clean; do
        ! reported "$plugin" "" || fail "the clean plugin $plugin was reported"
    done
    contains "$OUTPUT" "플러그인 14개 중 11개가 검사를 통과하지 못했어요" || fail "not exactly the 11 failing fixtures failed"
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

R03__check_plugin_deps_accepts_clean_plugins
R03__check_plugin_deps_rejects_app_and_plugin_dependencies
R03__check_plugin_deps_ignores_imports_in_comments_and_strings
R03__check_plugin_deps_rejects_every_import_form
R03__check_plugin_deps_ignores_imports_in_regex_literals
R03__check_plugin_deps_fails_on_a_file_the_compiler_cannot_parse
R03__check_plugin_deps_sees_imports_the_build_settings_enable

if [ "$failures" -ne 0 ]; then
    printf '%d check(s) failed\n' "$failures"
    exit 1
fi
printf 'all R03 check-plugin-deps.sh checks passed\n'
