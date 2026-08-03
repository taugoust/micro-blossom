#!/usr/bin/env python3
"""Binary beat bridge from CoyoteProcessBeatLink to an active xdb simulation."""

from __future__ import annotations

import argparse
import json
import os
import struct
import subprocess
import sys
from dataclasses import dataclass

BEAT_BYTES = 64
CONTINUATION_BYTES = 48
FULL_KEEP = (1 << BEAT_BYTES) - 1
CONTINUATION_KEEP = (1 << CONTINUATION_BYTES) - 1
QSHELL_MAGIC = 0x32485351


def valid_bytes(keep: int) -> int:
    if keep == FULL_KEEP:
        return BEAT_BYTES
    count = 0
    while keep & 1:
        count += 1
        keep >>= 1
    if keep != 0 or count == 0:
        raise ValueError("keep must be one non-empty contiguous low-lane mask")
    return count


@dataclass
class Beat:
    data: bytes
    keep: int
    last: bool


class XdbBeatBridge:
    def __init__(self, xdb: str, timeout_ms: int) -> None:
        self.xdb = xdb
        self.timeout_seconds = max(timeout_ms / 1000.0, 0.001)
        address_slot = os.getpid() & 0xFFFF
        self.tx_addr = 0x1000_0000 + address_slot * 0x1000
        self.rx_addr = self.tx_addr + 0x0800_0000
        self.tx_first: bytes | None = None
        self.rx_second: Beat | None = None
        self._run("mem", "map", "host", hex(self.rx_addr), str(2 * BEAT_BYTES))

    def close(self) -> None:
        for address in (self.tx_addr, self.rx_addr):
            try:
                self._run("mem", "unmap", "host", hex(address))
            except RuntimeError:
                pass

    def _run(self, *arguments: str) -> dict[str, object]:
        command = [self.xdb, "sim", *arguments]
        result = subprocess.run(command, check=False, capture_output=True, text=True)
        if result.returncode != 0:
            message = result.stderr.strip() or result.stdout.strip()
            raise RuntimeError(f"{' '.join(command)} failed: {message}")
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError(f"xdb returned malformed JSON: {result.stdout!r}") from error
        if not isinstance(value, dict):
            raise RuntimeError("xdb returned a non-object result")
        return value

    def write_beat(self, beat: Beat) -> None:
        count = valid_bytes(beat.keep)
        if self.tx_first is None:
            if count != BEAT_BYTES or beat.last:
                raise ValueError("first QShell beat must be full and non-final")
            self.tx_first = beat.data
            return
        if count != CONTINUATION_BYTES or not beat.last:
            raise ValueError("MBQ1 command continuation must be 48 bytes and final")

        payload = self.tx_first + beat.data[:CONTINUATION_BYTES]
        self.tx_first = None
        self._run("clear-completed")
        self._run("mem", "write", "host", hex(self.tx_addr), "--hex", payload.hex())
        self._run(
            "invoke",
            "local-read",
            "--addr",
            hex(self.tx_addr),
            "--len",
            str(BEAT_BYTES),
            "--no-last",
        )
        self._run(
            "invoke",
            "local-read",
            "--addr",
            hex(self.tx_addr + BEAT_BYTES),
            "--len",
            str(CONTINUATION_BYTES),
        )
        self._run(
            "completed",
            "local-read",
            "--count",
            "1",
            "--timeout",
            str(self.timeout_seconds),
        )

    def read_beat(self) -> Beat:
        if self.rx_second is not None:
            result = self.rx_second
            self.rx_second = None
            return result

        self._run("clear-completed")
        self._run(
            "invoke",
            "local-write",
            "--addr",
            hex(self.rx_addr),
            "--len",
            str(BEAT_BYTES),
            "--no-last",
        )
        self._run(
            "invoke",
            "local-write",
            "--addr",
            hex(self.rx_addr + BEAT_BYTES),
            "--len",
            str(CONTINUATION_BYTES),
        )
        self._run(
            "completed",
            "local-write",
            "--count",
            "1",
            "--timeout",
            str(self.timeout_seconds),
        )
        first = self._read_memory(self.rx_addr, BEAT_BYTES)
        continuation = self._read_memory(self.rx_addr + BEAT_BYTES, CONTINUATION_BYTES)
        if struct.unpack_from("<I", first, 0)[0] != QSHELL_MAGIC or first[4] != 2:
            raise RuntimeError("expected a QShell ABI-2 response")
        payload_bytes = struct.unpack_from("<I", first, 12)[0]
        if payload_bytes != BEAT_BYTES:
            raise RuntimeError("expected one fixed-size MBQ1 response payload")
        self.rx_second = Beat(
            data=continuation + bytes(BEAT_BYTES - CONTINUATION_BYTES),
            keep=CONTINUATION_KEEP,
            last=True,
        )
        return Beat(data=first, keep=FULL_KEEP, last=False)

    def _read_memory(self, address: int, size: int) -> bytes:
        result = self._run("mem", "read", "host", hex(address), str(size))
        data_hex = result.get("data_hex")
        if not isinstance(data_hex, str):
            raise RuntimeError("xdb memory response omitted data_hex")
        data = bytes.fromhex(data_hex)
        if len(data) != size:
            raise RuntimeError("xdb memory response has the wrong length")
        return data


def write_ok() -> None:
    sys.stdout.buffer.write(b"\x00")
    sys.stdout.buffer.flush()


def write_error(message: str) -> None:
    encoded = message.encode()
    sys.stdout.buffer.write(b"\x01" + struct.pack("<I", len(encoded)) + encoded)
    sys.stdout.buffer.flush()


def run_protocol(bridge: XdbBeatBridge) -> int:
    stream = sys.stdin.buffer
    try:
        while request := stream.read(1):
            try:
                if request == b"\x01":
                    header = stream.read(9)
                    data = stream.read(BEAT_BYTES)
                    if len(header) != 9 or len(data) != BEAT_BYTES:
                        raise ValueError("truncated write request")
                    last = header[0] != 0
                    keep = struct.unpack_from("<Q", header, 1)[0]
                    bridge.write_beat(Beat(data=data, keep=keep, last=last))
                    write_ok()
                elif request == b"\x02":
                    beat = bridge.read_beat()
                    write_ok()
                    sys.stdout.buffer.write(
                        bytes([int(beat.last)]) + struct.pack("<Q", beat.keep) + beat.data
                    )
                    sys.stdout.buffer.flush()
                else:
                    raise ValueError("unknown bridge request")
            except Exception as error:  # noqa: BLE001 - protocol must report backend errors
                write_error(str(error))
    finally:
        bridge.close()
    return 0


def self_test() -> int:
    assert valid_bytes(FULL_KEEP) == 64
    assert valid_bytes(CONTINUATION_KEEP) == 48
    try:
        valid_bytes(0x5)
    except ValueError:
        pass
    else:
        raise AssertionError("non-contiguous keep was accepted")
    print("MICROBLOSSOM_QSHELL_XDB_BRIDGE_PASS")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--xdb", required=False)
    parser.add_argument("--vfpga", type=int, default=0)
    parser.add_argument("--timeout-ms", type=int, default=10_000)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.xdb is None:
        parser.error("--xdb is required outside self-test")
    if args.vfpga != 0:
        parser.error("packaged simulation currently exposes only vFPGA 0")
    bridge = XdbBeatBridge(args.xdb, args.timeout_ms)
    return run_protocol(bridge)


if __name__ == "__main__":
    raise SystemExit(main())
