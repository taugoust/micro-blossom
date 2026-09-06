"""Bind the host wire identity to the selected, generated core manifest."""
import argparse
import json
import re
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("template", type=Path)
parser.add_argument("manifest", type=Path)
parser.add_argument("expected_graph")
parser.add_argument("output", type=Path)
args = parser.parse_args()
graph = json.loads(args.manifest.read_text())["graphSha256"]
if not isinstance(graph, str) or not re.fullmatch(r"[0-9a-f]{64}", graph):
    raise ValueError("Core manifest must contain a SHA256 graph identity")
if graph != args.expected_graph:
    raise ValueError("Selected graph and generated core manifest disagree")
template = args.template.read_text()
marker = "@MICROBLOSSOM_GRAPH_ID@"
if template.count(marker) != 1:
    raise ValueError("Expected one host graph identity placeholder")
# Wire byte zero is packed in the least-significant byte of the SV vector.
args.output.write_text(template.replace(marker, bytes.fromhex(graph)[::-1].hex()))
