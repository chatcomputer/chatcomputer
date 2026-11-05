"""Read actual guest readiness, never a bundled-version hint in a mismatch message."""
import re


def ready_guest_version(status):
    lines = status.splitlines()
    states = [line for line in lines if line.startswith('Virtual Mac:')]
    agents = [line for line in lines if line.startswith('Agent in the virtual Mac:')]
    if states != ['Virtual Mac: running, desktop ready'] or len(agents) != 1:
        return None
    # A mismatch appends "(this app brings VERSION; ...)". Match the entire
    # actual-agent line so the hint cannot stand in for the running version.
    match = re.fullmatch(r'Agent in the virtual Mac: ([^()\r\n]+ \([0-9.]+\))', agents[0])
    return match.group(1) if match else None
