#!/usr/bin/env python3
"""Bind routed application, shell, and firmware identities into a QShell bundle."""

import argparse
import json
import re
from pathlib import Path

import jsonschema

GRAPH_SHA256 = "4b078d3b6c6db24ea9726414569a97b3899be4e532be1c0ebd84b5fa875316c5"


def identity(value: str, name: str) -> str:
    if re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError(f"{name} must be a lowercase SHA-256 identity")
    return value


def revision(value: str, name: str) -> str:
    if re.fullmatch(r"[0-9a-f]{40}", value) is None:
        raise ValueError(f"{name} must be a Git revision")
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--schema", type=Path, required=True)
    parser.add_argument("--abi-spec", type=Path, required=True)
    parser.add_argument("--application-metadata", type=Path, required=True)
    parser.add_argument("--runtime-identity", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--qshell-revision", required=True)
    parser.add_argument("--coyote-revision", required=True)
    parser.add_argument("--coyote-nix-revision", required=True)
    parser.add_argument("--implementation-revision", required=True)
    args = parser.parse_args()

    contract = json.loads(args.template.read_text())
    schema = json.loads(args.schema.read_text())
    abi_spec = json.loads(args.abi_spec.read_text())
    record_abi = abi_spec["version"]
    request_schema = abi_spec["schemas"]["microblossom_decode_request"]
    result_schema = abi_spec["schemas"]["microblossom_decode_result"]
    contract["syndrome_interface"]["schema_id"] = request_schema
    contract["correction_interface"]["schema_id"] = result_schema
    contract["provenance"]["record_abi"] = record_abi
    application = json.loads(args.application_metadata.read_text())
    application_id = identity(application["application"]["id"], "application ID")
    shell_id = identity(application["shell"]["compatibilityId"], "shell compatibility ID")
    runtime_identity = identity(args.runtime_identity.read_text().strip(), "runtime identity")

    contract["placement"]["bitstream_id"] = application_id
    contract["auxiliary"]["coprocessor"]["image_identity"] = runtime_identity
    contract["provenance"]["shell_compatibility_id"] = shell_id
    jsonschema.Draft202012Validator(schema).validate(contract)

    dependencies = {
        "qshell": revision(args.qshell_revision, "QShell revision"),
        "coyote": revision(args.coyote_revision, "Coyote revision"),
        "coyoteNix": revision(args.coyote_nix_revision, "coyote-nix revision"),
        "microblossomImplementation": revision(
            args.implementation_revision, "MicroBlossom implementation revision"
        ),
    }
    manifest = {
        "api": "microblossom.v80-coprocessor-bundle/v1",
        "graphSha256": GRAPH_SHA256,
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
            "applicationMmio": "microblossom-d3-accelerator-v1",
            "providerFirmware": "coyote-r5-provider-mmio-v1",
        },
        "resourceReservation": "pre-route-conservative-from-accepted-u280-synthesis",
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
