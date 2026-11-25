#!/usr/bin/env python3
"""Record the targeted renderer signposts for an in-progress interaction test."""
import argparse
import ctypes
from pathlib import Path
import re
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("device")
parser.add_argument("tag")
parser.add_argument("evidence", type=Path)
parser.add_argument("--ssh-socket", required=True)
parser.add_argument("--ssh-host", required=True)
args = parser.parse_args()
if not re.fullmatch("[a-z0-9_]{1,40}", args.tag):
    parser.error("invalid run tag")
remote = "/var/mobile/Library/Caches/t3rm-rewrite-qa/tabs_" + args.tag + "/"
ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=2", "-S", args.ssh_socket, args.ssh_host]
deadline = time.monotonic() + 90
while time.monotonic() < deadline:
    r = subprocess.run(ssh + ["cat " + remote + "ready 2>/dev/null"], capture_output=True)
    if r.returncode == 0 and r.stdout.strip().isdigit():
        break
    time.sleep(0.3)
else:
    raise SystemExit("tabs did not reach the recording gate")
pid = r.stdout.strip().decode()
lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
token, changed = ctypes.c_int(), ctypes.c_int()
event = "com.davghz.t3rm.qa.tabs.profile." + args.tag
lib.notify_register_check(event.encode(), ctypes.byref(token))
lib.notify_check(token, ctypes.byref(changed))
for attempt in range(3):
    trace_name = args.tag + "_tabs" + ("" if not attempt else str(attempt + 1))
    with (args.evidence / (trace_name + ".xctrace.log")).open("w") as log:
        trace = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Logging",
                                  "--instrument", "os_signpost", "--device", args.device, "--attach", pid,
                                  "--time-limit", "13s", "--notify-tracing-started", event,
                                  "--output", str(args.evidence / (trace_name + ".trace"))],
                                 stdout=log, stderr=subprocess.STDOUT)
    cutoff = time.monotonic() + 10
    while time.monotonic() < cutoff and trace.poll() is None:
        lib.notify_check(token, ctypes.byref(changed))
        if changed.value:
            break
        time.sleep(0.1)
    if trace.poll() is None or trace.returncode == 0:
        break
lib.notify_cancel(token)
subprocess.run(ssh + ["touch " + remote + "trace.go"], check=True)
trace.wait(timeout=40)
for name in ["windows.json", "keys.json"]:
    until = time.monotonic() + 50
    while time.monotonic() < until:
        result = subprocess.run(ssh + ["cat " + remote + name + " 2>/dev/null"], capture_output=True)
        if result.returncode == 0:
            (args.evidence / (args.tag + "_" + name)).write_bytes(result.stdout)
            break
        time.sleep(0.5)
    else:
        raise SystemExit("missing " + name)
raise SystemExit(trace.returncode)
