#!/usr/bin/env python3

import argparse
import collections
import re
from pathlib import Path

MAX_FANOUT = 32
CASES = {
    "d3": {"consumers": 58, "local_reset_consumers": 19},
    "d9": {"consumers": 2170, "local_reset_consumers": 2170},
}


def fail(case: str, message: str) -> None:
    raise AssertionError(f"{case}: {message}")


def ceil_div(value: int, divisor: int) -> int:
    return (value + divisor - 1) // divisor


def message_level_widths(consumer_count: int) -> list[int]:
    if consumer_count <= MAX_FANOUT:
        return []
    widths_from_leaves = [ceil_div(consumer_count, MAX_FANOUT)]
    while widths_from_leaves[-1] > MAX_FANOUT:
        widths_from_leaves.append(ceil_div(widths_from_leaves[-1], MAX_FANOUT))
    return list(reversed(widths_from_leaves))


def minimum_reset_leaf_max_consumers(consumer_count: int, depth: int) -> int:
    return ceil_div(consumer_count, MAX_FANOUT**depth)


def fixed_depth_widths(leaf_count: int, depth: int) -> list[int]:
    if leaf_count > MAX_FANOUT**depth:
        raise AssertionError(
            f"{leaf_count} leaves cannot fit in {depth} levels at fanout {MAX_FANOUT}"
        )
    if depth == 0:
        return []
    widths = [1] * depth
    widths[-1] = leaf_count
    for level in range(depth - 2, -1, -1):
        widths[level] = ceil_div(widths[level + 1], MAX_FANOUT)
    return widths


def inspect_distributed_dual(case: str, path: Path, expected: dict[str, int]) -> None:
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

    expected_message_leaves = ceil_div(expected["consumers"], MAX_FANOUT)
    if len(message_loads) != expected_message_leaves:
        fail(case, f"found {len(message_loads)} used message leaves")
    if min(message_loads.values()) <= 0 or max(message_loads.values()) > MAX_FANOUT:
        fail(case, f"message leaf loads are outside 1..{MAX_FANOUT}: {message_loads}")

    message_depth = len(message_level_widths(expected["consumers"]))
    reset_leaf_max_consumers = minimum_reset_leaf_max_consumers(expected["consumers"], message_depth)
    expected_reset_leaves = ceil_div(expected["consumers"], reset_leaf_max_consumers)
    reset_loads: collections.Counter[int] = collections.Counter()
    for consumer_index, nets in enumerate(consumer_reset_nets):
        local_leaves = {reset_assignments[net] for net in nets if net in reset_assignments}
        if len(local_leaves) > 1:
            fail(case, f"a consumer uses multiple local resets {sorted(local_leaves)}")
        for leaf in local_leaves:
            expected_leaf = consumer_index // reset_leaf_max_consumers
            if leaf != expected_leaf:
                fail(case, f"consumer {consumer_index} uses reset leaf {leaf}, expected {expected_leaf}")
            if leaf >= expected_reset_leaves:
                fail(case, f"consumer {consumer_index} uses out-of-range reset leaf {leaf}")
            reset_loads[leaf] += 1
    if sum(reset_loads.values()) != expected["local_reset_consumers"]:
        fail(case, f"found local reset connections for {sum(reset_loads.values())} consumers")
    if reset_loads and max(reset_loads.values()) > reset_leaf_max_consumers:
        fail(
            case,
            f"local reset hierarchy groups exceed {reset_leaf_max_consumers}: {reset_loads}",
        )
    # A leaf assigned only to combinational graph hierarchies legally has no sink pin.


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


def inspect_fanout_module(case: str, path: Path, expected: dict[str, int]) -> None:
    module = module_text(path, "DistributedDualControlFanout")
    message_widths = message_level_widths(expected["consumers"])
    depth = len(message_widths)
    expected_message_leaves = message_widths[-1] if message_widths else 1
    reset_leaf_max_consumers = minimum_reset_leaf_max_consumers(expected["consumers"], depth)
    expected_reset_leaves = ceil_div(expected["consumers"], reset_leaf_max_consumers)
    reset_widths = fixed_depth_widths(expected_reset_leaves, depth)

    leaf_outputs = set(re.findall(r"output\s+io_leafMessages_(\d+)_valid", module))
    if len(leaf_outputs) != expected_message_leaves:
        fail(case, f"found {len(leaf_outputs)} message leaf outputs")

    reset_output = re.search(r"output\s+(?:reg\s+)?(?:\[(\d+):0\]\s+)?io_leafResets[,;]", module)
    if reset_output is None:
        fail(case, "distributed reset leaf output is absent")
    reset_output_width = int(reset_output.group(1)) + 1 if reset_output.group(1) else 1
    if reset_output_width != expected_reset_leaves:
        fail(case, f"found {reset_output_width} reset leaf outputs")

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

    message_nodes = nodes_by_field["valid"]
    actual_message_levels = collections.Counter(level for level, _ in message_nodes)
    expected_message_levels = {level: width for level, width in enumerate(message_widths)}
    if dict(actual_message_levels) != expected_message_levels:
        fail(case, f"message levels are {dict(actual_message_levels)}, expected {expected_message_levels}")

    reset_nodes = {
        (int(level), int(node))
        for level, node in re.findall(r"\breg\s+reset_l(\d+)_n(\d+);", module)
    }
    actual_reset_levels = collections.Counter(level for level, _ in reset_nodes)
    expected_reset_levels = {level: width for level, width in enumerate(reset_widths)}
    if dict(actual_reset_levels) != expected_reset_levels:
        fail(case, f"reset levels are {dict(actual_reset_levels)}, expected {expected_reset_levels}")
    if len(actual_reset_levels) != len(actual_message_levels):
        fail(case, "message and reset distributions do not have equal depth")

    for line in module.splitlines():
        if re.search(
            r"\breg\s+(?:\[[^]]+\]\s+)?"
            r"(?:message_l\d+_n\d+_(?:valid|instruction|isReset)|reset_l\d+_n\d+);$",
            line,
        ):
            for attribute in ('keep = "true"', 'dont_touch = "true"', f"max_fanout = {MAX_FANOUT}"):
                if attribute not in line:
                    fail(case, f"distribution register omits {attribute}: {line.strip()}")

    parents_by_child: dict[tuple[int, int, str], str] = {}
    for level, node, field, parent in re.findall(
        r"message_l(\d+)_n(\d+)_(valid|instruction|isReset) <= ([A-Za-z0-9_]+)",
        module,
    ):
        field_suffix = f"_{field}"
        if not parent.endswith(field_suffix):
            fail(case, f"message node l{level}/n{node} field {field} has mismatched parent {parent}")
        parents_by_child[(int(level), int(node), field)] = parent[: -len(field_suffix)]
    for level, node in message_nodes:
        field_parents = {
            parents_by_child.get((level, node, field))
            for field in ("valid", "instruction", "isReset")
        }
        if None in field_parents or len(field_parents) != 1:
            fail(case, f"message node l{level}/n{node} does not copy one complete parent bundle")

    message_parent_loads: collections.Counter[tuple[int, str]] = collections.Counter()
    for (level, _node, field), parent in parents_by_child.items():
        if field == "valid":
            message_parent_loads[(level, parent)] += 1
    if message_parent_loads and max(message_parent_loads.values()) > MAX_FANOUT:
        fail(case, f"an internal message node exceeds fanout {MAX_FANOUT}: {message_parent_loads}")

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
        for level, node in children:
            expected_parent = "sourceReset" if level == 0 else f"reset_l{level - 1}_n{node // MAX_FANOUT}"
            if parent != expected_parent:
                fail(case, f"reset node l{level}/n{node} has parent {parent}, expected {expected_parent}")
        reset_children.update(children)
    if reset_children != reset_nodes:
        fail(case, "not every reset node is driven by one bounded parent")

    reset_leaf_assignments = {
        int(index): (int(level), int(node))
        for index, level, node in re.findall(
            r"io_leafResets\[(\d+)\] = reset_l(\d+)_n(\d+);",
            module,
        )
    }
    expected_reset_assignments = {
        index: (depth - 1, index) for index in range(expected_reset_leaves)
    }
    if reset_leaf_assignments != expected_reset_assignments:
        fail(case, "reset leaf outputs do not map one-to-one to the final same-depth stage")

    print(
        f"{case}: {expected['consumers']} graph hierarchies, "
        f"message levels {message_widths}, reset levels {reset_widths}, "
        f"reset groups <= {reset_leaf_max_consumers}, internal fanout <= {MAX_FANOUT}"
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
