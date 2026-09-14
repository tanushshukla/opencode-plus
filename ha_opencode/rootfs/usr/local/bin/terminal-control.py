#!/usr/bin/env python3
"""Quit only the standalone TUI beneath the registered ttyd/tmux shell.

OpenCode v1.18.29 packages/tui/src/app.tsx handles SIGHUP by destroying the
renderer, the same path as app.exit. cli/cmd/tui.ts then shuts down its worker.
Recheck this contract when changing the stable runtime pin. Never escalate to a
hard kill. pidfds prevent PID reuse between validation, signaling and waiting.
"""

import hashlib
import json
import os
from pathlib import Path
import select
import signal
import stat
import sys

DIRECTORY = Path("/run/opencode-terminal")
PACKAGE = Path("/usr/local/lib/node_modules/opencode-ai")
BINARIES = [PACKAGE / "bin/opencode.exe", PACKAGE / "bin/.opencode"] + [
    PACKAGE / "node_modules" / name / "bin/opencode"
    for name in ("opencode-linux-x64", "opencode-linux-x64-baseline", "opencode-linux-arm64")
]


def process_info(pid):
    # comm can contain spaces and parentheses; fields after its final ')' start
    # at field 3. starttime (field 22) survives exec, unlike the command name.
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    return {"pid": pid, "state": fields[0], "parent": int(fields[1]), "start": fields[19],
            "group": int(fields[2]), "tty": int(fields[4]), "foreground": int(fields[5])}


def private_directory(directory):
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError("Unsafe terminal state directory")


def register(directory=DIRECTORY):
    directory.mkdir(mode=0o700, exist_ok=True)
    private_directory(directory)
    parent = process_info(os.getppid())
    parent["nonce"] = os.urandom(32).hex()
    temporary = directory / f"shell.{os.getpid()}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(parent, stream)
        os.replace(temporary, directory / "shell.json")
    finally:
        temporary.unlink(missing_ok=True)


def read_shell(directory):
    private_directory(directory)
    fd = os.open(directory / "shell.json", os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077 or info.st_nlink != 1 or info.st_size > 4096:
            raise ValueError("Unsafe terminal state file")
        shell = json.load(stream)
    if not isinstance(shell.get("pid"), int) or shell["pid"] < 2:
        raise ValueError("Invalid terminal shell")
    current = process_info(shell["pid"])
    if current["start"] != shell["start"] or current["state"] == "Z":
        return None
    return shell


def children(pid):
    return [int(value) for value in Path(f"/proc/{pid}/task/{pid}/children").read_text().split()]


def same_executable(pid, binaries):
    executable = os.stat(f"/proc/{pid}/exe")
    for binary in binaries:
        try:
            if os.path.samestat(executable, binary.stat()):
                return True
        except FileNotFoundError:
            pass
    return False


def target(directory=DIRECTORY, binaries=BINARIES):
    """Return (identity, pidfd) for one standalone TUI, never serve/run/attach."""
    try:
        shell = read_shell(directory)
        if not shell:
            return None
        candidates = []
        for pid in children(shell["pid"]):
            candidates.append((pid, shell["pid"]))
            # The npm Node launcher may sit between bash and the native TUI.
            argv = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")[:-1]
            if len(argv) == 2 and Path(os.fsdecode(argv[1])).resolve() == (PACKAGE / "bin/opencode").resolve():
                candidates.extend((child, pid) for child in children(pid))
        for pid, parent in candidates:
            fd = os.pidfd_open(pid)
            keep = False
            try:
                info = process_info(pid)
                argv = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")[:-1]
                if info["parent"] != parent or info["state"] == "Z" or len(argv) != 1 or not same_executable(pid, binaries):
                    continue
                if info["tty"] and info["group"] != info["foreground"]:
                    continue
                # Revalidate the root after opening the pidfd. The file records
                # the wrapper/shell, not an arbitrary PID received over HTTP.
                if process_info(shell["pid"])["start"] != shell["start"]:
                    continue
                if parent != shell["pid"] and process_info(parent)["parent"] != shell["pid"]:
                    continue
                identity = hashlib.sha256(f'{shell["nonce"]}:{pid}:{info["start"]}'.encode()).hexdigest()
                caught = next(line.split()[1] for line in Path(f"/proc/{pid}/status").read_text().splitlines() if line.startswith("SigCgt:"))
                ready = bool(int(caught, 16) & (1 << (signal.SIGHUP - 1)))
                keep = True
                return ({"state": "running" if ready else "starting", "instance": identity}, fd)
            finally:
                if not keep:
                    os.close(fd)
    except (FileNotFoundError, ProcessLookupError):
        return None
    return None


def control(action, expected=None, directory=DIRECTORY, binaries=BINARIES, timeout=10000):
    found = target(directory, binaries)
    if found is None:
        return {"state": "stopped", "message": "No managed standalone OpenCode is running. The shell is unchanged."}
    status, fd = found
    try:
        if action == "status":
            return status
        if status["instance"] != expected:
            return {"state": "changed", "message": "The terminal instance changed. Please try again."}
        if status["state"] != "running":
            return {"state": "starting", "message": "OpenCode is not ready for graceful exit. Try again after it starts."}
        poll = select.poll()
        poll.register(fd, select.POLLIN)
        try:
            signal.pidfd_send_signal(fd, signal.SIGHUP)
        except ProcessLookupError:
            return {"state": "stopped", "message": "OpenCode has exited. The terminal returns to the shell."}
        if not poll.poll(timeout):
            return {"state": "timeout", "message": "OpenCode has not exited yet. No force-kill was attempted."}
        return {"state": "stopped", "message": "OpenCode has exited. The terminal returns to the shell."}
    finally:
        os.close(fd)


def main():
    if sys.argv[1:] == ["register"]:
        register()
        return
    if sys.argv[1:] == ["status"]:
        result = control("status")
    elif len(sys.argv) == 3 and sys.argv[1] == "quit" and len(sys.argv[2]) == 64 and all(c in "0123456789abcdef" for c in sys.argv[2]):
        result = control("quit", sys.argv[2])
    else:
        raise ValueError("Invalid terminal control operation")
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print(json.dumps({"state": "unavailable", "message": "Terminal control is unavailable; use OpenCode's normal exit command."}))
        sys.exit(1)
