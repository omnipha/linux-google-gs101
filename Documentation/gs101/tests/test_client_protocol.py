#!/usr/bin/env python3
"""Host-only protocol tests for fastboot_client.FastbootSession.

No USB, no device, no network. Everything runs against the in-memory
transport in fastboot_client.py and the mock server in mock_fastboot.py.

Covered:
  * DATA handshake and exact transfer length
  * short writes are looped over until the full payload is sent
  * INFO/TEXT packets are consumed and do not end the command
  * FAIL is raised as a failure and never reported as success
  * a timeout is raised as a timeout and never reported as success
  * no trailing NUL on any command
  * no partition-write command is ever sent
  * complete stage+boot ordering
  * mismatched announced size is rejected
  * a DATA (not OKAY) data-phase completion is rejected
"""
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import fastboot_client as fc  # noqa: E402
import mock_fastboot as mf  # noqa: E402


def ok(payload=b""):
    return [b"OKAY" + payload]


def data(size):
    return [b"DATA%08x" % size]


class ProtocolTests(unittest.TestCase):
    def _session(self, peers, **kw):
        t = fc.InMemoryTransport(peers=peers, **kw)
        return fc.FastbootSession(t), t

    # ------------------------------------------------------------------
    def test_command_has_no_trailing_nul(self):
        s, t = self._session([ok(b"0.4")])
        s.command("getvar:version")
        self.assertEqual(t.sent, [b"getvar:version"])
        for msg in t.sent:
            self.assertFalse(msg.endswith(b"\x00"),
                             "command carried a trailing NUL: %r" % msg)

    def test_command_rejects_nul_terminated_input(self):
        s, t = self._session([ok()])
        with self.assertRaises(fc.FastbootProtocolError):
            s.command("getvar:version\x00")
        self.assertEqual(t.sent, [])

    # ------------------------------------------------------------------
    def test_download_data_handshake_and_exact_length(self):
        payload = b"X" * 4096
        s, t = self._session([data(len(payload)), ok()])
        n = s.download(payload)
        self.assertEqual(n, len(payload))
        # command, then payload, and no trailing NUL anywhere
        self.assertEqual(t.sent[0], b"download:%08x" % len(payload))
        self.assertEqual(t.sent[1], payload)
        self.assertEqual(b"".join(t.sent), b"download:%08x" % len(payload) + payload)

    def test_download_rejects_wrong_announced_size(self):
        s, t = self._session([data(99), ok()])
        with self.assertRaises(fc.FastbootProtocolError) as ctx:
            s.download(b"X" * 10)
        self.assertIn("announced", str(ctx.exception))

    def test_download_rejects_data_as_completion(self):
        """The data phase must complete with OKAY, never DATA."""
        s, t = self._session([data(4), data(4)])
        with self.assertRaises(fc.FastbootProtocolError) as ctx:
            s.download(b"ABCD")
        self.assertIn("OKAY", str(ctx.exception))

    def test_download_fail_is_a_failure(self):
        s, t = self._session([[b"FAILno space"]])
        with self.assertRaises(fc.FastbootFailure):
            s.download(b"X" * 10)
        # no payload was sent after the refusal
        self.assertEqual(len(t.sent), 1)

    def test_short_writes_are_completed(self):
        """A transport that accepts only 100 bytes per write must still
        transfer the whole payload."""
        payload = os.urandom(1000)
        s, t = self._session([data(len(payload)), ok()], max_write=100)
        s.download(payload)
        # Everything written is the command followed by the payload; the
        # transport chopped both into 100-byte chunks.
        joined = b"".join(t.sent)
        cmd = b"download:%08x" % len(payload)
        self.assertTrue(joined.startswith(cmd))
        self.assertEqual(joined[len(cmd):], payload)
        self.assertGreater(len(t.sent), 3,
                           "expected the payload to be split into chunks")

    def test_transport_failure_is_not_success(self):
        s, t = self._session([data(10), ok()], fail_after=1)
        with self.assertRaises(OSError):
            s.download(b"X" * 10)

    # ------------------------------------------------------------------
    def test_info_packets_are_consumed(self):
        s, t = self._session([[b"INFOworking", b"INFOstill working", b"OKAY"]])
        status, payload = s.command("flash:something")
        self.assertEqual(status, "OKAY")
        self.assertEqual(len(s.info_messages), 2)
        self.assertIn("working", s.info_messages[0])

    def test_text_packets_are_consumed(self):
        s, t = self._session([[b"TEXTsome text\x00", b"OKAY"]])
        status, payload = s.command("boot")
        self.assertEqual(status, "OKAY")
        self.assertEqual(len(s.info_messages), 1)

    def test_info_then_fail_is_a_failure(self):
        s, t = self._session([[b"INFOprogress", b"FAILbroken"]])
        status, payload = s.command("flash:x")
        self.assertEqual(status, "FAIL")
        self.assertEqual(payload, b"broken")

    # ------------------------------------------------------------------
    def test_timeout_is_not_success(self):
        # no response queued -> the read returns None until the deadline
        s, t = self._session([None])
        with self.assertRaises(fc.FastbootTimeout):
            s.command("boot", timeout=0.3)
        self.assertEqual(t.sent, [b"boot"])

    def test_unknown_status_is_a_protocol_error(self):
        s, t = self._session([[b"WTF??"]])
        with self.assertRaises(fc.FastbootProtocolError):
            s.command("boot", timeout=0.5)

    # ------------------------------------------------------------------
    def test_getvar_failure(self):
        s, t = self._session([[b"FAILunknown variable"]])
        with self.assertRaises(fc.FastbootFailure):
            s.getvar("nonexistent")

    def test_getvar_success(self):
        s, t = self._session([ok(b"0.4")])
        self.assertEqual(s.getvar("version"), "0.4")

    # ------------------------------------------------------------------
    def test_refuses_write_commands(self):
        s, t = self._session([])
        for cmd in ("flash:boot", "erase:cache", "format:ext4",
                    "flashing lock", "set_active a", "oem something"):
            with self.assertRaises(fc.FastbootError):
                s.refuse_write(cmd)
        self.assertEqual(t.sent, [])

    def test_stage_and_boot_ordering(self):
        vb = tempfile.NamedTemporaryFile(delete=False)
        vb.write(b"VENDOR" * 100)
        vb.close()
        bb = tempfile.NamedTemporaryFile(delete=False)
        bb.write(b"ANDROID!" + b"B" * 200)
        bb.close()
        self.addCleanup(os.unlink, vb.name)
        self.addCleanup(os.unlink, bb.name)

        s, t = self._session([data(600), ok(),          # stage: download
                              data(208), ok(),          # boot: download
                              ok()])                    # boot command
        self.assertTrue(s.stage_and_boot(vb.name, bb.name))

        self.assertEqual(t.sent[0], b"download:%08x" % 600)
        self.assertEqual(t.sent[1], b"VENDOR" * 100)
        self.assertEqual(t.sent[2], b"download:%08x" % 208)
        self.assertEqual(t.sent[3], b"ANDROID!" + b"B" * 200)
        self.assertEqual(t.sent[4], b"boot")
        self.assertEqual(len(t.sent), 5)

    # ------------------------------------------------------------------
    def test_stage_uses_a_plain_download_not_a_stage_command(self):
        """AOSP: `fastboot stage` is a download; there is no "stage" wire
        command. The client must not invent one."""
        vb = tempfile.NamedTemporaryFile(delete=False)
        vb.write(b"Z" * 32)
        vb.close()
        self.addCleanup(os.unlink, vb.name)
        s, t = self._session([data(32), ok()])
        s.stage(vb.name)
        self.assertNotIn(b"stage", b" ".join(t.sent))
        self.assertEqual(t.sent[0], b"download:00000020")

    # ------------------------------------------------------------------
    def test_against_the_mock_server_over_tcp(self):
        """End-to-end against mock_fastboot over the real TCP framing."""
        srv = mf.MockServer()
        srv.start()
        self.addCleanup(srv.stop)
        payload = os.urandom(50000)
        vb = tempfile.NamedTemporaryFile(delete=False)
        vb.write(payload)
        vb.close()
        self.addCleanup(os.unlink, vb.name)

        t = fc.TcpTransport("127.0.0.1", srv.port)
        s = fc.FastbootSession(t)
        n = s.stage(vb.name, timeout=20)
        self.assertEqual(n, len(payload))
        self.assertEqual(srv.downloads, [(len(payload), len(payload))])
        s.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
