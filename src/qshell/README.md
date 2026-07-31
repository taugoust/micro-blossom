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

## Board-independent frontend and native transport

`rtl/microblossom_qshell_frontend.sv` consumes one complete record per 512-bit AXI-stream beat and issues one single-beat 64-bit AXI4 MMIO operation at a time. It validates stream framing, protocol header/flags, graph identity, job/request state, sequence, operation count, address width, and natural alignment before touching the accelerator. Narrow writes and reads are shifted to and from the addressed AXI byte lanes. Read results, terminal completion, and structured errors remain stable under output backpressure; no later input record is accepted while an MMIO operation or response is pending.

AXI errors abort the active job. A timed-out transaction emits `Completion(Timeout)` and quarantines the AXI proxy until reset because AXI does not permit a partly accepted transaction to be cancelled safely. Reset aborts any active job and clears protocol state without manufacturing a completion. This prevents a stale late AXI response from entering a later job.

The Rust `QshellMmioTransport<RecordLink>` preserves synchronous native MMIO semantics while encoding and validating protocol-v1 records. It detects malformed, remote-error, failed-completion, incorrect-count, and unexpected responses. Responses for another graph or request are treated as stale and skipped up to a fixed bound; an error for the active request is surfaced even if it belongs to an earlier asynchronous write. `DualModuleQshellDriver` implements the existing primal `DualStacklessDriver`/`DualTrackedDriver` abstraction over this transport.

The Nix checks cover the synthesizable frontend with Verilator 5.014 and run the canonical generated d3 accelerator through a simulation `RecordLink`. The application clock candidate uses a dedicated Xilinx `BUFGCE_DIV/2`, producing 125 MHz from the routed U280 shell's 250 MHz `aclk` and approximately 166.5 MHz from the V80 shell's 333 MHz `aclk`; reset asserts asynchronously and deasserts synchronously in the slow domain. Its behavioral divider check passes, while device synthesis/routing remains mandatory before accepting this strategy. `microblossom_qshell_core.sv` also composes the frontend directly with the generated 64-bit AXI4 `MicroBlossomBus`; its integrated check reads hardware identity/capability registers, submits a reset instruction, and completes the job through actual frontend-generated AXI traffic. The packaged core manifest deliberately labels its shell-facing envelope `pending-QS0`: MBQ1 remains an internal 64-byte application record until the shared QShell framing contract resolves the canonical 12-byte outer header. The golden decode remains `defects=[0] correction_edges=[2] total_weight=2` and currently uses 14 ordered MMIO operations.

Phase 2 will retain coarse job identity and compatibility concepts, but fine-grained MMIO records will remain local between the V80 Arm CPU and accelerator rather than crossing PCIe.
