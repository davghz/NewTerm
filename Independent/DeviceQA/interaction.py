#!/usr/bin/env python3
"""Controlled hidden-terminal traffic and a keyboard-to-visible-color echo."""
import ctypes
import json
import os
from pathlib import Path
import re
import select
import sys
import termios
import time
import tty

from replay import ResourceSampler, position, write


def wait_for(path, seconds):
    deadline = time.monotonic() + seconds
    while not path.exists():
        if time.monotonic() >= deadline:
            raise TimeoutError(str(path))
        time.sleep(0.05)


def notify(name):
    ctypes.CDLL("/usr/lib/libSystem.B.dylib").notify_post(name.encode())


def paint_text(fd, letter):
    write(fd, position(2, 2) + bytes([letter]) * 30)


def hidden(fd, root, index):
    # The app switches away from all three PTYs before the common gate.
    print(f"HIDDEN READY {index}", flush=True)
    wait_for(root / "hidden.go", 90)
    for frame in range(100):
        paint_text(fd, 65 + frame % 26)
        time.sleep(0.047)
    write(fd, position(4, 2) + f"HIDDEN FINISHED {index}\r\n".encode())
    (root / f"done{index}").write_text("100\n")


def visible(fd, root, tag):
    resources = ResourceSampler()
    (root / "ready").write_text(str(resources.pid))
    wait_for(root / "trace.go", 40)
    windows = {}
    def start(name):
        windows[name] = {"start_unix": time.time(), "start_mono_ns": time.monotonic_ns()}
    def stop(name):
        windows[name].update(end_unix=time.time(), end_mono_ns=time.monotonic_ns())
    start("visible_before")
    for n in range(15):
        paint_text(fd, 65 + n)
        time.sleep(0.06)
    stop("visible_before")
    time.sleep(0.6)
    start("hidden_only")
    (root / "hidden.go").write_text("go")
    for index in range(1, 4):
        wait_for(root / f"done{index}", 20)
    stop("hidden_only")
    time.sleep(0.5)
    start("visible_after")
    for n in range(15):
        paint_text(fd, 90 - n)
        time.sleep(0.06)
    stop("visible_after")
    (root / "windows.json").write_text(json.dumps(windows, indent=2))
    # The XCTest runner reads the sentinel and checks all four actual tabs.
    print("\r\nVISIBLE FINISHED", flush=True)
    notify("com.davghz.t3rm.qa.tabs." + tag)


def echo(fd, root):
    original = termios.tcgetattr(fd)
    samples = []
    try:
        tty.setraw(fd)
        width, height = os.get_terminal_size(fd)
        write(fd, b"\x1b[2J" + position(1, 1) + b"ECHO READY")
        for i in range(7):
            if not select.select([fd], [], [], 15)[0]:
                raise TimeoutError("on-screen keyboard did not send a key")
            key = os.read(fd, 1)
            received = time.monotonic_ns()
            if key.lower() != b"x":
                raise ValueError(f"unexpected key {key.hex()}")
            # A colored field gives the screenshot a stable, unambiguous oracle.
            color = b"\x1b[48;2;255;0;0m" if i % 2 == 0 else b"\x1b[48;2;0;255;0m"
            fill = b"".join(position(row, 1) + b" " * max(1, width - 1) for row in range(2, height))
            write(fd, color + fill + b"\x1b[0m")
            samples.append({"key_received_mono_ns": received, "frame_written_mono_ns": time.monotonic_ns()})
        time.sleep(1)
    finally:
        (root / "keys.json").write_text(json.dumps(samples, indent=2))
        write(fd, b"\x1b[0m\x1b[2J" + position(1, 1))
        termios.tcsetattr(fd, termios.TCSANOW, original)


if __name__ == "__main__":
    mode, tag, num = sys.argv[1:]
    if not re.fullmatch("[a-z0-9_]{1,40}", tag) or num not in ["1", "2", "3", "4"]:
        raise SystemExit("invalid test identifier")
    scratch = Path(__file__).parent / ("tabs_" + tag)
    scratch.mkdir(exist_ok=True)
    terminal = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    if mode == "hidden":
        hidden(terminal, scratch, int(num))
    elif mode == "visible":
        visible(terminal, scratch, tag)
    elif mode == "echo":
        echo(terminal, scratch)
    else:
        raise SystemExit("unknown test mode")
