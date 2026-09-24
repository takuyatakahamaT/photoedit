#!/bin/zsh
# Photo Bench: NIHO Desktop に同梱する現像エンジン photobench-engine を dist/engine/ に作る
# （プロトコルと同梱の形は docs/ENGINE_PROTOCOL.md）。
#
#   scripts/package-engine.sh                          # release ビルド（--jobs 2）→ dist/engine/
#   PHOTO_BENCH_BUILD_JOBS=8 scripts/package-engine.sh # Studio などで並列度を上げる
#
# dist/engine/
#   MacOS/photobench-engine   実行ファイル（LC_RPATH = @executable_path/../Frameworks）
#   Frameworks/*.dylib        Homebrew の LibRaw・lcms2 と、otool -L で再帰的にたどった依存（install name は @rpath/…）
#   licenses/                 同梱 dylib のライセンス文（<formula>-<version>/）と一覧 INDEX.txt
#   engine.json               版・git の commit・同梱 dylib の出所・各ファイルの SHA-256
#
# NIHO Desktop は MacOS/ の中身を .app の Contents/MacOS/ に、Frameworks/ の中身を Contents/Frameworks/ に置く。
# dist/engine/ の中でも同じ相対位置なので、その場でも起動できる。すべて ad-hoc 署名する。
# 最後に、同梱した dylib だけで起動すること（DYLD_PRINT_LIBRARIES で /opt/homebrew を読んでいないこと）と
# hello に応答することを、dist/engine/ と一時的な .app の形の両方で確かめる。
set -euo pipefail

ROOT="${0:A:h:h}"
PRODUCT=photobench-engine
DIST="$ROOT/dist/engine"
WORK="$ROOT/.build/package-engine"
JOBS="${PHOTO_BENCH_BUILD_JOBS:-2}"
SWIFT=/usr/bin/swift

SEMVER="$(/usr/bin/sed -n 's/.*static let semanticVersion = "\(.*\)".*/\1/p' "$ROOT/Sources/PhotoBenchEngine/EngineVersion.swift")"
[[ -n "$SEMVER" ]] || { echo "EngineVersion.semanticVersion を読めません" >&2; exit 1; }
COMMIT="$(/usr/bin/git -C "$ROOT" rev-parse HEAD)"
SHORT_COMMIT="$(/usr/bin/git -C "$ROOT" rev-parse --short=12 HEAD)"
DIRTY=false
if [[ -n "$(/usr/bin/git -C "$ROOT" status --porcelain -- Package.swift Package.resolved Sources scripts/package-engine.sh)" ]]; then
    DIRTY=true
fi
BUILD_METADATA="$SHORT_COMMIT"
if $DIRTY; then
    BUILD_METADATA="$SHORT_COMMIT.dirty"
    echo "注意: ソースに未コミットの変更があります（版は $SEMVER+$BUILD_METADATA）" >&2
fi
VERSION="$SEMVER+$BUILD_METADATA"

# 1. release ビルド。NIHO Desktop.app の Contents/MacOS に置かれても Dock に2つ目のアイコンを出さないよう、
#    LSBackgroundOnly の Info.plist を __TEXT,__info_plist に埋め込む（scripts/engine-Info.plist）。
#    commit は __TEXT,__pb_engine_ver に焼き込む（EngineVersion.swift）。
#    リンクだけをやり直させるため、前の実行ファイルを消してからビルドする。
/bin/mkdir -p "$WORK"
VERSION_FILE="$WORK/version-$BUILD_METADATA.txt"
print -rn -- "$BUILD_METADATA" > "$VERSION_FILE"
BIN_DIR="$("$SWIFT" build -c release --product "$PRODUCT" --package-path "$ROOT" --show-bin-path)"
/bin/rm -f "$BIN_DIR/$PRODUCT"
"$SWIFT" build -c release --product "$PRODUCT" --jobs "$JOBS" --package-path "$ROOT" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __pb_engine_ver -Xlinker "$VERSION_FILE" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/scripts/engine-Info.plist" \
    -Xlinker -headerpad_max_install_names

# 2. 配置、dylib の収集と install name の書き換え、ad-hoc 署名、ライセンス、engine.json。
/bin/rm -rf "$DIST"
/bin/mkdir -p "$DIST/MacOS" "$DIST/Frameworks" "$DIST/licenses"
/usr/bin/install -m 755 "$BIN_DIR/$PRODUCT" "$DIST/MacOS/$PRODUCT"

python3 - "$DIST" "$BIN_DIR/$PRODUCT" "$VERSION" "$SEMVER" "$COMMIT" "$DIRTY" <<'PY'
import datetime
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

dist, source_executable, version, semver, commit, dirty = sys.argv[1:]
dist = Path(dist)
source_executable = Path(source_executable)
executable = dist / "MacOS" / "photobench-engine"
frameworks = dist / "Frameworks"
licenses = dist / "licenses"
SYSTEM_PREFIXES = ("/usr/lib/", "/System/")
EXECUTABLE_RPATH = "@executable_path/../Frameworks"
# Swift's runtime lives in the OS (the dyld shared cache, not on disk).
SWIFT_OS_RPATH = "/usr/lib/swift"
# Homebrew's `license` field, corrected where the keg's own license text says
# otherwise (libomp ships LLVM's Apache-2.0 WITH LLVM-exception text).
LICENSE_OVERRIDES = {"libomp": "Apache-2.0 WITH LLVM-exception"}
LICENSE_FILE = re.compile(r"^(licen[cs]e|copying|copyright|notice)([._-].*)?$", re.IGNORECASE)


def run(*args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True).stdout


def load_commands(path):
    return run("otool", "-l", path).splitlines()


def command_values(path, command, key):
    lines = load_commands(path)
    values = []
    for index, line in enumerate(lines):
        if line.strip() == f"cmd {command}":
            for following in lines[index + 1:index + 6]:
                match = re.match(rf"\s*{key} (.*?)(?: \(offset \d+\))?$", following)
                if match:
                    values.append(match.group(1))
                    break
    return values


def rpaths(path):
    return command_values(path, "LC_RPATH", "path")


def minimum_os(path):
    return (command_values(path, "LC_BUILD_VERSION", "minos") or command_values(path, "LC_VERSION_MIN_MACOSX", "version") or [None])[0]


def install_id(path):
    lines = run("otool", "-D", path).splitlines()
    return lines[1].strip() if len(lines) > 1 else None


def dependencies(path):
    own = install_id(path)
    references = []
    for line in run("otool", "-L", path).splitlines()[1:]:
        line = line.strip()
        if not line or line.endswith(":"):
            continue
        reference = line.split(" (compatibility version")[0].strip()
        if reference != own:
            references.append(reference)
    return references


def is_system(reference):
    return reference.startswith(SYSTEM_PREFIXES)


def resolve(reference, referrer):
    """Where dyld finds `reference` when `referrer` (an original, unmodified file) loads it."""
    if reference.startswith("@loader_path/"):
        return (referrer.parent / reference[len("@loader_path/"):]).resolve()
    if reference.startswith("@executable_path/"):
        return (source_executable.parent / reference[len("@executable_path/"):]).resolve()
    if reference.startswith("@rpath/"):
        name = reference[len("@rpath/"):]
        for base in rpaths(referrer) + rpaths(source_executable):
            if base == SWIFT_OS_RPATH:
                continue
            base = base.replace("@loader_path", str(referrer.parent)).replace("@executable_path", str(source_executable.parent))
            candidate = Path(base) / name
            if candidate.exists():
                return candidate.resolve()
        if name.startswith("libswift"):
            return None  # provided by the OS through /usr/lib/swift
        raise SystemExit(f"{referrer}: cannot resolve {reference}")
    return Path(reference).resolve()


# --- Collect every non-system dylib, recursively (breadth first). ---
bundled = {}        # bundled file name -> original resolved path
origin_of = {}      # original resolved path -> bundled file name
rewrites = {}       # Mach-O in dist -> {old reference: new reference}
queue = [(executable, source_executable)]
while queue:
    target, original = queue.pop(0)
    changes = rewrites.setdefault(target, {})
    for reference in dependencies(original):
        if is_system(reference):
            continue
        resolved = resolve(reference, original)
        if resolved is None:
            continue
        name = origin_of.get(resolved)
        if name is None:
            name = Path(install_id(resolved) or resolved.name).name
            if name in bundled:
                raise SystemExit(f"two different libraries named {name}: {bundled[name]} and {resolved}")
            bundled[name] = resolved
            origin_of[resolved] = name
            copy = frameworks / name
            shutil.copy2(resolved, copy)
            copy.chmod(0o644)
            queue.append((copy, resolved))
        if reference != f"@rpath/{name}":
            changes[reference] = f"@rpath/{name}"

# --- Rewrite install names and rpaths, then sign (inner code first). ---
for target, changes in rewrites.items():
    arguments = []
    for old, new in sorted(changes.items()):
        arguments += ["-change", old, new]
    if target == executable:
        kept = {SWIFT_OS_RPATH}
        for path in rpaths(target):
            if path not in kept:
                arguments += ["-delete_rpath", path]
        arguments += ["-add_rpath", EXECUTABLE_RPATH]
    else:
        arguments += ["-id", f"@rpath/{target.name}"]
        for path in rpaths(target):
            arguments += ["-delete_rpath", path]
    if arguments:
        subprocess.run(["install_name_tool", *arguments, str(target)], check=True, capture_output=True)

for target in sorted(frameworks.iterdir()) + [executable]:
    identifier = ["--identifier", "life.niho.photobench.engine"] if target == executable else []
    subprocess.run(
        ["codesign", "--force", "--sign", "-", "--timestamp=none", *identifier, str(target)],
        check=True, capture_output=True,
    )
    subprocess.run(["codesign", "--verify", "--strict", str(target)], check=True)

# --- Nothing may point outside the bundle any more. ---
problems = []
for target in [executable] + sorted(frameworks.iterdir()):
    for reference in dependencies(target):
        if is_system(reference):
            continue
        name = reference[len("@rpath/"):] if reference.startswith("@rpath/") else None
        if name is None or not ((frameworks / name).exists() or name.startswith("libswift")):
            problems.append(f"{target.name} -> {reference}")
    actual = rpaths(target)
    allowed = {SWIFT_OS_RPATH, EXECUTABLE_RPATH} if target == executable else set()
    if any(path not in allowed for path in actual) or (target == executable and EXECUTABLE_RPATH not in actual):
        problems.append(f"{target.name} rpaths {actual}")
if problems:
    raise SystemExit("references outside the bundle remain:\n  " + "\n  ".join(problems))

# --- Licenses, per Homebrew keg. ---
def keg_of(path):
    parts = path.parts
    if "Cellar" not in parts:
        return None
    index = parts.index("Cellar")
    return parts[index + 1], parts[index + 2], Path(*parts[:index + 3])


kegs = {}
for name, original in sorted(bundled.items()):
    keg = keg_of(original)
    if keg is None:
        raise SystemExit(f"{name} ({original}) is not from a Homebrew keg; add its license by hand")
    formula, keg_version, keg_root = keg
    kegs.setdefault((formula, keg_version, keg_root), []).append(name)

try:
    info = json.loads(run("brew", "info", "--json=v2", *sorted({formula for formula, _, _ in kegs})))
    spdx = {entry["name"]: entry.get("license") or "unknown" for entry in info.get("formulae", [])}
except (OSError, subprocess.CalledProcessError, ValueError):
    spdx = {}

libraries = []
index_lines = [
    "photobench-engine に同梱した第三者ライブラリ（Homebrew のボトル）とライセンス",
    "LibRaw などは動的リンクのまま同梱し、Frameworks/ の dylib を差し替えられる形を保っている。",
    "",
]
for (formula, keg_version, keg_root), names in sorted(kegs.items()):
    candidates = [p for p in keg_root.iterdir() if p.is_file() and LICENSE_FILE.match(p.name)]
    documentation = keg_root / "share" / "doc"
    if documentation.is_dir():
        candidates += [
            p for p in sorted(documentation.rglob("*"))
            if p.is_file() and (LICENSE_FILE.match(p.name) or p.name == "README.ijg")
        ]
    directory = licenses / f"{formula}-{keg_version}"
    directory.mkdir(parents=True, exist_ok=True)
    copied = {}
    for candidate in candidates:
        digest = hashlib.sha256(candidate.read_bytes()).hexdigest()
        if digest in copied.values():
            continue
        target_name = candidate.name if candidate.name not in copied else f"{candidate.parent.name}-{candidate.name}"
        shutil.copy2(candidate, directory / target_name)
        (directory / target_name).chmod(0o644)
        copied[target_name] = digest
    if not copied:
        raise SystemExit(f"no license text found in {keg_root}")
    license_id = LICENSE_OVERRIDES.get(formula, spdx.get(formula, "unknown"))
    index_lines.append(f"{formula} {keg_version}  ({license_id})")
    index_lines.append("  dylib: " + ", ".join(f"Frameworks/{n}" for n in names))
    index_lines.append("  license: " + ", ".join(f"licenses/{directory.name}/{n}" for n in sorted(copied)))
    index_lines.append("")
    for name in names:
        libraries.append({
            "file": f"Frameworks/{name}",
            "formula": formula,
            "version": keg_version,
            "license": license_id,
            "minimumMacOS": minimum_os(frameworks / name),
            "source": str(bundled[name]),
        })
(licenses / "INDEX.txt").write_text("\n".join(index_lines), encoding="utf-8")

# --- engine.json: version, commit, and the SHA-256 of every file. ---
def version_key(value):
    return tuple(int(part) for part in (value or "0").split("."))


minimums = [minimum_os(executable)] + [entry["minimumMacOS"] for entry in libraries]
files = []
for path in sorted(p for p in dist.rglob("*") if p.is_file() and p.name != "engine.json"):
    data = path.read_bytes()
    files.append({"path": str(path.relative_to(dist)), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
manifest = {
    "name": "photobench-engine",
    "engineVersion": version,
    "semanticVersion": semver,
    "protocolVersion": 1,
    "gitCommit": commit,
    "gitDirty": dirty == "true",
    "builtAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "executable": "MacOS/photobench-engine",
    "executableMinimumMacOS": minimum_os(executable),
    # The newest minimum among the executable and the bundled dylibs: the
    # oldest macOS the bundle can start on.
    "minimumMacOS": max(minimums, key=version_key),
    "libraries": libraries,
    "files": files,
}
(dist / "engine.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
for entry in libraries:
    if version_key(entry["minimumMacOS"]) > version_key(manifest["executableMinimumMacOS"]):
        print(
            f"注意: {entry['file']} は macOS {entry['minimumMacOS']} 以降用のボトルです"
            f"（実行ファイルは {manifest['executableMinimumMacOS']} 以降）",
            file=sys.stderr,
        )
print(f"bundled {len(bundled)} dylibs: {', '.join(sorted(bundled))}")
PY

# 3. 同梱した dylib だけで起動し、hello に答えることを確かめる。
#    NIHO Desktop が渡すのと同じく HOME と PATH だけの環境で起動する。
verify_launch() {
    local executable=$1 tag=$2 label=$3
    local out="$WORK/verify-$tag.out" err="$WORK/verify-$tag.err"
    printf '%s\n' '{"id":1,"method":"hello"}' '{"id":2,"method":"shutdown"}' \
        | /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin DYLD_PRINT_LIBRARIES=1 "$executable" --stdio > "$out" 2> "$err"
    python3 - "$out" "$err" "$VERSION" "${executable:h:h}/Frameworks/" "$label" <<'PY'
import json
import re
import sys

out, err, version, frameworks, label = sys.argv[1:]
responses = [json.loads(line) for line in open(out, encoding="utf-8").read().splitlines()]
assert [r.get("id") for r in responses] == [1, 2], f"{label}: unexpected responses {responses}"
hello = responses[0]
assert hello.get("ok") and hello["result"]["protocolVersion"] == 1, f"{label}: {hello}"
assert hello["result"]["engineVersion"] == version, f"{label}: engineVersion {hello['result']['engineVersion']} != {version}"
assert responses[1].get("ok"), f"{label}: shutdown {responses[1]}"
loaded = []
for line in open(err, encoding="utf-8", errors="replace").read().splitlines():
    match = re.match(r"dyld\[\d+\]: (?:<[0-9A-F-]+> )?(.*)$", line)
    if match:
        loaded.append(match.group(1))
outside = [p for p in loaded if p.startswith(("/opt/homebrew", "/usr/local"))]
assert not outside, f"{label}: loaded from outside the bundle: {outside}"
bundled = sorted({p for p in loaded if p.startswith(frameworks)})
assert any("libraw" in p for p in bundled), f"{label}: the bundled LibRaw was not loaded: {loaded[:20]}"
print(f"{label}: hello OK ({hello['result']['engineVersion']}), {len(bundled)} bundled dylibs loaded, none from /opt/homebrew")
PY
}

verify_launch "$DIST/MacOS/$PRODUCT" dist "dist/engine"

# NIHO Desktop のビルドと同じ Contents/MacOS・Contents/Frameworks の形でも起動する。
APP="$WORK/verify/PhotoBenchEngineCheck.app"
/bin/rm -rf "$WORK/verify"
/bin/mkdir -p "$APP/Contents"
/usr/bin/ditto "$DIST/MacOS" "$APP/Contents/MacOS"
/usr/bin/ditto "$DIST/Frameworks" "$APP/Contents/Frameworks"
verify_launch "$APP/Contents/MacOS/$PRODUCT" app "Contents/MacOS + Contents/Frameworks"
/bin/rm -rf "$WORK/verify"

echo "$DIST ($VERSION)"
(cd "$DIST" && /usr/bin/find . -type f | /usr/bin/sort | while read -r file; do
    printf '  %10s  %s\n' "$(/usr/bin/stat -f %z "$file")" "${file#./}"
done)
