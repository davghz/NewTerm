#!/usr/bin/env python3
"""Summarize Instruments renderer intervals and screenshot-confirmed PTY echoes."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import statistics
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser()
parser.add_argument("evidence", type=Path)
parser.add_argument("tag")
args = parser.parse_args()
root = args.evidence
prefix = args.tag
trace = ET.parse(root / f"{prefix}_signposts.xml").getroot()
defs = {item.get("id"): item for item in trace.iter() if item.get("id")}
toc = ET.parse(root / f"{prefix}_tabs.toc.xml")
start = datetime.fromisoformat(toc.findtext(".//start-date")).timestamp()
windows = json.loads((root / f"{prefix}_windows.json").read_text())


def field(row, key):
    item = row.find(key)
    if item is None:
        return None
    if item.get("ref"):
        item = defs[item.get("ref")]
    return item.text


for interval in windows.values():
    interval.update(LayoutRows=0, DrawRows=0)
for row in trace.findall(".//row"):
    marker = field(row, "signpost-name")
    if marker not in ["LayoutRows", "DrawRows"] or field(row, "event-type") != "Begin":
        continue
    timestamp = start + int(field(row, "event-time")) / 1e9
    for interval in windows.values():
        if interval["start_unix"] <= timestamp <= interval["end_unix"]:
            interval[marker] += 1

attachments = root / (prefix + "-attachments")
manifest = json.loads((attachments / "manifest.json").read_text())
file = next(item["exportedFileName"] for suite in manifest for item in suite["attachments"]
            if item["suggestedHumanReadableName"].startswith("Keyboard tap and composed"))
touches = json.loads((attachments / file).read_text())
keys = json.loads((root / (prefix + "_keys.json")).read_text())
if len(touches) != 7 or len(keys) != 7:
    parser.error("incomplete keyboard samples")

def milliseconds(t):
    return round(t / 1e6, 3)

bounds = [milliseconds(t["confirmed_screenshot_mono_ns"] - t["tap_start_mono_ns"]) for t in touches]
receipt = [milliseconds(t["confirmed_screenshot_mono_ns"] - k["key_received_mono_ns"]) for t, k in zip(touches, keys)]
print(json.dumps({
    "renderer_intervals": windows,
    "observed_keyboard_taps": len(touches),
    "tap_call_to_confirming_screenshot_ms": bounds,
    "median_tap_call_to_confirming_screenshot_ms": statistics.median(bounds),
    "pty_key_receipt_to_confirming_screenshot_ms": receipt,
    "median_pty_key_receipt_to_confirming_screenshot_ms": statistics.median(receipt),
    "interpretation": "Upper bounds include synchronous XCTest event delivery and screenshot capture; the screenshot pixels confirmed the expected color."
}, indent=2))
