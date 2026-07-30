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

- `BeginJob (0x01)`: argument 0 is the expected operation count.
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

Every record carries the exact graph SHA-256 so a shell/application can reject operations for an incompatible generated accelerator. Request IDs may be reused only after completion. Sequence numbers begin at zero and increase monotonically within a job.

Phase 2 will retain coarse job identity and compatibility concepts, but fine-grained MMIO records will remain local between the V80 Arm CPU and accelerator rather than crossing PCIe.
