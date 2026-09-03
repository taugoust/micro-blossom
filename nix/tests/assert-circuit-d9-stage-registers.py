#!/usr/bin/env python3
"""Assert the exact named register cuts in generated circuit-d9 Verilog."""

import argparse
import collections
import re
from pathlib import Path

EXPECTED_COUNTS = {
    "Vertex": 433,
    "Edge": 1737,
}

EXPECTED_REGISTERS = {
    "Vertex": {
        "stages_offloadSet3_regNext_state_speed",
        "stages_offloadSet3_regNext_state_node",
        "stages_offloadSet3_regNext_state_root",
        "stages_offloadSet3_regNext_state_isVirtual",
        "stages_offloadSet3_regNext_state_isDefect",
        "stages_offloadSet3_regNext_state_grown",
        "stages_offloadSet3_regNext_message_valid",
        "stages_offloadSet3_regNext_message_instruction",
        "stages_offloadSet3_regNext_message_isReset",
        "stages_offloadSet3_regNext_isUniqueTight",
        "stages_offloadSet3_regNext_isIsolated",
        "stages_executeSet2_regNext_state_speed",
        "stages_executeSet2_regNext_state_node",
        "stages_executeSet2_regNext_state_root",
        "stages_executeSet2_regNext_state_isVirtual",
        "stages_executeSet2_regNext_state_isDefect",
        "stages_executeSet2_regNext_state_grown",
        "stages_executeSet2_regNext_isStalled",
        "stages_executeSet2_regNext_compact_valid",
        "stages_executeSet2_regNext_compact_isReset",
        "stages_updateSet_regNext_state_speed",
        "stages_updateSet_regNext_state_node",
        "stages_updateSet_regNext_state_root",
        "stages_updateSet_regNext_state_isVirtual",
        "stages_updateSet_regNext_state_isDefect",
        "stages_updateSet_regNext_state_grown",
        "stages_updateSet_regNext_isStalled",
        "stages_updateSet_regNext_compact_valid",
        "stages_updateSet_regNext_compact_isReset",
        "stages_updateSet_regNext_propagatingPeer_valid",
        "stages_updateSet_regNext_propagatingPeer_node",
        "stages_updateSet_regNext_propagatingPeer_root",
    },
    "Edge": {
        "stages_offloadSet3_regNext_state_weight",
        "stages_offloadSet3_regNext_isTight",
        "stages_offloadSet3_regNext_compact_valid",
        "stages_offloadSet3_regNext_compact_isReset",
        "stages_executeSet2_regNext_state_weight",
        "stages_executeSet2_regNext_compact_valid",
        "stages_executeSet2_regNext_compact_isReset",
        "stages_updateSet_regNext_state_weight",
        "stages_updateSet_regNext_remaining",
        "stages_updateSet_regNext_compact_valid",
        "stages_updateSet_regNext_compact_isReset",
    },
    # Offloader has no payload at offload3. Its execute2 and update bundles each
    # carry the active condition through a real named register.
    "Offloader": {
        "stages_executeSet2_regNext_condition",
        "stages_updateSet_regNext_condition",
    },
}

MODULE = re.compile(r"^module (Vertex(?:_\d+)?|Edge(?:_\d+)?|Offloader(?:_\d+)?) \(")
REGISTER = re.compile(
    r"^\s*reg\s+(?:\[[^]]+\]\s+)?(stages_[A-Za-z0-9_]+_regNext_[A-Za-z0-9_]+);"
)
OFFLOADER_INSTANCE = re.compile(r"^\s*Offloader(?:_\d+)?\s+offloaders_\d+ \(")


def module_kind(name: str) -> str:
    return name.split("_", 1)[0]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("rtl", type=Path)
    parser.add_argument("--expect-active-offloaders", action="store_true")
    args = parser.parse_args()

    expected_counts = dict(EXPECTED_COUNTS)
    # SpinalHDL emits one module for each distinct offloader port shape and
    # shares those seven definitions across all 1,737 active graph entries.
    if args.expect_active_offloaders:
        expected_counts["Offloader"] = 7

    modules: dict[str, set[str]] = {}
    offloader_instances = 0
    current: str | None = None
    with args.rtl.open(encoding="utf-8", errors="strict") as rtl:
        for line in rtl:
            if OFFLOADER_INSTANCE.match(line):
                offloader_instances += 1
            module_match = MODULE.match(line)
            if module_match:
                current = module_match.group(1)
                if current in modules:
                    raise AssertionError(f"duplicate generated module {current}")
                modules[current] = set()
                continue
            if line.startswith("endmodule"):
                current = None
                continue
            if current is not None:
                register_match = REGISTER.match(line)
                if register_match:
                    modules[current].add(register_match.group(1))

    by_kind: dict[str, list[tuple[str, set[str]]]] = collections.defaultdict(list)
    for name, registers in modules.items():
        by_kind[module_kind(name)].append((name, registers))

    actual_counts = {kind: len(entries) for kind, entries in sorted(by_kind.items())}
    assert actual_counts == expected_counts, (
        f"generated circuit-d9 module counts differ: {actual_counts} != {expected_counts}"
    )
    expected_offloader_instances = 1737 if args.expect_active_offloaders else 0
    assert offloader_instances == expected_offloader_instances, (
        f"generated circuit-d9 offloader instances differ: "
        f"{offloader_instances} != {expected_offloader_instances}"
    )

    for kind, entries in by_kind.items():
        expected = EXPECTED_REGISTERS[kind]
        for name, actual in entries:
            assert actual == expected, (
                f"{name} named stage registers differ: "
                f"missing={sorted(expected - actual)}, extra={sorted(actual - expected)}"
            )

    mode = "active-offloaders" if args.expect_active_offloaders else "packaged"
    summary = ",".join(f"{kind}={expected_counts[kind]}" for kind in sorted(expected_counts))
    print(
        f"CIRCUIT_D9_STAGE_REGISTERS_OK mode={mode} {summary} "
        f"offloaderInstances={offloader_instances}"
    )


if __name__ == "__main__":
    main()
