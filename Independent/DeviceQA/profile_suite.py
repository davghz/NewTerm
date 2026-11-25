#!/usr/bin/env python3
"""Run six isolated-app workloads and record one matched Time Profiler trace per case."""
import argparse
import ctypes
import json
from pathlib import Path
import re
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("testrun", type=Path)
    parser.add_argument("device")
    parser.add_argument("target", choices=["baseline", "review"])
    parser.add_argument("tag")
    parser.add_argument("evidence", type=Path)
    cases = [f"{state}_{style}" for state in ("cold", "history") for style in ("sparse", "styled", "burst")]
    parser.add_argument("--case", choices=cases)
    parser.add_argument("--ssh-socket", required=True)
    parser.add_argument("--ssh-host", required=True)
    args = parser.parse_args()
    if not re.fullmatch("[a-z0-9_]{1,30}", args.tag):
        parser.error("use a new lowercase alphanumeric run tag")
    root = "/var/mobile/Library/Caches/t3rm-rewrite-qa/"
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=2", "-S", args.ssh_socket, args.ssh_host]
    args.evidence.mkdir(parents=True, exist_ok=True)
    output = args.evidence.resolve()
    selected = [args.case] if args.case else cases
    ui_case = args.case or "suite"
    ui_tag = args.tag + "_" + args.case if args.case else args.tag
    ui = subprocess.Popen([sys.executable, str(Path(__file__).with_name("run_ui.py")),
                           str(args.testrun.resolve()), args.device, args.target, ui_case, ui_tag, str(output), "--profile"])
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    traces = []
    valid = True
    for name in selected:
        case = args.tag + "_" + name
        base = root + case
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if ui.poll() is not None:
                raise RuntimeError(f"runner exited before {case} was ready; inspect its result bundle")
            probe = subprocess.run(ssh + ["cat " + base + ".active 2>/dev/null"], capture_output=True)
            if probe.returncode == 0 and probe.stdout.strip().isdigit():
                break
            time.sleep(0.3)
        else:
            raise RuntimeError("timed out waiting for " + case)
        pid = probe.stdout.strip().decode("ascii")
        event = ("com.davghz.t3rm.qa.trace." + case).encode()
        token, changed = ctypes.c_int(), ctypes.c_int()
        if lib.notify_register_check(event, ctypes.byref(token)):
            raise RuntimeError("could not monitor Instruments start")
        lib.notify_check(token, ctypes.byref(changed))
        for attempt in range(3):
            trace_name = case + ("" if attempt == 0 else f"_attempt{attempt + 1}")
            with (output / (trace_name + ".xctrace.log")).open("w") as log:
                trace = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Time Profiler",
                                          "--device", args.device, "--attach", pid, "--time-limit", "12s",
                                          "--notify-tracing-started", event.decode(), "--output", str(output / (trace_name + ".trace"))],
                                         stdout=log, stderr=subprocess.STDOUT)
            until = time.monotonic() + 12
            while time.monotonic() < until and trace.poll() is None:
                lib.notify_check(token, ctypes.byref(changed))
                if changed.value:
                    break
                time.sleep(0.1)
            if trace.poll() is None or trace.returncode == 0:
                break
        traces.append((trace_name, trace))
        lib.notify_cancel(token)
        subprocess.run(ssh + ["touch " + base + ".go"], check=True)
        until = time.monotonic() + 60
        while time.monotonic() < until:
            result = subprocess.run(ssh + ["cat " + base + ".json 2>/dev/null"], capture_output=True)
            if result.returncode == 0 and result.stdout:
                data = json.loads(result.stdout)
                (output / (case + ".json")).write_bytes(result.stdout)
                valid = valid and not data.get("error") and data.get("validated_frames") == 41
                print(case, data.get("error") or f"{data['validated_frames']} replies, median {data['median_ms']:.2f} ms", flush=True)
                break
            time.sleep(0.4)
        else:
            raise RuntimeError("timed out measuring " + case)
        # Only one Instruments recording can target the same device at a time.
        trace.wait(timeout=35)
    code = ui.wait(timeout=60)
    for name, trace in traces:
        print(name, "Time Profiler status", trace.returncode)
    return code or int(not valid or any(t.returncode for _, t in traces))


if __name__ == "__main__":
    raise SystemExit(main())
