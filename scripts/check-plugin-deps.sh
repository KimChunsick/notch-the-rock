#!/bin/bash
# Fails when a plugin package depends on anything but NotchKit and its own targets: in particular
# the app module NotchTheRock or another plugin. Names every offending plugin.
#
# Usage: scripts/check-plugin-deps.sh [<plugins-dir>]     (default: Plugins/ of this repository)
#
# Checks, for every <plugins-dir>/*/Package.swift (read with `swift package dump-package`):
#   - package dependencies: only the NotchKit package of this repository (SDK/NotchKit)
#   - target dependencies: only the NotchKit product and the plugin's own targets
#   - Swift sources: no import of NotchTheRock or another plugin's module. The compiler reads the
#     imports (`swiftc -frontend -emit-imported-modules`) in the package's language mode, once with
#     the defines of a debug build and once with those of a release build, so every import form it
#     accepts counts, text in comments and string or regex literals does not, and an import inside
#     `#if` counts when either build compiles it. A file the compiler cannot parse fails the check.
# Requires bash 3.2 or later, swiftc and python3 (part of the Command Line Tools).
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
import json, os, subprocess, sys

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

# The modules a Swift file imports, as the compiler resolves them in a debug and in a release build
# of a Swift package: the compiler's parser tells code from comments and string or regex literals and
# evaluates `#if`, and it names the top-level module of `import struct X.T` or `import X.Sub`.
# Returns the compiler's message instead when the file does not parse: such a file cannot be shown
# to import nothing else.
swift_version = "6" if int(manifest["toolsVersion"]["_version"].split(".")[0]) >= 6 else "5"

def imported_modules(path):
    modules = set()
    for defines in (["-D", "SWIFT_PACKAGE", "-D", "DEBUG"], ["-D", "SWIFT_PACKAGE"]):
        result = subprocess.run(
            ["swiftc", "-frontend", "-emit-imported-modules", "-swift-version", swift_version, *defines, path, "-o", "-"],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            return None, result.stderr.strip()
        modules.update(line.split(".")[0] for line in result.stdout.split())
    return modules, None

for directory, _, files in os.walk(package):
    if "/.build" in directory or "/build" in directory[len(package):]:
        continue
    for file in files:
        if file.endswith(".swift") and file != "Package.swift":
            path = os.path.join(directory, file)
            relative = os.path.relpath(path, package)
            modules, error = imported_modules(path)
            if error is not None:
                problems.append(f"{relative}를 컴파일러가 읽지 못해서 가져오는 모듈을 확인할 수 없어요:\n{error}")
                continue
            for module in sorted(modules & forbidden_modules):
                problems.append(f"{relative}에서 NotchKit이 아닌 모듈을 가져와요: {module}")

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
