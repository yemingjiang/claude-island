#!/usr/bin/env python3
"""
Claude Island Hook
- Sends only high-level session state to ClaudeIsland.app via Unix socket
- The app tracks three user-facing states: running, waiting for input, idle
"""
import json
import os
import socket
import subprocess
import sys

SOCKET_PATH = "/tmp/claude-island.sock"


def get_tty():
    """Get the TTY of the Claude process (parent)"""
    import subprocess

    # Get parent PID (Claude process)
    ppid = os.getppid()

    # Try to get TTY from ps command for the parent process
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2
        )
        tty = result.stdout.strip()
        if tty and tty != "??" and tty != "-":
            # ps returns just "ttys001", we need "/dev/ttys001"
            if not tty.startswith("/dev/"):
                tty = "/dev/" + tty
            return tty
    except Exception:
        pass

    # Fallback: try current process stdin/stdout
    try:
        return os.ttyname(sys.stdin.fileno())
    except (OSError, AttributeError):
        pass
    try:
        return os.ttyname(sys.stdout.fileno())
    except (OSError, AttributeError):
        pass
    return None


def get_process_info(pid):
    """Return (ppid, command) for a pid."""
    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "ppid=", "-o", "comm="],
            capture_output=True,
            text=True,
            timeout=2
        )
        line = result.stdout.strip()
        if not line:
            return None, None

        parts = line.split(None, 1)
        if len(parts) != 2:
            return None, None

        return int(parts[0]), parts[1]
    except Exception:
        return None, None


def is_running_in_ghostty(pid):
    """Walk process ancestors to confirm this Claude session lives inside Ghostty."""
    current = pid
    visited = set()

    while current and current > 1 and current not in visited:
        visited.add(current)
        parent_pid, command = get_process_info(current)
        if command and "ghostty" in command.lower():
            return True
        current = parent_pid

    return False


def get_ghostty_context():
    """Get the front Ghostty window/tab identifiers when Ghostty is hosting the session."""
    script = [
        "tell application id \"com.mitchellh.ghostty\"",
        "if (count of windows) is 0 then return \"\"",
        "set currentWindow to front window",
        "return (id of currentWindow as text) & \"|\" & (id of selected tab of currentWindow as text)",
        "end tell",
    ]

    try:
        result = subprocess.run(
            ["osascript", *sum([["-e", line] for line in script], [])],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if result.returncode != 0:
            return None, None

        output = result.stdout.strip()
        if not output or "|" not in output:
            return None, None

        window_id, tab_id = output.split("|", 1)
        return window_id or None, tab_id or None
    except Exception:
        return None, None


def send_event(state):
    """Send event to app (fire and forget)."""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())
        sock.close()
    except (socket.error, OSError):
        return


def session_file_exists(session_id, cwd):
    """Check whether Claude has created a JSONL file for this session yet."""
    if not session_id or session_id == "unknown" or not cwd:
        return False

    project_dir = cwd.replace("/", "-").replace(".", "-")
    path = os.path.expanduser(f"~/.claude/projects/{project_dir}/{session_id}.jsonl")
    return os.path.exists(path)


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")
    # Get process info
    claude_pid = os.getppid()
    tty = get_tty()
    if is_running_in_ghostty(claude_pid):
        ghostty_window_id, ghostty_tab_id = get_ghostty_context()
    else:
        ghostty_window_id, ghostty_tab_id = None, None

    # Build state object
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": claude_pid,
        "tty": tty,
        "ghostty_window_id": ghostty_window_id,
        "ghostty_tab_id": ghostty_tab_id,
    }

    # Some external SDK / queued runs can trigger hooks with PPID=1 before a real
    # Claude session exists. Those events create phantom rows in the app.
    if claude_pid <= 1 and not tty and not session_file_exists(session_id, cwd):
        sys.exit(0)

    # Map only the minimal states this app now cares about.
    if event == "UserPromptSubmit":
        state["status"] = "processing"

    elif event == "Notification":
        notification_type = data.get("notification_type")
        if notification_type != "idle_prompt":
            sys.exit(0)
        state["status"] = "waiting_for_input"
        state["notification_type"] = notification_type

    elif event == "Stop":
        state["status"] = "waiting_for_input"

    elif event == "SessionStart":
        state["status"] = "idle"

    elif event == "SessionEnd":
        state["status"] = "ended"

    else:
        sys.exit(0)

    send_event(state)


if __name__ == "__main__":
    main()
