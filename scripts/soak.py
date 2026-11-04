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
import math
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
    if os.environ.get("CC_DATA_DIR"):
        env += ["--env", "CC_DATA_DIR=" + os.environ["CC_DATA_DIR"]]
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


TASKS_DIR = os.path.join(data_dir(), "Tasks")


def task_ids():
    try:
        return set(os.listdir(TASKS_DIR))
    except OSError:
        return set()


def read_task(task_id):
    """Read this exact submitted task; an earlier completed task cannot satisfy a wait."""
    if not task_id or os.path.basename(task_id) != task_id:
        return {"phase": "unknown"}
    try:
        with open(os.path.join(TASKS_DIR, task_id, "task.json")) as handle:
            task = json.load(handle)
        if task.get("id") != task_id:
            return {"phase": "unknown"}
        phase = task.get("phase", {})
        name = next(iter(phase)) if isinstance(phase, dict) and phase else str(phase)
        return {"taskID": task_id, "goal": task.get("goal"), "phase": name,
                "modelID": task.get("modelID"), "inputTokens": task.get("inputTokens", 0)}
    except (OSError, ValueError, TypeError, AttributeError):
        return {"phase": "unknown"}


def wait_new_task(goal, previous_ids, limit=60):
    deadline = time.monotonic() + limit
    while time.monotonic() < deadline:
        for task_id in task_ids() - previous_ids:
            task = read_task(task_id)
            if task.get("goal") == goal:
                return task_id
        time.sleep(1)
    return None


def wait_task(task_id, limit=900):
    """Only this task's persisted completion plus actual model usage counts."""
    start = time.monotonic()
    while time.monotonic() - start < limit:
        task = read_task(task_id)
        phase = task["phase"]
        if phase == "completed":
            return round(time.monotonic() - start) if task.get("inputTokens", 0) > 0 and task.get("modelID") else None
        if phase in ("failed", "cancelled", "waitingForUser", "takenOver"):
            return None
        time.sleep(2)
    return None


def task_evidence(task_id):
    task = read_task(task_id)
    return {key: value for key, value in task.items() if key != "goal"}


def response_succeeded(reply, prefix):
    return not reply.get('isError') and reply.get('text', '').startswith(prefix)


def qualified(rows, required_seconds):
    """A finished loop is not proof that lifecycle recovery actually happened."""
    done = rows[-1] if rows else {}
    tasks = [r for r in rows if r.get("event") in ("task", "quit-mid-task")]
    return bool(tasks) and done.get("event") == "done" and done.get("t", 0) >= required_seconds and not any(
        r.get("crashes", 0) or r.get("ok") is False for r in rows
    ) and all(r.get("phase") == "completed" and r.get("inputTokens", 0) > 0 and r.get("modelID")
              and r.get("taskID") and r.get("seconds") is not None for r in tasks) and any(
        r.get("event") == "quit-mid-task" and r.get("wasBusy") and r.get("phaseAtQuit") == "paused"
        and r.get("quitOK") and r.get("relaunchOK")
        for r in rows
    ) and any(r.get("event") == "snapshot" and r.get("took") and r.get("restored") and r.get("deleted") and r.get("ready")
              for r in rows) and any(r.get("event") == "relaunch" and r.get("quitOK") and r.get("launchOK")
                                     for r in rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--hours", type=float, default=24)
    parser.add_argument("--log", default="soak.jsonl")
    args = parser.parse_args()
    if not math.isfinite(args.hours) or args.hours <= 0:
        parser.error('--hours must be finite and greater than zero')
    if not os.environ.get('CC_DATA_DIR'):
        parser.error('set CC_DATA_DIR to an isolated test data folder')
    app = os.path.abspath(args.app)
    started = time.time()
    end = started + args.hours * 3600
    log = open(args.log, "a")
    rows = []

    def record(event, **fields):
        pid = app_pid(app)
        line = {"t": round(time.time() - started), "event": event, "rssMB": rss_mb(pid) if pid else None,
                "crashes": len(crash_reports(started)), **fields}
        log.write(json.dumps(line) + "\n")
        log.flush()
        rows.append(line)
        print(json.dumps(line), flush=True)

    n = 0
    while time.time() < end:
        n += 1
        if not app_pid(app):
            ok = launch(app)
            record("launch", ok=ok)
            if not ok:
                record("done", tasks=n - 1, ok=False)
                log.close()
                return 1
        goal = random.choice(TASKS)
        previous_ids = task_ids()
        submitted = request("dev_ui", action="submit", text=goal)
        task_id = None if submitted.get("isError") else wait_new_task(goal, previous_ids)
        if task_id is None:
            record("task-start-failed", task=goal, ok=False)
            record("done", tasks=n - 1, ok=False)
            log.close()
            return 1
        if n % 3 == 0:
            time.sleep(random.uniform(1, 3))
            busy = agent_busy() and read_task(task_id)["phase"] == "running"
            if busy:
                quit_ok = quit_app(app)
                phase_at_quit = read_task(task_id)["phase"] if quit_ok else "unknown"
                # Never launch another process against a VM whose owner did not stop.
                relaunch_ok = quit_ok and launch(app, cont=True)
                seconds = wait_task(task_id) if relaunch_ok else None
                record("quit-mid-task", task=goal, wasBusy=True, phaseAtQuit=phase_at_quit, quitOK=quit_ok, relaunchOK=relaunch_ok,
                       seconds=seconds, ok=seconds is not None and quit_ok and relaunch_ok, **task_evidence(task_id))
            else:
                seconds = wait_task(task_id)
                record("task", task=goal, midTaskRequested=True, seconds=seconds,
                       ok=seconds is not None, **task_evidence(task_id))
        else:
            seconds = wait_task(task_id)
            record("task", task=goal, seconds=seconds, ok=seconds is not None, **task_evidence(task_id))
        if seconds is None:
            # Preserve the failure; normal suspension must finish before any relaunch.
            quit_app(app)
            record("done", tasks=n, ok=False)
            log.close()
            return 1
        if n % 5 == 0:
            t0 = time.time()
            taken = request("snapshot_take", name="Soak")
            took_ok = response_succeeded(taken, 'Saved snapshot')
            restored = request("snapshot_restore", snapshot="Soak", save_current=False) if took_ok else {"isError": True}
            restored_ok = response_succeeded(restored, 'Restored')
            deleted = request("snapshot_delete", snapshot="Soak") if restored_ok else {"isError": True}
            ready = launch(app)  # waits for the desktop again
            deleted_ok = response_succeeded(deleted, 'Deleted snapshot')
            ok = took_ok and restored_ok and deleted_ok and ready
            record("snapshot", seconds=round(time.time() - t0), took=took_ok,
                   restored=restored_ok, deleted=deleted_ok, ready=ready, ok=ok)
            if not ok:
                record("done", tasks=n, ok=False)
                log.close()
                return 1
        if n % 10 == 0:
            q = quit_app(app)
            l = q and launch(app)
            record("relaunch", quitOK=q, launchOK=l, ok=q and l)
            if not (q and l):
                record("done", tasks=n, ok=False)
                log.close()
                return 1
    record("done", tasks=n)
    ok = qualified(rows, args.hours * 3600)
    record("qualification", ok=ok)
    log.close()
    return 0 if ok else 1


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
    verdict = next((r.get('ok') for r in reversed(rows) if r.get('event') == 'qualification'), None)
    print('qualification: ' + ('PASS' if verdict is True else 'FAIL' if verdict is False else 'not recorded (legacy log)'))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--summary":
        summary(sys.argv[2])
    else:
        sys.exit(main())
