#!/usr/bin/env python3
"""Generate bounded R5/QSH2 service constants from a frozen graph fixture."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

QSHELL_HEADER_BYTES = 48
QSHELL_BEAT_BYTES = 64
PROVIDER_STORAGE_BYTES = 4096
PROVIDER_MAX_BEATS = PROVIDER_STORAGE_BYTES // QSHELL_BEAT_BYTES
REQUEST_PREFIX_BYTES = 40
RESULT_PREFIX_BYTES = 44
UINT16_MAX = (1 << 16) - 1


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def packet_shape(payload_bytes: int) -> dict[str, int]:
    packet_bytes = QSHELL_HEADER_BYTES + payload_bytes
    beats = (packet_bytes + QSHELL_BEAT_BYTES - 1) // QSHELL_BEAT_BYTES
    final_beat_bytes = packet_bytes - (beats - 1) * QSHELL_BEAT_BYTES
    if packet_bytes > PROVIDER_STORAGE_BYTES or beats > PROVIDER_MAX_BEATS:
        raise ValueError(
            f"{packet_bytes}-byte/{beats}-beat packet exceeds provider storage"
        )
    return {
        "payloadBytes": payload_bytes,
        "packetBytes": packet_bytes,
        "beats": beats,
        "finalBeatBytes": final_beat_bytes,
    }


def byte_initializer(values: bytes) -> str:
    return ", ".join(f"UINT8_C(0x{value:02x})" for value in values)


def virtual_bitmap(vertex_count: int, virtual_vertices: list[int]) -> bytes:
    bitmap = bytearray((vertex_count + 7) // 8)
    for vertex in virtual_vertices:
        bitmap[vertex // 8] |= 1 << (vertex % 8)
    return bytes(bitmap)


def compact_vertex_bits(vertex_count: int) -> int:
    """Match DualConfig.fitGraph's node-index width, including its 5-bit floor."""
    return max(5, (2 * vertex_count - 1).bit_length())


def build_csr(
    vertex_count: int, weighted_edges: list[dict[str, int]]
) -> tuple[list[int], list[int]]:
    degrees = [0] * vertex_count
    seen_pairs: set[tuple[int, int]] = set()
    for edge in weighted_edges:
        left = edge["l"]
        right = edge["r"]
        if left == right:
            raise ValueError("materializer graph contains a self-loop")
        pair = (min(left, right), max(left, right))
        if pair in seen_pairs:
            raise ValueError("materializer graph contains parallel edges")
        seen_pairs.add(pair)
        degrees[left] += 1
        degrees[right] += 1

    row_offsets = [0] * (vertex_count + 1)
    for vertex, degree in enumerate(degrees):
        row_offsets[vertex + 1] = row_offsets[vertex] + degree
    arc_count = row_offsets[-1]
    if arc_count != 2 * len(weighted_edges) or arc_count > UINT16_MAX:
        raise ValueError("CSR arc offsets do not fit u16")

    cursors = row_offsets[:-1].copy()
    arc_edge_indices = [0] * arc_count
    for edge_index, edge in enumerate(weighted_edges):
        for vertex in (edge["l"], edge["r"]):
            arc_edge_indices[cursors[vertex]] = edge_index
            cursors[vertex] += 1
    for vertex in range(vertex_count):
        row = arc_edge_indices[row_offsets[vertex] : row_offsets[vertex + 1]]
        if any(left >= right for left, right in zip(row, row[1:])):
            raise ValueError("CSR adjacency is not in deterministic edge-index order")
    return row_offsets, arc_edge_indices


def rust_array(values: list[object], render, per_line: int) -> str:
    lines = []
    for offset in range(0, len(values), per_line):
        chunk = ", ".join(render(value) for value in values[offset : offset + per_line])
        lines.append(f"    {chunk},")
    return "\n".join(lines)


def write_rust_module(
    path: Path,
    contract: dict[str, object],
    weighted_edges: list[dict[str, int]],
    row_offsets: list[int],
    arc_edge_indices: list[int],
) -> None:
    graph = contract["graph"]
    protocol = contract["protocol"]
    request = protocol["request"]
    response = protocol["response"]
    materializer = graph["materializer"]
    graph_identity = bytes.fromhex(graph["sha256"])
    bitmap = virtual_bitmap(graph["vertexCount"], graph["virtualVertices"])

    edges = rust_array(
        weighted_edges,
        lambda edge: (
            f"WeightedEdge::new({edge['l']}, {edge['r']}, {edge['w']})"
        ),
        2,
    )
    offsets = rust_array(row_offsets, str, 12)
    adjacency = rust_array(arc_edge_indices, str, 12)
    identity = rust_array(list(graph_identity), lambda value: f"0x{value:02x}", 16)
    bitmap_values = rust_array(list(bitmap), lambda value: f"0x{value:02x}", 16)

    path.write_text(
        "// Generated from a frozen graph fixture; do not edit.\n"
        "\n"
        "#[repr(transparent)]\n"
        "#[derive(Clone, Copy)]\n"
        "pub struct WeightedEdge([u8; 5]);\n"
        "\n"
        "impl WeightedEdge {\n"
        "    pub const fn new(left: u16, right: u16, weight: u8) -> Self {\n"
        "        Self([\n"
        "            left as u8,\n"
        "            (left >> 8) as u8,\n"
        "            right as u8,\n"
        "            (right >> 8) as u8,\n"
        "            weight,\n"
        "        ])\n"
        "    }\n"
        "\n"
        "    pub const fn left(self) -> u16 {\n"
        "        u16::from_le_bytes([self.0[0], self.0[1]])\n"
        "    }\n"
        "\n"
        "    pub const fn right(self) -> u16 {\n"
        "        u16::from_le_bytes([self.0[2], self.0[3]])\n"
        "    }\n"
        "\n"
        "    pub const fn weight(self) -> u8 {\n"
        "        self.0[4]\n"
        "    }\n"
        "\n"
        "    pub const fn neighbor(self, vertex: u16) -> Option<u16> {\n"
        "        if self.left() == vertex {\n"
        "            Some(self.right())\n"
        "        } else if self.right() == vertex {\n"
        "            Some(self.left())\n"
        "        } else {\n"
        "            None\n"
        "        }\n"
        "    }\n"
        "}\n"
        "\n"
        f"pub const GRAPH_ID: &str = {json.dumps(contract['fixture']['id'])};\n"
        f"pub const GRAPH_SHA256: &str = {json.dumps(graph['sha256'])};\n"
        "pub const GRAPH_IDENTITY: [u8; 32] = [\n"
        f"{identity}\n"
        "];\n"
        f"pub const VERTEX_COUNT: usize = {graph['vertexCount']};\n"
        f"pub const EDGE_COUNT: usize = {graph['edgeCount']};\n"
        f"pub const VIRTUAL_VERTEX_COUNT: usize = {graph['virtualVertexCount']};\n"
        f"pub const NONVIRTUAL_VERTEX_COUNT: usize = {graph['nonvirtualVertexCount']};\n"
        f"pub const VIRTUAL_BITMAP_BYTES: usize = {len(bitmap)};\n"
        f"pub const VERTEX_BITS: usize = {graph['vertexBits']};\n"
        f"pub const NUM_LAYERS: u8 = {graph['numLayers']};\n"
        f"pub const NODE_CAPACITY: usize = {graph['nodeCapacity']};\n"
        f"pub const DEFECT_NODE_CAPACITY: usize = {graph['defectNodeCapacity']};\n"
        f"pub const MAX_DEFECTS: usize = {request['maxItems']};\n"
        f"pub const MAX_CORRECTION_EDGES: usize = {response['maxItems']};\n"
        f"pub const REQUEST_PAYLOAD_BYTES: usize = {request['payloadBytes']};\n"
        f"pub const REQUEST_PACKET_BYTES: usize = {request['packetBytes']};\n"
        f"pub const REQUEST_BEATS: usize = {request['beats']};\n"
        f"pub const REQUEST_FINAL_BEAT_BYTES: usize = {request['finalBeatBytes']};\n"
        f"pub const RESPONSE_PAYLOAD_BYTES: usize = {response['payloadBytes']};\n"
        f"pub const RESPONSE_PACKET_BYTES: usize = {response['packetBytes']};\n"
        f"pub const RESPONSE_BEATS: usize = {response['beats']};\n"
        f"pub const RESPONSE_FINAL_BEAT_BYTES: usize = {response['finalBeatBytes']};\n"
        f"pub const PACKET_STORAGE_BYTES: usize = {protocol['storageBytes']};\n"
        f"pub const MAX_PACKET_BEATS: usize = {protocol['maxPacketBeats']};\n"
        f"pub const ARC_COUNT: usize = {materializer['arcCount']};\n"
        f"pub const SIMPLE_PATH_DISTANCE_UPPER_BOUND: u16 = {materializer['simplePathDistanceUpperBound']};\n"
        f"pub const TOTAL_EDGE_WEIGHT: u32 = {materializer['totalEdgeWeight']};\n"
        f"pub const GRAPH_RODATA_BYTES: usize = {materializer['rodataBytes']};\n"
        f"pub const MATERIALIZER_FIXED_ARRAY_BYTES: usize = {materializer['fixedArrayBytes']};\n"
        f"pub const MATERIALIZER_ALIGNED_ARRAY_BYTES: usize = {materializer['alignedArrayBytes']};\n"
        f"pub const MATERIALIZER_PROJECTED_WORKSPACE_BYTES: usize = {materializer['projectedWorkspaceBytes']};\n"
        "\n"
        "#[used]\n"
        "pub static VIRTUAL_VERTEX_BITMAP: [u8; VIRTUAL_BITMAP_BYTES] = [\n"
        f"{bitmap_values}\n"
        "];\n"
        "\n"
        "#[used]\n"
        "pub static WEIGHTED_EDGES: [WeightedEdge; EDGE_COUNT] = [\n"
        f"{edges}\n"
        "];\n"
        "\n"
        "#[used]\n"
        "pub static CSR_ROW_OFFSETS: [u16; VERTEX_COUNT + 1] = [\n"
        f"{offsets}\n"
        "];\n"
        "\n"
        "#[used]\n"
        "pub static CSR_EDGE_INDICES: [u16; ARC_COUNT] = [\n"
        f"{adjacency}\n"
        "];\n"
        "\n"
        "pub fn is_virtual(vertex: u16) -> bool {\n"
        "    let vertex = vertex as usize;\n"
        "    vertex < VERTEX_COUNT\n"
        "        && (VIRTUAL_VERTEX_BITMAP[vertex / 8] & (1u8 << (vertex % 8))) != 0\n"
        "}\n"
        "\n"
        "const _: [(); 5] = [(); core::mem::size_of::<WeightedEdge>()];\n"
        "const _: [(); 1] = [(); core::mem::align_of::<WeightedEdge>()];\n"
        "const _: () = assert!(NODE_CAPACITY == (1usize << VERTEX_BITS));\n"
        "const _: () = assert!(DEFECT_NODE_CAPACITY == NODE_CAPACITY / 2);\n"
        "const _: () = assert!(VERTEX_COUNT <= DEFECT_NODE_CAPACITY);\n"
        "const _: () = assert!(MAX_DEFECTS <= DEFECT_NODE_CAPACITY);\n"
        "const _: () = assert!(EDGE_COUNT < u16::MAX as usize);\n"
        "const _: () = assert!(ARC_COUNT == EDGE_COUNT * 2);\n"
        "const _: () = assert!(ARC_COUNT <= u16::MAX as usize);\n"
        "const _: () = assert!(SIMPLE_PATH_DISTANCE_UPPER_BOUND < u16::MAX);\n"
        "const _: () = assert!(REQUEST_PACKET_BYTES <= PACKET_STORAGE_BYTES);\n"
        "const _: () = assert!(RESPONSE_PACKET_BYTES <= PACKET_STORAGE_BYTES);\n"
        "const _: [(); GRAPH_RODATA_BYTES] = [();\n"
        "    core::mem::size_of::<WeightedEdge>() * EDGE_COUNT\n"
        "        + core::mem::size_of::<u16>() * (VERTEX_COUNT + 1)\n"
        "        + core::mem::size_of::<u16>() * ARC_COUNT\n"
        "        + VIRTUAL_BITMAP_BYTES\n"
        "];\n"
    )


def write_header(path: Path, contract: dict[str, object]) -> None:
    graph = contract["graph"]
    protocol = contract["protocol"]
    request = protocol["request"]
    response = protocol["response"]
    graph_id = bytes.fromhex(graph["sha256"])
    bitmap = virtual_bitmap(graph["vertexCount"], graph["virtualVertices"])

    path.write_text(
        "#ifndef MICROBLOSSOM_GRAPH_CONTRACT_H\n"
        "#define MICROBLOSSOM_GRAPH_CONTRACT_H\n\n"
        "/* Generated from a frozen graph fixture; do not edit. */\n"
        "#include <stdint.h>\n\n"
        f"#define MICROBLOSSOM_GRAPH_CONTRACT_VERSION UINT16_C({contract['schemaVersion']})\n"
        f"#define MICROBLOSSOM_GRAPH_ID \"{contract['fixture']['id']}\"\n"
        f"#define MICROBLOSSOM_GRAPH_SHA256 \"{graph['sha256']}\"\n"
        f"#define MICROBLOSSOM_GRAPH_VERTEX_COUNT UINT16_C({graph['vertexCount']})\n"
        f"#define MICROBLOSSOM_GRAPH_EDGE_COUNT UINT16_C({graph['edgeCount']})\n"
        f"#define MICROBLOSSOM_GRAPH_VIRTUAL_VERTEX_COUNT UINT16_C({graph['virtualVertexCount']})\n"
        f"#define MICROBLOSSOM_GRAPH_NONVIRTUAL_VERTEX_COUNT UINT16_C({graph['nonvirtualVertexCount']})\n"
        f"#define MICROBLOSSOM_GRAPH_VERTEX_BITS UINT16_C({graph['vertexBits']})\n"
        f"#define MICROBLOSSOM_GRAPH_NUM_LAYERS UINT8_C({graph['numLayers']})\n"
        f"#define MICROBLOSSOM_GRAPH_NODE_CAPACITY UINT16_C({graph['nodeCapacity']})\n"
        f"#define MICROBLOSSOM_GRAPH_DEFECT_NODE_CAPACITY UINT16_C({graph['defectNodeCapacity']})\n"
        f"#define MICROBLOSSOM_GRAPH_RODATA_BYTES UINT32_C({graph['materializer']['rodataBytes']})\n"
        f"#define MICROBLOSSOM_MATERIALIZER_WORKSPACE_BYTES UINT32_C({graph['materializer']['projectedWorkspaceBytes']})\n"
        f"#define MICROBLOSSOM_VIRTUAL_VERTEX_BITMAP_BYTES UINT16_C({len(bitmap)})\n"
        f"#define MICROBLOSSOM_FIRST_VIRTUAL_VERTEX UINT16_C({graph['virtualVertices'][0]})\n"
        f"#define MICROBLOSSOM_EXACT_GRAPH_CAPACITY UINT16_C({int(protocol['capacityMode'] == 'exact-graph')})\n"
        f"#define MICROBLOSSOM_MAX_DEFECTS UINT16_C({request['maxItems']})\n"
        f"#define MICROBLOSSOM_MAX_CORRECTION_EDGES UINT16_C({response['maxItems']})\n"
        f"#define MICROBLOSSOM_REQUEST_PAYLOAD_BYTES UINT32_C({request['payloadBytes']})\n"
        f"#define MICROBLOSSOM_REQUEST_PACKET_BYTES UINT32_C({request['packetBytes']})\n"
        f"#define MICROBLOSSOM_REQUEST_BEATS UINT16_C({request['beats']})\n"
        f"#define MICROBLOSSOM_REQUEST_FINAL_BEAT_BYTES UINT16_C({request['finalBeatBytes']})\n"
        f"#define MICROBLOSSOM_RESPONSE_PAYLOAD_BYTES UINT32_C({response['payloadBytes']})\n"
        f"#define MICROBLOSSOM_RESPONSE_PACKET_BYTES UINT32_C({response['packetBytes']})\n"
        f"#define MICROBLOSSOM_RESPONSE_BEATS UINT16_C({response['beats']})\n"
        f"#define MICROBLOSSOM_RESPONSE_FINAL_BEAT_BYTES UINT16_C({response['finalBeatBytes']})\n"
        f"#define MICROBLOSSOM_MAX_PACKET_BEATS UINT16_C({protocol['maxPacketBeats']})\n"
        f"#define MICROBLOSSOM_PACKET_STORAGE_BYTES UINT32_C({protocol['storageBytes']})\n"
        f"#define MICROBLOSSOM_FIRST_NONVIRTUAL_VERTEX UINT16_C({graph['firstNonvirtualVertex']})\n"
        f"#define MICROBLOSSOM_SMOKE_DEFECT_VERTEX UINT16_C({graph['firstNonvirtualVertex']})\n"
        f"#define MICROBLOSSOM_SMOKE_CORRECTION_EDGE UINT16_C({graph['smokeCorrectionEdge']})\n"
        f"#define MICROBLOSSOM_GRAPH_IDENTITY_INITIALIZER {{{byte_initializer(graph_id)}}}\n\n"
        f"static const uint8_t microblossom_graph_identity[32] = {{{byte_initializer(graph_id)}}};\n"
        f"static const uint8_t microblossom_virtual_vertex_bitmap[{len(bitmap)}] = "
        f"{{{byte_initializer(bitmap)}}};\n\n"
        "#endif\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--graph", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-defects", type=int)
    parser.add_argument("--max-correction-edges", type=int)
    args = parser.parse_args()

    graph = json.loads(args.graph.read_text())
    manifest = json.loads(args.manifest.read_text())
    if not isinstance(graph, dict) or not isinstance(manifest, dict):
        raise ValueError("graph and manifest must be JSON objects")
    generated = manifest["generated"]
    source_fixture = manifest["fixture"]
    fixture_id = source_fixture.get("id", source_fixture.get("fixtureId"))
    if not isinstance(fixture_id, str) or not fixture_id:
        raise ValueError("fixture manifest omits its identity")
    fixture = {
        "id": fixture_id,
        "family": source_fixture.get("family", source_fixture.get("code", {}).get("family")),
        "distance": source_fixture.get("distance", source_fixture.get("code", {}).get("distance")),
        "physicalErrorRate": source_fixture.get("physicalErrorRate"),
        "maxHalfWeight": source_fixture.get("maxHalfWeight"),
        "measurementRounds": source_fixture.get("measurementRounds"),
    }
    graph_hash = sha256(args.graph)
    if re.fullmatch(r"[0-9a-f]{64}", graph_hash) is None:
        raise ValueError("graph identity is not a lowercase SHA-256 digest")

    vertex_count = graph["vertex_num"]
    weighted_edges = graph["weighted_edges"]
    if not isinstance(weighted_edges, list) or any(
        not isinstance(edge, dict)
        or not {"l", "r", "w"}.issubset(edge)
        or not all(isinstance(edge[field], int) for field in ("l", "r", "w"))
        for edge in weighted_edges
    ):
        raise ValueError("weighted edge list is malformed")
    edge_count = len(weighted_edges)
    virtual_vertices = graph["virtual_vertices"]
    layer_fusion = graph.get("layer_fusion")
    if layer_fusion is None:
        num_layers = 0
    elif (
        isinstance(layer_fusion, dict)
        and isinstance(layer_fusion.get("num_layers"), int)
        and 0 <= layer_fusion["num_layers"] <= 0xFF
    ):
        num_layers = layer_fusion["num_layers"]
    else:
        raise ValueError("graph layer count does not fit the hardware-info register")
    if not isinstance(vertex_count, int) or not 0 < vertex_count <= UINT16_MAX:
        raise ValueError("vertex count does not fit the protocol")
    if not 0 < edge_count <= UINT16_MAX:
        raise ValueError("edge count does not fit the protocol")
    if (
        not isinstance(virtual_vertices, list)
        or any(not isinstance(vertex, int) for vertex in virtual_vertices)
        or sorted(set(virtual_vertices)) != virtual_vertices
        or any(vertex < 0 or vertex >= vertex_count for vertex in virtual_vertices)
    ):
        raise ValueError("virtual vertex list is not sorted, unique, and in range")
    if (
        graph_hash != generated["graphSha256"]
        or vertex_count != generated["vertexNum"]
        or edge_count != generated["edgeNum"]
        or len(virtual_vertices) != generated["virtualVertexNum"]
    ):
        raise ValueError("graph does not match its frozen generation manifest")
    if any(
        edge["l"] < 0
        or edge["l"] >= vertex_count
        or edge["r"] < 0
        or edge["r"] >= vertex_count
        or not 0 < edge["w"] <= 0xFF
        for edge in weighted_edges
    ):
        raise ValueError("weighted edge endpoint or positive u8 weight is out of range")

    row_offsets, arc_edge_indices = build_csr(vertex_count, weighted_edges)
    visited = {0}
    pending = [0]
    while pending:
        vertex = pending.pop()
        for edge_index in arc_edge_indices[
            row_offsets[vertex] : row_offsets[vertex + 1]
        ]:
            edge = weighted_edges[edge_index]
            neighbor = edge["r"] if edge["l"] == vertex else edge["l"]
            if neighbor not in visited:
                visited.add(neighbor)
                pending.append(neighbor)
    if len(visited) != vertex_count:
        raise ValueError("materializer graph is disconnected")

    virtual_set = set(virtual_vertices)
    nonvirtual_vertices = [
        vertex for vertex in range(vertex_count) if vertex not in virtual_set
    ]
    if not nonvirtual_vertices:
        raise ValueError("service graph has no admissible defect vertices")
    first_nonvirtual = nonvirtual_vertices[0]
    boundary_edges = [
        (edge["w"], index)
        for index, edge in enumerate(weighted_edges)
        if (edge["l"] == first_nonvirtual and edge["r"] in virtual_set)
        or (edge["r"] == first_nonvirtual and edge["l"] in virtual_set)
    ]
    if not boundary_edges:
        raise ValueError("first non-virtual vertex has no direct boundary edge")
    smoke_correction_edge = min(boundary_edges)[1]

    max_defects = (
        len(nonvirtual_vertices) if args.max_defects is None else args.max_defects
    )
    max_correction_edges = (
        edge_count
        if args.max_correction_edges is None
        else args.max_correction_edges
    )
    if not len(nonvirtual_vertices) <= max_defects <= vertex_count:
        raise ValueError(
            "defect capacity must cover every non-virtual vertex and fit the graph"
        )
    if not 0 < max_correction_edges <= edge_count:
        raise ValueError("correction capacity must be nonzero and fit the graph")

    vertex_bits = compact_vertex_bits(vertex_count)
    node_capacity = 1 << vertex_bits
    defect_node_capacity = node_capacity // 2
    if vertex_bits > 15 or vertex_count > defect_node_capacity:
        raise ValueError("graph does not fit the compact accelerator node width")
    if max_defects > defect_node_capacity:
        raise ValueError("defect capacity exceeds the compact primal node partition")
    maximum_edge_weight = max(edge["w"] for edge in weighted_edges)
    simple_path_distance_upper_bound = (vertex_count - 1) * maximum_edge_weight
    if simple_path_distance_upper_bound >= UINT16_MAX:
        raise ValueError("simple-path distance does not fit u16")
    total_edge_weight = sum(edge["w"] for edge in weighted_edges)
    bitmap_bytes = (vertex_count + 7) // 8
    correction_bitmap_bytes = (edge_count + 7) // 8
    fixed_array_bytes = 3 * vertex_count * 2 + bitmap_bytes + correction_bitmap_bytes
    aligned_array_bytes = (fixed_array_bytes + 7) // 8 * 8
    projected_workspace_bytes = aligned_array_bytes + 32
    graph_rodata_bytes = (
        5 * edge_count
        + 2 * len(row_offsets)
        + 2 * len(arc_edge_indices)
        + bitmap_bytes
    )
    exact_graph_capacity = (
        max_defects == len(nonvirtual_vertices) and max_correction_edges == edge_count
    )

    request = packet_shape(REQUEST_PREFIX_BYTES + 2 * max_defects)
    request.update(
        {
            "schema": "microblossom_decode_request",
            "item": "defectVertex",
            "maxItems": max_defects,
            "admissibleItems": len(nonvirtual_vertices),
        }
    )
    response = packet_shape(RESULT_PREFIX_BYTES + 2 * max_correction_edges)
    response.update(
        {
            "schema": "microblossom_decode_result",
            "item": "correctionEdge",
            "maxItems": max_correction_edges,
            "admissibleItems": edge_count,
        }
    )
    contract = {
        "schemaVersion": 1,
        "serviceAbi": "microblossom-coprocessor/v1",
        "fixture": fixture,
        "graph": {
            "sha256": graph_hash,
            "manifestSha256": sha256(args.manifest),
            "vertexCount": vertex_count,
            "edgeCount": edge_count,
            "virtualVertexCount": len(virtual_vertices),
            "virtualVertices": virtual_vertices,
            "virtualVertexBitmapHex": virtual_bitmap(
                vertex_count, virtual_vertices
            ).hex(),
            "nonvirtualVertexCount": len(nonvirtual_vertices),
            "firstNonvirtualVertex": first_nonvirtual,
            "smokeCorrectionEdge": smoke_correction_edge,
            "vertexBits": vertex_bits,
            "numLayers": num_layers,
            "nodeCapacity": node_capacity,
            "defectNodeCapacity": defect_node_capacity,
            "materializer": {
                "algorithm": "bounded-csr-dijkstra-xor-edge-bitmap",
                "arcCount": len(arc_edge_indices),
                "csrOrder": "ascending-edge-index-per-vertex",
                "weightedEdgeBytes": 5,
                "simplePathDistanceUpperBound": simple_path_distance_upper_bound,
                "totalEdgeWeight": total_edge_weight,
                "rodataBytes": graph_rodata_bytes,
                "fixedArrayBytes": fixed_array_bytes,
                "alignedArrayBytes": aligned_array_bytes,
                "scalarControlAllowanceBytes": 32,
                "projectedWorkspaceBytes": projected_workspace_bytes,
            },
        },
        "protocol": {
            "qshellAbi": 2,
            "headerBytes": QSHELL_HEADER_BYTES,
            "beatBytes": QSHELL_BEAT_BYTES,
            "storageBytes": PROVIDER_STORAGE_BYTES,
            "providerMaxPacketBeats": PROVIDER_MAX_BEATS,
            "maxPacketBeats": max(request["beats"], response["beats"]),
            "fixedCapacityPayloads": True,
            "capacityMode": (
                "exact-graph" if exact_graph_capacity else "legacy-compatible"
            ),
            "request": request,
            "response": response,
        },
    }

    args.output.mkdir(parents=True, exist_ok=True)
    contract_path = args.output / "graph-service-contract.json"
    contract_path.write_text(json.dumps(contract, indent=2, sort_keys=True) + "\n")
    write_header(args.output / "microblossom_graph_contract.h", contract)
    write_rust_module(
        args.output / "microblossom_graph.rs",
        contract,
        weighted_edges,
        row_offsets,
        arc_edge_indices,
    )


if __name__ == "__main__":
    main()
