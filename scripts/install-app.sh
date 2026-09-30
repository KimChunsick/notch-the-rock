#!/bin/bash
# Builds NotchTheRock with scripts/build-app.sh, installs it as /Applications/NotchTheRock.app and
# launches it. A running NotchTheRock is quit first. Safe to run again: the new copy replaces the
# old one.
#
# Usage: scripts/install-app.sh [--no-build]
#   --no-build   install the existing build/NotchTheRock.app without building
#
# The path stays the same on every install on purpose: Accessibility (TCC) and the login item
# (SMAppService) key on the installed copy, so a rebuild keeps both after reinstalling here.
# The new bundle is copied under a hidden temporary name inside /Applications, verified and then
# renamed into place, so a half-copied app never sits at the final path. The previous app is kept
# under a hidden name until the new one is verified and running, and goes back into place when any
# step fails; if even that fails, its path is printed. A new copy that was already launched is
# stopped before it is moved away, also when Launch Services never reported it running; only
# processes whose executable is the new bundle's are signalled. When it cannot be stopped, neither
# app is moved: both paths are printed. Never uses sudo: when /Applications is not writable it
# stops and says so.
#
# NOTCH_INSTALL_DIR overrides /Applications. It exists for scripts/tests only; TCC and the login
# item expect /Applications.
# Requires bash 3.2 or later.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
BUNDLE_ID="com.notchtherock.NotchTheRock"
DEST_DIR=${NOTCH_INSTALL_DIR:-/Applications}
FINAL="$DEST_DIR/NotchTheRock.app"
STAGED="$DEST_DIR/.NotchTheRock-install.$$"
OLD="$DEST_DIR/.NotchTheRock-old.$$"

say() {
    printf 'install-app: %s\n' "$*" >&2
}

fail() {
    say "$*"
    exit 1
}

build=1
for argument in "$@"; do
    case "$argument" in
        --no-build) build=0 ;;
        *) fail "알 수 없는 인자예요: $argument (사용법: scripts/install-app.sh [--no-build])" ;;
    esac
done

[ -d "$DEST_DIR" ] || fail "설치할 폴더가 없어요: $DEST_DIR"
[ -w "$DEST_DIR" ] || fail "$DEST_DIR 폴더에 쓸 수 없어요. 관리자 계정으로 로그인해서 다시 실행해 주세요."

# Recovery state, read only by the EXIT trap. `previous` is set once the installed app has been
# moved aside to $OLD; `launching` once `open` was asked to start the new app at $FINAL; `installed`
# once the new app is at $FINAL, verified and running. The previous app is deleted only when
# `previous` and `installed` are set; on any other exit it goes back to $FINAL, and when that fails
# or the new app at $FINAL cannot be stopped it stays at $OLD and the message says so.
previous=""
launching=0
installed=0

# Puts the previous app back at $FINAL. A new copy already at $FINAL failed, so it is moved to
# $STAGED (free again after the swap) for the trap to remove; when it was launched, whatever runs
# from it is stopped first. When the stop is not confirmed, both apps stay where they are: a bundle
# that still runs is neither moved nor deleted, and the previous app does not take its place.
# `mv` into an existing directory would move the previous app inside it, hence the check that $FINAL
# is gone.
restore_previous() {
    if [ "$launching" -eq 1 ] && ! stop_new_app; then
        say "새로 설치한 NotchTheRock이 아직 실행 중이라 이전 앱을 되돌려 놓지 않았어요. 새 앱은 ${FINAL}에, 이전 앱은 ${previous}에 남겨 뒀어요."
        say "NotchTheRock을 종료한 다음 ${FINAL}을 지우고 이전 앱을 그 자리로 옮겨 주세요."
        return
    fi
    [ -e "$FINAL" ] && [ ! -e "$STAGED" ] && mv "$FINAL" "$STAGED"
    if [ ! -e "$FINAL" ] && mv "$previous" "$FINAL"; then
        say "이전 앱을 ${FINAL}에 되돌려 놓았어요."
    else
        say "이전 앱을 ${FINAL}에 되돌려 놓지 못했어요. 이전 앱은 ${previous}에 남겨 뒀어요."
    fi
}

cleanup() {
    # A failing command here must neither stop the recovery nor change the exit status.
    set +e
    if [ -n "$previous" ]; then
        if [ "$installed" -eq 1 ]; then
            rm -rf "$previous"
        else
            restore_previous
        fi
    fi
    rm -rf "$STAGED"
}
trap cleanup EXIT

# The pid of one running NotchTheRock (any copy with this bundle id), or nothing.
running_pid() {
    lsappinfo info -only pid -app "$BUNDLE_ID" | sed -n 's/^"pid"=\([0-9][0-9]*\).*/\1/p'
}

# Quits every running copy and waits until each has exited. SIGTERM rather than an Apple Event:
# a quit event from the terminal can stop at an Automation consent prompt.
quit_running() {
    local pid rounds=0 waited
    while pid=$(running_pid) && [ -n "$pid" ]; do
        rounds=$((rounds + 1))
        [ "$rounds" -le 20 ] || fail "실행 중인 NotchTheRock을 종료하지 못했어요 (pid $pid)."
        say "실행 중인 NotchTheRock을 종료해요 (pid $pid)."
        kill -TERM "$pid" 2>/dev/null || true
        waited=0
        while kill -0 "$pid" 2>/dev/null; do
            [ "$waited" -lt 100 ] || fail "NotchTheRock(pid $pid)이 10초 안에 종료되지 않았어요."
            sleep 0.1
            waited=$((waited + 1))
        done
        # Launch Services forgets the process shortly after it exits.
        sleep 0.2
    done
}

# The given pids that are still running. Succeeds also when none is, so callers read the output.
alive() {
    local pid
    for pid; do
        if kill -0 "$pid" 2>/dev/null; then printf '%s\n' "$pid"; fi
    done
}

# The pids of the processes that run the new app's executable at $FINAL, whether Launch Services
# lists them yet or not. lsof finds a process by the file it maps as its program text (txt), which a
# process cannot fake the way it can its arguments or its argv[0] (what `ps -o comm` shows), and a
# copy of NotchTheRock elsewhere is another file. So the pid Launch Services lists under the bundle
# id counts only when this lookup finds it as well. Fails when lsof cannot answer; it exits 1 when
# no process matches.
new_app_pids() {
    local executable="$FINAL/Contents/MacOS/NotchTheRock" status=0
    [ -e "$executable" ] || return 0
    lsof -t -a -d txt -- "$executable" 2>/dev/null || status=$?
    [ "$status" -le 1 ]
}

# Stops the new app before rollback moves it away, so no process is left running from a bundle that
# is about to be deleted: TERM, then KILL what still runs the new executable after 10 seconds. Asks
# again afterwards, because a copy that Launch Services only started meanwhile has to stop as well.
# Succeeds only once no process runs the new executable.
stop_new_app() {
    local pids pid verified rounds=0 waited
    while :; do
        pids=$(new_app_pids) || { say "새로 설치한 NotchTheRock이 실행 중인지 확인하지 못했어요."; return 1; }
        [ -n "$pids" ] || return 0
        pids=$(printf '%s ' $pids)
        rounds=$((rounds + 1))
        if [ "$rounds" -gt 3 ]; then
            say "새로 설치한 NotchTheRock을 종료하지 못했어요 (pid ${pids% })."
            return 1
        fi
        say "되돌리기 전에 새로 설치한 NotchTheRock을 종료해요 (pid ${pids% })."
        kill -TERM $pids 2>/dev/null
        waited=0
        while [ -n "$(alive $pids)" ] && [ "$waited" -lt 100 ]; do
            sleep 0.1
            waited=$((waited + 1))
        done
        # A pid can pass to an unrelated process while we wait: KILL only what still runs the new executable.
        pids=$(alive $pids)
        if [ -n "$pids" ]; then
            verified=" $(printf '%s ' $(new_app_pids)) "
            for pid in $pids; do
                case "$verified" in *" $pid "*) kill -KILL "$pid" 2>/dev/null ;; esac
            done
        fi
        sleep 0.2
    done
}

if [ "$build" -eq 1 ]; then
    APP=$("$ROOT/scripts/build-app.sh") || fail "앱을 빌드하지 못했어요."
else
    APP="$ROOT/build/NotchTheRock.app"
fi
[ -d "$APP" ] || fail "설치할 앱이 없어요: $APP (--no-build 없이 실행하면 먼저 빌드해요)"

say "새 앱을 복사해요: $APP → $DEST_DIR"
ditto "$APP" "$STAGED" || fail "앱을 복사하지 못했어요: $STAGED"
codesign --verify --deep --strict "$STAGED" || fail "복사한 앱의 서명 검증에 실패했어요. 설치하지 않았어요."

quit_running

if [ -e "$FINAL" ]; then
    mv "$FINAL" "$OLD" || fail "기존 앱을 옮기지 못했어요: $FINAL"
    previous=$OLD
fi
mv "$STAGED" "$FINAL" || fail "새 앱을 제자리에 옮기지 못했어요: $FINAL"

codesign --verify --deep --strict "$FINAL" || fail "설치한 앱의 서명 검증에 실패했어요: $FINAL"

say "앱을 실행해요: $FINAL"
launching=1
open "$FINAL" || fail "앱을 실행하지 못했어요: $FINAL"
waited=0
until [ -n "$(running_pid)" ]; do
    [ "$waited" -lt 100 ] || fail "앱이 10초 안에 실행되지 않았어요: $FINAL"
    sleep 0.1
    waited=$((waited + 1))
done
installed=1

printf '%s\n' "$FINAL"
