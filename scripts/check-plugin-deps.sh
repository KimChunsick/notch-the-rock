#!/bin/bash
# Fails when a plugin package depends on anything but NotchKit and its own targets: in particular
# the app module NotchTheRock or another plugin. Names every offending plugin.
#
# Usage: scripts/check-plugin-deps.sh [<plugins-dir>]     (default: Plugins/ of this repository)
#
# Checks, for every <plugins-dir>/*/Package.swift (read with `swift package dump-package`):
#   - package dependencies: only the NotchKit package of this repository (SDK/NotchKit)
#   - target dependencies: only the NotchKit product and the plugin's own targets
#   - Swift sources: no `import NotchTheRock` and no import of another plugin's module; text inside
#     comments and string literals is not code and is ignored
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

string_start = re.compile(r'(#*)("""|")')

def code_only(source):
    """The source with comments and string literals blanked out. Newlines stay, so line-anchored
    patterns still see real code at the start of a line. Follows Swift's lexical rules: block
    comments nest, `#` delimits raw strings, and `\\(` (`\\#(` in raw strings) interpolates code."""
    out = []
    end_of_source = len(source)

    def blank(start, end):
        out.append(re.sub(r"[^\n]", " ", source[start:end]))

    def block_comment_end(i):
        depth = 0
        while i < end_of_source:
            if source.startswith("/*", i):
                depth, i = depth + 1, i + 2
            elif source.startswith("*/", i):
                depth, i = depth - 1, i + 2
                if depth == 0:
                    return i
            else:
                i += 1
        return end_of_source

    # Scans code from i. Inside an interpolation it returns at the ")" that closes it.
    def code(i, interpolation):
        depth = 0
        while i < end_of_source:
            string = string_start.match(source, i)
            if source.startswith("//", i):
                end = source.find("\n", i)
                end = end_of_source if end < 0 else end
                blank(i, end)
                i = end
            elif source.startswith("/*", i):
                end = block_comment_end(i)
                blank(i, end)
                i = end
            elif string:
                i = string_literal(i, len(string.group(1)), string.group(2) == '"""')
            elif interpolation and source[i] == ")" and depth == 0:
                return i
            else:
                if interpolation and source[i] in "()":
                    depth += 1 if source[i] == "(" else -1
                out.append(source[i])
                i += 1
        return i

    def string_literal(i, hashes, multiline):
        closing = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        start = i
        i += hashes + (3 if multiline else 1)
        while i < end_of_source:
            if source.startswith(closing, i):
                blank(start, i + len(closing))
                return i + len(closing)
            if source.startswith(escape, i):
                after = i + len(escape)
                if source.startswith("(", after):
                    blank(start, after + 1)
                    # The ")" that ends the interpolation is blanked with the rest of the string.
                    i = start = code(after + 1, True)
                    i += 1
                else:
                    i = after + 1
            elif not multiline and source[i] == "\n":
                break  # unterminated; the compiler reports it
            else:
                i += 1
        blank(start, min(i, end_of_source))
        return min(i, end_of_source)

    code(0, False)
    return "".join(out)

import_pattern = re.compile(r"^\s*(?:@[\w()]+\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)", re.M)
for directory, _, files in os.walk(package):
    if "/.build" in directory or "/build" in directory[len(package):]:
        continue
    for file in files:
        if file.endswith(".swift") and file != "Package.swift":
            path = os.path.join(directory, file)
            for module in import_pattern.findall(code_only(open(path, encoding="utf-8").read())):
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
