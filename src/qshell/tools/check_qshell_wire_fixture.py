#!/usr/bin/env python3
"""Check MicroBlossom's frozen QShell record bytes against the current spec."""

import argparse
import json
from pathlib import Path

EXPECTED_FIRST = bytes.fromhex(
    "51534832020100003000000040000000"
    "070000002a0000000100020012000000"
    "00000000214365870000000003000000"
    "4d425131010203004433221188776655"
)
EXPECTED_SECOND = bytes.fromhex(
    "4b078d3b6c6db24ea9726414569a97b3"
    "899be4e532be1c0ebd84b5fa875316c5"
    "08070605040302011817161514131211"
    "00000000000000000000000000000000"
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", required=True, type=Path)
    parser.add_argument("--fixtures", required=True, type=Path)
    args = parser.parse_args()

    spec = json.loads(args.spec.read_text())
    fixtures = json.loads(args.fixtures.read_text())["fixtures"]
    fixture = next(item for item in fixtures if item["name"] == "microblossom_mmio_write")
    fields = {field["name"]: field for field in spec["fields"]}
    payload = bytes.fromhex(fixture["payload_hex"])
    header = bytearray(spec["header_bytes"])

    def put(name: str, value: int) -> None:
        field = fields[name]
        start = field["offset"]
        header[start : start + field["bytes"]] = value.to_bytes(field["bytes"], "little")

    header[fields["magic"]["offset"] : fields["magic"]["offset"] + 4] = spec[
        "magic_ascii"
    ].encode("ascii")
    put("abi_version", spec["version"])
    put("record_class", spec["record_classes"][fixture["record_class"]])
    put("flags", sum(spec["flags"][flag] for flag in fixture["flags"]))
    put("header_bytes", spec["header_bytes"])
    put("payload_bytes", len(payload))
    for name in (
        "context_id",
        "round_id",
        "source_endpoint_id",
        "destination_endpoint_id",
        "route_capability_id",
        "route_version",
        "record_sequence",
    ):
        put(name, fixture[name])
    put("schema_id", spec["schemas"][fixture["schema_id"]])

    first_payload_bytes = spec["beat_bytes"] - spec["header_bytes"]
    first = bytes(header) + payload[:first_payload_bytes]
    second_payload = payload[first_payload_bytes:]
    second = second_payload + bytes(spec["beat_bytes"] - len(second_payload))

    assert spec["schemas"]["microblossom_command"] == 0x00020001
    assert spec["schemas"]["microblossom_response"] == 0x00020002
    assert first == EXPECTED_FIRST
    assert second == EXPECTED_SECOND
    assert len(second_payload) == 48


if __name__ == "__main__":
    main()
