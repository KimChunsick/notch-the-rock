#!/bin/bash
# R13: scripts/install-app.sh stops before it builds, copies, quits or launches anything when it is
# given an unknown argument or a destination it cannot write to. The destination is a read-only
# scratch folder (NOTCH_INSTALL_DIR) and --no-build is passed, so nothing is ever installed.
# Requires bash 3.2 or later.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK"; rm -rf "$WORK"' EXIT
READONLY="$WORK/readonly"
mkdir "$READONLY" && chmod 555 "$READONLY"
failures=0
current=""

fail() {
    printf 'FAIL %s: %s\n' "$current" "$*"
    failures=$((failures + 1))
}

# contains <text> <fixed-string>
contains() {
    case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac
}

# run_install <args>...: sets `output` and `status`.
run_install() {
    output=$(NOTCH_INSTALL_DIR="$READONLY" "$ROOT/scripts/install-app.sh" "$@" 2>&1)
    status=$?
    printf '%s\n(exit %s)\n' "$output" "$status"
}

R13__install_app_refuses_an_unknown_argument() {
    current=${FUNCNAME[0]}
    run_install --no-build --bogus
    [ "$status" -ne 0 ] || fail "an unknown argument did not make install-app.sh fail"
    contains "$output" "알 수 없는 인자예요: --bogus" || fail "the unknown argument is not named"
}

R13__install_app_refuses_a_destination_it_cannot_write() {
    current=${FUNCNAME[0]}
    run_install --no-build
    [ "$status" -ne 0 ] || fail "a read-only destination did not make install-app.sh fail"
    contains "$output" "폴더에 쓸 수 없어요" || fail "no message about the unwritable destination"
    contains "$output" "관리자 계정" || fail "the message does not point to an admin account"
    [ -z "$(ls -A "$READONLY")" ] || fail "something was written into the read-only destination"
}

R13__install_app_refuses_an_unknown_argument
R13__install_app_refuses_a_destination_it_cannot_write

if [ "$failures" -ne 0 ]; then
    printf '%d check(s) failed\n' "$failures"
    exit 1
fi
printf 'all R13 install-app.sh checks passed\n'
