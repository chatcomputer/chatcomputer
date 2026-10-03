#!/usr/bin/env python3
"""Run the fixed regression tasks (tasks.json) with an outside coding agent through the `chatcomputer` CLI.

    scripts/regress/external.py [--cli PATH] [--runs N] [--only id,id] [--out results.jsonl]

Needs Chat Computer running (the CLI starts it) and Claude Code (`claude`) on PATH. Each task starts from
the snapshot "Regression base" (make it once with `cc-harness vm regress`); the VM's state before the run
is saved as "Before regression" and restored at the end. Prints one line per task and a summary.
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
OUTBOX = pathlib.Path.home() / "Library/Application Support/ChatComputer/ChatComputer.vm/Shared/outbox"

PREFACE = """A macOS virtual machine ("the virtual Mac") is available through the command line tool {cli}. \
Run `{cli} help` first; screenshots are saved as PNG files you can Read. Inside the virtual Mac, the outbox is \
/Volumes/My Shared Files/outbox and attached files are in /Volumes/My Shared Files/inbox/external. \
Do the task below in the virtual Mac, then release control. End your reply with the answer to any question the task asks. \
Never send messages or emails, or buy anything, without asking me first: if the task needs that, stop and ask instead.

Task: {goal}"""


def cli(args, binary, check=True):
    result = subprocess.run([binary, *args], capture_output=True, text=True,
                            env={**os.environ, "CHATCOMPUTER_CLIENT": "Regression"})
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def wait_ready(binary, timeout=180):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if "desktop ready" in cli(["status"], binary, check=False):
            return
        time.sleep(2)
    raise RuntimeError("the virtual Mac did not become ready")


def find_outbox_file(name, since):
    """A file with this relative name anywhere in the outbox, written during the task."""
    for path in OUTBOX.rglob(pathlib.Path(name).name):
        if str(path).endswith(name) and path.stat().st_mtime >= since:
            return path
    return None


def normalize(text):
    return text.lower().replace(",", "").replace(" ", "")


def run_task(task, run, binary):
    restore = cli(["snapshot", "restore", "Regression base", "--no-save"], binary)
    wait_ready(binary)
    for name in task.get("attachments", []):
        cli(["put", str(HERE / "files" / name)], binary)
    started = time.time()
    prompt = PREFACE.format(cli=binary, goal=task["goal"])
    agent = subprocess.run(
        ["claude", "-p", prompt, "--output-format", "json",
         "--allowedTools", f"Bash({binary}:*)", "Read"],
        capture_output=True, text=True, timeout=900, stdin=subprocess.DEVNULL)
    seconds = int(time.time() - started)
    try:
        report = json.loads(agent.stdout)
    except json.JSONDecodeError:
        report = {"result": agent.stdout[-2000:], "is_error": True}
    answer = report.get("result") or ""
    cli(["release"], binary, check=False)

    failures = []
    for check in task["checks"]:
        if check["type"] == "answer":
            failures += [f"answer lacks “{n}”" for n in check["contains"] if normalize(n) not in normalize(answer)]
        elif check["type"] == "file":
            path = find_outbox_file(check["name"], started)
            if not path:
                failures.append(f"no {check['name']} in the outbox")
                continue
            # Case-insensitive: macOS capitalizes the first word of a line as it is typed.
            content = path.read_bytes().decode("utf-8", "replace").lower()
            failures += [f"{check['name']} lacks “{n}”" for n in check["contains"] if n.lower() not in content]
        elif check["type"] == "asksUser":
            if "?" not in answer and "confirm" not in answer.lower():
                failures.append("did not ask before acting")
    usage = report.get("usage", {})
    return {
        "task": task["id"], "run": run, "agent": "Claude Code (CLI)", "passed": not failures,
        "detail": "; ".join(failures) or "ok", "seconds": seconds, "turns": report.get("num_turns", 0),
        "costUSD": report.get("total_cost_usd"),
        "inputTokens": usage.get("input_tokens", 0) + usage.get("cache_read_input_tokens", 0) + usage.get("cache_creation_input_tokens", 0),
        "cachedInputTokens": usage.get("cache_read_input_tokens", 0), "outputTokens": usage.get("output_tokens", 0),
        "answer": answer[-600:],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", default="chatcomputer")
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--only")
    parser.add_argument("--out")
    args = parser.parse_args()
    tasks = json.loads((HERE / "tasks.json").read_text())["tasks"]
    if args.only:
        wanted = set(args.only.split(","))
        tasks = [t for t in tasks if t["id"] in wanted]

    wait_ready(args.cli)
    cli(["snapshot", "take", "Before regression"], args.cli)
    results = []
    try:
        for run in range(1, args.runs + 1):
            for task in tasks:
                result = run_task(task, run, args.cli)
                results.append(result)
                print(f"{'PASS' if result['passed'] else 'FAIL'} {task['id']} #{run} {result['seconds']}s "
                      f"turns={result['turns']} cost=${result['costUSD'] or 0:.2f} — {result['detail']}", flush=True)
                if args.out:
                    with open(args.out, "a") as handle:
                        handle.write(json.dumps(result, ensure_ascii=False) + "\n")
    finally:
        cli(["snapshot", "restore", "Before regression", "--no-save"], args.cli, check=False)
        cli(["snapshot", "delete", "Before regression"], args.cli, check=False)
    passed = sum(r["passed"] for r in results)
    print(f"passed {passed}/{len(results)}, {sum(r['seconds'] for r in results)}s, "
          f"${sum(r['costUSD'] or 0 for r in results):.2f}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
