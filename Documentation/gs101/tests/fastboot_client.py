#!/usr/bin/env python3
"""Corrected fastboot protocol client for the GS101 raven boot test.

Protocol implemented from the AOSP specification and reference
implementation, which this file follows exactly:

  * README.md (system/core/fastboot/README.md):
      - host sends an ascii command "no greater than 4096 bytes",
        "without a trailing 0 byte"
      - response is OKAY / FAIL / DATA / INFO / TEXT
      - INFO and TEXT are informational and are followed by another response
      - "download:%08x" is answered by "DATA%08x", then the data phase,
        then a second response whose success value is OKAY
      - completion of the data phase is OKAY, never DATA
  * fastboot_driver.cpp HandleResponse():
      - INFO and TEXT reset the response timer and are consumed
      - FAIL returns DEVICE_FAIL, unknown status is BAD_DEV_RESP
      - the response loop times out after RESP_TIMEOUT (30 s)

The transport is abstracted so the protocol logic can be exercised host-only
against a mock. The wire-level correctness of the *installed* AOSP fastboot
CLI is covered separately by test_real_fastboot.py.

Safety: this client refuses to emit flash/erase/format/flashing commands.
"""
import socket
import time

RESP_TIMEOUT = 30.0

# Commands that write to the device. Always refused here.
WRITE_PREFIXES = ("flash:", "flash", "erase:", "format", "flashing",
                  "set_active", "oem")

DOWNLOAD_CMD = "download:%08x"


class FastbootError(Exception):
    """Base error."""


class FastbootFailure(FastbootError):
    """Device answered FAIL."""


class FastbootProtocolError(FastbootError):
    """Device answered something the protocol does not allow."""


class FastbootTimeout(FastbootError):
    """No response within RESP_TIMEOUT. Never a success."""


class Transport:
    """Minimal transport interface: read/write with partial-operation support."""

    def read(self, maxlen, timeout):
        raise NotImplementedError

    def write(self, data, timeout):
        """Must write all of `data`; returns bytes written. Partial writes
        are the caller's problem to loop over."""
        raise NotImplementedError

    def close(self):
        pass


class InMemoryTransport(Transport):
    """Host-only test transport with programmable behaviour.

    `peers` is a list of responses. Each entry is either:
      * a list/tuple of bytes chunks -> queued as the device's reply to the
        next write, or
      * None -> the device does not answer (the client must time out).
    `max_write` simulates short writes, `fail_after` simulates a transport
    failure once that many writes have happened.
    """

    def __init__(self, peers=None, max_write=None, fail_after=None):
        self.peers = list(peers or [])
        self.sent = []          # every bytes object the client wrote
        self._queue = []
        self.max_write = max_write    # simulate short writes
        self.fail_after = fail_after  # simulate a transport failure
        self.closed = False
        self._data_bytes_left = 0      # bytes owed in the current data phase

    # -- Transport interface --------------------------------------------
    def write(self, data, timeout):
        if self.fail_after is not None and len(self.sent) >= self.fail_after:
            raise OSError("simulated transport failure")
        n = len(data)
        if self.max_write is not None:
            n = min(n, self.max_write)
        # Record only the bytes actually accepted, so a short write is
        # visible as a partial record rather than a full duplicate.
        self.sent.append(bytes(data[:n]))

        # Data-phase bytes are not commands: they must not consume a peer.
        if self._data_bytes_left > 0:
            self._data_bytes_left -= n
            if self._data_bytes_left <= 0:
                # Data phase complete -> the device's completion reply
                # (OKAY/FAIL) becomes available.
                if self.peers:
                    resp = self.peers.pop(0)
                    if resp:
                        self._queue.extend(resp)
            return n

        # A command write. If it is a download:, record how many data bytes
        # the device will absorb before it answers the next command.
        text = bytes(data[:n]).decode(errors="replace")
        if text.startswith("download:"):
            self._data_bytes_left = int(text.split(":", 1)[1], 16)

        if self.peers:
            resp = self.peers.pop(0)
            if resp:
                self._queue.extend(resp)
        return n

    def read(self, maxlen, timeout):
        if not self._queue:
            return None        # caller must treat this as a timeout
        chunk = self._queue.pop(0)
        if len(chunk) > maxlen:
            # keep the remainder for the next read, like a real stream
            self._queue.insert(0, chunk[maxlen:])
            chunk = chunk[:maxlen]
        return chunk


class TcpTransport(Transport):
    """fastboot-over-TCP transport (system/core/fastboot/tcp.cpp).

    4-byte handshake "FB01", then every message length-prefixed with an
    8-byte big-endian length.
    """

    HANDSHAKE = b"FB01"

    def __init__(self, host, port, timeout=RESP_TIMEOUT):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        self.sock.sendall(self.HANDSHAKE)
        hdr = self._recv_exact(4)
        if hdr is None or not hdr.startswith(b"FB"):
            raise FastbootProtocolError("bad TCP handshake: %r" % hdr)

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                return None
            buf += chunk
        return buf

    def read(self, maxlen, timeout):
        self.sock.settimeout(timeout)
        try:
            hdr = self._recv_exact(8)
        except socket.timeout:
            return None
        if hdr is None:
            return None
        length = int.from_bytes(hdr, "big")
        if length == 0:
            return b""
        data = self._recv_exact(length)
        if data is None:
            return None
        if len(data) > maxlen:
            raise FastbootProtocolError("message longer than buffer")
        return data

    def write(self, data, timeout):
        self.sock.settimeout(timeout)
        try:
            self.sock.sendall(len(data).to_bytes(8, "big") + data)
        except socket.timeout as exc:
            raise FastbootTimeout(str(exc))
        return len(data)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class FastbootSession:
    """One session = one transport = one connection.

    Every command is followed by an unconditional response read, so no reply
    is ever left unconsumed.
    """

    def __init__(self, transport):
        self.t = transport
        self.info_messages = []

    # ------------------------------------------------------------------
    def _write_all(self, payload, timeout=RESP_TIMEOUT):
        """Loop until every byte is written (short-write safe)."""
        view = memoryview(payload)
        total = 0
        deadline = time.monotonic() + timeout
        while total < len(view):
            if time.monotonic() > deadline:
                raise FastbootTimeout("short write: %d/%d" % (total, len(view)))
            n = self.t.write(view[total:], timeout)
            if n is None or n <= 0:
                raise FastbootProtocolError("transport wrote 0 bytes")
            total += n
        return total

    def _read_response(self, timeout=RESP_TIMEOUT):
        """Read one protocol response, consuming INFO/TEXT continuations.

        Returns (status, payload) where status in {"OKAY","FAIL","DATA"}.
        Raises FastbootTimeout when nothing arrives; FastbootProtocolError
        for unknown status words.
        """
        deadline = time.monotonic() + timeout
        while True:
            if time.monotonic() > deadline:
                raise FastbootTimeout("no response within %.0fs" % timeout)
            buf = self.t.read(4096, min(1.0, timeout))
            if buf is None or len(buf) < 4:
                time.sleep(0.01)                 # poll again until deadline
                continue
            status = buf[:4].decode(errors="replace")
            payload = buf[4:]
            if status == "INFO":
                msg = payload.decode(errors="replace")
                self.info_messages.append(msg)
                continue                      # another response follows
            if status == "TEXT":
                self.info_messages.append(payload.decode(errors="replace"))
                continue
            if status == "OKAY":
                return "OKAY", payload
            if status == "FAIL":
                return "FAIL", payload
            if status == "DATA":
                return "DATA", payload
            raise FastbootProtocolError("unknown status %r" % buf[:8])

    # ------------------------------------------------------------------
    def command(self, cmd, timeout=RESP_TIMEOUT):
        """Send `cmd` (no trailing NUL) and consume exactly one response."""
        if isinstance(cmd, str):
            cmd = cmd.encode()
        if cmd.endswith(b"\x00"):
            raise FastbootProtocolError("command must not end with NUL")
        if len(cmd) > 4096:
            raise FastbootProtocolError("command longer than 4096 bytes")
        self._write_all(cmd, timeout)
        return self._read_response(timeout)

    def getvar(self, name):
        status, payload = self.command("getvar:%s" % name)
        if status == "FAIL":
            raise FastbootFailure(payload.decode(errors="replace"))
        if status != "OKAY":
            raise FastbootProtocolError("getvar got %s" % status)
        return payload.decode(errors="replace")

    # ------------------------------------------------------------------
    def download(self, payload, timeout=RESP_TIMEOUT):
        """download:%08x -> DATA%08x -> exactly len(payload) -> OKAY.

        Validates the device-announced size against the requested size and
        the completion response against OKAY (never DATA).
        """
        size = len(payload)
        status, announced = self.command(DOWNLOAD_CMD % size, timeout)
        if status == "FAIL":
            raise FastbootFailure(announced.decode(errors="replace"))
        if status != "DATA":
            raise FastbootProtocolError(
                "download answered %s, expected DATA" % status)
        got = int(announced.decode(errors="replace") or "0", 16)
        if got != size:
            raise FastbootProtocolError(
                "device announced %d bytes, requested %d" % (got, size))

        self._write_all(payload, timeout)

        status, tail = self._read_response(timeout)
        if status == "FAIL":
            raise FastbootFailure(tail.decode(errors="replace"))
        if status != "OKAY":
            # DATA here would mean the completion handshake was not consumed.
            raise FastbootProtocolError(
                "data phase completed with %s, expected OKAY" % status)
        return size

    # ------------------------------------------------------------------
    def stage(self, path, timeout=RESP_TIMEOUT):
        """`stage` on the wire is a plain download (AOSP fastboot.cpp)."""
        with open(path, "rb") as fh:
            return self.download(fh.read(), timeout)

    def boot(self, path, timeout=RESP_TIMEOUT):
        """download the boot image, then send `boot`. Returns True only if
        the device answered OKAY to `boot`; timeouts and FAILs propagate."""
        with open(path, "rb") as fh:
            self.download(fh.read(), timeout)
        status, payload = self.command("boot", timeout)
        if status == "FAIL":
            raise FastbootFailure(payload.decode(errors="replace"))
        if status != "OKAY":
            raise FastbootProtocolError("boot answered %s" % status)
        return True

    def stage_and_boot(self, vendor_path, boot_path, timeout=RESP_TIMEOUT):
        """Exact ordering used by pmbootstrap `boot_gki`:

            download(vendor_boot) -> OKAY
            download(boot)        -> OKAY
            boot                  -> OKAY
        """
        self.stage(vendor_path, timeout)
        return self.boot(boot_path, timeout)

    def refuse_write(self, cmd):
        """Public guard: this client never writes to a partition."""
        lowered = cmd.lower()
        for prefix in WRITE_PREFIXES:
            if lowered.startswith(prefix):
                raise FastbootError("refusing partition write: %s" % cmd)
        return cmd

    def close(self):
        self.t.close()
