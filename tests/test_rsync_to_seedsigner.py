"""Exercise the deployment script without connecting to a device."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "docs/scripts/rsync-to-seedsigner.sh"
MOUNT = "/dev/mmcblk0p2 /mnt/data ext4 rw,relatime 0 0\n"

SSH = r'''
import os, shlex, subprocess, sys
from pathlib import Path
command = sys.argv[1]
stage = "cold-read" if command == "python3 -" else command if command in ("sync", "seedsigner restart") else "mount"
with open(os.environ["CHECK_CALLS"], "a") as calls:
    calls.write(stage + "\n")
if stage == "mount":
    command = command.replace("/proc/mounts", shlex.quote(os.environ["CHECK_MOUNTS"]))
    sys.exit(subprocess.run(["sh", "-c", command]).returncode)
if stage == "sync" and os.environ.get("CHECK_FAIL_SYNC"):
    sys.exit(1)
if stage == "cold-read" and os.environ.get("CHECK_FAIL_COLD_READ"):
    sys.exit(1)
if stage == "sync" and os.environ.get("CHECK_CORRUPT_AFTER_SYNC"):
    (Path(os.environ["CHECK_DEST"]) / "src/main.py").write_text("print('evil')\n")
'''

RSYNC = r'''
import os, shutil, sys
from pathlib import Path
dry_run = any(arg.startswith("-") and not arg.startswith("--") and "n" in arg for arg in sys.argv[1:])
with open(os.environ["CHECK_CALLS"], "a") as calls:
    calls.write("verify\n" if dry_run else "rsync\n")
if os.environ.get("CHECK_FAIL_RSYNC"):
    sys.exit(23)
source = Path(sys.argv[-2]) / "src"
destination = Path(os.environ["CHECK_DEST"]) / "src"
checksum = any(arg.startswith("-") and not arg.startswith("--") and "c" in arg for arg in sys.argv[1:])
for path in source.rglob("*"):
    if not path.is_file():
        continue
    target = destination / path.relative_to(source)
    if dry_run:
        if not target.exists() or path.read_bytes() != target.read_bytes():
            print("Different file:", path.relative_to(source))
        continue
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and not checksum:
        a, b = path.stat(), target.stat()
        if a.st_size == b.st_size and int(a.st_mtime) == int(b.st_mtime):
            continue
    shutil.copy2(path, target)
if os.environ.get("CHECK_REMOVE_CARD"):
    Path(os.environ["CHECK_MOUNTS"]).write_text("")
'''


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bigsigner sync ")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        scripts = root / "scripts"
        scripts.mkdir()
        self.script = scripts / SCRIPT.name
        shutil.copy2(SCRIPT, self.script)
        binaries = root / "bin"
        binaries.mkdir()
        for path, code in ((scripts / "ssh-seedsigner.sh", SSH), (binaries / "rsync", RSYNC)):
            path.write_text(f"#!{sys.executable}\n" + code)
            path.chmod(0o755)
        self.source = root / "checkout"
        (self.source / "src").mkdir(parents=True)
        self.source_file = self.source / "src/main.py"
        self.source_file.write_text("print('good')\n")
        self.destination = root / "device"
        self.destination.mkdir()
        self.mounts = root / "mounts"
        self.mounts.write_text(MOUNT)
        self.calls = root / "calls"
        self.env = {
            **os.environ,
            "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
            "CHECK_MOUNTS": str(self.mounts),
            "CHECK_CALLS": str(self.calls),
            "CHECK_DEST": str(self.destination),
        }

    def run_sync(self, restart=True):
        args = ["sh", str(self.script)]
        if restart:
            args.append("--restart")
        return subprocess.run(args + [str(self.source)], env=self.env, capture_output=True, text=True)

    def stages(self):
        return self.calls.read_text().splitlines()

    def test_refuses_missing_wrong_or_read_only_sd_mount(self):
        for mounts in ("", "none /mnt/data tmpfs rw 0 0\n", MOUNT.replace("rw,", "ro,"), MOUNT.replace("mmcblk0p2", "mmcblk0p1")):
            with self.subTest(mounts=mounts):
                self.mounts.write_text(mounts)
                self.calls.write_text("")
                result = self.run_sync()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("not mounted read-write", result.stderr)
                self.assertEqual(self.stages(), ["mount"])
                self.assertFalse((self.destination / "src").exists())

    def test_repairs_corruption_with_unchanged_size_and_timestamp_before_restart(self):
        target = self.destination / "src/main.py"
        target.parent.mkdir()
        target.write_text("print('evil')\n")
        shutil.copystat(self.source_file, target)
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_bytes(), self.source_file.read_bytes())
        self.assertEqual(self.stages(), ["mount", "rsync", "sync", "mount", "cold-read", "verify", "seedsigner restart"])

    def test_transfer_failure_does_not_restart(self):
        self.env["CHECK_FAIL_RSYNC"] = "1"
        self.assertEqual(self.run_sync().returncode, 23)
        self.assertEqual(self.stages(), ["mount", "rsync"])

    def test_flush_failure_does_not_restart(self):
        self.env["CHECK_FAIL_SYNC"] = "1"
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.stages(), ["mount", "rsync", "sync"])

    def test_card_removed_during_transfer_does_not_restart(self):
        self.env["CHECK_REMOVE_CARD"] = "1"
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.stages(), ["mount", "rsync", "sync", "mount"])

    def test_sync_without_restart_still_flushes_and_checks_mount(self):
        result = self.run_sync(restart=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.stages(), ["mount", "rsync", "sync", "mount", "cold-read", "verify"])

    def test_cold_read_failure_does_not_restart(self):
        self.env["CHECK_FAIL_COLD_READ"] = "1"
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.stages(), ["mount", "rsync", "sync", "mount", "cold-read"])

    def test_corruption_after_flush_does_not_restart(self):
        self.env["CHECK_CORRUPT_AFTER_SYNC"] = "1"
        result = self.run_sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("verification failed", result.stderr)
        self.assertEqual(self.stages(), ["mount", "rsync", "sync", "mount", "cold-read", "verify"])


if __name__ == "__main__":
    unittest.main()
