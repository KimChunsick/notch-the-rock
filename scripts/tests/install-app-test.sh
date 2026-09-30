#!/bin/bash
# R13: scripts/install-app.sh stops before it builds, copies, quits or launches anything when it is
# given an unknown argument or a destination it cannot write to, and it never loses the previously
# installed app: a failure at the swap, at restoring or at the verify/launch step leaves the previous
# app at the final path or at the backup path it reports, and only a successful install removes it.
# A launched copy that the pid detection never saw is stopped before rollback moves it away. Rollback
# signals only processes whose executable is the new bundle's: never one that merely names that path
# in its arguments, never another copy of the app. When the new app cannot be stopped, both the new
# bundle and the previous app stay where they are, the message names both, and the exit is non-zero.
#
# Nothing here touches /Applications or a running NotchTheRock. Every destination is a scratch
# folder (NOTCH_INSTALL_DIR), --no-build is always passed, and the failure checks run a copy of the
# script next to a fake build/NotchTheRock.app with `lsappinfo`, `open`, `codesign` and `mv` shimmed
# on PATH. The `lsappinfo` shim reports no running copy until the `open` shim has run, so the script
# never quits a real process. The processes the checks start are the fake app of a sandbox bundle,
# a fake app of a scratch copy outside the sandbox and a shell that only names the sandbox bundle.
# The fake app is a small C program built with `cc`, because the script tells processes apart by
# the executable file they run, and a shell script's executable is the shell.
# Requires bash 3.2 or later, cc and lsof (Command Line Tools and macOS).
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
WORK=$(mktemp -d)
# Processes a check starts itself; the exit trap ends whatever of them still runs.
helpers=""
trap 'kill -KILL $helpers 2>/dev/null; chmod -R u+w "$WORK"; rm -rf "$WORK"' EXIT
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
# the app, Launch Services lists a pid that is already gone, and `open` still fails;
# listed-then-failed: `open` starts nothing, Launch Services lists INSTALL_TEST_LISTED_PID, and
# `open` fails; respawning: `open` starts the app under a loop that starts it again whenever it
# exits, and fails).
SHIMS="$WORK/shims"
mkdir "$SHIMS"
cat >"$SHIMS/lsappinfo" <<'EOF'
#!/bin/bash
# 999999 is above the macOS pid limit, so no kill can reach a real process.
[ -e "$INSTALL_TEST_STATE/launched" ] && printf '"pid"=%s\n' "${INSTALL_TEST_LISTED_PID:-999999}"
exit 0
EOF
cat >"$SHIMS/open" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$INSTALL_TEST_STATE/open.log"
wait_for_app() {
    waited=0
    until [ -s "$INSTALL_TEST_STATE/app.pid" ] || [ "$waited" -ge 50 ]; do sleep 0.1; waited=$((waited + 1)); done
}
case " $INSTALL_TEST_FAIL " in
    *" launch "*) echo "open: injected failure" >&2; exit 1 ;;
    *" unlisted "*) (sleep 1; exec "$1/Contents/MacOS/NotchTheRock") </dev/null >/dev/null 2>&1 & exit 0 ;;
    *" started-then-failed "*)
        "$1/Contents/MacOS/NotchTheRock" </dev/null >/dev/null 2>&1 &
        wait_for_app
        touch "$INSTALL_TEST_STATE/launched"
        echo "open: injected failure after the app started" >&2
        exit 1 ;;
    *" listed-then-failed "*)
        touch "$INSTALL_TEST_STATE/launched"
        echo "open: injected failure while another copy is listed" >&2
        exit 1 ;;
    *" respawning "*)
        (while :; do "$1/Contents/MacOS/NotchTheRock" || sleep 0.1; done) </dev/null >/dev/null 2>&1 &
        printf '%s\n' "$!" >"$INSTALL_TEST_STATE/supervisor.pid"
        wait_for_app
        echo "open: injected failure while the app keeps coming back" >&2
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

# The fake app's executable: it writes its pid to $INSTALL_TEST_STATE/app.pid and runs until it is
# stopped; on TERM it records the marker of the app then installed at the path it was started from.
FAKE_APP="$WORK/fake-app"
cc -x c -o "$FAKE_APP" - <<'EOF' || { printf 'cc could not build the fake app; refusing to run install-app.sh\n'; exit 1; }
#include <libgen.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static volatile sig_atomic_t stopping;

static void stop(int signal) { (void)signal; stopping = 1; }

int main(void) {
    char executable[4096], path[8192], marker[256] = "";
    uint32_t size = sizeof executable;
    const char *state = getenv("INSTALL_TEST_STATE");
    FILE *file;
    if (state == NULL || _NSGetExecutablePath(executable, &size) != 0) return 1;
    signal(SIGTERM, stop);
    snprintf(path, sizeof path, "%s/app.pid", state);
    if ((file = fopen(path, "w")) == NULL) return 1;
    fprintf(file, "%d\n", getpid());
    fclose(file);
    while (!stopping) usleep(100000);
    snprintf(path, sizeof path, "%s/../marker", dirname(executable));
    if ((file = fopen(path, "r")) != NULL) {
        if (fgets(marker, sizeof marker, file) == NULL) marker[0] = 0;
        fclose(file);
    }
    snprintf(path, sizeof path, "%s/app.stopped", state);
    if ((file = fopen(path, "w")) != NULL) {
        fputs(marker, file);
        fclose(file);
    }
    return 0;
}
EOF

# make_bundle <path> <marker>: a fake app whose Contents/marker tells the old copy from the new one.
make_bundle() {
    mkdir -p "$1/Contents/MacOS"
    printf '%s\n' "$2" >"$1/Contents/marker"
    cp "$FAKE_APP" "$1/Contents/MacOS/NotchTheRock"
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

# A process that only names the new bundle's executable in its arguments is not the app.
R13__install_app_never_stops_a_process_that_only_names_the_bundle() {
    current=${FUNCNAME[0]}
    local bystander
    /bin/bash -c 'while :; do sleep 0.2; done' "$FINAL/Contents/MacOS/NotchTheRock" </dev/null >/dev/null 2>&1 &
    bystander=$!
    helpers="$helpers $bystander"
    run_sandboxed launch
    kill -0 "$bystander" 2>/dev/null || fail "a process that only names $FINAL/Contents/MacOS/NotchTheRock in its arguments was stopped"
    expect_restored
    kill -KILL "$bystander" 2>/dev/null
}

# Another copy of the app, even the one Launch Services lists under the bundle id, is not the new app.
R13__install_app_never_stops_another_copy_of_the_app() {
    current=${FUNCNAME[0]}
    local other="$WORK/other" pid
    rm -rf "$other"
    mkdir -p "$other/state"
    make_bundle "$other/NotchTheRock.app" other
    INSTALL_TEST_STATE="$other/state" "$other/NotchTheRock.app/Contents/MacOS/NotchTheRock" </dev/null >/dev/null 2>&1 &
    pid=$!
    helpers="$helpers $pid"
    export INSTALL_TEST_LISTED_PID=$pid
    run_sandboxed listed-then-failed
    unset INSTALL_TEST_LISTED_PID
    contains "$output" "앱을 실행하지 못했어요" || fail "the failed launch is not named"
    kill -0 "$pid" 2>/dev/null || fail "the copy at $other/NotchTheRock.app that Launch Services listed was stopped"
    [ ! -e "$other/state/app.stopped" ] || fail "the copy at $other/NotchTheRock.app received TERM"
    expect_restored
    kill -KILL "$pid" 2>/dev/null
}

# When the new app keeps running, rollback moves and deletes nothing: the new bundle stays at the
# final path, the previous app at the backup path the message names, and the install fails.
R13__install_app_keeps_both_apps_when_the_new_app_cannot_be_stopped() {
    current=${FUNCNAME[0]}
    local supervisor backup
    run_sandboxed respawning
    supervisor=$(cat "$SANDBOX/state/supervisor.pid" 2>/dev/null)
    if [ -n "$supervisor" ]; then
        kill -KILL "$supervisor" 2>/dev/null
        sleep 0.3
        kill -KILL "$(cat "$SANDBOX/state/app.pid")" 2>/dev/null
    fi
    [ "$status" -ne 0 ] || fail "the failed install exited 0"
    contains "$output" "새로 설치한 NotchTheRock을 종료하지 못했어요" || fail "the failed stop is not named"
    [ "$(marker "$FINAL")" = new ] || fail "the new app that still ran was moved away from $FINAL (marker: $(marker "$FINAL"))"
    contains "$output" "새 앱은 ${FINAL}에" || fail "the message does not name where the new app is"
    contains "$output" "종료한 다음" || fail "the message does not say what to do"
    backup=$(printf '%s\n' "$output" | sed -n 's/.*이전 앱은 \(.*\)에 남겨 뒀어요.*/\1/p' | head -n 1)
    [ -n "$backup" ] || { fail "no message naming where the previous app was left"; return; }
    [ "$(marker "$backup")" = old ] || fail "the previous app is not at the reported path $backup"
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
R13__install_app_never_stops_a_process_that_only_names_the_bundle
R13__install_app_never_stops_another_copy_of_the_app
R13__install_app_keeps_both_apps_when_the_new_app_cannot_be_stopped
R13__install_app_replaces_the_app_and_removes_the_backup_after_success

if [ "$failures" -ne 0 ]; then
    printf '%d check(s) failed\n' "$failures"
    exit 1
fi
printf 'all R13 install-app.sh checks passed\n'
