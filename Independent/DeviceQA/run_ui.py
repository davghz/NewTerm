#!/usr/bin/env python3
"""Run the signed QA test with per-case options against an isolated app."""
import argparse
import plistlib
import re
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("testrun", type=Path)
parser.add_argument("device")
parser.add_argument("target", choices=["baseline", "review"])
parser.add_argument("case", choices=["editing", "suite", "smoke", "cold_sparse", "cold_styled", "cold_burst", "history_sparse", "history_styled", "history_burst"])
parser.add_argument("run")
parser.add_argument("evidence", type=Path)
parser.add_argument("--profile", action="store_true")
args = parser.parse_args()
if not re.fullmatch("[a-z0-9_]{1,50}", args.run):
    parser.error("run tag must contain 1–50 lowercase ASCII letters, digits, or underscores")
config = plistlib.loads(args.testrun.read_bytes())
if "TestConfigurations" in config:
    targets = [t for group in config["TestConfigurations"] for t in group["TestTargets"]]
else:
    targets = [t for name, t in config.items() if not name.startswith("__")]
for test in targets:
    test.setdefault("EnvironmentVariables", {}).update(
            QA_TARGET="com.davghz.t3rm." + args.target, QA_CASE=args.case, QA_RUN=args.run, QA_PROFILE=str(int(args.profile)))
configured = args.testrun.parent / (args.run + ".xctestrun")
configured.write_bytes(plistlib.dumps(config))
args.evidence.mkdir(parents=True, exist_ok=True)
with (args.evidence / (args.run + ".xcodebuild.log")).open("w") as log:
    run = subprocess.run(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
                          "-destination", "id=" + args.device, "-parallel-testing-enabled", "NO",
                          "-resultBundlePath", str(args.evidence / (args.run + ".xcresult"))],
                         stdout=log, stderr=subprocess.STDOUT)
raise SystemExit(run.returncode)
