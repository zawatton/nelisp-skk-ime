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
    epoch = subprocess.run([str(out / "Release/host-policy-unit.exe"), "epoch-use"],
                           check=True, capture_output=True, text=True, timeout=15)
    for hit in (0, 1):
        if f"hit={hit} refreshed=2 native_delta=0" not in epoch.stdout:
            raise AssertionError(f"missing epoch single-use evidence: {epoch.stdout}")
    print(epoch.stdout, end="")
    for mode, evidence in (("broken-coalescing", "hit=0 refreshed=0 native_delta=1"),
                           ("broken-reseed", "policy restart unit: reseed=0 native_calls=2"),
                           ("broken-candidate", "reset_native=1")):
        result = subprocess.run([str(out / "Release/host-policy-unit.exe"), mode],
                                capture_output=True, text=True, timeout=15,
                                env=dict(os.environ, DDSKK_HOST_POLICY_COUNTERS="1"))
        if result.returncode != 1 or evidence not in result.stdout:
            raise AssertionError(f"{mode}: regression control did not fail: {result.stdout}")
    broken = subprocess.run([str(out / "Release/host-policy-unit.exe"), "broken-keepalive"],
                            timeout=15, env=dict(os.environ, DDSKK_HOST_POLICY_COUNTERS="1"))
    if broken.returncode != 1:
        raise AssertionError("disabled keep-alive unexpectedly passed memo-hit checks")
    env = dict(os.environ, DDSKK_HOST_POLICY_COUNTERS="1", DDSKK_HARNESS_DIAGNOSTICS="1",
               NATIVEIME_REGISTRY_KEY="Software\\NativeIME-test-keepalive-unit")
    # Keep this fixture independent of any coordinator's native bundle settings.
    for name in ("DDSKK_HOST_POLICY_RUNTIME", "DDSKK_HOST_POLICY_BUNDLE"):
        env.pop(name, None)
    for mode, expected in (("broken-stderr", 1), ("transport", 0)):
        log = out / f"{mode}.log"
        log.unlink(missing_ok=True)
        result = subprocess.run([str(out / "Release/host-policy-unit.exe"), mode, str(log)],
                                timeout=20, env=env)
        if result.returncode != expected:
            raise AssertionError(f"{mode}: expected exit {expected}, got {result.returncode}")
        evidence = log.read_text("utf-8")
        if mode == "broken-stderr":
            # Old routing consumes a partial READY plus stderr and stops on CR.
            if "policy-ready-rejected line_complete=0 bytes=21 hex=48503220524566616b6520646961676e6f73746963" not in evidence:
                raise AssertionError("old stderr routing did not reproduce partial READY")
        elif evidence.count("policy-ready startup_ms=") != 2 or "keepalive=1 reseed=1" not in evidence or "policy-start-failed" in evidence:
            raise AssertionError("missing clean READY/keepalive evidence across relaunch")
    print("PASS policy adapter keepalive fake_clock=1 fake_child=1 ready_relaunch=1 "
          "negative_control=coalescing,disabled,reseed,candidate-pruning,old-stderr-routing stacks=0")

if __name__ == "__main__":
    main()
