#!/bin/bash
# R13: scripts/install-app.sh stops before it builds, copies, quits or launches anything when it is
# given an unknown argument or a destination it cannot write to, and it never loses the previously
# installed app: a failure at the swap, at restoring or at the verify/launch step leaves the previous
# app at the final path or at the backup path it reports, and only a successful install removes it.
# A launched copy that the pid detection never saw is stopped before rollback moves it away.
#
# Nothing here touches /Applications or a running NotchTheRock. Every destination is a scratch
# folder (NOTCH_INSTALL_DIR), --no-build is always passed, and the failure checks run a copy of the
# script next to a fake build/NotchTheRock.app with `lsappinfo`, `open`, `codesign` and `mv` shimmed
# on PATH. The `lsappinfo` shim reports no running copy until the `open` shim has run, so the script
# never quits a real process. The only process any check starts is the fake app of a sandbox bundle,
# and rollback finds it by that sandbox path.
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

# The shims read INSTALL_TEST_STATE (a folder for their records) and INSTALL_TEST_FAIL (the steps
# that fail: swap, restore, verify-installed, launch; unlisted: the app starts a second after `open`
# returns but is never listed, so the pid detection times out; started-then-failed: `open` starts
# the app, Launch Services lists a pid that is already gone, and `open` still fails).
SHIMS="$WORK/shims"
mkdir "$SHIMS"
cat >"$SHIMS/lsappinfo" <<'EOF'
#!/bin/bash
# 999999 is above the macOS pid limit, so no kill can reach a real process.
[ -e "$INSTALL_TEST_STATE/launched" ] && printf '"pid"=999999\n'
exit 0
EOF
cat >"$SHIMS/open" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$INSTALL_TEST_STATE/open.log"
case " $INSTALL_TEST_FAIL " in
    *" launch "*) echo "open: injected failure" >&2; exit 1 ;;
    *" unlisted "*) (sleep 1; exec "$1/Contents/MacOS/NotchTheRock") </dev/null >/dev/null 2>&1 & exit 0 ;;
    *" started-then-failed "*)
        "$1/Contents/MacOS/NotchTheRock" </dev/null >/dev/null 2>&1 &
        waited=0
        until [ -s "$INSTALL_TEST_STATE/app.pid" ] || [ "$waited" -ge 50 ]; do sleep 0.1; waited=$((waited + 1)); done
        touch "$INSTALL_TEST_STATE/launched"
        echo "open: injected failure after the app started" >&2
        exit 1 ;;
esac
touch "$INSTALL_TEST_STATE/launched"
EOF
cat >"$SHIMS/codesign" <<'EOF'
#!/bin/bash
for target; do :; done
case "$target: $INSTALL_TEST_FAIL " in
    */NotchTheRock.app:*" verify-installed "*) echo "codesign: injected failure" >&2; exit 1 ;;
esac
exit 0
EOF
cat >"$SHIMS/mv" <<'EOF'
#!/bin/bash
source=${@:$#-1:1}
case "$(basename "$source"): $INSTALL_TEST_FAIL " in
    .NotchTheRock-install.*:*" swap "*|.NotchTheRock-old.*:*" restore "*) echo "mv: injected failure" >&2; exit 1 ;;
esac
exec /bin/mv "$@"
EOF
chmod +x "$SHIMS"/*

SANDBOX="$WORK/sandbox"
APPS="$SANDBOX/Applications"
FINAL="$APPS/NotchTheRock.app"

# What keeps the real app safe: the script must find the shims before the system commands.
if [ "$(PATH="$SHIMS:$PATH" command -v lsappinfo)" != "$SHIMS/lsappinfo" ] \
    || [ "$(PATH="$SHIMS:$PATH" command -v open)" != "$SHIMS/open" ]; then
    printf 'the lsappinfo/open shims are not first on PATH; refusing to run install-app.sh\n'
    exit 1
fi

# make_bundle <path> <marker>: a fake app whose Contents/marker tells the old copy from the new one.
# Its executable runs until it is stopped; on TERM it records the marker of the app then installed at
# the path it was started from.
make_bundle() {
    mkdir -p "$1/Contents/MacOS"
    printf '%s\n' "$2" >"$1/Contents/marker"
    cat >"$1/Contents/MacOS/NotchTheRock" <<'EOF'
#!/bin/bash
printf '%s\n' "$$" >"$INSTALL_TEST_STATE/app.pid"
trap 'cat "$(dirname "$0")/../marker" >"$INSTALL_TEST_STATE/app.stopped" 2>/dev/null; exit 0' TERM
while :; do sleep 0.1; done
EOF
    chmod +x "$1/Contents/MacOS/NotchTheRock"
}

marker() {
    cat "$1/Contents/marker" 2>/dev/null
}

# run_sandboxed <failing steps>: a fresh sandbox with an "old" app installed and a "new" one built;
# runs the copied script with the shims and sets `output` and `status`.
run_sandboxed() {
    rm -rf "$SANDBOX"
    mkdir -p "$SANDBOX/repo/scripts" "$SANDBOX/state" "$APPS"
    cp "$ROOT/scripts/install-app.sh" "$SANDBOX/repo/scripts/install-app.sh"
    make_bundle "$SANDBOX/repo/build/NotchTheRock.app" new
    make_bundle "$FINAL" old
    output=$(PATH="$SHIMS:$PATH" INSTALL_TEST_STATE="$SANDBOX/state" INSTALL_TEST_FAIL="$1" \
        NOTCH_INSTALL_DIR="$APPS" "$SANDBOX/repo/scripts/install-app.sh" --no-build 2>&1)
    status=$?
    printf '%s\n(exit %s)\n' "$output" "$status"
}

# The previous app is back at the final path and nothing else is left in the destination.
expect_restored() {
    [ "$status" -ne 0 ] || fail "the failed install exited 0"
    [ "$(marker "$FINAL")" = old ] || fail "the previous app is not back at $FINAL (marker: $(marker "$FINAL"))"
    contains "$output" "이전 앱을 ${FINAL}에 되돌려 놓았어요" || fail "no message that the previous app was restored"
    [ "$(ls -A "$APPS")" = NotchTheRock.app ] || fail "left over in the destination: $(ls -A "$APPS" | tr '\n' ' ')"
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

R13__install_app_restores_the_previous_app_when_the_swap_fails() {
    current=${FUNCNAME[0]}
    run_sandboxed swap
    contains "$output" "새 앱을 제자리에 옮기지 못했어요" || fail "the failed swap is not named"
    expect_restored
}

R13__install_app_keeps_the_backup_when_restoring_fails() {
    current=${FUNCNAME[0]}
    run_sandboxed "swap restore"
    [ "$status" -ne 0 ] || fail "the failed install exited 0"
    local backup
    backup=$(printf '%s\n' "$output" | sed -n 's/.*이전 앱은 \(.*\)에 남겨 뒀어요.*/\1/p' | head -n 1)
    [ -n "$backup" ] || { fail "no message naming where the previous app was left"; return; }
    [ "$(marker "$backup")" = old ] || fail "the previous app is not at the reported path $backup"
}

R13__install_app_restores_the_previous_app_when_the_installed_copy_fails_verification() {
    current=${FUNCNAME[0]}
    run_sandboxed verify-installed
    contains "$output" "설치한 앱의 서명 검증에 실패했어요" || fail "the failed verification is not named"
    [ ! -e "$SANDBOX/state/open.log" ] || fail "the app was launched after its signature failed"
    expect_restored
}

R13__install_app_restores_the_previous_app_when_launch_fails() {
    current=${FUNCNAME[0]}
    run_sandboxed launch
    contains "$output" "앱을 실행하지 못했어요" || fail "the failed launch is not named"
    expect_restored
}

# expect_new_app_stopped: the fake app started from the new bundle ran, no longer runs, and was
# stopped while the new bundle was still at the final path.
expect_new_app_stopped() {
    local pid
    pid=$(cat "$SANDBOX/state/app.pid" 2>/dev/null)
    [ -n "$pid" ] || fail "the new app never started, so there was nothing to stop"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        fail "the app launched from the new bundle still runs (pid $pid)"
        kill -KILL "$pid"
    fi
    [ "$(cat "$SANDBOX/state/app.stopped" 2>/dev/null)" = new ] || fail "the app was not stopped while the new bundle was still at $FINAL"
}

R13__install_app_stops_an_unlisted_launch_before_restoring() {
    current=${FUNCNAME[0]}
    run_sandboxed unlisted
    contains "$output" "앱이 10초 안에 실행되지 않았어요" || fail "the timed-out pid detection is not named"
    expect_new_app_stopped
    expect_restored
}

# Launch Services lists 999999, which is not running and sorts after every real pid; the running app
# must still be found and stopped.
R13__install_app_stops_a_started_app_next_to_a_stale_listed_pid() {
    current=${FUNCNAME[0]}
    run_sandboxed started-then-failed
    contains "$output" "앱을 실행하지 못했어요" || fail "the failed launch is not named"
    expect_new_app_stopped
    expect_restored
}

R13__install_app_replaces_the_app_and_removes_the_backup_after_success() {
    current=${FUNCNAME[0]}
    run_sandboxed ""
    [ "$status" -eq 0 ] || fail "a successful install exited $status"
    [ "$(marker "$FINAL")" = new ] || fail "the new app is not at $FINAL"
    [ "$(cat "$SANDBOX/state/open.log" 2>/dev/null)" = "$FINAL" ] || fail "the installed app was not launched"
    [ "$(ls -A "$APPS")" = NotchTheRock.app ] || fail "left over in the destination: $(ls -A "$APPS" | tr '\n' ' ')"
}

R13__install_app_refuses_an_unknown_argument
R13__install_app_refuses_a_destination_it_cannot_write
R13__install_app_restores_the_previous_app_when_the_swap_fails
R13__install_app_keeps_the_backup_when_restoring_fails
R13__install_app_restores_the_previous_app_when_the_installed_copy_fails_verification
R13__install_app_restores_the_previous_app_when_launch_fails
R13__install_app_stops_an_unlisted_launch_before_restoring
R13__install_app_stops_a_started_app_next_to_a_stale_listed_pid
R13__install_app_replaces_the_app_and_removes_the_backup_after_success

if [ "$failures" -ne 0 ]; then
    printf '%d check(s) failed\n' "$failures"
    exit 1
fi
printf 'all R13 install-app.sh checks passed\n'
