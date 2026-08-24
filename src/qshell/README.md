# MicroBlossom QShell baseline protocol

Phase 1 keeps the Rust primal algorithm on the x86 host and proxies its existing fine-grained accelerator operations through fixed 64-byte QShell records. This is a correctness baseline, not the eventual V80 hard-Arm service interface.

## Record layout

All integers are little-endian. Every record is exactly 64 bytes.

| Bytes | Field | Meaning |
|---:|---|---|
| 0–3 | magic | ASCII `MBQ1` |
| 4 | version | protocol version, currently `1` |
| 5 | opcode | operation listed below |
| 6–7 | flags | access width and response marker |
| 8–11 | request ID | identifies one decode job |
| 12–15 | sequence | orders operations within that job |
| 16–47 | graph ID | full SHA-256 of the graph JSON |
| 48–55 | argument 0 | opcode-specific address/count/status |
| 56–63 | argument 1 | opcode-specific value/result/detail |

Opcodes:

- `BeginJob (0x01)`: argument 0 is the expected operation count. `UINT64_MAX` selects an unbounded streaming job when the primal algorithm cannot know its data-dependent MMIO count before execution.
- `MmioWrite (0x02)`: argument 0 is byte address; argument 1 is write data.
- `MmioRead (0x03)`: argument 0 is byte address.
- `EndJob (0x04)`: closes the submitted operation sequence.
- `ReadResult (0x83)`: response carrying address and read value.
- `Completion (0x84)`: response carrying completion code and completed-operation count.
- `Error (0xff)`: response carrying error code and optional detail.

Flags bits 0–1 encode access width (`1`, `2`, `4`, or `8` bytes). Bit 8 marks response records. All other bits are reserved and must be zero.

The initial lifecycle is:

```text
BeginJob
  → ordered MmioWrite/MmioRead records
  → one ReadResult per read
  → EndJob
  → Completion or Error
```

Every record carries the exact graph SHA-256 so a shell/application can reject operations for an incompatible generated accelerator. Request IDs may be reused only after completion. Sequence numbers begin at zero and increase monotonically within a job. `BeginJob` has sequence zero; each MMIO operation and `EndJob` consumes the next sequence value. Exact-count jobs may end only after that count completes; unbounded jobs report their actual completed count.

## Current QShell envelope

`rtl/microblossom_qshell_envelope.sv` consumes QShell's generated SystemVerilog constants from pinned `coprocessor-hybrid-services` revision `5faaf403931b5791fc9c3f51e9c26dac5475e8de`; MicroBlossom does not redefine ABI offsets, classes, flags, or schema IDs. Each command uses one full header beat containing the first 16 MBQ1 bytes and one final 48-byte continuation. The adapter validates the syndrome class, command schema, exact 64-byte payload, contiguous keep masks, and `EndJob`/`END_OF_ROUND` relationship before presenting one complete internal MBQ1 record.

A response reverses the request endpoints, preserves context/round/capability/route identity, uses the MicroBlossom response schema and correction class, and emits the 64-byte MBQ1 response in the same two-beat shape. Correction sequence numbers are independent of command sequence numbers and reset after terminal `Completion` or `Error` records. The adapter serializes commands until the internal frontend either returns a response or becomes ready again after a response-free operation, keeping request metadata unambiguous under backpressure.

## Board-independent frontend and native transport

`rtl/microblossom_qshell_frontend.sv` consumes one complete record per 512-bit AXI-stream beat and issues one single-beat 64-bit AXI4 MMIO operation at a time. It validates stream framing, protocol header/flags, graph identity, job/request state, sequence, operation count, address width, and natural alignment before touching the accelerator. Narrow writes and reads are shifted to and from the addressed AXI byte lanes. Read results, terminal completion, and structured errors remain stable under output backpressure; no later input record is accepted while an MMIO operation or response is pending.

AXI errors abort the active job. A timed-out transaction emits `Completion(Timeout)` and quarantines the AXI proxy until reset because AXI does not permit a partly accepted transaction to be cancelled safely. Reset aborts any active job and clears protocol state without manufacturing a completion. This prevents a stale late AXI response from entering a later job.

The Rust `QshellMmioTransport<RecordLink>` preserves synchronous native MMIO semantics while encoding and validating protocol-v1 records. It detects malformed, remote-error, failed-completion, incorrect-count, and unexpected responses. Responses for another graph or request are treated as stale and skipped up to a fixed bound; an error for the active request is surfaced even if it belongs to an earlier asynchronous write. `DualModuleQshellDriver` implements the existing primal `DualStacklessDriver`/`DualTrackedDriver` abstraction over this transport.

`QshellRecordLink<BeatLink>` wraps that internal record contract in canonical QShell beats. It emits an exact full header beat plus 48-byte final continuation, manages independent command/correction sequences and modulo-2^32 rounds, validates response identity and endpoint attribution, and surfaces structured QShell errors. Rust constants are generated from the pinned QShell JSON spec and checked on every flake run, so the checked generated module is not a second ABI authority.

`CoyoteProcessBeatLink` connects the Rust adapter to the separately packaged `microblossom-qshell-coyote-bridge`. In Coyote's host-centric operation naming, the bridge maps the two command beats to one-sided `LOCAL_READ` requests (host memory to FPGA) and queues two `LOCAL_WRITE` buffers (FPGA to host) for each response. It preserves the first-beat boundary and the fixed 48-byte continuation used by MBQ1 correction records. This avoids padding a valid 112-byte command to 128 bytes and avoids requiring a response for successful MBQ1 writes. Structured QShell errors remain supported by the abstract Rust beat link, but Coyote's fixed receive-length request cannot switch the queued continuation from 48 to 8 bytes after inspecting the first beat; the hardware bridge therefore accepts MBQ1 responses only. Its device-free package self-test and packaged Coyote/xdb behavioral workload pass. `microblossom-d3-qshell-coyote-run` composes this real bridge with the canonical native Rust primal workload for physical execution against `/dev/coyote_fpga_0_v0`. The physical U280 path on `rose` passes the canonical correction with 14 completed operations after `reconfigure-app` loads the timing-clean partial. Twenty consecutive fresh host processes pass without reconfiguration; persistent-connection jobs and induced fault recovery remain separate.

The Nix checks cover the synthesizable frontend with Verilator 5.014 and run the canonical generated d3 accelerator through a simulation `RecordLink`. The application clock candidate uses a dedicated Xilinx `BUFGCE_DIV/2`, producing 125 MHz from the routed U280 shell's 250 MHz `aclk` and approximately 166.5 MHz from the V80 shell's 333 MHz `aclk`. Reset asserts asynchronously and deasserts through independent `ASYNC_REG` synchronizers in the local fast and slow domains, preventing Coyote's high-fanout reset net from directly driving application registers across the static/PR boundary. The generated accelerator has independent fast- and slow-domain reset inputs, and its two `StreamFifoCC` payload memories request dual-clock block RAM so payload transfer is represented by a native dual-port clock boundary rather than cross-clock distributed-RAM timing arcs. `microblossom_qshell_timing.xdc` uses scoped-checkpoint-persistent endpoint constraints for asynchronous reset-synchronizer controls and source-period max-delay/bus-skew constraints for each Gray-pointer bus; same-domain functional paths remain timed. Inactive request, operation, and response data registers are not reset because protocol state and valid bits gate every use. The behavioral divider and complete functional checks pass. The accepted U280 route for commit `25d875c` meets all setup, hold, and pulse-width constraints with overall WNS `+0.051 ns`; application-clock WNS is `+0.388 ns` at 250 MHz and `+2.211 ns` at 125 MHz. `microblossom_qshell_core.sv` composes the frontend directly with the generated 64-bit AXI4 `MicroBlossomBus`, with separate parent- and slow-domain resets. `microblossom_qshell_application.sv` adds the current QShell envelope and dedicated slow clock. The integrated application check sends two-beat `BeginJob`, hardware-info read, and `EndJob` commands through the complete envelope/frontend/accelerator hierarchy and verifies the two-beat read/completion responses, hardware version `0x240123c0`, endpoint reversal, sequence, and end-of-round metadata.

`checks.x86_64-linux.qshell-u280-xdb-d3` launches the packaged U280 Coyote simulation with QShell's resident service and the MicroBlossom vFPGA application, then runs the native Rust workload through the xdb-backed process bridge. The normal `nix flake check` surface therefore proves the complete 14-operation ABI-2/MBQ1 path and retains workload, simulation-time, Coyote-status, provenance, and xdb debug-bundle artifacts. The accepted result is `MICROBLOSSOM_D3_QSHELL_COYOTE_PASS defects=[0] correction_edges=[2] total_weight=2 operations=14`; the validated run completed at 2610 ns of simulated time with 14 Coyote response writes and no protocol error.

## V80 co-processor service

The CPU-assisted V80 application uses one 96-byte, two-beat QShell record per decode rather than exposing MBQ1 MMIO commands to the host. Request schema `0x00020003` carries `MBJ1`, protocol version 1, a sorted defect list of at most four d3 vertices, and the full graph SHA-256. Result schema `0x00020004` carries `MBR1`, status, graph identity, accelerator-operation count, and at most two correction-edge indices. Both records set `END_OF_ROUND`; the response reverses source and destination while retaining context, round, route capability, and record sequence.

`microblossom_coprocessor_application` forwards those records unchanged between QShell and logical co-processor stream port 0. Its separate 4-KiB AXI-Lite window exposes only the generated accelerator's hardware identity, instruction, growth, and obstacle-readout registers; unsupported addresses return `DECERR`. The R5 is the MMIO initiator. It receives complete packets through Coyote's bounded provider queues, validates ABI and graph identity, performs the canonical d3 primal/dual interaction locally, and returns one coarse result. Quiesce, binding-generation refresh, idle indication, bounded MMIO polling, and runtime-image readback use Coyote's generic firmware API.

The packaged `microblossom_d3_coprocessor` host executable emits the canonical request through the existing Coyote process bridge and verifies correction edge `[2]`. It configures the bridge for the coarse record's 32-byte continuation; the host-driven MBQ1 path retains its 48-byte continuation.

The deployment-facing build is intentionally two-stage. Build and retain `qshell-v80-r5-shell` once in the QShell repository, then build only this decoder service in MicroBlossom:

```sh
nix build -L .#microblossom-d3-v80-r5-app -o result-v80-r5-app
```

The app output contains `bitstreams/microblossom-d3-v80-r5.pdi`, `firmware/r5.elf`, the host runner, the Coyote bridge, the QShell control CLI, and exact decoder/application/shell metadata. Its underlying Coyote `BUILD_APP` flow reads the locked QShell checkpoint and routes only the MicroBlossom vFPGA; it does not synthesize or route QShell. Explicit `*-app-synth` and `*-app-routed` outputs allow those expensive application stages to retain separate Nix GC roots.

The older `microblossom-d3-v80-coprocessor-compatibility-bundle` remains an internal compatibility/provenance package consumed by the app output. It is not the user-facing deployment target. The host-driven U280/V80 packages remain available under their existing names; no fine-grained MMIO operation crosses PCIe in the CPU-assisted package.

The post-deployment control sequence is explicit. First read the live provider generation and image identity, then bind logical port 0 with that exact generation. Configure the QShell service/route from the bundle's `decoder-contract.json`, using request/result schemas `131075`/`131076`, before launching the workload:

```sh
nix run ../qshell#qshell -- coprocessor-control --operation provider
nix run ../qshell#qshell -- coprocessor-control --operation bind \
  --endpoint 1 --endpoint-generation <live-generation>

./result-v80-r5-app/bin/microblossom_d3_coprocessor \
  --bridge ./result-v80-r5-app/bin/microblossom-qshell-coyote-bridge \
  --context <context> --round <round> --source-endpoint <source> \
  --decoder-endpoint <decoder> --capability <capability>
```

`qshell coprocessor-control` also exposes bounded binding read, quiesce, unbind, and recover operations. The QShell admission API remains the authority for service lifecycle and route ownership; the CLI is the physical bring-up surface, not a bypass of those checks.
