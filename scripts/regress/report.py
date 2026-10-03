#!/usr/bin/env python3
"""Summarizes regression results (JSONL from `cc-harness vm regress --out` or external.py --out).

    scripts/regress/report.py results.jsonl [more.jsonl …] [--baseline old.jsonl …]

Per agent and task: passes/runs, median turns, seconds and input tokens. With --baseline, each task also shows
the change against the baseline runs (same agent and task), so a prompt or driver change can be judged on
several runs rather than one.
"""
import argparse
import json
import statistics
from collections import defaultdict


def load(paths):
    rows = []
    for path in paths:
        with open(path) as handle:
            rows += [json.loads(line) for line in handle if line.strip()]
    return rows


def summarize(rows):
    groups = defaultdict(list)
    for row in rows:
        groups[(row["agent"], row["task"])].append(row)
    summary = {}
    for key, runs in groups.items():
        summary[key] = {
            "runs": len(runs),
            "passed": sum(r["passed"] for r in runs),
            "turns": statistics.median(r["turns"] for r in runs),
            "seconds": statistics.median(r["seconds"] for r in runs),
            "input": statistics.median(r.get("inputTokens", 0) for r in runs),
            "failures": [r["detail"] for r in runs if not r["passed"]],
        }
    return summary


def delta(now, before, key, unit=""):
    if before is None:
        return ""
    change = now[key] - before[key]
    if before[key]:
        return f" ({change:+.0f}{unit}, {change * 100 / before[key]:+.0f}%)"
    return f" ({change:+.0f}{unit})"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("results", nargs="+")
    parser.add_argument("--baseline", nargs="*", default=[])
    args = parser.parse_args()
    now = summarize(load(args.results))
    base = summarize(load(args.baseline)) if args.baseline else {}

    for agent in sorted({a for a, _ in now}):
        keys = sorted(k for k in now if k[0] == agent)
        passed = sum(now[k]["passed"] for k in keys)
        runs = sum(now[k]["runs"] for k in keys)
        print(f"\n## {agent}: {passed}/{runs} runs passed ({passed * 100 // max(runs, 1)}%)\n")
        print("| Task | Passed | Median turns | Median seconds | Median input tokens |")
        print("|---|---|---|---|---|")
        for key in keys:
            s, b = now[key], base.get(key)
            pass_text = f"{s['passed']}/{s['runs']}" + (f" (was {b['passed']}/{b['runs']})" if b else "")
            print(f"| {key[1]} | {pass_text} | {s['turns']:.0f}{delta(s, b, 'turns')} | {s['seconds']:.0f}{delta(s, b, 'seconds', 's')} "
                  f"| {s['input'] / 1000:.0f}k |")
        failures = [(k[1], f) for k in keys for f in now[k]["failures"]]
        if failures:
            print("\nFailures:")
            for task, detail in failures:
                print(f"- {task}: {detail}")


if __name__ == "__main__":
    main()
