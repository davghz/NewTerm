#!/usr/bin/env python3
"""Produce a CSV from completed physical runs with matching workloads."""
import argparse
import csv
import json
from pathlib import Path
import sys


parser = argparse.ArgumentParser()
parser.add_argument("evidence", type=Path)
parser.add_argument("baseline")
parser.add_argument("candidate")
args = parser.parse_args()
writer = csv.writer(sys.stdout)
writer.writerow(["case", "frames_per_app", "columns", "rows", "baseline_median_ms", "candidate_median_ms",
                 "median_speedup", "baseline_p95_ms", "candidate_p95_ms", "baseline_cpu_pct", "candidate_cpu_pct",
                 "baseline_peak_thermal", "candidate_peak_thermal", "baseline_peak_footprint_MiB", "candidate_peak_footprint_MiB"])
for state in ["cold", "history"]:
    for paint in ["sparse", "styled", "burst"]:
        case = f"{state}_{paint}"
        runs = [json.loads((args.evidence / f"{tag}_{case}.json").read_text()) for tag in [args.baseline, args.candidate]]
        for run in runs:
            if "error" in run or run.get("validated_frames") != 41:
                parser.error(f"invalid sample set in {run['run']}")
        old, new = runs
        if old["workload_grid"] != new["workload_grid"] or old["prefill_rows"] != new["prefill_rows"]:
            parser.error(f"unmatched workload in {case}")
        writer.writerow([case, 41, *old["workload_grid"], *[round(r["median_ms"], 3) for r in runs],
                         round(old["median_ms"] / new["median_ms"], 2), *[round(r["p95_ms"], 3) for r in runs],
                         *[round(r["app_cpu_percent_one_core"], 2) for r in runs],
                         *[max(s["thermal_state"] for s in r["resource_trace"]) for r in runs],
                         *[round(max(s["footprint_bytes"] for s in r["resource_trace"]) / 1024**2, 2) for r in runs]])
