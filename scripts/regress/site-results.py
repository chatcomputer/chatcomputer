#!/usr/bin/env python3
"""Writes the website's results matrix (results.json) from regression results.

    scripts/regress/site-results.py OUT.json "Label=results.jsonl[,more.jsonl]" ["Label=…" …]

Each label becomes one row group on chatcomputer.github.io: every task, every run, passed or not, plus the pass
count and the median turns and seconds.
"""
import json
import statistics
import sys


def main():
    out, groups = sys.argv[1], sys.argv[2:]
    tasks = [t["id"] for t in json.load(open(__file__.replace("site-results.py", "tasks.json")))["tasks"]]
    models = []
    for group in groups:
        label, files = group.split("=", 1)
        rows = [json.loads(line) for path in files.split(",") for line in open(path) if line.strip()]
        by_task = {}
        for row in sorted(rows, key=lambda r: r.get("run", 1)):
            by_task.setdefault(row["task"], []).append(bool(row["passed"]))
        models.append({
            "label": label,
            "passed": sum(r["passed"] for r in rows),
            "total": len(rows),
            "medianTurns": statistics.median(r["turns"] for r in rows),
            "medianSeconds": statistics.median(r["seconds"] for r in rows),
            "tasks": {t: by_task.get(t, []) for t in tasks},
        })
    json.dump({"tasks": tasks, "models": models}, open(out, "w"), indent=1)
    for m in models:
        print(f"{m['label']}: {m['passed']}/{m['total']}, median {m['medianTurns']} turns, {m['medianSeconds']} s")


if __name__ == "__main__":
    main()
