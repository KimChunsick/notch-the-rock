#!/bin/bash
# Fails when a plugin package depends on anything but NotchKit and its own targets: in particular
# the app module NotchTheRock or another plugin. Names every offending plugin.
#
# Usage: scripts/check-plugin-deps.sh [<plugins-dir>]     (default: Plugins/ of this repository)
#
# Checks, for every <plugins-dir>/*/Package.swift (read with `swift package dump-package`):
#   - package dependencies: only the NotchKit package of this repository (SDK/NotchKit)
#   - target dependencies: only the NotchKit product and the plugin's own targets
#   - Swift sources: no `import NotchTheRock` and no import of another plugin's module
# Requires bash 3.2 or later and python3 (part of the Command Line Tools).
set -euo pipefail
shopt -s nullglob

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SDK_DIR="$ROOT/SDK/NotchKit"
plugins_dir=${1:-"$ROOT/Plugins"}
[ $# -le 1 ] || { printf '사용법: %s [<plugins-dir>]\n' "$0" >&2; exit 2; }

packages=()
if [ -d "$plugins_dir" ]; then
    for manifest in "$plugins_dir"/*/Package.swift; do
        packages+=("$(dirname "$manifest")")
    done
fi
if [ ${#packages[@]} -eq 0 ]; then
    printf 'check-plugin-deps: 확인할 플러그인이 없어요: %s\n' "$plugins_dir"
    exit 0
fi

# Module names another plugin must not import: the app and every plugin in the folder.
modules="NotchTheRock"
for package in "${packages[@]}"; do
    modules="$modules,$(basename "$package")"
done

dump=$(mktemp)
trap 'rm -f "$dump"' EXIT
offenders=0
for package in "${packages[@]}"; do
    name=$(basename "$package")
    if ! swift package dump-package --package-path "$package" >"$dump" 2>&1; then
        printf '%s: Package.swift를 읽지 못했어요.\n%s\n' "$name" "$(cat "$dump")"
        offenders=$((offenders + 1))
        continue
    fi
    python3 - "$name" "$package" "$SDK_DIR" "$modules" "$dump" <<'PY' || offenders=$((offenders + 1))
import json, os, re, sys

name, package, sdk_dir, modules, dump = sys.argv[1:]
manifest = json.load(open(dump))
own_targets = {target["name"] for target in manifest["targets"]}
forbidden_modules = set(modules.split(",")) - {name} - own_targets
problems = []

for dependency in manifest["dependencies"]:
    kind, (details,) = next(iter(dependency.items()))
    location = details.get("path") or json.dumps(details.get("location"))
    if kind != "fileSystem" or os.path.realpath(details["path"]) != os.path.realpath(sdk_dir):
        problems.append(f"패키지 의존성은 NotchKit만 쓸 수 있어요: {details.get('identity')} ({location})")

for target in manifest["targets"]:
    for dependency in target["dependencies"]:
        kind, value = next(iter(dependency.items()))
        if kind == "product":
            allowed = value[0] == "NotchKit" and (value[1] or "").lower() == "notchkit"
            label = f"{value[0]} (패키지 {value[1]})"
        else:
            allowed = value[0] in own_targets or (kind == "byName" and value[0] == "NotchKit")
            label = value[0]
        if not allowed:
            problems.append(f"타깃 {target['name']}은 NotchKit과 자기 타깃만 의존할 수 있어요: {label}")

import_pattern = re.compile(r"^\s*(?:@[\w()]+\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)", re.M)
for directory, _, files in os.walk(package):
    if "/.build" in directory or "/build" in directory[len(package):]:
        continue
    for file in files:
        if file.endswith(".swift") and file != "Package.swift":
            path = os.path.join(directory, file)
            for module in import_pattern.findall(open(path, encoding="utf-8").read()):
                if module in forbidden_modules:
                    problems.append(f"{os.path.relpath(path, package)}에서 NotchKit이 아닌 모듈을 가져와요: {module}")

for problem in problems:
    print(f"{name}: {problem}")
sys.exit(1 if problems else 0)
PY
done

if [ "$offenders" -ne 0 ]; then
    printf 'check-plugin-deps: 플러그인 %d개 중 %d개가 NotchKit 말고 다른 것에 의존해요.\n' "${#packages[@]}" "$offenders"
    exit 1
fi
printf 'check-plugin-deps: 플러그인 %d개 모두 NotchKit만 의존해요.\n' "${#packages[@]}"
