#!/usr/bin/env python3
"""Bind graph, routed application, shell, and firmware identities into a bundle."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import jsonschema


def identity(value: str, name: str) -> str:
    if re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError(f"{name} must be a lowercase SHA-256 identity")
    return value


def revision(value: str, name: str) -> str:
    if re.fullmatch(r"[0-9a-f]{40}", value) is None:
        raise ValueError(f"{name} must be a Git revision")
    return value


def fixture_name(identifier: str) -> str:
    return identifier[:-3] if identifier.endswith("-v1") else identifier


def require_graph_application(application: dict[str, object], graph_id: str) -> None:
    try:
        application_graph = application["provenance"]["caller"]["graphSha256"]
    except (KeyError, TypeError) as error:
        raise ValueError("application metadata omits its caller graph identity") from error
    if application_graph != graph_id:
        raise ValueError("application and service graph identities differ")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--graph-contract", type=Path, required=True)
    parser.add_argument("--schema", type=Path, required=True)
    parser.add_argument("--abi-spec", type=Path, required=True)
    parser.add_argument("--application-metadata", type=Path, required=True)
    parser.add_argument("--firmware-metadata", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--qshell-revision", required=True)
    parser.add_argument("--coyote-revision", required=True)
    parser.add_argument("--coyote-nix-revision", required=True)
    parser.add_argument("--implementation-revision", required=True)
    args = parser.parse_args()

    contract = json.loads(args.template.read_text())
    graph_contract = json.loads(args.graph_contract.read_text())
    schema = json.loads(args.schema.read_text())
    abi_spec = json.loads(args.abi_spec.read_text())
    application = json.loads(args.application_metadata.read_text())
    firmware = json.loads(args.firmware_metadata.read_text())

    if graph_contract.get("schemaVersion") != 1:
        raise ValueError("unsupported graph service contract")
    graph = graph_contract["graph"]
    protocol = graph_contract["protocol"]
    fixture = graph_contract["fixture"]
    graph_id = identity(graph["sha256"], "graph ID")
    if (
        graph_contract.get("serviceAbi") != "microblossom-coprocessor/v1"
        or protocol.get("qshellAbi") != abi_spec["version"]
        or protocol.get("headerBytes") != abi_spec["header_bytes"]
        or protocol.get("beatBytes") != abi_spec["beat_bytes"]
        or protocol.get("storageBytes") != 4096
        or protocol.get("providerMaxPacketBeats") != 64
    ):
        raise ValueError("graph service and current QShell contracts differ")

    fixture_id = fixture_name(fixture["id"])
    firmware_abi = f"microblossom-{fixture_id}-coprocessor-v1"
    if firmware.get("firmwareAbi") != firmware_abi:
        raise ValueError("firmware ABI does not match the graph service")
    runtime_identity = identity(firmware["runtimeIdentity"], "runtime identity")

    application_id = identity(application["application"]["id"], "application ID")
    shell_id = identity(
        application["shell"]["compatibilityId"], "shell compatibility ID"
    )
    require_graph_application(application, graph_id)

    record_abi = abi_spec["version"]
    request_schema = abi_spec["schemas"]["microblossom_decode_request"]
    result_schema = abi_spec["schemas"]["microblossom_decode_result"]
    request = protocol["request"]
    response = protocol["response"]

    contract["service"]["name"] = f"microblossom-{fixture_id}-r5"
    contract["qec"]["code_family"] = fixture["family"]
    contract["qec"]["problem_sizes"] = [fixture["distance"]]
    contract["syndrome_interface"].update(
        {
            "schema_id": request_schema,
            "schema_name": f"microblossom-{fixture_id}-decode-request",
            "max_payload_bytes": request["payloadBytes"],
        }
    )
    contract["correction_interface"].update(
        {
            "schema_id": result_schema,
            "schema_name": f"microblossom-{fixture_id}-decode-result",
            "max_payload_bytes": response["payloadBytes"],
        }
    )
    contract["placement"]["bitstream_id"] = application_id
    contract["auxiliary"]["coprocessor"].update(
        {
            "firmware_abi": firmware_abi,
            "image_identity": runtime_identity,
            "max_packet_beats": protocol["maxPacketBeats"],
        }
    )
    contract["provenance"].update(
        {
            "record_abi": record_abi,
            "shell_compatibility_id": shell_id,
            "source_revision": revision(
                args.implementation_revision, "MicroBlossom implementation revision"
            ),
        }
    )
    jsonschema.Draft202012Validator(schema).validate(contract)

    dependencies = {
        "qshell": revision(args.qshell_revision, "QShell revision"),
        "coyote": revision(args.coyote_revision, "Coyote revision"),
        "coyoteNix": revision(args.coyote_nix_revision, "coyote-nix revision"),
        "microblossomImplementation": contract["provenance"]["source_revision"],
    }
    manifest = {
        "api": "microblossom.v80-coprocessor-bundle/v1",
        "fixture": fixture_id,
        "graphSha256": graph_id,
        "graphManifestSha256": identity(
            graph["manifestSha256"], "graph manifest ID"
        ),
        "identities": {
            "application": application_id,
            "shellCompatibility": shell_id,
            "firmwareRuntime": runtime_identity,
        },
        "dependencies": dependencies,
        "abi": {
            "qshellRecord": record_abi,
            "requestSchema": request_schema,
            "resultSchema": result_schema,
            "logicalPort": 0,
            "stream": 1,
            "mmio": 1,
            "applicationMmio": f"microblossom-{fixture_id}-accelerator-v1",
            "providerFirmware": firmware_abi,
            "packetStorageBytes": protocol["storageBytes"],
            "providerMaxPacketBeats": protocol["providerMaxPacketBeats"],
            "request": {
                "payloadBytes": request["payloadBytes"],
                "packetBytes": request["packetBytes"],
                "beats": request["beats"],
                "finalBeatBytes": request["finalBeatBytes"],
            },
            "response": {
                "payloadBytes": response["payloadBytes"],
                "packetBytes": response["packetBytes"],
                "beats": response["beats"],
                "finalBeatBytes": response["finalBeatBytes"],
            },
        },
        "resourceReservation": "pre-route-conservative",
        "physicalAcceptance": False,
        "imageCompositionIncluded": False,
    }
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "decoder-contract.json").write_text(
        json.dumps(contract, indent=2) + "\n"
    )
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
