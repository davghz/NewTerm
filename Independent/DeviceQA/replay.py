#!/usr/bin/env python3
"""Measure a real terminal's processing fence using ANSI cursor-position replies."""
import ctypes
import json
import math
import os
from pathlib import Path
import re
import select
import statistics
import subprocess
import sys
import termios
import time
import tty


REPLY = re.compile(rb"\x1b\[(\d+);(\d+)R")
ESC = b"\x1b["
CASES = ["smoke"] + [f"{state}_{paint}" for state in ["cold", "history"]
                     for paint in ["sparse", "styled", "burst"]]


def thermal_state():
    objc = ctypes.CDLL("/usr/lib/libobjc.A.dylib")
    ctypes.CDLL("/System/Library/Frameworks/Foundation.framework/Foundation")
    objc.objc_getClass.argtypes = [ctypes.c_char_p]
    objc.objc_getClass.restype = ctypes.c_void_p
    objc.sel_registerName.argtypes = [ctypes.c_char_p]
    objc.sel_registerName.restype = ctypes.c_void_p
    call = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(("objc_msgSend", objc))
    info = call(objc.objc_getClass(b"NSProcessInfo"), objc.sel_registerName(b"processInfo"))
    return int(call(info, objc.sel_registerName(b"thermalState")) or 0)


def write(fd, data):
    data = memoryview(data)
    while data:
        data = data[os.write(fd, data):]


def position(row, column):
    return ESC + f"{row};{column}H".encode()


def measure(fd, payload, expected):
    begin = time.monotonic_ns()
    write(fd, payload + ESC + b"6n")
    response = b""
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        readable, _, _ = select.select([fd], [], [], max(0, deadline - time.monotonic()))
        if not readable:
            break
        part = os.read(fd, 256)
        if not part:
            break
        response += part
        match = REPLY.search(response)
        if match:
            got = tuple(int(x) for x in match.groups())
            if got != expected:
                raise ValueError(f"expected cursor {expected}, received {got}")
            return (time.monotonic_ns() - begin) / 1_000_000
        if len(response) > 1024:
            break
    raise TimeoutError(f"cursor reply timed out; {len(response)} terminal input bytes")


def frame(style, index, columns, rows):
    patches = {"sparse": 4, "styled": min(18, rows), "burst": rows * 6}
    parts = []
    for patch in range(patches[style]):
        row = 1 + (patch * 7 + index * 3) % rows
        col = 1 + ((patch + index) % max(1, columns - 8)) if style == "sparse" else 1
        count = 3 if style == "sparse" else columns - 2
        parts.append(position(row, col))
        if style != "sparse":
            parts.append(ESC + f"38;5;{16 + (patch + index) % 216}m".encode())
        parts.append(bytes([65 + (patch + index) % 26]) * count)
    parts.append(ESC + b"0m")
    return b"".join(parts), (row, col + count)


class ResourceSampler:
    """Same-UID terminal process counters, converted from mach absolute time."""
    def __init__(self):
        # The baseline uses a login process between the shell and the app.
        self.pid = os.getppid()
        allowed = ("/t3rm-alpha3-qa.app/t3rm", "/com.davghz.t3rm.review.app/t3rm")
        for _ in range(5):
            row = subprocess.check_output(["ps", "-p", str(self.pid), "-o", "ppid=,comm="], text=True).strip()
            parent, _, name = row.partition(" ")
            if name.strip().endswith(allowed):
                break
            self.pid = int(parent)
            if self.pid <= 1:
                raise RuntimeError("isolated terminal app is absent from process ancestry")
        else:
            raise RuntimeError("cannot identify isolated terminal process")
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        ratio = (ctypes.c_uint32 * 2)()
        if self.system.mach_timebase_info(ctypes.byref(ratio)):
            raise OSError("mach_timebase_info")
        self.nanoseconds_per_tick = ratio[0] / ratio[1]
        self.buffer = (ctypes.c_uint64 * 12)()

    def sample(self):
        if self.lib.proc_pid_rusage(self.pid, 0, ctypes.byref(self.buffer)) != 0:
            raise OSError(ctypes.get_errno(), "proc_pid_rusage")
        return dict(monotonic_ns=time.monotonic_ns(),
                    cpu_ns=round((self.buffer[2] + self.buffer[3]) * self.nanoseconds_per_tick),
                    resident_bytes=self.buffer[8], footprint_bytes=self.buffer[9],
                    thermal_state=thermal_state())


def run_case(case, run, profile):
    result = {"case": case, "run": run, "clock": "monotonic_ns",
              "metric": "PTY write start through validated terminal CPR", "samples_ms": []}
    output = Path(__file__).parent / (run + ".json")
    active = output.with_suffix(".active")
    fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    saved = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        size = os.get_terminal_size(fd)
        columns, rows = min(46, size.columns), min(24, size.lines)
        if columns < 10 or rows < 4:
            raise ValueError(f"invalid terminal size {size}")
        resources = ResourceSampler()
        result.update(pty_size=[size.columns, size.lines], workload_grid=[columns, rows],
                      pid=os.getpid(), app_pid=resources.pid, started_unix=time.time(),
                      thermal_before=thermal_state())
        if profile:
            active.write_text(str(resources.pid))
            gate = output.with_suffix(".go")
            timeout = time.monotonic() + 30
            while not gate.exists() and time.monotonic() < timeout:
                time.sleep(0.1)
            if not gate.exists():
                raise TimeoutError("host profiler did not release workload")
            gate.unlink()
        else:
            active.write_text(str(resources.pid))
        # Use primary-screen history and keep setup time separate from frame latency.
        measure(fd, ESC + b"3J" + ESC + b"2J" + position(1, 1), (1, 1))
        history = 10000 if case.startswith("history_") else 0
        result["prefill_rows"] = history
        begin = time.monotonic()
        for block in range(history // 100):
            write(fd, b"".join(f"qa history {block * 100 + n:05d}\r\n".encode() for n in range(100)))
        measure(fd, position(1, 1), (1, 1))
        result["setup_seconds"] = time.monotonic() - begin
        style = "sparse" if case == "smoke" else case.split("_")[1]
        result["resource_trace"] = [resources.sample()]
        for index in range(3 if case == "smoke" else 41):
            data, expected = frame(style, index, columns, rows)
            latency = measure(fd, data, expected)
            result["samples_ms"].append(latency)
            # Fixed refresh cadence provides a comparable workload and power window.
            time.sleep(max(0, 0.060 - latency / 1000))
            if index % 4 == 3:
                result["resource_trace"].append(resources.sample())
        result["resource_trace"].append(resources.sample())
        first, last = result["resource_trace"][0], result["resource_trace"][-1]
        result["app_cpu_percent_one_core"] = 100 * (last["cpu_ns"] - first["cpu_ns"]) / (last["monotonic_ns"] - first["monotonic_ns"])
        timings = sorted(result["samples_ms"])
        result.update(median_ms=statistics.median(timings),
                      p95_ms=timings[math.ceil(0.95 * len(timings)) - 1], validated_frames=len(timings))
    except Exception as error:
        result["error"] = str(error)
    finally:
        result["ended_unix"] = time.time()
        result["thermal_after"] = thermal_state()
        write(fd, ESC + b"0m" + b"\r\n")
        termios.tcsetattr(fd, termios.TCSANOW, saved)
        os.close(fd)
        temporary = output.with_suffix(".tmp")
        temporary.write_text(json.dumps(result, indent=2) + "\n")
        temporary.replace(output)
        active.unlink(missing_ok=True)
    print("T3RM QA", case, "ERROR" if "error" in result else "complete")
    return int("error" in result)


if __name__ == "__main__":
    selected, run = sys.argv[1:3]
    profile = sys.argv[3:] == ["profile"]
    if selected not in ["suite"] + CASES or not re.fullmatch(r"[a-z0-9_]{1,50}", run):
        raise SystemExit("invalid device QA case or run tag")
    try:
        cases = CASES[1:] if selected == "suite" else [selected]
        errors = [run_case(case, run + "_" + case if selected == "suite" else run, profile) for case in cases]
    finally:
        system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        system.notify_post(("com.davghz.t3rm.qa.done." + run).encode())
    sys.exit(int(any(errors)))
