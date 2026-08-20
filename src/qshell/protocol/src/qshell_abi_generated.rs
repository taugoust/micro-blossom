// Generated from QShell abi/qshell-abi.json; do not edit.
pub const VERSION: u8 = 2;
pub const BEAT_BYTES: usize = 64;
pub const HEADER_BYTES: usize = 48;
pub const MAGIC: u32 = 0x32485351;

pub mod record_class {
    pub const SYNDROME: u8 = 0x1;
    pub const CORRECTION: u8 = 0x2;
    pub const CONTROL: u8 = 0x3;
    pub const ERROR: u8 = 0x4;
}

pub mod flag {
    pub const END_OF_ROUND: u16 = 0x1;
    pub const CONTROL_RESPONSE: u16 = 0x2;
}

pub mod schema {
    pub const OPAQUE_LOOPBACK: u32 = 0x1;
    pub const HELIOS_PHENOM_SYNDROME: u32 = 0x10001;
    pub const HELIOS_SPARSE_CORRECTION: u32 = 0x10002;
    pub const MICROBLOSSOM_COMMAND: u32 = 0x20001;
    pub const MICROBLOSSOM_RESPONSE: u32 = 0x20002;
    pub const MICROBLOSSOM_DECODE_REQUEST: u32 = 0x20003;
    pub const MICROBLOSSOM_DECODE_RESULT: u32 = 0x20004;
    pub const PAULI_FRAME_XOR: u32 = 0x30001;
    pub const CONTROL: u32 = 0xffff0001;
    pub const ERROR: u32 = 0xffff0002;
}

pub mod error_scope {
    pub const DROP_RECORD: u8 = 0x1;
    pub const ABORT_ROUND: u8 = 0x2;
    pub const DISABLE_ROUTE: u8 = 0x3;
    pub const QUARANTINE_SERVICE: u8 = 0x4;
}

pub mod error_code {
    pub const MALFORMED_RECORD: u16 = 0x1;
    pub const UNSUPPORTED_ABI: u16 = 0x2;
    pub const UNKNOWN_RECORD_CLASS: u16 = 0x3;
    pub const INVALID_FLAGS: u16 = 0x4;
    pub const INVALID_LENGTH: u16 = 0x5;
    pub const INVALID_KEEP: u16 = 0x6;
    pub const UNEXPECTED_LAST: u16 = 0x7;
    pub const UNKNOWN_CAPABILITY: u16 = 0x10;
    pub const SOURCE_MISMATCH: u16 = 0x11;
    pub const CONTEXT_MISMATCH: u16 = 0x12;
    pub const SCHEMA_MISMATCH: u16 = 0x13;
    pub const ROUND_REPLAY: u16 = 0x14;
    pub const SEQUENCE_MISMATCH: u16 = 0x15;
    pub const INGRESS_ROUTE_VERSION_NONZERO: u16 = 0x16;
    pub const QUEUE_OVERFLOW: u16 = 0x17;
    pub const ROUTE_DISABLED: u16 = 0x18;
    pub const STALE_CORRECTION: u16 = 0x20;
    pub const CORRECTION_PRODUCER_MISMATCH: u16 = 0x21;
    pub const CORRECTION_DESTINATION_MISMATCH: u16 = 0x22;
    pub const CORRECTION_VERSION_MISMATCH: u16 = 0x23;
    pub const CORRECTION_SCHEMA_MISMATCH: u16 = 0x24;
    pub const CORRECTION_DUPLICATE: u16 = 0x25;
    pub const CONTROL_MALFORMED: u16 = 0x30;
    pub const UNSUPPORTED_CONTROL: u16 = 0x31;
    pub const INVALID_TRANSITION: u16 = 0x32;
    pub const VERSION_EXHAUSTED: u16 = 0x33;
    pub const SERVICE_UNAVAILABLE: u16 = 0x40;
    pub const SERVICE_QUARANTINED: u16 = 0x41;
}

pub mod offset {
    pub const MAGIC: usize = 0;
    pub const ABI_VERSION: usize = 4;
    pub const RECORD_CLASS: usize = 5;
    pub const FLAGS: usize = 6;
    pub const HEADER_BYTES: usize = 8;
    pub const RESERVED: usize = 10;
    pub const PAYLOAD_BYTES: usize = 12;
    pub const CONTEXT_ID: usize = 16;
    pub const ROUND_ID: usize = 20;
    pub const SCHEMA_ID: usize = 24;
    pub const SOURCE_ENDPOINT_ID: usize = 28;
    pub const DESTINATION_ENDPOINT_ID: usize = 32;
    pub const ROUTE_CAPABILITY_ID: usize = 36;
    pub const ROUTE_VERSION: usize = 40;
    pub const RECORD_SEQUENCE: usize = 44;
}
