"""Build/run the policy memo unit with a fake clock/child; no stack or registry."""
from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parents[2]

def main():
    out = ROOT / "build/w/policy-adapter-unit"
    subprocess.run(["cmake", "-S", str(ROOT / "windows/test-host/s3"), "-B", str(out),
                    "-G", "Visual Studio 17 2022", "-A", "x64"], check=True, timeout=60)
    subprocess.run(["cmake", "--build", str(out), "--config", "Release", "--target",
                    "host-policy-unit", "host-policy-sync-control"], check=True, timeout=120)
    for enabled in ("0", "1"):
        log = out / f"keepalive-{enabled}.log"
        log.unlink(missing_ok=True)
        subprocess.run([str(out / "Release/host-policy-unit.exe"), "normal", str(log)],
                       check=True, timeout=15, env=dict(os.environ,
                       DDSKK_HOST_POLICY_COUNTERS=enabled, DDSKK_HARNESS_DIAGNOSTICS="1",
                       NATIVEIME_REGISTRY_KEY="Software\\NativeIME-test-keepalive-unit"))
        if "policy-keepalive refreshed=2 skipped=" not in log.read_text("utf-8"):
            raise AssertionError("missing private keep-alive diagnostics")
    broken = subprocess.run([str(out / "Release/host-policy-unit.exe"), "broken-keepalive"],
                            timeout=15, env=dict(os.environ, DDSKK_HOST_POLICY_COUNTERS="1"))
    if broken.returncode != 1:
        raise AssertionError("disabled keep-alive unexpectedly passed memo-hit checks")
    print("PASS policy adapter keepalive fake_clock=1 fake_child=1 negative_control=disabled stacks=0")

if __name__ == "__main__":
    main()
