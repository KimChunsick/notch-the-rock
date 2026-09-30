#!/bin/bash
# R03: scripts/check-plugin-deps.sh rejects plugins that depend on anything but NotchKit, through
# the manifest or through any Swift import form (attributes, access levels, kinds, submodules,
# backticks, several statements on a line), and ignores text that only looks like an import: in
# comments, string literals and regex literals. A quote inside a regex literal opens no string, so
# real imports after it still count. Builds nothing; each fixture is read with
# `swift package dump-package`. Requires bash 3.2 or later.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd "$WORK" && pwd -P)
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

# The Swift files of the Forms fixture: <file name> <module it imports> <source>, one per import form
# the compiler accepts. Each must be reported on its own.
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
    Submodule NotchTheRock 'import NotchTheRock.Window'
    Backticks NotchTheRock 'import `NotchTheRock`'
    OtherPlugin Other 'import NotchKit; @testable internal import Other'
    # A quote inside a regex literal opens no string that could hide the next line.
    AfterExtendedRegex NotchTheRock $'let pattern = #/"""/#\nimport NotchTheRock'
    AfterBareRegex NotchTheRock $'let quote = /"""/\nimport NotchTheRock'
    AfterPrefixedRegex NotchTheRock $'let negated = !/"""/\nimport NotchTheRock'
    # A `/` that Swift reads as an operator starts no regex literal that could hide an import.
    AfterDivision NotchTheRock 'let width = 4; let half = width/2; import NotchTheRock; let third = width/3'
    AfterOperatorFunction NotchTheRock $'struct Ratio {}\nfunc /(a: Ratio, b: Ratio) -> Ratio { a }; import NotchTheRock; let q = 4/2'
    AfterOperatorDeclaration NotchTheRock 'infix operator /+; import NotchTheRock; let a = 4/2'
    AfterOperatorReference NotchTheRock 'let divide: (Int, Int) -> Int = (/); import NotchTheRock; let z = 4/2'
)

R03__check_plugin_deps_rejects_every_import_form() {
    current=${FUNCNAME[0]}
    local output status index sources="$WORK/forms/Forms/Sources/Forms"
    write_fixture "$WORK/forms" Other "" "" ""
    write_fixture "$WORK/forms" Forms "" "" ""
    for ((index = 0; index < ${#FORMS[@]}; index += 3)); do
        printf '%s\n' "${FORMS[index + 2]}" >"$sources/${FORMS[index]}.swift"
    done
    output=$("$ROOT/scripts/check-plugin-deps.sh" "$WORK/forms" 2>&1)
    status=$?
    printf '%s\n(exit %s)\n' "$output" "$status"
    [ "$status" -ne 0 ] || fail "check-plugin-deps.sh passed a plugin that imports the app and another plugin"
    for ((index = 0; index < ${#FORMS[@]}; index += 3)); do
        contains "$output" "Forms: Sources/Forms/${FORMS[index]}.swift에서 NotchKit이 아닌 모듈을 가져와요: ${FORMS[index + 1]}" \
            || fail "${FORMS[index]}.swift is not reported"
    done
    ! contains "$output" 'Forms.swift에서' || fail "the file importing only NotchKit was reported"
}

R03__check_plugin_deps_ignores_imports_in_regex_literals() {
    current=${FUNCNAME[0]}
    local output status sources="$WORK/regex/Clean/Sources/Clean"
    write_fixture "$WORK/regex" Clean "" "" ""
    cat >"$sources/Regex.swift" <<'EOF'
let multiline = #/
  import NotchTheRock
/#
let bare = /x; import NotchTheRock/
let escaped = /a\/; import NotchTheRock/
let extended = #/x; import NotchTheRock/#
let doubled = ##/a/#; import NotchTheRock/##
let prefixed = !/x; import NotchTheRock/
let grouped = (/x; import NotchTheRock/)
EOF
    cat >"$sources/Quotes.swift" <<'EOF'
let pattern = #/"""/#
let text = """
import NotchTheRock
"""
let quote = /"""/
let more = """
import NotchTheRock
"""
EOF
    cat >"$sources/Text.swift" <<'EOF'
// import NotchKit; import NotchTheRock
/* internal import NotchTheRock */
let plain = "import NotchKit; import NotchTheRock"
let raw = #"x"; @testable import NotchTheRock"#
let ratio = 4 / 2 // ; import NotchTheRock
EOF
    output=$("$ROOT/scripts/check-plugin-deps.sh" "$WORK/regex" 2>&1)
    status=$?
    printf '%s\n(exit %s)\n' "$output" "$status"
    [ "$status" -eq 0 ] || fail "text inside regex literals, comments or strings was treated as an import"
    ! contains "$output" 'Clean:' || fail "the clean plugin was reported"
}

R03__check_plugin_deps_accepts_clean_plugins
R03__check_plugin_deps_rejects_app_and_plugin_dependencies
R03__check_plugin_deps_ignores_imports_in_comments_and_strings
R03__check_plugin_deps_rejects_every_import_form
R03__check_plugin_deps_ignores_imports_in_regex_literals

if [ "$failures" -ne 0 ]; then
    printf '%d check(s) failed\n' "$failures"
    exit 1
fi
printf 'all R03 check-plugin-deps.sh checks passed\n'
