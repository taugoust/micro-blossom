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

import qshell_abi_generated as qshell_abi

BEAT_BYTES = qshell_abi.BEAT_BYTES
HEADER_BYTES = qshell_abi.HEADER_BYTES
PACKET_STORAGE_BYTES = 4096
MAX_PACKET_BEATS = PACKET_STORAGE_BYTES // BEAT_BYTES
DEFAULT_RESPONSE_BYTES = HEADER_BYTES + 64
FULL_KEEP = (1 << BEAT_BYTES) - 1


@dataclass(frozen=True)
class PacketShape:
    size: int
    beats: int
    final_bytes: int


@dataclass(frozen=True)
class Beat:
    data: bytes
    keep: int
    last: bool


def low_keep(size: int) -> int:
    if not 0 < size <= BEAT_BYTES:
        raise ValueError("beat size must be in 1..64 bytes")
    return FULL_KEEP if size == BEAT_BYTES else (1 << size) - 1


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


def shape_for_bytes(size: int) -> PacketShape:
    if not HEADER_BYTES < size <= PACKET_STORAGE_BYTES:
        raise ValueError("QShell packet exceeds the 4096-byte provider store")
    beats = (size + BEAT_BYTES - 1) // BEAT_BYTES
    if not 0 < beats <= MAX_PACKET_BEATS:
        raise ValueError("QShell packet exceeds the 64-beat provider bound")
    return PacketShape(
        size=size,
        beats=beats,
        final_bytes=size - (beats - 1) * BEAT_BYTES,
    )


def shape_from_header(first: bytes, first_valid_bytes: int) -> PacketShape:
    if len(first) != BEAT_BYTES or first_valid_bytes < HEADER_BYTES:
        raise ValueError("truncated current-QSH2 header")
    if (
        struct.unpack_from("<I", first, qshell_abi.OFFSET_MAGIC)[0]
        != qshell_abi.MAGIC
        or first[qshell_abi.OFFSET_ABI_VERSION] != qshell_abi.VERSION
        or struct.unpack_from("<H", first, qshell_abi.OFFSET_HEADER_BYTES)[0]
        != HEADER_BYTES
        or struct.unpack_from("<H", first, qshell_abi.OFFSET_RESERVED)[0] != 0
    ):
        raise ValueError("invalid current-QSH2 header")
    payload_bytes = struct.unpack_from(
        "<I", first, qshell_abi.OFFSET_PAYLOAD_BYTES
    )[0]
    if payload_bytes > PACKET_STORAGE_BYTES - HEADER_BYTES:
        raise ValueError("QShell payload exceeds the provider packet store")
    return shape_for_bytes(HEADER_BYTES + payload_bytes)


class PacketAssembler:
    """Validate one whole QSH2 record and isolate malformed continuations."""

    def __init__(self) -> None:
        self.poisoned = False
        self._reset_record()

    def _reset_record(self) -> None:
        self.shape: PacketShape | None = None
        self.beats = 0
        self.record = bytearray()
        self.discard_error: str | None = None

    def _poison(self, message: str) -> None:
        self._reset_record()
        self.poisoned = True
        raise RuntimeError(f"{message}; reconnect required")

    def _reject(self, message: str, last: bool) -> bytes | None:
        self.shape = None
        self.record.clear()
        if last:
            self._reset_record()
            raise ValueError(message)
        if self.beats >= MAX_PACKET_BEATS:
            self._poison("malformed QShell request exceeded bounded discard")
        self.discard_error = message
        return None

    def push(self, beat: Beat) -> bytes | None:
        if self.poisoned:
            raise RuntimeError("QShell request assembler is poisoned; reconnect required")
        if len(beat.data) != BEAT_BYTES:
            self._poison("bridge beat does not contain 64 data bytes")

        self.beats += 1
        if self.beats > MAX_PACKET_BEATS:
            self._poison("QShell request exceeded the 64-beat provider bound")
        if self.discard_error is not None:
            if beat.last:
                message = self.discard_error
                self._reset_record()
                raise ValueError(message)
            if self.beats == MAX_PACKET_BEATS:
                self._poison("malformed QShell request has no bounded tlast")
            return None

        try:
            count = valid_bytes(beat.keep)
            if self.shape is None:
                self.shape = shape_from_header(beat.data, count)
        except ValueError as error:
            return self._reject(str(error), beat.last)

        assert self.shape is not None
        if self.beats > self.shape.beats:
            return self._reject("QShell request exceeds its declared length", beat.last)
        final = self.beats == self.shape.beats
        expected_bytes = self.shape.final_bytes if final else BEAT_BYTES
        if count != expected_bytes:
            return self._reject("QShell request beat boundary mismatch", beat.last)
        if beat.last != final:
            if final:
                self._poison("QShell request omitted its declared tlast")
            return self._reject("QShell request beat boundary mismatch", beat.last)

        self.record.extend(beat.data[:count])
        if not final:
            return None
        if len(self.record) != self.shape.size:
            self._poison("QShell request ended before its declared length")
        result = bytes(self.record)
        self._reset_record()
        return result


def accepted_response_shape(first: bytes, normal: PacketShape) -> PacketShape:
    """Accept only the configured fixed-length correction response."""

    actual = shape_from_header(first, BEAT_BYTES)
    record_class = first[qshell_abi.OFFSET_RECORD_CLASS]
    if record_class == qshell_abi.RECORD_CLASS_CORRECTION and actual == normal:
        return actual
    raise ValueError(
        "production bridge accepts only the fixed-length correction response"
    )


class XdbBeatBridge:
    def __init__(self, xdb: str, timeout_ms: int, response_bytes: int) -> None:
        self.xdb = xdb
        self.timeout_seconds = max(timeout_ms / 1000.0, 0.001)
        self.normal_response_shape = shape_for_bytes(response_bytes)
        address_slot = os.getpid() & 0xFFFF
        self.tx_addr = 0x1000_0000 + address_slot * PACKET_STORAGE_BYTES
        self.rx_addr = self.tx_addr + 0x0800_0000
        self.tx = PacketAssembler()
        self.rx_record: bytes | None = None
        self.rx_shape: PacketShape | None = None
        self.rx_beat = 0
        self.poisoned = False
        self.mapped_addresses: list[int] = []
        try:
            for address in (self.tx_addr, self.rx_addr):
                self._run(
                    "mem",
                    "map",
                    "host",
                    hex(address),
                    str(PACKET_STORAGE_BYTES),
                )
                self.mapped_addresses.append(address)
        except Exception:
            self.close()
            raise

    def close(self) -> None:
        while self.mapped_addresses:
            address = self.mapped_addresses.pop()
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

    def _ensure_healthy(self) -> None:
        if self.poisoned or self.tx.poisoned:
            raise RuntimeError("QShell bridge link is poisoned; reconnect required")

    def write_beat(self, beat: Beat) -> None:
        self._ensure_healthy()
        record: bytes | None = None
        try:
            record = self.tx.push(beat)
            if record is not None:
                self._send_record(record)
        except Exception:
            if self.tx.poisoned or record is not None:
                self.poisoned = True
            raise

    def _send_record(self, record: bytes) -> None:
        shape = shape_for_bytes(len(record))
        self._run("clear-completed")
        self._run("mem", "write", "host", hex(self.tx_addr), "--hex", record.hex())
        for index in range(shape.beats):
            size = shape.final_bytes if index + 1 == shape.beats else BEAT_BYTES
            arguments = [
                "invoke",
                "local-read",
                "--addr",
                hex(self.tx_addr + index * BEAT_BYTES),
                "--len",
                str(size),
            ]
            if index + 1 != shape.beats:
                arguments.append("--no-last")
            self._run(*arguments)
        self._run(
            "completed",
            "local-read",
            "--count",
            "1",
            "--timeout",
            str(self.timeout_seconds),
        )

    def read_beat(self) -> Beat:
        self._ensure_healthy()
        if self.rx_record is None:
            try:
                self._receive_record()
            except Exception:
                self.poisoned = True
                raise
        assert self.rx_record is not None and self.rx_shape is not None
        if self.rx_beat >= self.rx_shape.beats:
            self.poisoned = True
            raise RuntimeError("cached response beat index overflow; reconnect required")
        final = self.rx_beat + 1 == self.rx_shape.beats
        # XDB exposes neither source tkeep/tlast nor a completed byte count.
        # These sidebands are reconstructed from the graph-sized descriptor
        # only after resident QShell validation/frame commit and completion.
        size = self.rx_shape.final_bytes if final else BEAT_BYTES
        offset = self.rx_beat * BEAT_BYTES
        data = self.rx_record[offset : offset + size] + bytes(BEAT_BYTES - size)
        self.rx_beat += 1
        if final:
            self.rx_record = None
            self.rx_shape = None
            self.rx_beat = 0
        return Beat(data=data, keep=low_keep(size), last=final)

    def _wait_for_write(self) -> None:
        self._run(
            "completed",
            "local-write",
            "--count",
            "1",
            "--timeout",
            str(self.timeout_seconds),
        )

    def _receive_record(self) -> None:
        expected = self.normal_response_shape
        self._run(
            "mem",
            "write",
            "host",
            hex(self.rx_addr),
            "--hex",
            bytes(expected.size).hex(),
        )
        self._run("clear-completed")
        # Submit one fixed normal-result descriptor. The active resident QShell
        # store-and-forward validator and frame commit are the trusted framing
        # boundary; XDB cannot report the source record's sidebands or length.
        self._run(
            "invoke",
            "local-write",
            "--addr",
            hex(self.rx_addr),
            "--len",
            str(expected.size),
        )
        self._wait_for_write()

        record = self._read_memory(self.rx_addr, expected.size)
        actual = accepted_response_shape(record[:BEAT_BYTES], expected)
        self.rx_record = record
        self.rx_shape = actual
        self.rx_beat = 0

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
                        bytes([int(beat.last)])
                        + struct.pack("<Q", beat.keep)
                        + beat.data
                    )
                    sys.stdout.buffer.flush()
                else:
                    raise ValueError("unknown bridge request")
            except Exception as error:  # noqa: BLE001 - protocol reports backend errors
                write_error(str(error))
    finally:
        bridge.close()
    return 0


def make_first_beat(
    payload_bytes: int,
    record_class: int = qshell_abi.RECORD_CLASS_SYNDROME,
    schema_id: int = 0,
) -> bytes:
    first = bytearray(BEAT_BYTES)
    struct.pack_into("<I", first, qshell_abi.OFFSET_MAGIC, qshell_abi.MAGIC)
    first[qshell_abi.OFFSET_ABI_VERSION] = qshell_abi.VERSION
    first[qshell_abi.OFFSET_RECORD_CLASS] = record_class
    struct.pack_into("<H", first, qshell_abi.OFFSET_HEADER_BYTES, HEADER_BYTES)
    struct.pack_into("<I", first, qshell_abi.OFFSET_PAYLOAD_BYTES, payload_bytes)
    struct.pack_into("<I", first, qshell_abi.OFFSET_SCHEMA_ID, schema_id)
    return bytes(first)


def self_test() -> int:
    assert valid_bytes(FULL_KEEP) == BEAT_BYTES
    assert valid_bytes(low_keep(48)) == 48
    for size, beats, final in (
        (112, 2, 48),
        (170, 3, 42),
        (808, 13, 40),
        (3566, 56, 46),
    ):
        assert shape_for_bytes(size) == PacketShape(size, beats, final)
    assert shape_from_header(make_first_beat(760), BEAT_BYTES).beats == 13

    d3_response = shape_for_bytes(170)
    d9_response = shape_for_bytes(3566)
    assert accepted_response_shape(
        make_first_beat(
            d3_response.size - HEADER_BYTES,
            qshell_abi.RECORD_CLASS_CORRECTION,
            qshell_abi.SCHEMA_MICROBLOSSOM_DECODE_RESULT,
        ),
        d3_response,
    ) == d3_response
    assert accepted_response_shape(
        make_first_beat(
            d9_response.size - HEADER_BYTES,
            qshell_abi.RECORD_CLASS_CORRECTION,
            qshell_abi.SCHEMA_MICROBLOSSOM_DECODE_RESULT,
        ),
        d9_response,
    ) == d9_response
    error_first = make_first_beat(
        24,
        qshell_abi.RECORD_CLASS_ERROR,
        qshell_abi.SCHEMA_ERROR,
    )
    try:
        accepted_response_shape(error_first, d3_response)
    except ValueError:
        pass
    else:
        raise AssertionError("72-byte in-band QSH2 error was accepted")

    class RecordingXdbBridge(XdbBeatBridge):
        def __init__(self, response: bytes) -> None:
            self.timeout_seconds = 0.01
            self.normal_response_shape = d3_response
            self.rx_addr = 0x1800_0000
            self.tx = PacketAssembler()
            self.rx_record = None
            self.rx_shape = None
            self.rx_beat = 0
            self.poisoned = False
            self.response = response
            self.completed = False
            self.commands: list[tuple[str, ...]] = []

        def _run(self, *arguments: str) -> dict[str, object]:
            self.commands.append(arguments)
            if arguments[:2] == ("completed", "local-write"):
                self.completed = True
                return {}
            if arguments[:3] == ("mem", "read", "host"):
                if not self.completed:
                    raise AssertionError("response memory was read before final completion")
                size = int(arguments[4])
                return {"data_hex": self.response[:size].hex()}
            return {}

    normal_record = bytearray(d3_response.size)
    normal_record[:BEAT_BYTES] = make_first_beat(
        d3_response.size - HEADER_BYTES,
        qshell_abi.RECORD_CLASS_CORRECTION,
        qshell_abi.SCHEMA_MICROBLOSSOM_DECODE_RESULT,
    )
    recording = RecordingXdbBridge(bytes(normal_record))
    first_result = recording.read_beat()
    assert recording.completed
    assert first_result.keep == FULL_KEEP and not first_result.last
    invokes = [command for command in recording.commands if command[:2] == ("invoke", "local-write")]
    completions = [
        command
        for command in recording.commands
        if command[:2] == ("completed", "local-write")
    ]
    reads = [command for command in recording.commands if command[:3] == ("mem", "read", "host")]
    assert len(invokes) == 1 and "--no-last" not in invokes[0]
    assert invokes[0][invokes[0].index("--len") + 1] == str(d3_response.size)
    assert len(completions) == 1 and "--count" in completions[0]
    assert len(reads) == 1
    assert recording.commands.index(completions[0]) < recording.commands.index(reads[0])
    second_result = recording.read_beat()
    final_result = recording.read_beat()
    assert second_result.keep == FULL_KEEP and not second_result.last
    assert final_result.keep == low_keep(42) and final_result.last

    collision = bytearray(d3_response.size)
    collision[:BEAT_BYTES] = error_first
    collision[72:] = normal_record[: d3_response.size - 72]
    recording = RecordingXdbBridge(bytes(collision))
    try:
        recording.read_beat()
    except ValueError:
        pass
    else:
        raise AssertionError("completed 72-byte collision was published")
    assert recording.completed and recording.poisoned and recording.rx_record is None
    invokes = [command for command in recording.commands if command[:2] == ("invoke", "local-write")]
    assert len(invokes) == 1
    assert invokes[0][invokes[0].index("--len") + 1] == str(d3_response.size)

    assembler = PacketAssembler()
    first = make_first_beat(760)
    assert assembler.push(Beat(first, FULL_KEEP, False)) is None
    for _ in range(11):
        assert assembler.push(Beat(bytes(BEAT_BYTES), FULL_KEEP, False)) is None
    record = assembler.push(Beat(bytes(BEAT_BYTES), low_keep(40), True))
    assert record is not None and len(record) == 808

    assembler = PacketAssembler()
    try:
        assembler.push(Beat(first, FULL_KEEP, True))
    except ValueError:
        pass
    else:
        raise AssertionError("truncated record was accepted")
    assert assembler.record == b"" and assembler.shape is None

    malformed = bytearray(make_first_beat(64))
    malformed[qshell_abi.OFFSET_MAGIC] ^= 1
    assert assembler.push(Beat(bytes(malformed), FULL_KEEP, False)) is None
    try:
        assembler.push(Beat(bytes(BEAT_BYTES), low_keep(48), True))
    except ValueError:
        pass
    else:
        raise AssertionError("malformed record terminator was accepted")
    valid_first = make_first_beat(64)
    assert assembler.push(Beat(valid_first, FULL_KEEP, False)) is None
    recovered = assembler.push(Beat(bytes(BEAT_BYTES), low_keep(48), True))
    assert recovered is not None and len(recovered) == 112

    unterminated = PacketAssembler()
    assert unterminated.push(Beat(bytes(malformed), FULL_KEEP, False)) is None
    for _ in range(MAX_PACKET_BEATS - 2):
        assert unterminated.push(Beat(bytes(BEAT_BYTES), FULL_KEEP, False)) is None
    try:
        unterminated.push(Beat(bytes(BEAT_BYTES), FULL_KEEP, False))
    except RuntimeError:
        pass
    else:
        raise AssertionError("unterminated malformed record did not poison the link")
    assert unterminated.poisoned

    for invalid in (0x5, 0):
        try:
            valid_bytes(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid keep was accepted")
    try:
        shape_for_bytes(PACKET_STORAGE_BYTES + 1)
    except ValueError:
        pass
    else:
        raise AssertionError("oversized packet was accepted")

    print(
        "MICROBLOSSOM_QSHELL_XDB_BRIDGE_PASS "
        "request_beats=13 response_beats=56 storage_bytes=4096 "
        "receive_descriptors=1 completion_before_publish=1 "
        "first_beat_poll=0 shell_error_72=rejected"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--xdb", required=False)
    parser.add_argument("--vfpga", type=int, default=0)
    parser.add_argument("--timeout-ms", type=int, default=10_000)
    parser.add_argument("--response-bytes", type=int)
    parser.add_argument("--continuation-bytes", type=int)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.xdb is None:
        parser.error("--xdb is required outside self-test")
    if args.vfpga != 0:
        parser.error("packaged simulation currently exposes only vFPGA 0")
    if args.response_bytes is not None and args.continuation_bytes is not None:
        parser.error("--response-bytes and --continuation-bytes are mutually exclusive")
    response_bytes = args.response_bytes
    if args.continuation_bytes is not None:
        if not 0 < args.continuation_bytes <= BEAT_BYTES:
            parser.error("continuation must contain 1..64 bytes")
        response_bytes = BEAT_BYTES + args.continuation_bytes
    if response_bytes is None:
        response_bytes = DEFAULT_RESPONSE_BYTES
    if not BEAT_BYTES < response_bytes <= PACKET_STORAGE_BYTES:
        parser.error("response packet must contain 65..4096 bytes")
    bridge = XdbBeatBridge(args.xdb, args.timeout_ms, response_bytes)
    return run_protocol(bridge)


if __name__ == "__main__":
    raise SystemExit(main())
