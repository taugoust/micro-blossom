#!/usr/bin/env python3
"""Generate MicroBlossom language bindings from QShell's current ABI spec."""

import argparse
import json
from pathlib import Path


def upper(name: str) -> str:
    return name.upper()


def load_spec(path: Path) -> dict[str, object]:
    spec = json.loads(path.read_text(encoding="utf-8"))
    assert spec["byte_order"] == "little"
    assert spec["header_bytes"] < spec["beat_bytes"]
    assert len(spec["magic_ascii"].encode("ascii")) == 4
    return spec


def generate_rust(spec: dict[str, object]) -> str:
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
    return "\n".join(lines)


def generate_c(spec: dict[str, object]) -> str:
    magic = int.from_bytes(spec["magic_ascii"].encode(), "little")
    lines = [
        "/* Generated from QShell abi/qshell-abi.json; do not edit. */",
        "#ifndef MICROBLOSSOM_QSHELL_ABI_GENERATED_H",
        "#define MICROBLOSSOM_QSHELL_ABI_GENERATED_H",
        "",
        "#include <stddef.h>",
        "#include <stdint.h>",
        "",
        f"#define QSHELL_ABI_VERSION UINT8_C({spec['version']})",
        f"#define QSHELL_BEAT_BYTES ((size_t){spec['beat_bytes']})",
        f"#define QSHELL_HEADER_BYTES ((size_t){spec['header_bytes']})",
        f"#define QSHELL_MAGIC UINT32_C(0x{magic:08x})",
        "",
    ]
    for group, prefix, macro in (
        ("record_classes", "QSHELL_CLASS", "UINT8_C"),
        ("flags", "QSHELL_FLAG", "UINT16_C"),
        ("schemas", "QSHELL_SCHEMA", "UINT32_C"),
        ("error_scopes", "QSHELL_ERROR_SCOPE", "UINT8_C"),
        ("error_codes", "QSHELL_ERROR", "UINT16_C"),
    ):
        for name, value in spec[group].items():
            lines.append(f"#define {prefix}_{upper(name)} {macro}(0x{value:x})")
        lines.append("")
    for field in spec["fields"]:
        lines.append(
            f"#define QSHELL_OFFSET_{upper(field['name'])} ((size_t){field['offset']})"
        )
    lines.extend(["", "#endif", ""])
    return "\n".join(lines)


def generate_python(spec: dict[str, object]) -> str:
    magic = int.from_bytes(spec["magic_ascii"].encode(), "little")
    lines = [
        '"""Generated from QShell abi/qshell-abi.json; do not edit."""',
        "",
        f"VERSION = {spec['version']}",
        f"BEAT_BYTES = {spec['beat_bytes']}",
        f"HEADER_BYTES = {spec['header_bytes']}",
        f"MAGIC = 0x{magic:08x}",
        "",
    ]
    for group, prefix in (
        ("record_classes", "RECORD_CLASS"),
        ("flags", "FLAG"),
        ("schemas", "SCHEMA"),
        ("error_scopes", "ERROR_SCOPE"),
        ("error_codes", "ERROR"),
    ):
        for name, value in spec[group].items():
            lines.append(f"{prefix}_{upper(name)} = 0x{value:x}")
        lines.append("")
    for field in spec["fields"]:
        lines.append(f"OFFSET_{upper(field['name'])} = {field['offset']}")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--rust-out", type=Path, required=True)
    parser.add_argument("--c-out", type=Path, required=True)
    parser.add_argument("--python-out", type=Path, required=True)
    args = parser.parse_args()

    spec = load_spec(args.spec)
    outputs = {
        args.rust_out: generate_rust(spec),
        args.c_out: generate_c(spec),
        args.python_out: generate_python(spec),
    }
    for path, content in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")


if __name__ == "__main__":
    main()
