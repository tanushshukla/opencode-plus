"""Linux process-control tests with disposable Python stand-ins, never real HA."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "rootfs/usr/local/bin/terminal-control.py"
spec = importlib.util.spec_from_file_location("terminal_control", SCRIPT)
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)


@unittest.skipUnless(hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"), "Linux pidfds required")
class TerminalControlTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.shell = control.process_info(os.getpid()) | {"nonce": "test-instance-nonce"}
        self.save_shell()

    def save_shell(self):
        file = self.directory / "shell.json"
        file.write_text(json.dumps(self.shell))
        file.chmod(0o600)

    def child(self, handler="sys.exit(0)"):
        # No CLI args, like the native standalone TUI. In tests only, its
        # executable inode substitutes for the pinned OpenCode executable.
        child = subprocess.Popen([sys.executable], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        def cleanup():
            if child.poll() is None:
                child.kill()
            child.wait(timeout=3)
            child.stdout.close()
        self.addCleanup(cleanup)
        child.stdin.write(
            "import signal, sys\n"
            + ("signal.signal(signal.SIGHUP, signal.SIG_DFL)\n" if handler is None else
               f"signal.signal(signal.SIGHUP, lambda *_: {handler})\n")
            + "print('ready', flush=True)\nwhile True: signal.pause()\n"
        )
        child.stdin.close()
        self.assertEqual(child.stdout.readline().strip(), "ready")
        return child

    def invoke(self, action="status", instance=None, **kwargs):
        return control.control(action, instance, directory=self.directory, binaries=[Path(sys.executable)], **kwargs)

    def test_graceful_exit_and_shell_noop(self):
        child = self.child()
        status = self.invoke()
        self.assertEqual(status["state"], "running")
        self.assertEqual(self.invoke("quit", status["instance"])["state"], "stopped")
        self.assertEqual(child.wait(timeout=3), 0)
        self.assertEqual(self.invoke()["state"], "stopped")
        self.assertEqual(self.invoke("quit", status["instance"])["state"], "stopped")

    def test_old_button_cannot_quit_replacement_instance(self):
        old = self.child()
        previous = self.invoke()
        old.terminate()
        old.wait(timeout=3)
        new = self.child()
        self.assertNotEqual(previous["instance"], self.invoke()["instance"])
        self.assertEqual(self.invoke("quit", previous["instance"])["state"], "changed")
        self.assertIsNone(new.poll())

    def test_no_signal_until_sighup_handler_installed(self):
        child = self.child(handler=None)
        status = self.invoke()
        self.assertEqual(status["state"], "starting")
        self.assertEqual(self.invoke("quit", status["instance"])["state"], "starting")
        self.assertIsNone(child.poll())

    def test_timeout_does_not_force_kill(self):
        child = self.child(handler="None")
        status = self.invoke()
        self.assertEqual(self.invoke("quit", status["instance"], timeout=25)["state"], "timeout")
        self.assertIsNone(child.poll())

    def test_stale_shell_and_wrong_binary_are_not_targets(self):
        child = self.child()
        self.assertEqual(control.control("status", directory=self.directory, binaries=[])["state"], "stopped")
        self.shell["start"] = "0"
        self.save_shell()
        self.assertEqual(self.invoke()["state"], "stopped")
        self.assertIsNone(child.poll())

    def test_other_shell_descendants_are_not_targets(self):
        # A separate service/shell is not the registered ttyd shell. No global
        # process-name lookup is allowed to discover this child.
        child = self.child()
        self.shell = control.process_info(child.pid) | {"nonce": "other-shell"}
        self.save_shell()
        self.assertEqual(self.invoke()["state"], "stopped")
        self.assertIsNone(child.poll())

    def test_permissions_and_symlinks_fail_closed(self):
        file = self.directory / "shell.json"
        file.chmod(0o644)
        with self.assertRaises(ValueError):
            self.invoke()
        file.unlink()
        file.symlink_to(self.directory / "other")
        with self.assertRaises(OSError):
            self.invoke()


if __name__ == "__main__":
    unittest.main()
