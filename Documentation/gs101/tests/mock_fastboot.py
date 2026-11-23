#!/usr/bin/env python3
"""Mock fastboot server for host-only protocol testing.

Speaks the fastboot protocol as specified in the AOSP README
(system/core/fastboot/README.md) and as implemented in
system/core/fastboot/fastboot_driver.cpp:

  host  -> "cmd"            (ascii, NO trailing NUL, <= 4096 bytes)
  device-> "OKAY" | "FAIL" | "DATA%08x" | "INFO..." | "TEXT..."
  host  -> <data phase>
  device-> "OKAY" | "FAIL" | "INFO..." | "TEXT..."

The server records everything it sees so tests can assert on the exact wire
traffic. It refuses any flash/erase/format command by default, so a test can
prove the client never asks for a partition write.

Run as a module: python3 -m mock_fastboot --port 0 --script <name>
"""
import argparse
import json
import socket
import struct
import threading
import time

OKAY = b"OKAY"
FAIL = b"FAIL"
DATA = b"DATA"
INFO = b"INFO"
TEXT = b"TEXT"

# TCP transport framing (system/core/fastboot/tcp.cpp):
#   handshake: 4 bytes "FB%02d" both ways, protocol version 1
#   every message: 8-byte big-endian length prefix, then payload
TCP_HANDSHAKE = b"FB01"
TCP_PROTOCOL_VERSION = 1


def tcp_encode(payload):
    """8-byte big-endian length prefix, as written by TcpTransport::Write."""
    return len(payload).to_bytes(8, "big") + payload


class TcpFramedSocket:
    """Wraps a socket with the fastboot-over-TCP framing."""

    def __init__(self, sock):
        self.sock = sock
        self._pending = b""

    def handshake(self, timeout=2.0):
        self.sock.settimeout(timeout)
        self.sock.sendall(TCP_HANDSHAKE)
        hdr = self._recv_exact(4)
        if hdr is None or not hdr.startswith(b"FB"):
            raise ConnectionError("bad TCP handshake: %r" % hdr)
        version = int(hdr[2:])
        if version < TCP_PROTOCOL_VERSION:
            raise ConnectionError("unsupported protocol version %r" % hdr)
        return hdr

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                return None
            buf += chunk
        return buf

    def read_message(self, maxlen=4096):
        """One framed message from the host (a command or data chunk)."""
        while len(self._pending) < 8:
            chunk = self.sock.recv(65536)
            if not chunk:
                return None
            self._pending += chunk
        length = int.from_bytes(self._pending[:8], "big")
        self._pending = self._pending[8:]
        if length > (64 << 20):
            raise ValueError("oversized message length %d" % length)
        while len(self._pending) < length:
            chunk = self.sock.recv(65536)
            if not chunk:
                return None
            self._pending += chunk
        out, self._pending = self._pending[:length], self._pending[length:]
        return out

    def write_message(self, payload):
        self.sock.sendall(tcp_encode(payload))


# Commands that write to the device. The mock refuses them unless explicitly
# allowed, which is how the tests prove "no flash".
WRITE_COMMANDS = ("flash", "erase", "format", "flashing", "oem", "set_active")


class MockServer:
    def __init__(self, script=None, allow_write=False, max_payload=1 << 22):
        self.script = script or {}
        self.allow_write = allow_write
        self.max_payload = max_payload
        self.log = []              # list of dicts describing the wire traffic
        self.commands = []         # every command string received
        self.downloads = []        # (requested_size, received_bytes)
        self.staged = None
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind(("127.0.0.1", 0))
        self.socket.listen(1)
        self.port = self.socket.getsockname()[1]
        self._thread = None
        self._done = threading.Event()

    # ------------------------------------------------------------------
    def start(self):
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        return self

    def stop(self):
        self._done.set()
        try:
            self.socket.close()
        except OSError:
            pass

    def wait(self, timeout=30):
        return self._done.wait(timeout)

    # ------------------------------------------------------------------
    def _recv_exact(self, conn, n):
        buf = b""
        while len(buf) < n:
            chunk = conn.recv(min(65536, n - len(buf)))
            if not chunk:
                return None
            buf += chunk
        return buf

    def _serve(self):
        try:
            conn, _ = self.socket.accept()
        except OSError:
            return
        conn.settimeout(60)
        try:
            self._session(conn)
        except Exception as exc:                      # pragma: no cover
            self.log.append({"event": "server_error", "error": repr(exc)})
        finally:
            try:
                conn.close()
            except OSError:
                pass
            self._done.set()

    def _session(self, conn):
        framer = TcpFramedSocket(conn)
        try:
            framer.handshake()
        except (OSError, ConnectionError) as exc:
            self.log.append({"event": "handshake_error", "error": repr(exc)})
            return
        self.log.append({"event": "handshake_ok"})

        while True:
            # --- command phase ---------------------------------------
            raw = framer.read_message()
            if raw is None:
                return
            self.log.append({"event": "command", "raw": raw.decode(errors="replace")})
            text = raw.decode(errors="replace")
            self.commands.append(text)
            if not self._handle(framer, text):
                return

    def _handle(self, framer, text):
        """Returns False to end the session."""
        script = self.script
        # --- scripted overrides ------------------------------------
        if text in script:
            action = script[text]
            if action == "FAIL":
                self._send(framer, FAIL + b"mock failure")
                return True
            if action == "INFO_THEN_OKAY":
                self._send(framer, INFO + b"informational message")
                self._send(framer, INFO + b"second info")
                self._send(framer, OKAY)
                return True
            if action == "TEXT_THEN_OKAY":
                self._send(framer, TEXT + b"raw text payload\0")
                self._send(framer, OKAY)
                return True
            if action == "TIMEOUT":
                time.sleep(script.get("timeout_sleep", 120))
                return True
            if action == "NO_REPLY":
                return True

        # --- default handling ---------------------------------------
        if text.startswith("getvar:"):
            name = text.split(":", 1)[1]
            if name == "max-download-size":
                # AOSP fastboot parses this as an integer byte count.
                value = self.script.get("getvar:max-download-size", "1073741824")
            else:
                value = self.script.get("getvar:" + name, "0.4")
            self._send(framer, OKAY + value.encode())
            return True
        if text == "getvar":
            self._send(framer, OKAY + b"0.4")
            return True
        if text.startswith("download:"):
            size = int(text.split(":", 1)[1], 16)
            self._send(framer, DATA + ("%08x" % size).encode())
            received = 0
            while received < size:
                chunk = framer.read_message()
                if chunk is None:
                    self.log.append({"event": "download_short",
                                     "requested": size, "received": received})
                    return False
                received += len(chunk)
            self.downloads.append((size, received))
            self.log.append({"event": "download", "requested": size,
                             "received": received})
            # Completion response for the data phase must be OKAY.
            # A script may inject INFO/TEXT packets before it.
            completion = self.script.get("__download_completion__", "OKAY")
            if completion == "INFO_THEN_OKAY":
                self._send(framer, INFO + b"informational message")
                self._send(framer, INFO + b"second info")
                self._send(framer, OKAY)
            elif completion == "TEXT_THEN_OKAY":
                self._send(framer, TEXT + b"raw text payload\0")
                self._send(framer, OKAY)
            elif completion == "FAIL":
                self._send(framer, FAIL + b"mock download failure")
            else:
                self._send(framer, OKAY)
            return True
        if text == "boot":
            self._send(framer, OKAY)
            return True
        if text in WRITE_COMMANDS or text.startswith("flash:") \
                or text.startswith("erase:") or text.startswith("format:"):
            if not self.allow_write:
                self.log.append({"event": "refused_write", "command": text})
                self._send(framer, FAIL + b"mock refuses write commands")
                return True
            self._send(framer, OKAY)
            return True
        self._send(framer, FAIL + b"unknown command")
        return True

    def _send(self, framer, payload):
        framer.write_message(payload)
        self.log.append({"event": "response", "raw": payload.decode(errors="replace")})



def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--script", default=None,
                    help="JSON file: {command: action}")
    ap.add_argument("--allow-write", action="store_true")
    ap.add_argument("--log", default=None)
    args = ap.parse_args()

    script = {}
    if args.script:
        with open(args.script) as fh:
            script = json.load(fh)

    srv = MockServer(script=script, allow_write=args.allow_write)
    if args.port:
        srv.socket.close()
        srv.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.socket.bind(("127.0.0.1", args.port))
        srv.socket.listen(1)
        srv.port = args.port
    srv.start()
    print("PORT=%d" % srv.port, flush=True)
    srv.wait()
    if args.log:
        with open(args.log, "w") as fh:
            json.dump({"log": srv.log, "commands": srv.commands,
                       "downloads": srv.downloads}, fh, indent=2)


if __name__ == "__main__":
    main()
