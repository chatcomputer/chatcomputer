#!/usr/bin/env python3
"""Long-running reliability test of the app itself (STATUS.md 1.0, item 6).

    scripts/soak.py --app path/to/ChatComputer.app [--hours 24] [--log soak.jsonl]
    scripts/soak.py --summary soak.jsonl

Loops until the time is up: launches the app if it is not running, submits a task to the built-in agent (through the
development socket, so the app must accept CC_DEV_WINDOW_SHOTS), and waits for it to finish. Mixed in:
- every 3rd task, quits the app mid-task (SIGTERM, as at logout), relaunches it with CC_DEV_CONTINUE=1 and checks the
  task carries on;
- every 5th task, takes a snapshot and restores it;
- every 10th task, quits and relaunches between tasks.
Each step is a JSON line in the log: what happened, how long it took, the app's memory, and any crash report.
The app uses its normal VM and model settings; run it on a test machine.
"""
import argparse
import glob
import json
import os
import random
import signal
import socket
import subprocess
import sys
import time

def data_dir():
    """Chat Computer's data folder: CC_DATA_DIR, the one chosen in setup, or ~/.chatcomputer."""
    if os.environ.get("CC_DATA_DIR"):
        return os.path.expanduser(os.environ["CC_DATA_DIR"])
    chosen = subprocess.run(["defaults", "read", "app.chatcomputer.ChatComputer", "DataDirectory"],
                            capture_output=True, text=True).stdout.strip()
    return chosen or os.path.expanduser("~/.chatcomputer")


SOCKET = os.path.join(data_dir(), "control.sock")
TASKS = [
    "Use the Calculator app to compute 4321 × 8765 and tell me the result.",
    "Open TextEdit, write the line 'soak test' in a new document and save it as soak.txt.",
    "What version of macOS is the virtual Mac running? Check in About This Mac.",
    "In the outbox, create a folder named Notes with a plain-text file todo.txt containing: water the plants.",
    "Open Safari, go to en.wikipedia.org and tell me the first word of today's featured article title.",
    "Is dark mode on in the virtual Mac? Check System Settings › Appearance.",
]


def request(command, **arguments):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(120)
    s.connect(SOCKET)
    s.sendall((json.dumps({"command": command, "arguments": arguments, "client": "soak"}) + "\n").encode())
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    s.close()
    return json.loads(data)


def status():
    try:
        return request("status").get("text", "")
    except OSError:
        return ""


def app_pid(app):
    out = subprocess.run(["pgrep", "-f", os.path.join(app, "Contents/MacOS/ChatComputer")], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def rss_mb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return int(out) // 1024 if out else None


def crash_reports(since):
    paths = glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/ChatComputer*.ips"))
    return [p for p in paths if os.path.getmtime(p) > since]


def launch(app, cont=False):
    env = ["--env", "CC_DEV_WINDOW_SHOTS=1"] + (["--env", "CC_DEV_CONTINUE=1"] if cont else [])
    subprocess.run(["open"] + env + [app], check=True)
    deadline = time.time() + 300
    while time.time() < deadline:
        if "desktop ready" in status():
            return True
        time.sleep(3)
    return False


def quit_app(app):
    pid = app_pid(app)
    if not pid:
        return True
    os.kill(pid, signal.SIGTERM)
    deadline = time.time() + 180
    while time.time() < deadline:
        if not app_pid(app):
            return True
        time.sleep(1)
    return False


def agent_busy():
    return "own agent (working on a task)" in status()


def wait_task(limit=900):
    """Waits for the built-in agent to start and then finish; returns seconds, or None on timeout."""
    start = time.time()
    while time.time() - start < 60 and not agent_busy():
        time.sleep(2)
    while time.time() - start < limit:
        if not agent_busy():
            return round(time.time() - start)
        time.sleep(5)
    return None


TASKS_DIR = os.path.join(data_dir(), "Tasks")


def last_task():
    """Phase and token counts of the most recently started task."""
    try:
        folders = sorted((os.path.join(TASKS_DIR, f) for f in os.listdir(TASKS_DIR)), key=os.path.getmtime)
        task = json.load(open(os.path.join(folders[-1], "task.json")))
        phase = task.get("phase", {})
        name = next(iter(phase)) if isinstance(phase, dict) and phase else str(phase)
        return {"phase": name, "inputTokens": task.get("inputTokens", 0)}
    except (OSError, ValueError, IndexError):
        return {"phase": "unknown"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--hours", type=float, default=24)
    parser.add_argument("--log", default="soak.jsonl")
    args = parser.parse_args()
    app = os.path.abspath(args.app)
    started = time.time()
    end = started + args.hours * 3600
    log = open(args.log, "a")

    def record(event, **fields):
        pid = app_pid(app)
        line = {"t": round(time.time() - started), "event": event, "rssMB": rss_mb(pid) if pid else None,
                "crashes": len(crash_reports(started)), **fields}
        log.write(json.dumps(line) + "\n")
        log.flush()
        print(json.dumps(line), flush=True)

    n = 0
    while time.time() < end:
        n += 1
        if not app_pid(app):
            ok = launch(app)
            record("launch", ok=ok)
            if not ok:
                quit_app(app)
                continue
        goal = random.choice(TASKS)
        request("dev_ui", action="submit", text=goal)
        if n % 3 == 0:
            time.sleep(random.uniform(20, 60))
            busy = agent_busy()
            quit_ok = quit_app(app)
            relaunch_ok = launch(app, cont=True)
            seconds = wait_task()
            record("quit-mid-task", task=goal, wasBusy=busy, quitOK=quit_ok, relaunchOK=relaunch_ok, seconds=seconds, **last_task())
        else:
            seconds = wait_task()
            record("task", task=goal, seconds=seconds, **last_task())
        if seconds is None:
            # Stuck: stop the task the hard way and start fresh.
            quit_app(app)
            continue
        if n % 5 == 0:
            t0 = time.time()
            taken = request("snapshot_take", name="Soak").get("text", "")
            restored = request("snapshot_restore", snapshot="Soak", save_current=False).get("text", "")
            request("snapshot_delete", snapshot="Soak")
            ready = launch(app)  # waits for the desktop again
            record("snapshot", seconds=round(time.time() - t0), took="Saved" in taken, restored="Restored" in restored, ready=ready)
        if n % 10 == 0:
            q, l = quit_app(app), launch(app)
            record("relaunch", quitOK=q, launchOK=l)
    record("done", tasks=n)


def summary(path):
    rows = [json.loads(line) for line in open(path) if line.strip()]
    tasks = [r for r in rows if r["event"] in ("task", "quit-mid-task")]
    done = [r for r in tasks if r.get("phase") == "completed"]
    rss = [r["rssMB"] for r in rows if r.get("rssMB")]
    print(f"{len(tasks)} tasks, {len(done)} completed; quits mid-task {sum(r['event'] == 'quit-mid-task' for r in rows)}, "
          f"snapshot rounds {sum(r['event'] == 'snapshot' for r in rows)}, relaunches {sum(r['event'] == 'relaunch' for r in rows)}; "
          f"crashes {rows[-1]['crashes'] if rows else 0}; app memory {min(rss) if rss else 0}–{max(rss) if rss else 0} MB")
    for r in tasks:
        if r.get("phase") != "completed":
            print(f"  not completed at t={r['t']}s: {r.get('phase')} — {r['task'][:60]}")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--summary":
        summary(sys.argv[2])
    else:
        main()
