#!/bin/bash
# Fails when a plugin package depends on anything but NotchKit and its own targets: in particular
# the app module NotchTheRock or another plugin. Names every offending plugin.
#
# Usage: scripts/check-plugin-deps.sh [<plugins-dir>]     (default: Plugins/ of this repository)
#
# Checks, for every <plugins-dir>/*/Package.swift (read with `swift package dump-package`):
#   - package dependencies: only the NotchKit package of this repository (SDK/NotchKit)
#   - target dependencies: only the NotchKit product and the plugin's own targets
#   - target settings: no unsafeFlags, because -I and -F flags reach modules without a dependency
#   - the Swift modules the build loads. The plugin's product is built the way
#     scripts/build-plugin.sh builds it (`swift build --product <Name>`), in release and then in
#     debug, with SWIFT_LOADED_MODULE_TRACE_FILE set: the compiler records every Swift module it
#     loads for each module it compiles, under the build's own language mode, defines, traits,
#     `#if` conditions and search paths. A loaded module passes only when it lies in the active SDK or
#     in the toolchain's lib/swift, or when it lies in the Modules folder of the plugin's own build
#     and is NotchKit or one of the plugin's targets that this build compiled, as the trace names
#     them. A declared target that the product does not build, such as a test target, does not
#     count. Anything else fails and is named with the module that loaded it. A build that fails
#     fails the check, and so does a build whose trace holds none of the plugin's modules. The app
#     and every plugin are Swift modules, which the trace lists. Test targets are not part of the
#     product; the manifest rules above cover them.
# A plugin that depends on another package is not built: the build would fetch or build that
# package. Every plugin builds in a scratch folder of its own in a temporary directory, which is
# deleted afterwards, so Plugins/*/.build is neither read nor written. NotchKit is built alone once
# per configuration; before each plugin the scratch folder is deleted and made again as a copy of
# that build, so it holds NotchKit and this plugin's build and nothing another plugin built. A plugin
# that imports another one without depending on it therefore does not compile and fails the check.
# The copy keeps the folder's path because the compiler's module cache records it: a copy at
# another path would build NotchKit again for every plugin.
# Takes about two and a half minutes for three plugins, mostly building NotchKit twice.
# Requires bash 3.2 or later, swift, xcrun and python3 (part of the Command Line Tools).
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

# Where the modules of the SDK and of the toolchain lie, the only folders a plugin may load
# modules from besides the build's own Modules folder.
sdk_root=$(xcrun --sdk macosx --show-sdk-path)
toolchain_lib="$(dirname "$(xcrun --find swiftc)")/../lib/swift"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
scratch="$work/build"
notchkit_build="$work/notchkit-build"
printf 'check-plugin-deps: NotchKit을 빌드해요.\n' >&2
for configuration in release debug; do
    if ! swift build -c "$configuration" --package-path "$SDK_DIR" --product NotchKit --scratch-path "$scratch" >"$work/notchkit.log" 2>&1; then
        printf 'check-plugin-deps: NotchKit %s 빌드에 실패해서 플러그인을 확인하지 못했어요.\n%s\n' "$configuration" "$(tail -n 20 "$work/notchkit.log")"
        exit 1
    fi
done
mv "$scratch" "$notchkit_build"
offenders=0
for package in "${packages[@]}"; do
    name=$(basename "$package")
    dump="$work/$name.json"
    # This plugin's own scratch folder: only NotchKit's build, at the path it was built in.
    rm -rf "$scratch"
    cp -cR "$notchkit_build" "$scratch"
    if ! swift package dump-package --package-path "$package" --scratch-path "$scratch" >"$dump" 2>&1; then
        printf '%s: Package.swift를 읽지 못했어요.\n%s\n' "$name" "$(cat "$dump")"
        offenders=$((offenders + 1))
        continue
    fi
    printf 'check-plugin-deps: 빌드해서 확인해요: %s\n' "$name" >&2
    python3 - "$name" "$package" "$SDK_DIR" "$dump" "$work" "$scratch" "$sdk_root" "$toolchain_lib" <<'PY' || offenders=$((offenders + 1))
import json, os, re, subprocess, sys

name, package, sdk_dir, dump, work, scratch, sdk_root, toolchain_lib = sys.argv[1:]
manifest = json.load(open(dump))
own_targets = {target["name"] for target in manifest["targets"]}
problems = []

depends_on_other_packages = False
for dependency in manifest["dependencies"]:
    kind, (details,) = next(iter(dependency.items()))
    location = details.get("path") or json.dumps(details.get("location"))
    if kind != "fileSystem" or os.path.realpath(details["path"]) != os.path.realpath(sdk_dir):
        problems.append(f"패키지 의존성은 NotchKit만 쓸 수 있어요: {details.get('identity')} ({location})")
        depends_on_other_packages = True

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
    for setting in target.get("settings", []):
        flags = setting["kind"].get("unsafeFlags")
        if flags is not None:
            problems.append(f"타깃 {target['name']}의 설정에 unsafeFlags가 있어요 ({setting['tool']}): {' '.join(flags['_0'])}")

# SwiftPM names a target's module after the target, with every character that cannot appear in an
# identifier replaced by an underscore.
def module_of(target):
    module = re.sub(r"[^A-Za-z0-9_]", "_", target)
    return "_" + module if module[:1].isdigit() else module

# The module a loaded file belongs to and the folder that holds it: the last path component named
# <Module>.swiftmodule (a file, or a folder of per-architecture files), else <Module>.swiftinterface.
def loaded_module(path):
    parts = path.split(os.sep)
    for index in range(len(parts) - 1, -1, -1):
        if parts[index].endswith(".swiftmodule"):
            return parts[index][: -len(".swiftmodule")], os.sep.join(parts[:index])
    return os.path.splitext(parts[-1])[0], os.path.dirname(path)

def inside(path, folder):
    return path == folder or path.startswith(folder + os.sep)

own_modules = {module_of(target) for target in own_targets}
system_folders = [os.path.realpath(sdk_root), os.path.realpath(toolchain_lib)]
real_scratch = os.path.realpath(scratch)
# (compiled module, loaded module, path) -> the configurations whose build loaded it
foreign = {}
if depends_on_other_packages:
    problems.append("NotchKit 말고 다른 패키지를 의존해서 빌드하지 않았어요.")
else:
    for configuration in ("release", "debug"):
        trace = os.path.join(work, f"{name}-{configuration}.trace")
        result = subprocess.run(
            ["swift", "build", "-c", configuration, "--package-path", package, "--product", name, "--scratch-path", scratch],
            env=dict(os.environ, SWIFT_LOADED_MODULE_TRACE_FILE=trace),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        if result.returncode != 0:
            lines = result.stdout.splitlines()
            errors = [line for line in lines if "error:" in line] or lines
            problems.append(f"{configuration} 빌드에 실패해서 불러오는 모듈을 확인하지 못했어요. 빌드 오류:\n" + "\n".join(errors[-20:]))
            break
        records = []
        if os.path.exists(trace):
            with open(trace) as file:
                records = [json.loads(line) for line in file if line.strip()]
        # The plugin's targets this build compiled. A declared target the product does not build
        # is not among them, so a module of that name in the Modules folder is not the plugin's.
        built_modules = own_modules & {record["name"] for record in records}
        if not built_modules:
            problems.append(f"{configuration} 빌드 기록에 이 플러그인의 모듈이 없어서 불러오는 모듈을 확인하지 못했어요.")
            continue
        allowed_modules = built_modules | {"NotchKit"}
        # Every record counts, not only those of the own targets: the manifest's and NotchKit's
        # records load only SDK and toolchain modules.
        for record in records:
            for path in record["swiftmodules"]:
                real = os.path.realpath(path)
                module, folder = loaded_module(real)
                if any(inside(real, system) for system in system_folders):
                    continue
                if module in allowed_modules and os.path.basename(folder) == "Modules" and inside(folder, real_scratch):
                    continue
                configurations = foreign.setdefault((record["name"], module, path), [])
                if configuration not in configurations:
                    configurations.append(configuration)
for (compiled, module, path), configurations in foreign.items():
    problems.append(f"타깃 {compiled}의 {', '.join(configurations)} 빌드가 NotchKit이 아닌 모듈을 불러와요: {module} ({path})")

for problem in problems:
    print(f"{name}: {problem}")
sys.exit(1 if problems else 0)
PY
done

if [ "$offenders" -ne 0 ]; then
    printf 'check-plugin-deps: 플러그인 %d개 중 %d개가 검사를 통과하지 못했어요.\n' "${#packages[@]}" "$offenders"
    exit 1
fi
printf 'check-plugin-deps: 플러그인 %d개 모두 NotchKit만 의존해요.\n' "${#packages[@]}"
