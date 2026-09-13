"""Public renderer input validation and wire-byte ordering."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

renderer = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    template = root / "template.svh"
    manifest = root / "manifest.json"
    output = root / "output.svh"
    graph = bytes(range(32)).hex()

    def render(identity, expected=graph, text="256'h@MICROBLOSSOM_GRAPH_ID@"):
        template.write_text(text)
        manifest.write_text(json.dumps({"graphSha256": identity}))
        output.write_text("unchanged")
        result = subprocess.run(
            [sys.executable, str(renderer), str(template), str(manifest), expected, str(output)],
            capture_output=True,
        )
        return result.returncode

    assert render(graph) == 0
    packed = output.read_text().removeprefix("256'h")
    assert int(packed, 16).to_bytes(32, "little") == bytes(range(32))
    for invalid in [None, 12, "", "0" * 63, "g" * 64, "A" * 64]:
        assert render(invalid) != 0
        assert output.read_text() == "unchanged"
    assert render(graph, "ff" * 32) != 0
    assert output.read_text() == "unchanged"
    for text in ["no marker", "@MICROBLOSSOM_GRAPH_ID@@MICROBLOSSOM_GRAPH_ID@"]:
        assert render(graph, text=text) != 0
        assert output.read_text() == "unchanged"
print("HOST_GRAPH_RENDERER_PASS")
