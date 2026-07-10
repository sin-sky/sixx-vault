#!/usr/bin/env python3
"""slither-check.py — baseline-diff gate for Slither.

Phase-1 defense-in-depth (ADR-006). The committed baseline
(`audit/slither-baseline.json`) is the machine-readable allowlist of already-triaged
findings (human canon: threads/sixx-vault/SLITHER_TRIAGE.md). Any High/Medium finding in
the current run whose stable id is NOT in the baseline is a NEW issue and fails the gate.

Usage:
    slither-check.py --current <cur.json> --baseline <base.json> [--out <new.txt>]

Exit 0 = no new High/Medium. Exit 1 = new High/Medium found (details on stdout / --out).
Exit 2 = usage / parse error.
"""
import argparse
import json
import sys


GATE_IMPACTS = {"High", "Medium"}


def load_detectors(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        print(f"ERROR: cannot read {path}: {e}", file=sys.stderr)
        sys.exit(2)
    return data.get("results", {}).get("detectors", []) or []


def key(det):
    # Slither's `id` is a sha256 over the finding; stable across identical code.
    # Fall back to (check + first element source) if a run predates ids.
    if det.get("id"):
        return det["id"]
    els = det.get("elements") or []
    src = ""
    if els:
        sm = els[0].get("source_mapping", {})
        src = f"{sm.get('filename_relative','')}:{sm.get('lines',[])}"
    return f"{det.get('check','')}|{src}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--current", required=True)
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--out")
    args = ap.parse_args()

    cur = load_detectors(args.current)
    base_ids = {key(d) for d in load_detectors(args.baseline)}

    new_gate = []
    for d in cur:
        if d.get("impact") in GATE_IMPACTS and key(d) not in base_ids:
            new_gate.append(d)

    lines = []
    if new_gate:
        lines.append(f"NEW High/Medium Slither findings (not in baseline): {len(new_gate)}")
        for d in new_gate:
            desc = (d.get("description") or "").strip().splitlines()
            head = desc[0] if desc else ""
            lines.append(f"  [{d.get('impact')}/{d.get('confidence')}] {d.get('check')}: {head}")
    else:
        lines.append("No new High/Medium Slither findings vs baseline.")

    report = "\n".join(lines)
    print(report)
    if args.out:
        with open(args.out, "w") as f:
            f.write(report + "\n")

    sys.exit(1 if new_gate else 0)


if __name__ == "__main__":
    main()
