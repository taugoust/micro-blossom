# Source and bitstream baselines

The `coprocessor-hybrid-service` branch contains the graph-matrix, circuit-d9 timing, and R5/C2H integration source. Its current flake consumes canonical QShell and Coyote tooling. Updating those pins affects future builds, not existing images.

Retained V80 circuit-d9 images:

| Execution model | Source baseline | PDI SHA-256 | Qualification |
| --- | --- | --- | --- |
| Host-driven | `aba2ba6cc07ce136548c72a9cffae8f981bdfdab` | `5263726a708e3089d8c9fb4a247107b1f03a9cf1efa44d98ff4dcffac11c5958` | Historical timing-qualified application |
| R5-backed hardware | `bf1ebdac6c45bbc79a8fad52c502ddc717f32781` | `9a5e561c6b9be26f0c6065c09c0baa0ab913fff5311d713858e40a9045fa5443` | Image complete; setup −0.545 ns and hold −0.141 ns; not timing-qualified |

These images require their original shell compatibility identities. The R5 application image does not include the decoder firmware and does not establish R5 runtime correctness. Its accepted accelerator RTL is separately identified in the artifact's `metadata/app.json`.

New U280 aggregate builds use the source-built static flow rather than importing the old checkpoint under an unrelated source hash. New R5 metadata identifies the selected shell derivation, not a previously built shell's store path. New compositions require their own physical and runtime validation; non-strict image generation is not timing qualification.

The graph-generic R5 firmware work and health-event successor are not part of this source baseline. Preserve original artifact metadata, reports, checksums and GC roots independently of future source merges.
