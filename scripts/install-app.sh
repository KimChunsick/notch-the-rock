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
# renamed into place, so a half-copied app never sits at the final path. Never uses sudo: when
# /Applications is not writable it stops and says so.
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

cleanup() {
    rm -rf "$STAGED" "$OLD"
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
fi
if ! mv "$STAGED" "$FINAL"; then
    [ -e "$OLD" ] && mv "$OLD" "$FINAL"
    fail "새 앱을 제자리에 옮기지 못했어요. 기존 앱을 되돌려 놓았어요."
fi
rm -rf "$OLD"

codesign --verify --deep --strict "$FINAL" || fail "설치한 앱의 서명 검증에 실패했어요: $FINAL"

say "앱을 실행해요: $FINAL"
open "$FINAL" || fail "앱을 실행하지 못했어요: $FINAL"
waited=0
until [ -n "$(running_pid)" ]; do
    [ "$waited" -lt 100 ] || fail "앱이 10초 안에 실행되지 않았어요: $FINAL"
    sleep 0.1
    waited=$((waited + 1))
done

printf '%s\n' "$FINAL"
