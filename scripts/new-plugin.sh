#!/bin/bash
# Creates a plugin package from Templates/PluginTemplate and prints its path. The new plugin
# builds as is, shows one live activity beside the notch and one tab in the expanded notch.
#
# Usage: scripts/new-plugin.sh <Name> [--dir <parent>] [--id <identifier>]
#   <Name>   type-style name: an uppercase letter followed by letters and digits (e.g. Clock)
#   --dir    folder to create <Name>/ in (default: Plugins/ of this repository)
#   --id     reverse-DNS plugin identifier (default: com.example.<name in lowercase>)
# Requires bash 3.2 or later.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TEMPLATE="$ROOT/Templates/PluginTemplate"
SDK_DIR="$ROOT/SDK/NotchKit"

fail() {
    printf 'new-plugin: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf '사용법: %s <Name> [--dir <parent>] [--id <identifier>]\n' "$0" >&2
    exit 2
}

name=""
parent="$ROOT/Plugins"
id=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dir) [ $# -ge 2 ] || usage; parent=$2; shift 2 ;;
        --id) [ $# -ge 2 ] || usage; id=$2; shift 2 ;;
        -*) usage ;;
        *) [ -z "$name" ] || usage; name=$1; shift ;;
    esac
done
[ -n "$name" ] || usage

[[ $name =~ ^[A-Z][A-Za-z0-9]*$ ]] || fail "이름은 대문자로 시작하고 영문자와 숫자만 써야 해요: $name"
case "$name" in
    NotchKit | NotchTheRock) fail "SDK나 앱 모듈과 같은 이름은 쓸 수 없어요: $name" ;;
esac
[ -n "$id" ] || id="com.example.$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
[[ $id =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || fail "식별자는 역도메인 형식(예: com.example.clock)이어야 해요: $id"

mkdir -p "$parent"
parent=$(cd "$parent" && pwd -P)
dest="$parent/$name"
[ ! -e "$dest" ] || fail "이미 있는 폴더예요: $dest"

# Inside this repository the SDK path stays relative so a fresh clone builds anywhere; elsewhere it
# is absolute so the plugin folder can move on its own.
case "$dest/" in
    "$ROOT"/*) sdk_path=$(perl -MFile::Spec -e 'print File::Spec->abs2rel($ARGV[0], $ARGV[1])' "$SDK_DIR" "$dest") ;;
    *) sdk_path=$SDK_DIR ;;
esac
case "$sdk_path" in
    *'"'* | *'\'*) fail "SDK 경로에 따옴표나 역슬래시가 있어서 Package.swift에 넣을 수 없어요: $sdk_path" ;;
esac

cp -R "$TEMPLATE" "$dest"
mv "$dest/Sources/__NAME__" "$dest/Sources/$name"
# Every template source is named __NAME__<Part>.swift: __NAME__Plugin.swift becomes <Name>Plugin.swift.
for file in "$dest/Sources/$name"/__NAME__*.swift; do
    mv "$file" "$dest/Sources/$name/$name${file##*/__NAME__}"
done
PLUGIN_NAME=$name PLUGIN_ID=$id NOTCHKIT_PATH=$sdk_path perl -pi -e '
    s/__NAME__/$ENV{PLUGIN_NAME}/g;
    s/__ID__/$ENV{PLUGIN_ID}/g;
    s/__NOTCHKIT_PATH__/$ENV{NOTCHKIT_PATH}/g;
' "$dest/Package.swift" "$dest/Sources/$name"/*.swift

printf 'new-plugin: 만들었어요. 다음 명령으로 빌드해요: %s/scripts/build-plugin.sh "%s"\n' "$ROOT" "$dest" >&2
printf '%s\n' "$dest"
