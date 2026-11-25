#!/usr/bin/env python3
"""Exercise the app's zsh login hook with a real PTY and isolated dotfiles."""
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import time

startup = Path(__file__).resolve().parents[1] / "ShellStartup"
for custom in (False, True):
    with tempfile.TemporaryDirectory() as home:
        if custom:
            (Path(home) / ".zshrc").write_text("PROMPT='custom%%> '\n")
        env = dict(os.environ, HOME=home, ZDOTDIR=str(startup), T3RM_HAD_ZDOTDIR="1",
                   T3RM_ORIGINAL_ZDOTDIR=home, PROMPT_EOL_MARK="", TERM="xterm-256color",
                   PROMPT="%m%::%~ %n%# ", HISTFILE="/dev/null")
        master, slave = pty.openpty()
        proc = subprocess.Popen(["/bin/zsh", "-dil"], env=env, cwd=home,
                                stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        try:
            def until(expected):
                data = bytearray()
                end = time.monotonic() + 5
                while expected not in data and time.monotonic() < end:
                    if select.select([master], [], [], 0.2)[0]:
                        data.extend(os.read(master, 32768))
                if expected not in data:
                    raise AssertionError(f"Missing {expected!r} in zsh PTY")
                return data

            prompt = until(b"custom%> " if custom else b" > ")
            if not custom:
                assert b"%" not in prompt, "Default prompt still contains a percent sign"
            os.write(master, b"printf 'literal%s\\n' '100%'\r")
            until(b"literal100%")
        finally:
            os.close(master)
            if proc.poll() is None:
                proc.send_signal(signal.SIGKILL)
            proc.wait()
print("Stock prompt, user-configured prompt, and literal percent output passed.")
