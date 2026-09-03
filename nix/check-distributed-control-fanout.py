#!/usr/bin/env python3

import argparse
import collections
import re
from pathlib import Path

MAX_FANOUT = 32
CASES = {
    "d3": {"consumers": 58, "vertices": 19, "levels": {0: 2}},
    "d9": {"consumers": 2170, "vertices": 433, "levels": {0: 3, 1: 68}},
}


def fail(case: str, message: str) -> None:
    raise AssertionError(f"{case}: {message}")


def inspect_distributed_dual(case: str, path: Path, expected: dict[str, object]) -> None:
    in_module = False
    in_consumer = False
    consumer_lines: list[str] = []
    consumers: list[str] = []
    reset_assignments: dict[str, int] = {}
    source_reset_connections = 0

    with path.open() as source:
        for line in source:
            if not in_module:
                if line.startswith("module DistributedDual ("):
                    in_module = True
                continue
            if line.startswith("endmodule"):
                break

            if in_consumer:
                consumer_lines.append(line)
                if line == "  );\n":
                    consumers.append("".join(consumer_lines))
                    consumer_lines = []
                    in_consumer = False
                continue

            if re.match(r"^  (?:Vertex(?:_\d+)?|Edge(?:_\d+)?) (?:vertices|edges)_\d+ \($", line.rstrip()):
                in_consumer = True
                consumer_lines = [line]
                continue

            if re.search(r"\.sourceReset\s+\(slow_reset\s*\)", line):
                source_reset_connections += 1
            assignment = re.search(
                r"assign (_zz_\d+) = controlFanout_io_leafResets\[(\d+)\];",
                line,
            )
            if assignment:
                reset_assignments[assignment.group(1)] = int(assignment.group(2))

    if not in_module:
        fail(case, "DistributedDual module is absent")
    if in_consumer:
        fail(case, "unterminated Vertex/Edge instance")
    if len(consumers) != expected["consumers"]:
        fail(case, f"found {len(consumers)} message consumers")
    if source_reset_connections != 1:
        fail(case, f"found {source_reset_connections} root reset connections")

    message_loads: collections.Counter[int] = collections.Counter()
    consumer_reset_nets: list[set[str]] = []
    for block in consumers:
        if "(slow_reset" in block:
            fail(case, "a graph consumer is driven directly by slow_reset")
        leaves = []
        for field in ("valid", "instruction", "isReset"):
            match = re.search(
                rf"\.io_message_{field}\s+\(controlFanout_io_leafMessages_(\d+)_{field}",
                block,
            )
            if match is None:
                fail(case, f"a consumer omits message field {field}")
            leaves.append(int(match.group(1)))
        if len(set(leaves)) != 1:
            fail(case, f"a consumer splits its message bundle across leaves {leaves}")
        message_loads[leaves[0]] += 1
        consumer_reset_nets.append(set(re.findall(r"\((_zz_\d+)\s*\)", block)))

    expected_leaves = (int(expected["consumers"]) + MAX_FANOUT - 1) // MAX_FANOUT
    if len(message_loads) != expected_leaves:
        fail(case, f"found {len(message_loads)} used message leaves")
    if min(message_loads.values()) <= 0 or max(message_loads.values()) > MAX_FANOUT:
        fail(case, f"message leaf loads are outside 1..{MAX_FANOUT}: {message_loads}")

    reset_loads: collections.Counter[int] = collections.Counter()
    for nets in consumer_reset_nets:
        local_leaves = {reset_assignments[net] for net in nets if net in reset_assignments}
        if len(local_leaves) > 1:
            fail(case, f"a consumer uses multiple local resets {sorted(local_leaves)}")
        for leaf in local_leaves:
            reset_loads[leaf] += 1
    if sum(reset_loads.values()) != expected["vertices"]:
        fail(case, f"found local reset connections for {sum(reset_loads.values())} vertices")
    if max(reset_loads.values()) > MAX_FANOUT:
        fail(case, f"local reset leaf loads exceed {MAX_FANOUT}: {reset_loads}")


def module_text(path: Path, module_name: str) -> str:
    lines: list[str] = []
    in_module = False
    with path.open() as source:
        for line in source:
            if not in_module:
                if line.startswith(f"module {module_name} ("):
                    in_module = True
                    lines.append(line)
                continue
            lines.append(line)
            if line.startswith("endmodule"):
                return "".join(lines)
    raise AssertionError(f"module {module_name} is absent from {path}")


def inspect_fanout_module(case: str, path: Path, expected: dict[str, object]) -> None:
    module = module_text(path, "DistributedDualControlFanout")
    expected_levels = expected["levels"]

    leaf_outputs = set(re.findall(r"output\s+io_leafMessages_(\d+)_valid", module))
    if len(leaf_outputs) != max(expected_levels.values()):
        fail(case, f"found {len(leaf_outputs)} control leaf outputs")

    nodes_by_field: dict[str, set[tuple[int, int]]] = {}
    for field in ("valid", "instruction", "isReset"):
        nodes_by_field[field] = {
            (int(level), int(node))
            for level, node in re.findall(
                rf"\breg\s+(?:\[[^]]+\]\s+)?message_l(\d+)_n(\d+)_{field};",
                module,
            )
        }
    if not (nodes_by_field["valid"] == nodes_by_field["instruction"] == nodes_by_field["isReset"]):
        fail(case, "message fields do not have identical replication nodes")

    reset_nodes = {
        (int(level), int(node))
        for level, node in re.findall(r"\breg\s+reset_l(\d+)_n(\d+);", module)
    }
    if reset_nodes != nodes_by_field["valid"]:
        fail(case, "reset and message trees do not have identical nodes")

    actual_levels = collections.Counter(level for level, _ in reset_nodes)
    if dict(actual_levels) != expected_levels:
        fail(case, f"tree levels are {dict(actual_levels)}, expected {expected_levels}")

    for line in module.splitlines():
        if re.search(
            r"\breg\s+(?:\[[^]]+\]\s+)?"
            r"(?:message_l\d+_n\d+_(?:valid|instruction|isReset)|reset_l\d+_n\d+);$",
            line,
        ):
            for attribute in ('keep = "true"', 'dont_touch = "true"', f"max_fanout = {MAX_FANOUT}"):
                if attribute not in line:
                    fail(case, f"replication register omits {attribute}: {line.strip()}")

    parents_by_child: dict[tuple[int, int, str], str] = {}
    for level, node, field, parent in re.findall(
        r"message_l(\d+)_n(\d+)_(valid|instruction|isReset) <= ([A-Za-z0-9_]+)",
        module,
    ):
        field_suffix = f"_{field}"
        if not parent.endswith(field_suffix):
            fail(case, f"message node l{level}/n{node} field {field} has mismatched parent {parent}")
        parents_by_child[(int(level), int(node), field)] = parent[: -len(field_suffix)]
    for level, node in reset_nodes:
        field_parents = {
            parents_by_child.get((level, node, field))
            for field in ("valid", "instruction", "isReset")
        }
        if None in field_parents or len(field_parents) != 1:
            fail(case, f"message node l{level}/n{node} does not copy one complete parent bundle")

    parent_loads: collections.Counter[tuple[int, str]] = collections.Counter()
    for (level, node, field), parent in parents_by_child.items():
        if field == "valid":
            parent_loads[(level, parent)] += 1
    if max(parent_loads.values()) > MAX_FANOUT:
        fail(case, f"an internal message node exceeds fanout {MAX_FANOUT}: {parent_loads}")

    reset_blocks = list(
        re.finditer(
            r"always @\(posedge \w+ or posedge ([A-Za-z0-9_]+)\) begin\n"
            r"(.*?)(?=\n  always @|\n\nendmodule)",
            module,
            re.DOTALL,
        )
    )
    reset_children: set[tuple[int, int]] = set()
    for block in reset_blocks:
        parent = block.group(1)
        children = {
            (int(level), int(node))
            for level, node in re.findall(r"reset_l(\d+)_n(\d+) <=", block.group(2))
        }
        if not children or len(children) > MAX_FANOUT:
            fail(case, f"reset parent {parent} drives {len(children)} release registers")
        reset_children.update(children)
    if reset_children != reset_nodes:
        fail(case, "not every reset node is driven by one bounded parent")

    print(
        f"{case}: {expected['consumers']} consumers, levels {dict(actual_levels)}, "
        f"message/reset fanout <= {MAX_FANOUT}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--d3", required=True, type=Path)
    parser.add_argument("--d9", required=True, type=Path)
    arguments = parser.parse_args()

    for case, path in (("d3", arguments.d3), ("d9", arguments.d9)):
        expected = CASES[case]
        inspect_distributed_dual(case, path, expected)
        inspect_fanout_module(case, path, expected)


if __name__ == "__main__":
    main()
