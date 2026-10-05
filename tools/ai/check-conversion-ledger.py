"""Strict ledger meter: hash evidence and run every stored-value command in bash."""
import hashlib
import os
import re
import shutil
import subprocess
from pathlib import Path


def main():
    root = Path(__file__).resolve().parents[2]
    bash = shutil.which("bash")
    if os.name == "nt" and shutil.which("git"):
        # Windows' system bash.exe can be a WSL launcher with no distro.
        # Discover Git Bash from the installed Git executable, without
        # putting a machine-specific installation path in this repository.
        git_bash = Path(shutil.which("git")).resolve().parent.parent / "bin/bash.exe"
        if git_bash.is_file():
            bash = str(git_bash)
    assert bash, "bash is required"
    ledger = root / "tools/ai/conversion-latency-progress.org"
    sections = re.split(r"(?m)^\*\* ", ledger.read_text(encoding="utf-8"))[1:]
    passed = 0
    for section in sections:
        name = section.split()[0]
        lines = section.splitlines()[1:]
        commands = [line[5:] for line in lines if line.startswith("cmd: ")]
        evidence = [line for line in lines if line.startswith("evidence: ")]
        pending = "pending" in lines
        assert not (pending and (commands or evidence)), f"invalid pending section: {name}"
        valid = not pending and bool(commands or evidence)
        for entry in evidence:
            match = re.fullmatch(r"evidence: (.+) sha256=([0-9a-fA-F]{64})", entry)
            assert match, f"invalid evidence: {entry}"
            path = root / match[1]
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            valid = valid and actual == match[2].lower()
            print(f"{name} hash {match[1]} {'PASS' if actual == match[2].lower() else 'FAIL'}")
        for command in commands:
            result = subprocess.run([bash, "--noprofile", "--norc", "-c", command], cwd=root,
                                    capture_output=True, text=True, encoding="utf-8", errors="replace")
            valid = valid and result.returncode == 0
            print(f"{name} cmd exit={result.returncode}: {command}")
            for line in (result.stdout + result.stderr).splitlines()[-4:]:
                print(line)
        passed += int(valid)
        print(f"{name} {'PASS' if valid else 'PENDING' if pending else 'FAIL'}")
    print(f"Ledger meter: {passed}/{len(sections)}")
    return 0 if passed == len(sections) else 1


if __name__ == "__main__":
    raise SystemExit(main())
