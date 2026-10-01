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
#   - the Swift modules each helper product loads. Helpers are chosen the way scripts/build-plugin.sh
#     chooses them: every executable product and every dynamic library product other than <Name>;
#     static and automatic libraries are none. Each is built and traced like the plugin's product,
#     but a helper runs in a process of its own, outside the app that carries NotchKit (D-29), so a
#     module it loads passes only when it lies in the SDK or the toolchain, or in the Modules folder
#     of its own build as one of the package's targets that this build compiled. NotchKit fails. The
#     helper's Swift targets come from `swift package describe`; a helper that has some fails when its
#     trace holds none of them, and a C helper, which loads no Swift module, has nothing to trace.
#   - the libraries each of these builds links, which no trace shows when a target links them through
#     linker settings alone. After every build that succeeds, the binary it built, named the way
#     scripts/build-plugin.sh names it (lib<product>.dylib for a dynamic library, <product> for an
#     executable) in the folder that `swift build --show-bin-path` reports for the same configuration,
#     package and scratch folder, is read with `otool -l`: every LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB,
#     LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB and LC_LOAD_UPWARD_DYLIB command names a library it links.
#     `otool -L` would also list a library's own install name (LC_ID_DYLIB) and does not say which
#     command an entry comes from. A linked library passes when it lies in /usr/lib/ or
#     /System/Library/, when it is one of the package's dynamic library products other than <Name>
#     (@rpath/lib<product>.dylib), or, for the plugin's product only, when it is
#     @rpath/libNotchKit.dylib. Anything else fails and is named with the product and the
#     configurations that link it.
# A plugin that depends on another package is not built: the build would fetch or build that
# package. Every plugin builds in a scratch folder of its own in a temporary directory, which is
# deleted afterwards, so Plugins/*/.build is neither read nor written. NotchKit is built alone once
# per configuration; before each plugin the scratch folder is deleted and made again as a copy of
# that build, so it holds NotchKit and this plugin's build and nothing another plugin built. A plugin
# that imports another one without depending on it therefore does not compile and fails the check.
# Before each helper the folder is made again the same way, so the helper's build compiles every
# package target it depends on and its trace names them, even those the plugin's product compiled
# first, and the helper reaches no module that the product or another helper built.
# The copy keeps the folder's path because the compiler's module cache records it: a copy at
# another path would build NotchKit again for every plugin.
# Takes about two and a half minutes for three plugins, mostly building NotchKit twice; every helper
# adds a build of its own targets.
# Requires bash 3.2 or later, swift, xcrun, otool and python3 (part of the Command Line Tools).
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
    python3 - "$name" "$package" "$SDK_DIR" "$dump" "$work" "$scratch" "$notchkit_build" "$sdk_root" "$toolchain_lib" <<'PY' || offenders=$((offenders + 1))
import json, os, re, shutil, subprocess, sys, tempfile

name, package, sdk_dir, dump, work, scratch, notchkit_build, sdk_root, toolchain_lib = sys.argv[1:]
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
# The compiler appends to a trace file, so every build writes a file of its own in this folder.
traces = tempfile.mkdtemp(dir=work)

# The helper products, chosen the way scripts/build-plugin.sh chooses them, the file each product
# builds in the build's bin folder, and the install names of the package's own dynamic libraries
# other than the plugin's, which any of its builds may link.
helpers = []
binaries = {}
own_libraries = set()
for product in manifest["products"]:
    if (product["type"].get("library") or [None])[0] == "dynamic":
        binaries[product["name"]] = f"lib{product['name']}.dylib"
        if product["name"] != name:
            helpers.append(product["name"])
            own_libraries.add(f"@rpath/lib{product['name']}.dylib")
    elif "executable" in product["type"]:
        binaries[product["name"]] = product["name"]
        helpers.append(product["name"])

# The folder a build of <configuration> writes its products to, as SwiftPM reports it for this
# package and scratch folder, or None when it does not say.
bin_paths = {}
def bin_path(configuration):
    if configuration not in bin_paths:
        result = subprocess.run(
            ["swift", "build", "-c", configuration, "--package-path", package, "--scratch-path", scratch, "--show-bin-path"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        bin_paths[configuration] = result.stdout.strip() if result.returncode == 0 else None
    return bin_paths[configuration]

# The install name of every library <binary> links, from its dylib load commands, or None when
# otool cannot read it.
DYLIB_LOADS = {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LAZY_LOAD_DYLIB", "LC_LOAD_UPWARD_DYLIB"}
def linked_libraries(binary):
    result = subprocess.run(["otool", "-l", binary], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.returncode != 0:
        return None
    libraries, command = [], None
    for line in result.stdout.splitlines():
        field, _, value = line.strip().partition(" ")
        if field == "cmd":
            command = value
        elif field == "name" and command in DYLIB_LOADS:
            libraries.append(re.sub(r" \(offset \d+\)$", "", value))
    return libraries

def library_allowed(library, helper):
    if library.startswith(("/usr/lib/", "/System/Library/")) or library in own_libraries:
        return True
    return not helper and library == "@rpath/libNotchKit.dylib"

# Builds <product> in release and then in debug, each with a trace of its own, and returns the
# problems. The plugin's product may load and link NotchKit and fails when its trace names none of
# the plugin's modules. A helper may neither load nor link NotchKit and fails for a trace without its
# modules only when it has Swift targets (swift_modules), because a C helper loads no Swift module.
def check(product, index, helper, swift_modules):
    prefix = f"도우미 {product}: " if helper else ""
    found = []
    # (compiled module, loaded module, path) -> the configurations whose build loaded it
    foreign = {}
    # linked library -> the configurations whose build links it
    linked = {}
    for configuration in ("release", "debug"):
        trace = os.path.join(traces, f"{index}-{configuration}.trace")
        result = subprocess.run(
            ["swift", "build", "-c", configuration, "--package-path", package, "--product", product, "--scratch-path", scratch],
            env=dict(os.environ, SWIFT_LOADED_MODULE_TRACE_FILE=trace),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        if result.returncode != 0:
            lines = result.stdout.splitlines()
            # The linker's own lines, such as "ld: library 'X' not found", carry no "error:".
            errors = [line for line in lines if "error:" in line or line.startswith("ld: ")] or lines
            found.append(f"{prefix}{configuration} 빌드에 실패해서 불러오는 모듈을 확인하지 못했어요. 빌드 오류:\n" + "\n".join(errors[-20:]))
            break
        folder = bin_path(configuration)
        binary = os.path.join(folder, binaries[product]) if folder and product in binaries else None
        libraries = linked_libraries(binary) if binary and os.path.isfile(binary) else None
        if libraries is None:
            found.append(f"{prefix}{configuration} 빌드 결과를 읽지 못해서 링크하는 라이브러리를 확인하지 못했어요: {binary or product}")
        for library in libraries or []:
            if not library_allowed(library, helper):
                configurations = linked.setdefault(library, [])
                if configuration not in configurations:
                    configurations.append(configuration)
        records = []
        if os.path.exists(trace):
            with open(trace) as file:
                records = [json.loads(line) for line in file if line.strip()]
        # The package's targets this build compiled. A declared target the product does not build
        # is not among them, so a module of that name in the Modules folder is not the plugin's.
        built_modules = own_modules & {record["name"] for record in records}
        if not built_modules and not helper:
            found.append(f"{configuration} 빌드 기록에 이 플러그인의 모듈이 없어서 불러오는 모듈을 확인하지 못했어요.")
            continue
        if not built_modules and swift_modules:
            found.append(f"{prefix}{configuration} 빌드 기록에 이 도우미의 Swift 타깃이 없어서 불러오는 모듈을 확인하지 못했어요.")
            continue
        allowed_modules = built_modules if helper else built_modules | {"NotchKit"}
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
        configurations = ", ".join(configurations)
        if not helper:
            found.append(f"타깃 {compiled}의 {configurations} 빌드가 NotchKit이 아닌 모듈을 불러와요: {module} ({path})")
        elif module == "NotchKit":
            found.append(f"{prefix}타깃 {compiled}의 {configurations} 빌드가 NotchKit을 불러와요 ({path}). 도우미는 앱과 다른 프로세스에서 실행돼서 앱에 들어 있는 NotchKit을 쓸 수 없어요.")
        else:
            found.append(f"{prefix}타깃 {compiled}의 {configurations} 빌드가 도우미가 쓸 수 없는 모듈을 불러와요: {module} ({path})")
    for library, configurations in linked.items():
        configurations = ", ".join(configurations)
        if not helper:
            found.append(f"제품 {product}의 {configurations} 빌드가 NotchKit이 아닌 라이브러리를 링크해요: {library}")
        elif os.path.basename(library) == "libNotchKit.dylib":
            found.append(f"{prefix}{configurations} 빌드가 NotchKit을 링크해요 ({library}). 도우미는 앱과 다른 프로세스에서 실행돼서 앱에 들어 있는 NotchKit을 쓸 수 없어요.")
        else:
            found.append(f"{prefix}{configurations} 빌드가 도우미가 쓸 수 없는 라이브러리를 링크해요: {library}")
    return found

if depends_on_other_packages:
    problems.append("NotchKit 말고 다른 패키지를 의존해서 빌드하지 않았어요.")
else:
    problems += check(name, 0, False, set())
    if helpers:
        # The dump does not say which targets are Swift ones; describe does, with the products each
        # target is part of, directly or through another target.
        result = subprocess.run(
            ["swift", "package", "--package-path", package, "--scratch-path", scratch, "describe", "--type", "json"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        if result.returncode != 0:
            problems.append("swift package describe가 실패해서 도우미를 확인하지 못했어요.\n" + result.stderr.strip())
        else:
            described = json.loads(result.stdout)["targets"]
            for index, product in enumerate(helpers, start=1):
                print(f"check-plugin-deps: 도우미를 빌드해서 확인해요: {name} {product}", file=sys.stderr, flush=True)
                # This helper's own scratch folder: only NotchKit's build, at the path it was built in.
                shutil.rmtree(scratch)
                subprocess.run(["cp", "-cR", notchkit_build, scratch], check=True)
                swift_modules = {
                    module_of(target["name"]) for target in described
                    if target.get("module_type") == "SwiftTarget" and product in target.get("product_memberships", [])
                }
                problems += check(product, index, True, swift_modules)

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
