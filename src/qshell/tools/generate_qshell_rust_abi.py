#!/usr/bin/env python3
"""Generate Rust constants from QShell's authoritative current ABI JSON spec."""

import argparse
import json
from pathlib import Path


def upper(name: str) -> str:
    return name.upper()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    spec = json.loads(args.spec.read_text(encoding="utf-8"))
    assert spec["byte_order"] == "little"
    assert spec["header_bytes"] < spec["beat_bytes"]
    assert len(spec["magic_ascii"].encode("ascii")) == 4

    lines = [
        "// Generated from QShell abi/qshell-abi.json; do not edit.",
        f"pub const VERSION: u8 = {spec['version']};",
        f"pub const BEAT_BYTES: usize = {spec['beat_bytes']};",
        f"pub const HEADER_BYTES: usize = {spec['header_bytes']};",
        f"pub const MAGIC: u32 = 0x{int.from_bytes(spec['magic_ascii'].encode(), 'little'):08x};",
        "",
    ]

    for group, module, rust_type in (
        ("record_classes", "record_class", "u8"),
        ("flags", "flag", "u16"),
        ("schemas", "schema", "u32"),
        ("error_scopes", "error_scope", "u8"),
        ("error_codes", "error_code", "u16"),
    ):
        lines.append(f"pub mod {module} {{")
        for name, value in spec[group].items():
            lines.append(f"    pub const {upper(name)}: {rust_type} = 0x{value:x};")
        lines.extend(["}", ""])

    lines.append("pub mod offset {")
    for field in spec["fields"]:
        lines.append(f"    pub const {upper(field['name'])}: usize = {field['offset']};")
    lines.extend(["}", ""])

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    main()
