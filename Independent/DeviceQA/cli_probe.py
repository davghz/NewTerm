#!/usr/bin/env python3
"""Start real foreground apps in an isolated working directory for the XCUI keyboard."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import shlex

tag = sys.argv[1]
if not re.fullmatch("[a-z0-9_]{1,50}", tag):
    raise SystemExit("invalid run tag")
scratch = Path(__file__).parent
work = scratch / ("editing_" + tag)
work.mkdir(mode=0o700)
env = dict(os.environ)
for name, leaf in [("HOME", "home"), ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                   ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache")]:
    location = work / leaf
    location.mkdir()
    env[name] = str(location)
env.update(OPENCODE_DISABLE_AUTOUPDATE="1", OPENCODE_DISABLE_MODELS_FETCH="1",
           OPENCODE_DISABLE_LSP_DOWNLOAD="1")
editor = subprocess.run(["/var/jb/usr/bin/vi", "edit.txt"], env=env, cwd=work)
edited = work / "edit.txt"
content = edited.read_bytes() if edited.exists() else b""
oracle = {"vi_status": editor.returncode, "exact_saved_text": content == b"qa edit verified\n",
          "saved_bytes": len(content)}
(scratch / (tag + "_editor.json")).write_text(json.dumps(oracle) + "\n")
if not oracle["exact_saved_text"]:
    raise SystemExit("Unexpected vi output")
# Sourced by the interactive shell so it runs the installed CLI through its
# ordinary command lookup. Only this scratch directory receives CLI state.
settings = ["cd " + shlex.quote(str(work))]
for name in ["HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
             "OPENCODE_DISABLE_AUTOUPDATE", "OPENCODE_DISABLE_MODELS_FETCH", "OPENCODE_DISABLE_LSP_DOWNLOAD"]:
    settings.append("export " + name + "=" + shlex.quote(env[name]))
(work / "environment.sh").write_text("\n".join(settings) + "\n")
print("T3 editor save verified")
