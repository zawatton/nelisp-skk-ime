"""Build/replay the current C++ oracle and reject a byte-corrupted golden."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests/fixtures/host-native-nelisp"
OUTPUTS = ("oracle.jsonl", "parsed.bin")
FILES = ("SKK-JISYO.synthetic",) + OUTPUTS


def digest(data):
    return hashlib.sha256(data).hexdigest()


def compare(fixtures, actual):
    """This exact check is also used by the corrupted-fixture child process."""
    manifest = json.loads((fixtures / "manifest.json").read_text("utf-8"))
    if manifest["schema"] != 1 or set(manifest["sha256"]) != set(FILES):
        raise ValueError("unexpected fixture manifest")
    for name in FILES:
        data = (fixtures / name).read_bytes()
        if digest(data) != manifest["sha256"][name]:
            raise ValueError(f"fixture sha256 mismatch: {name}")
        if name in OUTPUTS and data != (actual / name).read_bytes():
            raise ValueError(f"C++ golden mismatch: {name}")
    records = [json.loads(line) for line in (actual / "oracle.jsonl").read_text("utf-8").splitlines()]
    groups = {row["case"].split("/")[0] for row in records}
    if not {"SOURCES", "CACHE", "RESTART", "PUBLICATION", "LEARNING"} <= groups:
        raise ValueError("missing policy group")
    if len(records) < 1700 or not (actual / "parsed.bin").stat().st_size:
        raise ValueError("empty or incomplete corpus")
    return len(records)


def run(command, timeout):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(map(str, command))}\n{result.stdout}\n{result.stderr}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--freeze", action="store_true", help="explicitly replace reviewed frozen bytes; normal checks never write goldens")
    parser.add_argument("--compare-only", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--fixtures", type=Path, default=FIXTURES, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.compare_only:
        count = compare(args.fixtures, args.compare_only)
        print(f"PASS HN oracle compare records={count}")
        return
    if args.fixtures != FIXTURES:
        raise ValueError("normal runs require the public repository fixture")
    if not args.freeze:
        manifest = json.loads((FIXTURES / "manifest.json").read_text("utf-8"))
        if digest((FIXTURES / FILES[0]).read_bytes()) != manifest["sha256"][FILES[0]]:
            raise ValueError("synthetic input sha256 mismatch before oracle execution")
    build = ROOT / "build/w"
    if not (build / "CMakeCache.txt").exists():
        run(["cmake", "-S", "windows", "-B", "build/w", "-G", "Visual Studio 17 2022", "-A", "x64"], 60)
    run(["cmake", "--build", "build/w", "--config", "Release", "--target", "hn-oracle"], 90)
    started = time.monotonic()
    executables = list(build.rglob("hn-oracle.exe"))
    executable = next((path for path in executables if path.parent.name == "Release"), None)
    if executable is None:
        raise ValueError("missing Release hn-oracle.exe")
    with tempfile.TemporaryDirectory(prefix="hn-oracle-", dir=build) as temp:
        actual = Path(temp) / "actual"
        run([str(executable), str(FIXTURES / FILES[0]), str(actual)], 20)
        if args.freeze:
            for name in OUTPUTS:
                shutil.copyfile(actual / name, FIXTURES / name)
            manifest = {
                "schema": 1,
                "sha256": {name: digest((FIXTURES / name).read_bytes()) for name in FILES},
                "production_source_sha256": digest((ROOT / "windows/host/main.cpp").read_bytes()),
                "index": "ParseSkkJisyo produces no index; parsed.bin is sorted key/tail byte records, uint32 LE lengths",
            }
            (FIXTURES / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
        count = compare(FIXTURES, actual)
        corrupt = Path(temp) / "corrupt"
        shutil.copytree(FIXTURES, corrupt)
        data = bytearray((corrupt / "parsed.bin").read_bytes())
        data[len(data) // 2] ^= 1
        (corrupt / "parsed.bin").write_bytes(data)
        command = [sys.executable, str(Path(__file__).resolve()), "--compare-only", str(actual), "--fixtures", str(corrupt)]
        rejected = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10)
        if rejected.returncode != 1 or "fixture sha256 mismatch: parsed.bin" not in rejected.stdout:
            raise ValueError(f"corrupted-fixture negative control did not fail correctly: {rejected.stdout} {rejected.stderr}")
        # Also corrupt its hash, proving byte comparison independently of hashes.
        manifest = json.loads((corrupt / "manifest.json").read_text("utf-8"))
        manifest["sha256"]["parsed.bin"] = digest(data)
        (corrupt / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        rejected = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10)
        if rejected.returncode != 1 or "C++ golden mismatch: parsed.bin" not in rejected.stdout:
            raise ValueError("byte-comparison negative control did not fail correctly")
        print(f"PASS HN oracle records={count} outputs={len(OUTPUTS)} groups=5 negative_controls=2 post_build_seconds={time.monotonic()-started:.3f}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(f"FAIL HN oracle: {error}")
        raise SystemExit(1)
