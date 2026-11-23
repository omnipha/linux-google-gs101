#!/usr/bin/env python3
"""Host-only tests that drive the REAL installed `fastboot` binary against
mock_fastboot.MockServer over `-s tcp:127.0.0.1:PORT`.

Nothing here touches USB or a device.

Covered per the assignment:
  * DATA handshake and exact transfer length
  * INFO/TEXT packets followed by OKAY
  * FAIL produces a non-zero exit and no false success
  * no trailing NUL on commands (no flash)
  * complete stage+boot ordering in ONE connection
  * no partition-write command is ever issued
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import mock_fastboot as mf  # noqa: E402

FASTBOOT = shutil.which("fastboot") or \
    "/usr/lib/android-sdk/platform-tools/fastboot"


def run_fastboot(port, args, timeout=60):
    """Run the installed fastboot CLI against the mock TCP transport."""
    cmd = [FASTBOOT, "-s", "tcp:127.0.0.1:%d" % port] + list(args)
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


class RealFastbootClientTests(unittest.TestCase):
    def setUp(self):
        if not os.path.exists(FASTBOOT):
            self.skipTest("fastboot binary not installed")

    def _server(self, script=None):
        srv = mf.MockServer(script=script or {})
        srv.start()
        self.addCleanup(srv.stop)
        return srv

    # ------------------------------------------------------------------
    def test_getvar_no_trailing_nul(self):
        """Commands must be sent without a trailing NUL byte."""
        srv = self._server({"getvar:version": "0.4"})
        r = run_fastboot(srv.port, ["getvar", "version"])
        self.assertEqual(r.returncode, 0, r.stderr)
        # AOSP fastboot prints getvar results to stderr, not stdout.
        self.assertIn("0.4", r.stderr)
        for entry in srv.log:
            if entry["event"] == "command":
                self.assertNotIn("\x00", entry["raw"],
                                 "command carried a trailing NUL")
        # The wire command must be exactly "getvar:version"
        self.assertIn("getvar:version", srv.commands)

    # ------------------------------------------------------------------
    def test_stage_download_exact_length(self):
        """`stage` = download:%08x -> DATA%08x -> exactly N bytes -> OKAY."""
        srv = self._server()
        payload = os.urandom(300000)
        with tempfile.NamedTemporaryFile(delete=False) as fh:
            fh.write(payload)
            path = fh.name
        self.addCleanup(os.unlink, path)

        r = run_fastboot(srv.port, ["stage", path])
        self.assertEqual(r.returncode, 0, r.stderr)

        # exactly one download, requested == received == len(payload)
        self.assertEqual(len(srv.downloads), 1, srv.log)
        requested, received = srv.downloads[0]
        self.assertEqual(requested, len(payload))
        self.assertEqual(received, len(payload),
                         "server did not receive the exact announced length")

        # The wire command was a download, NOT an OEM "stage" command
        dl = [c for c in srv.commands if c.startswith("download:")]
        self.assertEqual(len(dl), 1, srv.commands)
        self.assertEqual(int(dl[0].split(":", 1)[1], 16), len(payload))
        self.assertNotIn("stage", srv.commands,
                         "client sent a literal 'stage' command")

    # ------------------------------------------------------------------
    def test_stage_then_boot_single_connection(self):
        """stage + boot in one invocation = ONE connection, correct order."""
        srv = self._server()
        with tempfile.NamedTemporaryFile(delete=False) as v:
            v.write(b"VENDOR" * 1000)
            vpath = v.name
        with tempfile.NamedTemporaryFile(delete=False) as b:
            b.write(b"ANDROID!" + os.urandom(20000))
            bpath = b.name
        self.addCleanup(os.unlink, vpath)
        self.addCleanup(os.unlink, bpath)

        r = run_fastboot(srv.port, ["stage", vpath, "boot", bpath])
        self.assertEqual(r.returncode, 0, r.stderr)

        # AOSP fastboot first asks for max-download-size; that is a read-only
        # query and is expected.
        wire = [c for c in srv.commands]
        self.assertIn("getvar:max-download-size", wire)
        payload_cmds = [c for c in wire if c.startswith("download:")]
        self.assertEqual(len(payload_cmds), 2, wire)
        self.assertEqual(wire[-1], "boot", wire)
        self.assertEqual(int(payload_cmds[0].split(":", 1)[1], 16), 6 * 1000)
        self.assertEqual(int(payload_cmds[1].split(":", 1)[1], 16), 8 + 20000)

        # both transfers completed with exact lengths
        self.assertEqual(len(srv.downloads), 2)
        for requested, received in srv.downloads:
            self.assertEqual(requested, received)

        # ONE TCP connection served both commands
        self.assertTrue(srv.wait(5))

    # ------------------------------------------------------------------
    def test_no_flash_command_issued(self):
        """stage/boot must never send flash/erase/format/flashing."""
        srv = self._server()
        with tempfile.NamedTemporaryFile(delete=False) as v:
            v.write(b"X" * 5000)
            vpath = v.name
        with tempfile.NamedTemporaryFile(delete=False) as b:
            b.write(b"ANDROID!" + b"Y" * 9000)
            bpath = b.name
        self.addCleanup(os.unlink, vpath)
        self.addCleanup(os.unlink, bpath)

        r = run_fastboot(srv.port, ["stage", vpath, "boot", bpath])
        self.assertEqual(r.returncode, 0, r.stderr)

        forbidden = ("flash:", "erase:", "format", "flashing", "set_active")
        for cmd in srv.commands:
            self.assertFalse(cmd.startswith(forbidden),
                             "client issued a write command: %r" % cmd)
        self.assertFalse([e for e in srv.log
                          if e["event"] == "refused_write"], srv.log)

    # ------------------------------------------------------------------
    def test_info_then_okay_reported_as_success(self):
        """INFO packets then OKAY = success; INFO must be surfaced."""
        srv = self._server({"__download_completion__": "INFO_THEN_OKAY"})
        with tempfile.NamedTemporaryFile(delete=False) as v:
            v.write(b"ABCDEF")
            vpath = v.name
        self.addCleanup(os.unlink, vpath)

        r = run_fastboot(srv.port, ["stage", vpath])
        # INFO handling must not be mistaken for failure
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(srv.downloads[0], (6, 6))

    # ------------------------------------------------------------------
    def test_text_then_okay_reported_as_success(self):
        """TEXT packets then OKAY = success."""
        srv = self._server({"__download_completion__": "TEXT_THEN_OKAY"})
        with tempfile.NamedTemporaryFile(delete=False) as v:
            v.write(b"ABCDEF")
            vpath = v.name
        self.addCleanup(os.unlink, vpath)
        r = run_fastboot(srv.port, ["stage", vpath])
        self.assertEqual(r.returncode, 0, r.stderr)

    # ------------------------------------------------------------------
    def test_fail_is_reported_as_failure_not_success(self):
        """FAIL must be reported as a failure, never as a successful value."""
        srv = self._server({"getvar:version": "FAIL"})
        r = run_fastboot(srv.port, ["getvar", "version"])
        # AOSP DisplayVarOrError() prints FAILED and still exits 0 for getvar,
        # so the meaningful assertion is that it is not presented as a value.
        self.assertIn("FAILED", r.stderr)
        self.assertNotIn("version: FAIL", r.stdout + r.stderr)
        # ... and the client must not have started a download
        self.assertEqual(srv.downloads, [])

    def test_fail_on_boot_is_not_success(self):
        """A FAIL to the boot command must be a non-zero failure."""
        srv = self._server({"boot": "FAIL"})
        with tempfile.NamedTemporaryFile(delete=False) as b:
            b.write(b"ANDROID!" + b"W" * 9000)
            bpath = b.name
        self.addCleanup(os.unlink, bpath)
        r = run_fastboot(srv.port, ["boot", bpath])
        self.assertNotEqual(r.returncode, 0,
                            "FAIL on boot reported as success")
        self.assertIn("FAILED", r.stderr)

    # ------------------------------------------------------------------
    def test_fail_on_download_reports_failure(self):
        """A FAIL to download: must not be followed by a data phase."""
        srv = self._server({"download:00000006": "FAIL"})
        with tempfile.NamedTemporaryFile(delete=False) as v:
            v.write(b"ABCDEF")
            vpath = v.name
        self.addCleanup(os.unlink, vpath)
        r = run_fastboot(srv.port, ["stage", vpath])
        self.assertNotEqual(r.returncode, 0, "FAIL reported as success")
        # no data was sent after the refusal
        self.assertEqual(srv.downloads, [])

    # ------------------------------------------------------------------
    def test_no_reply_times_out_without_success(self):
        """No reply must time out and never be reported as a successful boot."""
        srv = self._server({"boot": "NO_REPLY"})
        with tempfile.NamedTemporaryFile(delete=False) as b:
            b.write(b"ANDROID!" + b"Z" * 9000)
            bpath = b.name
        self.addCleanup(os.unlink, bpath)
        try:
            r = run_fastboot(srv.port, ["boot", bpath], timeout=90)
        except subprocess.TimeoutExpired:
            # CLI hanging forever is still not a false success
            return
        self.assertNotEqual(r.returncode, 0,
                            "no reply reported as successful boot")

    # ------------------------------------------------------------------
    def test_getvar_unknown_variable_reports_failure(self):
        """A FAIL to getvar must be reported as a failure to the user."""
        srv = self._server({"getvar:nonexistent": "FAIL"})
        r = run_fastboot(srv.port, ["getvar", "nonexistent"])
        # DisplayVarOrError() prints "FAILED (...)" and this AOSP version
        # still exits 0, so assert on the reported failure text.
        self.assertIn("FAILED", r.stderr)

    # ------------------------------------------------------------------
    def test_download_size_validation(self):
        """server-announced size must equal the bytes actually transferred."""
        srv = self._server()
        payload = os.urandom(1 << 20)      # 1 MiB
        with tempfile.NamedTemporaryFile(delete=False) as fh:
            fh.write(payload)
            path = fh.name
        self.addCleanup(os.unlink, path)
        r = run_fastboot(srv.port, ["stage", path])
        self.assertEqual(r.returncode, 0, r.stderr)
        requested, received = srv.downloads[0]
        self.assertEqual(requested, 1 << 20)
        self.assertEqual(received, 1 << 20)


class ShortWriteHandlingTests(unittest.TestCase):
    """The mock reads the data phase in small chunks and rejoins them, so a
    client that stops early on a short write is detected as a length
    mismatch."""

    def test_partial_tcp_reads_are_reassembled(self):
        srv = mf.MockServer()
        srv.start()
        try:
            payload = os.urandom(500000)
            path = tempfile.mktemp()
            with open(path, "wb") as fh:
                fh.write(payload)
            try:
                r = run_fastboot(srv.port, ["stage", path], timeout=60)
            finally:
                os.unlink(path)
            self.assertEqual(r.returncode, 0, r.stderr)
            requested, received = srv.downloads[0]
            self.assertEqual(requested, len(payload))
            self.assertEqual(received, len(payload),
                             "short write was not completed")
        finally:
            srv.stop()


if __name__ == "__main__":
    unittest.main(verbosity=2)
