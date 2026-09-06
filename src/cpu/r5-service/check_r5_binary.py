#!/usr/bin/env python3
"""Validate freestanding Cortex-R5 archives and final ELF images."""

import argparse
import hashlib
import io
import json
import re
from pathlib import Path

from elftools.common.exceptions import ELFError
from elftools.elf.elffile import ELFFile
from elftools.elf.sections import SymbolTableSection


class PolicyError(RuntimeError):
    pass


SHF_WRITE = 0x1
SHF_ALLOC = 0x2
SHF_TLS = 0x400
HARD_FLOAT_ABI = 0x400

UNWIND_SECTIONS = (
    ".ARM.exidx",
    ".ARM.extab",
    ".eh_frame",
    ".gcc_except_table",
)
DYNAMIC_SECTIONS = {
    ".dynamic",
    ".dynstr",
    ".dynsym",
    ".interp",
    ".got",
    ".got.plt",
    ".plt",
}
ALLOCATOR_SYMBOLS = {
    "malloc",
    "calloc",
    "realloc",
    "free",
    "aligned_alloc",
    "posix_memalign",
}
ALLOCATOR_SYMBOL_FRAGMENTS = (
    "__rust_alloc",
    "__rust_dealloc",
    "__rust_realloc",
    "__rust_alloc_zeroed",
    "__rg_alloc",
    "__rg_dealloc",
    "__rg_realloc",
    "__rg_alloc_zeroed",
    "__rdl_alloc",
    "__rdl_dealloc",
    "__rdl_realloc",
    "__rdl_alloc_zeroed",
)
UNWIND_SYMBOL_FRAGMENTS = (
    "_Unwind_",
    "__aeabi_unwind_cpp",
    "__gnu_unwind",
    "rust_eh_personality",
    "__gxx_personality_v0",
)


def require(condition, message):
    if not condition:
        raise PolicyError(message)


def decode_member_name(raw_name, payload, string_table):
    name = raw_name.decode("ascii", errors="strict").rstrip()
    if name.startswith("#1/"):
        name_bytes = int(name[3:])
        require(name_bytes <= len(payload), "archive: invalid BSD member name")
        decoded = payload[:name_bytes].decode("utf-8", errors="strict").rstrip("\0")
        return decoded, payload[name_bytes:]
    if name.startswith("/") and name[1:].isdigit():
        require(string_table is not None, "archive: member references a missing string table")
        offset = int(name[1:])
        require(offset < len(string_table), "archive: member name offset is out of range")
        end = string_table.find(b"/\n", offset)
        if end < 0:
            end = string_table.find(b"\0", offset)
        require(end >= 0, "archive: unterminated member name")
        return string_table[offset:end].decode("utf-8", errors="strict"), payload
    return name.removesuffix("/"), payload


def archive_members(path):
    encoded = path.read_bytes()
    require(encoded.startswith(b"!<arch>\n"), "archive: input is not a regular ar archive")
    offset = 8
    string_table = None
    members = []
    while offset < len(encoded):
        require(offset + 60 <= len(encoded), "archive: truncated member header")
        header = encoded[offset : offset + 60]
        require(header[58:60] == b"`\n", "archive: invalid member header trailer")
        try:
            size = int(header[48:58].decode("ascii").strip())
        except ValueError as error:
            raise PolicyError("archive: invalid member size") from error
        offset += 60
        require(offset + size <= len(encoded), "archive: truncated member payload")
        payload = encoded[offset : offset + size]
        offset += size
        if offset & 1:
            offset += 1
        raw_name = header[:16]
        short_name = raw_name.decode("ascii", errors="strict").rstrip()
        if short_name == "//":
            string_table = payload
            continue
        if short_name in {"/", "/SYM64/", "__.SYMDEF", "__.SYMDEF SORTED"}:
            continue
        name, payload = decode_member_name(raw_name, payload, string_table)
        members.append((name, payload))
    require(offset == len(encoded) or offset == len(encoded) + 1, "archive: invalid trailing bytes")
    require(members, "archive: no object members")
    return members


def symbol_is_undefined(symbol):
    return symbol.entry["st_shndx"] == "SHN_UNDEF"


def inspect_elf(stream, label, expected_type, allow_cantunwind=False):
    try:
        elf = ELFFile(stream)
    except ELFError as error:
        raise PolicyError(f"ELF: {label} is not an ELF object") from error

    require(elf.elfclass == 32, f"ELF: {label} is not 32-bit")
    require(elf.little_endian, f"ELF: {label} is not little-endian")
    require(elf.header["e_machine"] == "EM_ARM", f"ELF: {label} is not ARM")
    flags = int(elf.header["e_flags"])
    require((flags & HARD_FLOAT_ABI) == 0, f"hard-float: {label} uses the hard-float parameter ABI")

    segments = list(elf.iter_segments())
    for segment in segments:
        segment_type = segment.header["p_type"]
        require(segment_type not in {"PT_INTERP", "PT_DYNAMIC"}, f"dynamic: {label} contains {segment_type}")
        require(segment_type != "PT_TLS", f"TLS: {label} contains PT_TLS")
    require(elf.header["e_type"] == expected_type, f"ELF: {label} has type {elf.header['e_type']}, expected {expected_type}")

    defined = {}
    undefined = set()
    all_symbols = set()
    initialized_writable = []
    unwind_sections = []
    tls_sections = []
    dynamic_sections = []

    for section in elf.iter_sections():
        name = section.name
        size = int(section.header["sh_size"])
        section_type = section.header["sh_type"]
        section_flags = int(section.header["sh_flags"])
        if size:
            if name.startswith(UNWIND_SECTIONS):
                if allow_cantunwind and name.startswith(".ARM.exidx"):
                    data = section.data()
                    cantunwind = len(data) % 8 == 0 and all(
                        int.from_bytes(data[offset + 4 : offset + 8], "little") == 1
                        for offset in range(0, len(data), 8)
                    )
                    require(cantunwind, f"unwind: {label} contains active unwind entries in {name}")
                else:
                    unwind_sections.append(name)
            if section_flags & SHF_TLS or name in {".tdata", ".tbss"}:
                tls_sections.append(name)
            if section_type == "SHT_DYNAMIC" or name in DYNAMIC_SECTIONS:
                dynamic_sections.append(name)
            if (
                section_flags & SHF_ALLOC
                and section_flags & SHF_WRITE
                and section_type != "SHT_NOBITS"
            ):
                initialized_writable.append(name)
        if isinstance(section, SymbolTableSection):
            for symbol in section.iter_symbols():
                symbol_name = symbol.name
                if not symbol_name:
                    continue
                all_symbols.add(symbol_name)
                binding = symbol.entry["st_info"]["bind"]
                if binding not in {"STB_GLOBAL", "STB_WEAK"}:
                    continue
                if symbol_is_undefined(symbol):
                    undefined.add(symbol_name)
                else:
                    defined.setdefault(symbol_name, set()).add(
                        symbol.entry["st_info"]["type"]
                    )

    require(not unwind_sections, f"unwind: {label} contains {', '.join(sorted(set(unwind_sections)))}")
    require(not tls_sections, f"TLS: {label} contains {', '.join(sorted(set(tls_sections)))}")
    require(not dynamic_sections, f"dynamic: {label} contains {', '.join(sorted(set(dynamic_sections)))}")
    require(
        not initialized_writable,
        f"initialized-writable-data: {label} contains {', '.join(sorted(set(initialized_writable)))}",
    )

    allocator_symbols = sorted(
        symbol
        for symbol in all_symbols
        if symbol in ALLOCATOR_SYMBOLS
        or any(fragment in symbol for fragment in ALLOCATOR_SYMBOL_FRAGMENTS)
    )
    require(
        not allocator_symbols,
        f"allocator: {label} references {', '.join(allocator_symbols)}",
    )
    unwind_symbols = sorted(
        symbol
        for symbol in all_symbols
        if any(fragment in symbol for fragment in UNWIND_SYMBOL_FRAGMENTS)
    )
    require(
        not unwind_symbols,
        f"unwind: {label} references {', '.join(unwind_symbols)}",
    )

    return {
        "defined": defined,
        "undefined": undefined,
        "flags": flags,
        "sectionCount": elf.num_sections(),
        "segmentCount": len(segments),
    }


def merge_symbols(results):
    defined = {}
    undefined = set()
    for result in results:
        undefined.update(result["undefined"])
        for name, types in result["defined"].items():
            defined.setdefault(name, set()).update(types)
    return defined, undefined - set(defined)


def validate_required_symbols(defined, required_functions, required_objects):
    for name in required_functions:
        require(name in defined, f"symbol: required function {name} is missing")
        require("STT_FUNC" in defined[name], f"symbol: {name} is not a function")
    for name in required_objects:
        require(name in defined, f"symbol: required object {name} is missing")
        require("STT_OBJECT" in defined[name], f"symbol: {name} is not an object")


def validate_archive(path, args):
    members = archive_members(path)
    results = []
    member_names = []
    for name, payload in members:
        require(payload.startswith(b"\x7fELF"), f"archive: member {name} is not ELF")
        results.append(
            inspect_elf(
                io.BytesIO(payload),
                name,
                "ET_REL",
                allow_cantunwind=args.allow_cantunwind,
            )
        )
        member_names.append(name)
    defined, unresolved = merge_symbols(results)
    validate_required_symbols(defined, args.require_function, args.require_object)
    unexpected = sorted(unresolved - set(args.allow_undefined))
    require(
        not unexpected,
        f"undefined-symbol: archive has unresolved {', '.join(unexpected)}",
    )
    return {
        "kind": "archive",
        "memberCount": len(members),
        "members": member_names,
        "undefinedAllowlist": sorted(args.allow_undefined),
        "unresolvedSymbols": sorted(unresolved),
    }


def validate_final_elf(path, args):
    with path.open("rb") as stream:
        result = inspect_elf(
            stream, path.name, "ET_EXEC", allow_cantunwind=args.allow_cantunwind
        )
    defined, unresolved = merge_symbols([result])
    validate_required_symbols(defined, args.require_function, args.require_object)
    unexpected = sorted(unresolved - set(args.allow_undefined))
    require(
        not unexpected,
        f"undefined-symbol: final ELF has unresolved {', '.join(unexpected)}",
    )
    return {
        "kind": "elf",
        "memberCount": None,
        "undefinedAllowlist": sorted(args.allow_undefined),
        "unresolvedSymbols": sorted(unresolved),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--kind", choices=("archive", "elf"), required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--allow-undefined", action="append", default=[])
    parser.add_argument("--allow-cantunwind", action="store_true")
    parser.add_argument("--require-function", action="append", default=[])
    parser.add_argument("--require-object", action="append", default=[])
    args = parser.parse_args()

    try:
        require(args.input.is_file(), f"input: {args.input} is not a file")
        if args.kind == "archive":
            report = validate_archive(args.input, args)
        else:
            report = validate_final_elf(args.input, args)
    except (PolicyError, OSError, UnicodeError, ValueError) as error:
        raise SystemExit(f"R5 binary policy error: {error}") from error

    report.update(
        {
            "api": "microblossom.r5-binary-policy/v1",
            "input": str(args.input),
            "sha256": hashlib.sha256(args.input.read_bytes()).hexdigest(),
            "arm": True,
            "bits": 32,
            "littleEndian": True,
            "hardFloatAbi": False,
            "unwind": False,
            "allocator": False,
            "dynamic": False,
            "tls": False,
            "initializedWritableData": False,
        }
    )
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output is None:
        print(encoded, end="")
    else:
        args.output.write_text(encoded, encoding="utf-8")


if __name__ == "__main__":
    main()
