//! Fixed-size MBQ1 codec and current QShell record adapter.

use core::fmt;

pub mod qshell_abi_generated;

use qshell_abi_generated as qshell_abi;

pub const RECORD_BYTES: usize = 64;
pub const MAGIC: [u8; 4] = *b"MBQ1";
pub const VERSION: u8 = 1;
pub const UNBOUNDED_OPERATIONS: u64 = u64::MAX;
pub const MAX_STALE_RESPONSES: usize = 16;
pub const MAX_QSHELL_PACKET_BYTES: usize = 4096;
pub const MAX_QSHELL_PACKET_BEATS: usize = MAX_QSHELL_PACKET_BYTES / qshell_abi::BEAT_BYTES;

const WIDTH_MASK: u16 = 0x0003;
const RESPONSE_FLAG: u16 = 0x0100;
const KNOWN_FLAGS: u16 = WIDTH_MASK | RESPONSE_FLAG;

pub type GraphId = [u8; 32];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Opcode {
    BeginJob = 0x01,
    MmioWrite = 0x02,
    MmioRead = 0x03,
    EndJob = 0x04,
    ReadResult = 0x83,
    Completion = 0x84,
    Error = 0xff,
}

impl Opcode {
    fn from_wire(value: u8) -> Result<Self, DecodeError> {
        match value {
            0x01 => Ok(Self::BeginJob),
            0x02 => Ok(Self::MmioWrite),
            0x03 => Ok(Self::MmioRead),
            0x04 => Ok(Self::EndJob),
            0x83 => Ok(Self::ReadResult),
            0x84 => Ok(Self::Completion),
            0xff => Ok(Self::Error),
            _ => Err(DecodeError::UnknownOpcode(value)),
        }
    }

    pub const fn is_response(self) -> bool {
        matches!(self, Self::ReadResult | Self::Completion | Self::Error)
    }

    const fn uses_access_width(self) -> bool {
        matches!(self, Self::MmioWrite | Self::MmioRead | Self::ReadResult)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u16)]
pub enum AccessWidth {
    Byte = 0,
    HalfWord = 1,
    Word = 2,
    DoubleWord = 3,
}

impl AccessWidth {
    pub const fn bytes(self) -> u8 {
        match self {
            Self::Byte => 1,
            Self::HalfWord => 2,
            Self::Word => 4,
            Self::DoubleWord => 8,
        }
    }

    const fn from_flags(flags: u16) -> Self {
        match flags & WIDTH_MASK {
            0 => Self::Byte,
            1 => Self::HalfWord,
            2 => Self::Word,
            3 => Self::DoubleWord,
            _ => unreachable!(),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u64)]
pub enum CompletionCode {
    Success = 0,
    Rejected = 1,
    Timeout = 2,
    AcceleratorFault = 3,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u64)]
pub enum ErrorCode {
    MalformedRecord = 1,
    UnsupportedVersion = 2,
    GraphMismatch = 3,
    InvalidSequence = 4,
    InvalidAddress = 5,
    JobState = 6,
    AcceleratorFault = 7,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Record {
    pub opcode: Opcode,
    pub request_id: u32,
    pub sequence: u32,
    pub graph_id: GraphId,
    pub argument0: u64,
    pub argument1: u64,
    flags: u16,
}

impl Record {
    pub fn begin_job(graph_id: GraphId, request_id: u32, expected_operations: u64) -> Self {
        Self::new(
            Opcode::BeginJob,
            graph_id,
            request_id,
            0,
            0,
            expected_operations,
            0,
        )
    }

    pub fn mmio_write(
        graph_id: GraphId,
        request_id: u32,
        sequence: u32,
        width: AccessWidth,
        address: u64,
        value: u64,
    ) -> Self {
        Self::new(
            Opcode::MmioWrite,
            graph_id,
            request_id,
            sequence,
            width as u16,
            address,
            value,
        )
    }

    pub fn mmio_read(
        graph_id: GraphId,
        request_id: u32,
        sequence: u32,
        width: AccessWidth,
        address: u64,
    ) -> Self {
        Self::new(
            Opcode::MmioRead,
            graph_id,
            request_id,
            sequence,
            width as u16,
            address,
            0,
        )
    }

    pub fn end_job(graph_id: GraphId, request_id: u32, sequence: u32) -> Self {
        Self::new(Opcode::EndJob, graph_id, request_id, sequence, 0, 0, 0)
    }

    pub fn read_result(
        graph_id: GraphId,
        request_id: u32,
        sequence: u32,
        width: AccessWidth,
        address: u64,
        value: u64,
    ) -> Self {
        Self::new(
            Opcode::ReadResult,
            graph_id,
            request_id,
            sequence,
            RESPONSE_FLAG | width as u16,
            address,
            value,
        )
    }

    pub fn completion(
        graph_id: GraphId,
        request_id: u32,
        sequence: u32,
        code: CompletionCode,
        completed_operations: u64,
    ) -> Self {
        Self::new(
            Opcode::Completion,
            graph_id,
            request_id,
            sequence,
            RESPONSE_FLAG,
            code as u64,
            completed_operations,
        )
    }

    pub fn error(
        graph_id: GraphId,
        request_id: u32,
        sequence: u32,
        code: ErrorCode,
        detail: u64,
    ) -> Self {
        Self::new(
            Opcode::Error,
            graph_id,
            request_id,
            sequence,
            RESPONSE_FLAG,
            code as u64,
            detail,
        )
    }

    fn new(
        opcode: Opcode,
        graph_id: GraphId,
        request_id: u32,
        sequence: u32,
        flags: u16,
        argument0: u64,
        argument1: u64,
    ) -> Self {
        Self {
            opcode,
            request_id,
            sequence,
            graph_id,
            argument0,
            argument1,
            flags,
        }
    }

    pub const fn access_width(self) -> Option<AccessWidth> {
        if self.opcode.uses_access_width() {
            Some(AccessWidth::from_flags(self.flags))
        } else {
            None
        }
    }

    pub const fn is_response(self) -> bool {
        self.opcode.is_response()
    }

    pub fn encode(self) -> [u8; RECORD_BYTES] {
        let mut bytes = [0_u8; RECORD_BYTES];
        bytes[0..4].copy_from_slice(&MAGIC);
        bytes[4] = VERSION;
        bytes[5] = self.opcode as u8;
        bytes[6..8].copy_from_slice(&self.flags.to_le_bytes());
        bytes[8..12].copy_from_slice(&self.request_id.to_le_bytes());
        bytes[12..16].copy_from_slice(&self.sequence.to_le_bytes());
        bytes[16..48].copy_from_slice(&self.graph_id);
        bytes[48..56].copy_from_slice(&self.argument0.to_le_bytes());
        bytes[56..64].copy_from_slice(&self.argument1.to_le_bytes());
        bytes
    }

    pub fn decode(bytes: &[u8; RECORD_BYTES]) -> Result<Self, DecodeError> {
        if bytes[0..4] != MAGIC {
            return Err(DecodeError::BadMagic);
        }
        if bytes[4] != VERSION {
            return Err(DecodeError::UnsupportedVersion(bytes[4]));
        }

        let opcode = Opcode::from_wire(bytes[5])?;
        let flags = u16::from_le_bytes(bytes[6..8].try_into().unwrap());
        if flags & !KNOWN_FLAGS != 0 {
            return Err(DecodeError::InvalidFlags(flags));
        }
        if opcode.is_response() != (flags & RESPONSE_FLAG != 0) {
            return Err(DecodeError::InvalidFlags(flags));
        }
        if !opcode.uses_access_width() && flags & WIDTH_MASK != 0 {
            return Err(DecodeError::InvalidFlags(flags));
        }

        let mut graph_id = [0_u8; 32];
        graph_id.copy_from_slice(&bytes[16..48]);
        Ok(Self {
            opcode,
            request_id: u32::from_le_bytes(bytes[8..12].try_into().unwrap()),
            sequence: u32::from_le_bytes(bytes[12..16].try_into().unwrap()),
            graph_id,
            argument0: u64::from_le_bytes(bytes[48..56].try_into().unwrap()),
            argument1: u64::from_le_bytes(bytes[56..64].try_into().unwrap()),
            flags,
        })
    }
}

/// Blocking record link used by the native host-side transport.
///
/// `send_record` must not return until the record has been accepted into an
/// ordered link. In particular, backpressure must not permit a later record to
/// pass an earlier MMIO operation. `receive_record` returns the next complete
/// response record from that same ordered link.
pub trait RecordLink {
    type Error;

    fn send_record(&mut self, record: [u8; RECORD_BYTES]) -> Result<(), Self::Error>;
    fn receive_record(&mut self) -> Result<[u8; RECORD_BYTES], Self::Error>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AxisBeat {
    pub data: [u8; qshell_abi::BEAT_BYTES],
    pub keep: u64,
    pub last: bool,
}

/// Blocking logical transport for individual 64-byte record beats.
///
/// Implementations preserve beat order and logical low-lane `keep` framing.
/// The production Coyote/XDB receive adapters do not observe source AXI-stream
/// sidebands: after resident QShell store-and-forward validation/frame commit,
/// they reconstruct this logical shape from one fixed graph-sized descriptor.
pub trait BeatLink {
    type Error;

    fn send_beat(&mut self, beat: AxisBeat) -> Result<(), Self::Error>;
    fn receive_beat(&mut self) -> Result<AxisBeat, Self::Error>;
}

#[derive(Debug)]
pub enum CoyoteProcessError {
    Io(std::io::Error),
    Bridge(String),
    UnexpectedStatus(u8),
}

impl fmt::Display for CoyoteProcessError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "Coyote bridge I/O failed: {error}"),
            Self::Bridge(error) => write!(formatter, "Coyote bridge rejected request: {error}"),
            Self::UnexpectedStatus(status) => {
                write!(formatter, "Coyote bridge returned unknown status {status}")
            }
        }
    }
}

impl std::error::Error for CoyoteProcessError {}

impl From<std::io::Error> for CoyoteProcessError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

/// Process-backed logical beat transport for the packaged Coyote C++ bridge.
///
/// Keeping the Coyote driver boundary in a separately packaged process avoids
/// adding C++ ABI assumptions to the Rust protocol crate. On receive, the
/// bridge waits for one fixed-length DMA descriptor to complete before exposing
/// bytes and derives logical beat boundaries rather than reporting source
/// `tkeep`/`tlast` observations.
pub struct CoyoteProcessBeatLink {
    child: std::process::Child,
    input: std::process::ChildStdin,
    output: std::io::BufReader<std::process::ChildStdout>,
}

impl CoyoteProcessBeatLink {
    pub fn spawn(
        executable: impl AsRef<std::ffi::OsStr>,
        vfpga_id: i32,
        timeout_ms: u64,
    ) -> Result<Self, CoyoteProcessError> {
        Self::spawn_with_response_bytes(
            executable,
            vfpga_id,
            timeout_ms,
            qshell_abi::BEAT_BYTES + 48,
        )
    }

    pub fn spawn_with_continuation(
        executable: impl AsRef<std::ffi::OsStr>,
        vfpga_id: i32,
        timeout_ms: u64,
        continuation_bytes: usize,
    ) -> Result<Self, CoyoteProcessError> {
        if continuation_bytes == 0 || continuation_bytes > qshell_abi::BEAT_BYTES {
            return Err(CoyoteProcessError::Bridge(
                "response continuation must contain 1..64 bytes".to_owned(),
            ));
        }
        let response_bytes = qshell_abi::BEAT_BYTES
            .checked_add(continuation_bytes)
            .ok_or_else(|| CoyoteProcessError::Bridge("response size overflow".to_owned()))?;
        Self::spawn_with_response_bytes(executable, vfpga_id, timeout_ms, response_bytes)
    }

    pub fn spawn_with_response_bytes(
        executable: impl AsRef<std::ffi::OsStr>,
        vfpga_id: i32,
        timeout_ms: u64,
        response_bytes: usize,
    ) -> Result<Self, CoyoteProcessError> {
        use std::process::Stdio;

        if response_bytes <= qshell_abi::BEAT_BYTES || response_bytes > MAX_QSHELL_PACKET_BYTES {
            return Err(CoyoteProcessError::Bridge(format!(
                "response packet must contain 65..={MAX_QSHELL_PACKET_BYTES} bytes"
            )));
        }
        let mut child = std::process::Command::new(executable)
            .arg("--vfpga")
            .arg(vfpga_id.to_string())
            .arg("--timeout-ms")
            .arg(timeout_ms.to_string())
            .arg("--response-bytes")
            .arg(response_bytes.to_string())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()?;
        let input = child
            .stdin
            .take()
            .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::BrokenPipe, "missing stdin"))?;
        let output = child
            .stdout
            .take()
            .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::BrokenPipe, "missing stdout"))?;
        Ok(Self {
            child,
            input,
            output: std::io::BufReader::new(output),
        })
    }

    fn read_status(&mut self) -> Result<(), CoyoteProcessError> {
        use std::io::Read;

        let mut status = [0_u8; 1];
        self.output.read_exact(&mut status)?;
        match status[0] {
            0 => Ok(()),
            1 => {
                let mut length = [0_u8; 4];
                self.output.read_exact(&mut length)?;
                let length = u32::from_le_bytes(length) as usize;
                let mut message = vec![0_u8; length];
                self.output.read_exact(&mut message)?;
                Err(CoyoteProcessError::Bridge(
                    String::from_utf8_lossy(&message).into_owned(),
                ))
            }
            status => Err(CoyoteProcessError::UnexpectedStatus(status)),
        }
    }
}

impl BeatLink for CoyoteProcessBeatLink {
    type Error = CoyoteProcessError;

    fn send_beat(&mut self, beat: AxisBeat) -> Result<(), Self::Error> {
        use std::io::Write;

        self.input.write_all(&[1, u8::from(beat.last)])?;
        self.input.write_all(&beat.keep.to_le_bytes())?;
        self.input.write_all(&beat.data)?;
        self.input.flush()?;
        self.read_status()
    }

    fn receive_beat(&mut self) -> Result<AxisBeat, Self::Error> {
        use std::io::{Read, Write};

        self.input.write_all(&[2])?;
        self.input.flush()?;
        self.read_status()?;
        let mut last = [0_u8; 1];
        let mut keep = [0_u8; 8];
        let mut data = [0_u8; qshell_abi::BEAT_BYTES];
        self.output.read_exact(&mut last)?;
        self.output.read_exact(&mut keep)?;
        self.output.read_exact(&mut data)?;
        Ok(AxisBeat {
            data,
            keep: u64::from_le_bytes(keep),
            last: last[0] != 0,
        })
    }
}

impl Drop for CoyoteProcessBeatLink {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct QshellRoute {
    pub context_id: u32,
    pub initial_round_id: u32,
    pub source_endpoint_id: u32,
    pub route_capability_id: u32,
    /// Optional expected decoder endpoint for correction attribution. Leave
    /// this unset for the current identity-shell baseline, which does not yet
    /// stamp a decoder endpoint.
    pub expected_decoder_endpoint_id: Option<u32>,
}

#[derive(Debug, Eq, PartialEq)]
pub enum QshellLinkError<LinkError> {
    Link(LinkError),
    InnerRecord(DecodeError),
    UnexpectedInnerResponse,
    CommandSequence { expected: u32, actual: u32 },
    MalformedEnvelope,
    UnexpectedClass(u8),
    InvalidEnvelopeFlags(u16),
    InvalidEnvelopeLength(u32),
    InvalidEnvelopeKeep { expected: u64, actual: u64 },
    MetadataMismatch,
    RequestGraphMismatch,
    InvalidDefects,
    ResultGraphMismatch,
    InvalidCorrectionEdge(u16),
    NonzeroPayloadPadding,
    CorrectionSequence { expected: u32, actual: u32 },
    EndOfRoundMismatch,
    LinkPoisoned,
    RemoteQshellError { code: u16, scope: u8, detail: u32 },
}

impl<LinkError: fmt::Display> fmt::Display for QshellLinkError<LinkError> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Link(error) => write!(formatter, "QShell beat link failed: {error}"),
            Self::InnerRecord(error) => write!(formatter, "invalid MBQ1 record: {error}"),
            Self::UnexpectedInnerResponse => {
                formatter.write_str("cannot send an MBQ1 response as a QShell command")
            }
            Self::CommandSequence { expected, actual } => write!(
                formatter,
                "QShell command sequence mismatch: expected {expected}, received {actual}"
            ),
            Self::MalformedEnvelope => formatter.write_str("malformed QShell ABI-2 envelope"),
            Self::UnexpectedClass(class) => {
                write!(formatter, "unexpected QShell record class {class}")
            }
            Self::InvalidEnvelopeFlags(flags) => {
                write!(formatter, "invalid QShell envelope flags 0x{flags:04x}")
            }
            Self::InvalidEnvelopeLength(bytes) => {
                write!(formatter, "invalid QShell envelope payload length {bytes}")
            }
            Self::InvalidEnvelopeKeep { expected, actual } => write!(
                formatter,
                "invalid QShell keep mask 0x{actual:016x}, expected 0x{expected:016x}"
            ),
            Self::MetadataMismatch => formatter.write_str("QShell response metadata mismatch"),
            Self::RequestGraphMismatch => {
                formatter.write_str("decode request does not match the graph contract")
            }
            Self::InvalidDefects => formatter.write_str("invalid bounded defect list"),
            Self::ResultGraphMismatch => {
                formatter.write_str("decode result does not match the graph contract")
            }
            Self::InvalidCorrectionEdge(edge) => {
                write!(
                    formatter,
                    "correction edge {edge} is outside the graph contract"
                )
            }
            Self::NonzeroPayloadPadding => {
                formatter.write_str("fixed-capacity payload has nonzero padding")
            }
            Self::CorrectionSequence { expected, actual } => write!(
                formatter,
                "QShell correction sequence mismatch: expected {expected}, received {actual}"
            ),
            Self::EndOfRoundMismatch => {
                formatter.write_str("QShell and MBQ1 terminal markers disagree")
            }
            Self::LinkPoisoned => {
                formatter.write_str("QShell link is poisoned; reconnect required")
            }
            Self::RemoteQshellError {
                code,
                scope,
                detail,
            } => write!(
                formatter,
                "QShell error {code} with scope {scope} (detail {detail})"
            ),
        }
    }
}

impl<LinkError: fmt::Debug + fmt::Display> std::error::Error for QshellLinkError<LinkError> {}

/// Converts the internal fixed-size MBQ1 `RecordLink` contract to canonical
/// current QShell beats without owning a second copy of the ABI constants.
pub struct QshellRecordLink<Link> {
    link: Link,
    route: QshellRoute,
    round_id: u32,
    command_sequence: u32,
    correction_sequence: u32,
}

impl<Link> QshellRecordLink<Link> {
    pub fn new(link: Link, route: QshellRoute) -> Self {
        Self {
            link,
            route,
            round_id: route.initial_round_id,
            command_sequence: 0,
            correction_sequence: 0,
        }
    }

    pub const fn round_id(&self) -> u32 {
        self.round_id
    }

    pub const fn command_sequence(&self) -> u32 {
        self.command_sequence
    }

    pub const fn correction_sequence(&self) -> u32 {
        self.correction_sequence
    }

    pub fn link(&self) -> &Link {
        &self.link
    }

    pub fn link_mut(&mut self) -> &mut Link {
        &mut self.link
    }

    pub fn into_inner(self) -> Link {
        self.link
    }
}

impl<Link: BeatLink> QshellRecordLink<Link> {
    fn send_command(
        &mut self,
        bytes: [u8; RECORD_BYTES],
    ) -> Result<(), QshellLinkError<Link::Error>> {
        let record = Record::decode(&bytes).map_err(QshellLinkError::InnerRecord)?;
        if record.is_response() {
            return Err(QshellLinkError::UnexpectedInnerResponse);
        }
        if record.sequence != self.command_sequence {
            return Err(QshellLinkError::CommandSequence {
                expected: self.command_sequence,
                actual: record.sequence,
            });
        }

        let end_of_round = record.opcode == Opcode::EndJob;
        let mut first = AxisBeat {
            data: [0; qshell_abi::BEAT_BYTES],
            keep: u64::MAX,
            last: false,
        };
        put_u32(
            &mut first.data,
            qshell_abi::offset::MAGIC,
            qshell_abi::MAGIC,
        );
        first.data[qshell_abi::offset::ABI_VERSION] = qshell_abi::VERSION;
        first.data[qshell_abi::offset::RECORD_CLASS] = qshell_abi::record_class::SYNDROME;
        put_u16(
            &mut first.data,
            qshell_abi::offset::FLAGS,
            if end_of_round {
                qshell_abi::flag::END_OF_ROUND
            } else {
                0
            },
        );
        put_u16(
            &mut first.data,
            qshell_abi::offset::HEADER_BYTES,
            qshell_abi::HEADER_BYTES as u16,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::PAYLOAD_BYTES,
            RECORD_BYTES as u32,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::CONTEXT_ID,
            self.route.context_id,
        );
        put_u32(&mut first.data, qshell_abi::offset::ROUND_ID, self.round_id);
        put_u32(
            &mut first.data,
            qshell_abi::offset::SCHEMA_ID,
            qshell_abi::schema::MICROBLOSSOM_COMMAND,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::SOURCE_ENDPOINT_ID,
            self.route.source_endpoint_id,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::ROUTE_CAPABILITY_ID,
            self.route.route_capability_id,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::RECORD_SEQUENCE,
            record.sequence,
        );
        first.data[qshell_abi::HEADER_BYTES..].copy_from_slice(&bytes[..16]);

        let mut continuation = AxisBeat {
            data: [0; qshell_abi::BEAT_BYTES],
            keep: low_keep(RECORD_BYTES - 16),
            last: true,
        };
        continuation.data[..RECORD_BYTES - 16].copy_from_slice(&bytes[16..]);

        self.link.send_beat(first).map_err(QshellLinkError::Link)?;
        self.link
            .send_beat(continuation)
            .map_err(QshellLinkError::Link)?;
        if !end_of_round {
            self.command_sequence = self.command_sequence.wrapping_add(1);
        }
        Ok(())
    }

    fn receive_response(&mut self) -> Result<[u8; RECORD_BYTES], QshellLinkError<Link::Error>> {
        let first = self.link.receive_beat().map_err(QshellLinkError::Link)?;
        if first.keep != u64::MAX {
            return Err(QshellLinkError::InvalidEnvelopeKeep {
                expected: u64::MAX,
                actual: first.keep,
            });
        }
        if first.last
            || get_u32(&first.data, qshell_abi::offset::MAGIC) != qshell_abi::MAGIC
            || first.data[qshell_abi::offset::ABI_VERSION] != qshell_abi::VERSION
            || get_u16(&first.data, qshell_abi::offset::HEADER_BYTES)
                != qshell_abi::HEADER_BYTES as u16
            || get_u16(&first.data, qshell_abi::offset::RESERVED) != 0
        {
            return Err(QshellLinkError::MalformedEnvelope);
        }

        let record_class = first.data[qshell_abi::offset::RECORD_CLASS];
        let flags = get_u16(&first.data, qshell_abi::offset::FLAGS);
        let payload_bytes = get_u32(&first.data, qshell_abi::offset::PAYLOAD_BYTES);
        if record_class == qshell_abi::record_class::ERROR {
            return self.receive_qshell_error(first, payload_bytes, flags);
        }
        if record_class != qshell_abi::record_class::CORRECTION {
            return Err(QshellLinkError::UnexpectedClass(record_class));
        }
        if flags & !qshell_abi::flag::END_OF_ROUND != 0 {
            return Err(QshellLinkError::InvalidEnvelopeFlags(flags));
        }
        if payload_bytes != RECORD_BYTES as u32 {
            return Err(QshellLinkError::InvalidEnvelopeLength(payload_bytes));
        }
        if get_u32(&first.data, qshell_abi::offset::CONTEXT_ID) != self.route.context_id
            || get_u32(&first.data, qshell_abi::offset::ROUND_ID) != self.round_id
            || get_u32(&first.data, qshell_abi::offset::SCHEMA_ID)
                != qshell_abi::schema::MICROBLOSSOM_RESPONSE
            || get_u32(&first.data, qshell_abi::offset::DESTINATION_ENDPOINT_ID)
                != self.route.source_endpoint_id
            || get_u32(&first.data, qshell_abi::offset::ROUTE_CAPABILITY_ID)
                != self.route.route_capability_id
            || self
                .route
                .expected_decoder_endpoint_id
                .is_some_and(|endpoint| {
                    get_u32(&first.data, qshell_abi::offset::SOURCE_ENDPOINT_ID) != endpoint
                })
        {
            return Err(QshellLinkError::MetadataMismatch);
        }
        let actual_sequence = get_u32(&first.data, qshell_abi::offset::RECORD_SEQUENCE);
        if actual_sequence != self.correction_sequence {
            return Err(QshellLinkError::CorrectionSequence {
                expected: self.correction_sequence,
                actual: actual_sequence,
            });
        }

        let continuation = self.link.receive_beat().map_err(QshellLinkError::Link)?;
        let expected_keep = low_keep(RECORD_BYTES - 16);
        if continuation.keep != expected_keep {
            return Err(QshellLinkError::InvalidEnvelopeKeep {
                expected: expected_keep,
                actual: continuation.keep,
            });
        }
        if !continuation.last {
            return Err(QshellLinkError::MalformedEnvelope);
        }

        let mut payload = [0; RECORD_BYTES];
        payload[..16].copy_from_slice(&first.data[qshell_abi::HEADER_BYTES..]);
        payload[16..].copy_from_slice(&continuation.data[..RECORD_BYTES - 16]);
        let inner = Record::decode(&payload).map_err(QshellLinkError::InnerRecord)?;
        let envelope_eor = flags & qshell_abi::flag::END_OF_ROUND != 0;
        let inner_terminal = matches!(inner.opcode, Opcode::Completion | Opcode::Error);
        if envelope_eor != inner_terminal {
            return Err(QshellLinkError::EndOfRoundMismatch);
        }
        if envelope_eor {
            self.round_id = self.round_id.wrapping_add(1);
            self.command_sequence = 0;
            self.correction_sequence = 0;
        } else {
            self.correction_sequence = self.correction_sequence.wrapping_add(1);
        }
        Ok(payload)
    }

    fn receive_qshell_error(
        &mut self,
        first: AxisBeat,
        payload_bytes: u32,
        flags: u16,
    ) -> Result<[u8; RECORD_BYTES], QshellLinkError<Link::Error>> {
        if flags != 0 {
            return Err(QshellLinkError::InvalidEnvelopeFlags(flags));
        }
        if payload_bytes != 24 {
            return Err(QshellLinkError::InvalidEnvelopeLength(payload_bytes));
        }
        let continuation = self.link.receive_beat().map_err(QshellLinkError::Link)?;
        if continuation.keep != low_keep(8) || !continuation.last {
            return Err(QshellLinkError::MalformedEnvelope);
        }
        let payload = &first.data[qshell_abi::HEADER_BYTES..];
        Err(QshellLinkError::RemoteQshellError {
            code: u16::from_le_bytes(payload[0..2].try_into().unwrap()),
            scope: payload[2],
            detail: u32::from_le_bytes(payload[4..8].try_into().unwrap()),
        })
    }
}

impl<Link: BeatLink> RecordLink for QshellRecordLink<Link> {
    type Error = QshellLinkError<Link::Error>;

    fn send_record(&mut self, record: [u8; RECORD_BYTES]) -> Result<(), Self::Error> {
        self.send_command(record)
    }

    fn receive_record(&mut self) -> Result<[u8; RECORD_BYTES], Self::Error> {
        self.receive_response()
    }
}

const fn low_keep(bytes: usize) -> u64 {
    if bytes == 64 {
        u64::MAX
    } else {
        (1_u64 << bytes) - 1
    }
}

fn put_u16(target: &mut [u8], offset: usize, value: u16) {
    target[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
}

fn put_u32(target: &mut [u8], offset: usize, value: u32) {
    target[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
}

fn get_u16(source: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes(source[offset..offset + 2].try_into().unwrap())
}

fn get_u32(source: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(source[offset..offset + 4].try_into().unwrap())
}

#[derive(Debug)]
pub enum TransportError<LinkError> {
    Link(LinkError),
    Decode(DecodeError),
    AlreadyActive,
    Inactive,
    SequenceOverflow,
    StaleResponseLimit,
    UnexpectedResponse {
        expected: Opcode,
        actual: Opcode,
        sequence: u32,
    },
    RemoteError {
        sequence: u32,
        code: u64,
        detail: u64,
    },
    CompletionFailed {
        sequence: u32,
        code: u64,
        completed_operations: u64,
    },
    CompletionCount {
        expected: u64,
        actual: u64,
    },
}

impl<LinkError: fmt::Display> fmt::Display for TransportError<LinkError> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Link(error) => write!(formatter, "QShell record link failed: {error}"),
            Self::Decode(error) => write!(formatter, "invalid QShell response: {error}"),
            Self::AlreadyActive => formatter.write_str("a QShell job is already active"),
            Self::Inactive => formatter.write_str("no QShell job is active"),
            Self::SequenceOverflow => formatter.write_str("QShell sequence number overflow"),
            Self::StaleResponseLimit => formatter.write_str("too many stale QShell responses"),
            Self::UnexpectedResponse {
                expected,
                actual,
                sequence,
            } => write!(
                formatter,
                "expected {expected:?} for sequence {sequence}, received {actual:?}"
            ),
            Self::RemoteError {
                sequence,
                code,
                detail,
            } => write!(
                formatter,
                "QShell frontend error {code} at sequence {sequence} (detail {detail})"
            ),
            Self::CompletionFailed {
                sequence,
                code,
                completed_operations,
            } => write!(
                formatter,
                "QShell job failed at sequence {sequence} with completion {code} after {completed_operations} operations"
            ),
            Self::CompletionCount { expected, actual } => write!(
                formatter,
                "QShell completion reported {actual} operations, expected {expected}"
            ),
        }
    }
}

impl<LinkError: fmt::Debug + fmt::Display> std::error::Error for TransportError<LinkError> {}

impl<LinkError> From<DecodeError> for TransportError<LinkError> {
    fn from(error: DecodeError) -> Self {
        Self::Decode(error)
    }
}

/// Stateful native transport preserving the existing synchronous MMIO
/// semantics over protocol-v1 records.
pub struct QshellMmioTransport<Link> {
    link: Link,
    graph_id: GraphId,
    request_id: u32,
    sequence: u32,
    operations: u64,
    active: bool,
}

impl<Link: RecordLink> QshellMmioTransport<Link> {
    pub fn new(link: Link, graph_id: GraphId) -> Self {
        Self {
            link,
            graph_id,
            request_id: 0,
            sequence: 0,
            operations: 0,
            active: false,
        }
    }

    pub const fn is_active(&self) -> bool {
        self.active
    }

    pub const fn operations(&self) -> u64 {
        self.operations
    }

    pub fn link(&self) -> &Link {
        &self.link
    }

    pub fn link_mut(&mut self) -> &mut Link {
        &mut self.link
    }

    pub fn into_inner(self) -> Link {
        self.link
    }

    pub fn begin_job(
        &mut self,
        request_id: u32,
        expected_operations: u64,
    ) -> Result<(), TransportError<Link::Error>> {
        if self.active {
            return Err(TransportError::AlreadyActive);
        }
        self.link
            .send_record(Record::begin_job(self.graph_id, request_id, expected_operations).encode())
            .map_err(TransportError::Link)?;
        self.request_id = request_id;
        self.sequence = 1;
        self.operations = 0;
        self.active = true;
        Ok(())
    }

    pub fn mmio_write(
        &mut self,
        width: AccessWidth,
        address: u64,
        value: u64,
    ) -> Result<(), TransportError<Link::Error>> {
        self.ensure_active()?;
        let sequence = self.sequence;
        self.link
            .send_record(
                Record::mmio_write(
                    self.graph_id,
                    self.request_id,
                    sequence,
                    width,
                    address,
                    value,
                )
                .encode(),
            )
            .map_err(TransportError::Link)?;
        self.advance()?;
        Ok(())
    }

    pub fn mmio_read(
        &mut self,
        width: AccessWidth,
        address: u64,
    ) -> Result<u64, TransportError<Link::Error>> {
        self.ensure_active()?;
        let sequence = self.sequence;
        self.link
            .send_record(
                Record::mmio_read(self.graph_id, self.request_id, sequence, width, address)
                    .encode(),
            )
            .map_err(TransportError::Link)?;
        let response = self.receive_matching(Opcode::ReadResult, sequence)?;
        if response.access_width() != Some(width) || response.argument0 != address {
            return Err(TransportError::UnexpectedResponse {
                expected: Opcode::ReadResult,
                actual: response.opcode,
                sequence,
            });
        }
        self.advance()?;
        Ok(response.argument1)
    }

    pub fn end_job(&mut self) -> Result<u64, TransportError<Link::Error>> {
        self.ensure_active()?;
        let sequence = self.sequence;
        self.link
            .send_record(Record::end_job(self.graph_id, self.request_id, sequence).encode())
            .map_err(TransportError::Link)?;
        let response = self.receive_matching(Opcode::Completion, sequence)?;
        self.active = false;
        if response.argument0 != CompletionCode::Success as u64 {
            return Err(TransportError::CompletionFailed {
                sequence,
                code: response.argument0,
                completed_operations: response.argument1,
            });
        }
        if response.argument1 != self.operations {
            return Err(TransportError::CompletionCount {
                expected: self.operations,
                actual: response.argument1,
            });
        }
        Ok(response.argument1)
    }

    fn ensure_active(&self) -> Result<(), TransportError<Link::Error>> {
        if self.active {
            Ok(())
        } else {
            Err(TransportError::Inactive)
        }
    }

    fn advance(&mut self) -> Result<(), TransportError<Link::Error>> {
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or(TransportError::SequenceOverflow)?;
        self.operations = self
            .operations
            .checked_add(1)
            .ok_or(TransportError::SequenceOverflow)?;
        Ok(())
    }

    fn receive_matching(
        &mut self,
        expected_opcode: Opcode,
        expected_sequence: u32,
    ) -> Result<Record, TransportError<Link::Error>> {
        for _ in 0..MAX_STALE_RESPONSES {
            let bytes = self.link.receive_record().map_err(TransportError::Link)?;
            let response = Record::decode(&bytes)?;
            if response.graph_id != self.graph_id || response.request_id != self.request_id {
                continue;
            }
            if response.opcode == Opcode::Error {
                return Err(TransportError::RemoteError {
                    sequence: response.sequence,
                    code: response.argument0,
                    detail: response.argument1,
                });
            }
            if response.opcode == Opcode::Completion && expected_opcode != Opcode::Completion {
                return Err(TransportError::CompletionFailed {
                    sequence: response.sequence,
                    code: response.argument0,
                    completed_operations: response.argument1,
                });
            }
            if response.sequence != expected_sequence {
                continue;
            }
            if response.opcode != expected_opcode {
                return Err(TransportError::UnexpectedResponse {
                    expected: expected_opcode,
                    actual: response.opcode,
                    sequence: expected_sequence,
                });
            }
            return Ok(response);
        }
        Err(TransportError::StaleResponseLimit)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DecodeError {
    BadMagic,
    UnsupportedVersion(u8),
    UnknownOpcode(u8),
    InvalidFlags(u16),
}

impl fmt::Display for DecodeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BadMagic => formatter.write_str("invalid MicroBlossom QShell magic"),
            Self::UnsupportedVersion(version) => {
                write!(
                    formatter,
                    "unsupported MicroBlossom QShell version {version}"
                )
            }
            Self::UnknownOpcode(opcode) => write!(formatter, "unknown opcode 0x{opcode:02x}"),
            Self::InvalidFlags(flags) => write!(formatter, "invalid flags 0x{flags:04x}"),
        }
    }
}

impl std::error::Error for DecodeError {}

pub const COPROCESSOR_REQUEST_PREFIX_BYTES: usize = 40;
pub const COPROCESSOR_RESULT_PREFIX_BYTES: usize = 44;
const DECODE_REQUEST_MAGIC: [u8; 4] = *b"MBJ1";
const DECODE_RESULT_MAGIC: [u8; 4] = *b"MBR1";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CoprocessorContractError {
    ZeroGraphIdentity,
    InvalidGraphShape,
    PacketStorageExceeded,
}

impl fmt::Display for CoprocessorContractError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ZeroGraphIdentity => formatter.write_str("graph identity must be nonzero"),
            Self::InvalidGraphShape => formatter.write_str("graph dimensions are inconsistent"),
            Self::PacketStorageExceeded => write!(
                formatter,
                "graph records exceed the {MAX_QSHELL_PACKET_BYTES}-byte provider store"
            ),
        }
    }
}

impl std::error::Error for CoprocessorContractError {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CoprocessorGraphContract {
    graph_id: GraphId,
    vertex_count: u16,
    edge_count: u16,
    virtual_vertices: Vec<u16>,
    max_defects: usize,
    max_correction_edges: usize,
}

impl CoprocessorGraphContract {
    pub fn new(
        graph_id: GraphId,
        vertex_count: u16,
        edge_count: u16,
        virtual_vertices: &[u16],
    ) -> Result<Self, CoprocessorContractError> {
        Self::new_with_capacities(
            graph_id,
            vertex_count,
            edge_count,
            virtual_vertices,
            usize::from(vertex_count).saturating_sub(virtual_vertices.len()),
            usize::from(edge_count),
        )
    }

    pub fn new_with_capacities(
        graph_id: GraphId,
        vertex_count: u16,
        edge_count: u16,
        virtual_vertices: &[u16],
        max_defects: usize,
        max_correction_edges: usize,
    ) -> Result<Self, CoprocessorContractError> {
        if graph_id.iter().all(|byte| *byte == 0) {
            return Err(CoprocessorContractError::ZeroGraphIdentity);
        }
        let nonvirtual_vertices = usize::from(vertex_count).saturating_sub(virtual_vertices.len());
        if vertex_count == 0
            || edge_count == 0
            || virtual_vertices.len() >= usize::from(vertex_count)
            || virtual_vertices
                .iter()
                .any(|vertex| *vertex >= vertex_count)
            || virtual_vertices.windows(2).any(|pair| pair[0] >= pair[1])
            || max_defects < nonvirtual_vertices
            || max_defects > usize::from(vertex_count)
            || max_correction_edges == 0
            || max_correction_edges > usize::from(edge_count)
        {
            return Err(CoprocessorContractError::InvalidGraphShape);
        }
        let contract = Self {
            graph_id,
            vertex_count,
            edge_count,
            virtual_vertices: virtual_vertices.to_vec(),
            max_defects,
            max_correction_edges,
        };
        if contract.request_packet_bytes() > MAX_QSHELL_PACKET_BYTES
            || contract.response_packet_bytes() > MAX_QSHELL_PACKET_BYTES
            || contract.request_beats() > MAX_QSHELL_PACKET_BEATS
            || contract.response_beats() > MAX_QSHELL_PACKET_BEATS
        {
            return Err(CoprocessorContractError::PacketStorageExceeded);
        }
        Ok(contract)
    }

    pub const fn graph_id(&self) -> GraphId {
        self.graph_id
    }

    pub const fn vertex_count(&self) -> u16 {
        self.vertex_count
    }

    pub fn virtual_vertices(&self) -> &[u16] {
        &self.virtual_vertices
    }

    pub fn virtual_vertex_count(&self) -> usize {
        self.virtual_vertices.len()
    }

    pub const fn edge_count(&self) -> u16 {
        self.edge_count
    }

    pub fn is_virtual_vertex(&self, vertex: u16) -> bool {
        self.virtual_vertices.binary_search(&vertex).is_ok()
    }

    pub const fn max_defects(&self) -> usize {
        self.max_defects
    }

    pub const fn max_correction_edges(&self) -> usize {
        self.max_correction_edges
    }

    pub fn has_exact_graph_capacities(&self) -> bool {
        self.max_defects == usize::from(self.vertex_count) - self.virtual_vertices.len()
            && self.max_correction_edges == usize::from(self.edge_count)
    }

    pub fn request_payload_bytes(&self) -> usize {
        COPROCESSOR_REQUEST_PREFIX_BYTES + 2 * self.max_defects()
    }

    pub const fn response_payload_bytes(&self) -> usize {
        COPROCESSOR_RESULT_PREFIX_BYTES + 2 * self.max_correction_edges()
    }

    pub fn request_packet_bytes(&self) -> usize {
        qshell_abi::HEADER_BYTES + self.request_payload_bytes()
    }

    pub const fn response_packet_bytes(&self) -> usize {
        qshell_abi::HEADER_BYTES + self.response_payload_bytes()
    }

    pub fn request_beats(&self) -> usize {
        packet_beats(self.request_packet_bytes())
    }

    pub const fn response_beats(&self) -> usize {
        packet_beats(self.response_packet_bytes())
    }
}

const fn packet_beats(bytes: usize) -> usize {
    (bytes + qshell_abi::BEAT_BYTES - 1) / qshell_abi::BEAT_BYTES
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DecodeRequest {
    pub graph_id: GraphId,
    pub defects: Vec<u16>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DecodeResult {
    pub graph_id: GraphId,
    pub status: u16,
    pub accelerator_operations: u16,
    pub correction_edges: Vec<u16>,
}

pub struct CoprocessorQshellLink<Link: BeatLink> {
    link: Link,
    route: QshellRoute,
    contract: CoprocessorGraphContract,
    round_id: u32,
    expected_route_version: u32,
    poisoned: bool,
}

impl<Link: BeatLink> CoprocessorQshellLink<Link> {
    /// Establish a decode session from a freshly opened transport epoch and
    /// its currently admitted route capability. A poisoned instance cannot be
    /// refreshed in place because an accepted round may still be outstanding.
    pub fn new(
        link: Link,
        route: QshellRoute,
        contract: CoprocessorGraphContract,
        expected_route_version: u32,
    ) -> Self {
        Self {
            link,
            round_id: route.initial_round_id,
            route,
            contract,
            expected_route_version,
            poisoned: false,
        }
    }

    pub fn contract(&self) -> &CoprocessorGraphContract {
        &self.contract
    }

    pub fn link(&self) -> &Link {
        &self.link
    }

    pub fn link_mut(&mut self) -> &mut Link {
        &mut self.link
    }

    pub const fn expected_route_version(&self) -> u32 {
        self.expected_route_version
    }

    pub const fn poisoned(&self) -> bool {
        self.poisoned
    }

    fn ensure_healthy(&self) -> Result<(), QshellLinkError<Link::Error>> {
        if self.poisoned {
            Err(QshellLinkError::LinkPoisoned)
        } else {
            Ok(())
        }
    }

    fn send_axis_beat(&mut self, beat: AxisBeat) -> Result<(), QshellLinkError<Link::Error>> {
        match self.link.send_beat(beat) {
            Ok(()) => Ok(()),
            Err(error) => {
                // BeatLink has no accepted-count receipt, so a send failure is
                // ambiguous and cannot be treated as a provably pre-send error.
                self.poisoned = true;
                Err(QshellLinkError::Link(error))
            }
        }
    }

    fn receive_axis_beat(&mut self) -> Result<AxisBeat, QshellLinkError<Link::Error>> {
        match self.link.receive_beat() {
            Ok(beat) => Ok(beat),
            Err(error) => {
                self.poisoned = true;
                Err(QshellLinkError::Link(error))
            }
        }
    }

    fn response_identity_matches(&self, first: &AxisBeat, schema_id: u32) -> bool {
        let route_version = get_u32(&first.data, qshell_abi::offset::ROUTE_VERSION);
        let expected_source = self.route.expected_decoder_endpoint_id;
        get_u32(&first.data, qshell_abi::offset::CONTEXT_ID) == self.route.context_id
            && get_u32(&first.data, qshell_abi::offset::ROUND_ID) == self.round_id
            && get_u32(&first.data, qshell_abi::offset::SCHEMA_ID) == schema_id
            && expected_source.is_some_and(|source| {
                source != 0
                    && get_u32(&first.data, qshell_abi::offset::SOURCE_ENDPOINT_ID) == source
            })
            && get_u32(&first.data, qshell_abi::offset::DESTINATION_ENDPOINT_ID)
                == self.route.source_endpoint_id
            && get_u32(&first.data, qshell_abi::offset::ROUTE_CAPABILITY_ID)
                == self.route.route_capability_id
            && route_version != 0
            && route_version == self.expected_route_version
            && get_u32(&first.data, qshell_abi::offset::RECORD_SEQUENCE) == 0
    }

    fn send_payload(&mut self, payload: &[u8]) -> Result<(), QshellLinkError<Link::Error>> {
        let mut first = AxisBeat {
            data: [0; qshell_abi::BEAT_BYTES],
            keep: u64::MAX,
            last: false,
        };
        put_u32(
            &mut first.data,
            qshell_abi::offset::MAGIC,
            qshell_abi::MAGIC,
        );
        first.data[qshell_abi::offset::ABI_VERSION] = qshell_abi::VERSION;
        first.data[qshell_abi::offset::RECORD_CLASS] = qshell_abi::record_class::SYNDROME;
        put_u16(
            &mut first.data,
            qshell_abi::offset::FLAGS,
            qshell_abi::flag::END_OF_ROUND,
        );
        put_u16(
            &mut first.data,
            qshell_abi::offset::HEADER_BYTES,
            qshell_abi::HEADER_BYTES as u16,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::PAYLOAD_BYTES,
            payload.len() as u32,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::CONTEXT_ID,
            self.route.context_id,
        );
        put_u32(&mut first.data, qshell_abi::offset::ROUND_ID, self.round_id);
        put_u32(
            &mut first.data,
            qshell_abi::offset::SCHEMA_ID,
            qshell_abi::schema::MICROBLOSSOM_DECODE_REQUEST,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::SOURCE_ENDPOINT_ID,
            self.route.source_endpoint_id,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::DESTINATION_ENDPOINT_ID,
            0,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::ROUTE_CAPABILITY_ID,
            self.route.route_capability_id,
        );
        put_u32(&mut first.data, qshell_abi::offset::ROUTE_VERSION, 0);
        put_u32(&mut first.data, qshell_abi::offset::RECORD_SEQUENCE, 0);
        first.data[qshell_abi::HEADER_BYTES..].copy_from_slice(&payload[..16]);
        self.send_axis_beat(first)?;

        let mut offset = 16;
        while offset < payload.len() {
            let valid = (payload.len() - offset).min(qshell_abi::BEAT_BYTES);
            let mut beat = AxisBeat {
                data: [0; qshell_abi::BEAT_BYTES],
                keep: low_keep(valid),
                last: offset + valid == payload.len(),
            };
            beat.data[..valid].copy_from_slice(&payload[offset..offset + valid]);
            self.send_axis_beat(beat)?;
            offset += valid;
        }
        Ok(())
    }

    fn receive_payload_tail(
        &mut self,
        first: AxisBeat,
        payload_bytes: usize,
    ) -> Result<Vec<u8>, QshellLinkError<Link::Error>> {
        let first_payload = qshell_abi::BEAT_BYTES - qshell_abi::HEADER_BYTES;
        if payload_bytes < first_payload
            || qshell_abi::HEADER_BYTES
                .checked_add(payload_bytes)
                .map_or(true, |packet_bytes| packet_bytes > MAX_QSHELL_PACKET_BYTES)
        {
            return Err(QshellLinkError::InvalidEnvelopeLength(payload_bytes as u32));
        }
        let mut payload = vec![0_u8; payload_bytes];
        payload[..first_payload].copy_from_slice(&first.data[qshell_abi::HEADER_BYTES..]);
        let mut offset = first_payload;
        while offset < payload.len() {
            let beat = self.receive_axis_beat()?;
            let valid = (payload.len() - offset).min(qshell_abi::BEAT_BYTES);
            let expected_keep = low_keep(valid);
            if beat.keep != expected_keep {
                return Err(QshellLinkError::InvalidEnvelopeKeep {
                    expected: expected_keep,
                    actual: beat.keep,
                });
            }
            let expected_last = offset + valid == payload.len();
            if beat.last != expected_last {
                return Err(QshellLinkError::MalformedEnvelope);
            }
            payload[offset..offset + valid].copy_from_slice(&beat.data[..valid]);
            offset += valid;
        }
        Ok(payload)
    }

    pub fn decode(
        &mut self,
        request: &DecodeRequest,
    ) -> Result<DecodeResult, QshellLinkError<Link::Error>> {
        self.ensure_healthy()?;
        if request.graph_id != self.contract.graph_id() {
            return Err(QshellLinkError::RequestGraphMismatch);
        }
        if request.defects.len() > self.contract.max_defects()
            || request.defects.iter().any(|defect| {
                *defect >= self.contract.vertex_count() || self.contract.is_virtual_vertex(*defect)
            })
            || request.defects.windows(2).any(|pair| pair[0] >= pair[1])
        {
            return Err(QshellLinkError::InvalidDefects);
        }

        let mut request_payload = vec![0_u8; self.contract.request_payload_bytes()];
        request_payload[..4].copy_from_slice(&DECODE_REQUEST_MAGIC);
        put_u16(&mut request_payload, 4, 1);
        put_u16(&mut request_payload, 6, request.defects.len() as u16);
        request_payload[8..40].copy_from_slice(&request.graph_id);
        for (index, defect) in request.defects.iter().enumerate() {
            put_u16(
                &mut request_payload,
                COPROCESSOR_REQUEST_PREFIX_BYTES + 2 * index,
                *defect,
            );
        }
        self.send_payload(&request_payload)?;

        // send_payload returns only after the final EOR beat has been accepted
        // by the link. No response fault can make that round safe to resend.
        let response = self.receive_decode_response();
        if response.is_err() {
            self.poisoned = true;
        }
        response
    }

    fn receive_decode_response(&mut self) -> Result<DecodeResult, QshellLinkError<Link::Error>> {
        let first = self.receive_axis_beat()?;
        if first.keep != u64::MAX {
            return Err(QshellLinkError::InvalidEnvelopeKeep {
                expected: u64::MAX,
                actual: first.keep,
            });
        }
        if first.last
            || get_u32(&first.data, qshell_abi::offset::MAGIC) != qshell_abi::MAGIC
            || first.data[qshell_abi::offset::ABI_VERSION] != qshell_abi::VERSION
            || get_u16(&first.data, qshell_abi::offset::HEADER_BYTES)
                != qshell_abi::HEADER_BYTES as u16
            || get_u16(&first.data, qshell_abi::offset::RESERVED) != 0
        {
            return Err(QshellLinkError::MalformedEnvelope);
        }

        let record_class = first.data[qshell_abi::offset::RECORD_CLASS];
        if record_class != qshell_abi::record_class::CORRECTION {
            return Err(QshellLinkError::UnexpectedClass(record_class));
        }
        let flags = get_u16(&first.data, qshell_abi::offset::FLAGS);
        if flags != qshell_abi::flag::END_OF_ROUND {
            return Err(QshellLinkError::InvalidEnvelopeFlags(flags));
        }
        let payload_bytes = get_u32(&first.data, qshell_abi::offset::PAYLOAD_BYTES) as usize;
        if payload_bytes != self.contract.response_payload_bytes() {
            return Err(QshellLinkError::InvalidEnvelopeLength(payload_bytes as u32));
        }

        let result_payload = self.receive_payload_tail(first, payload_bytes)?;
        if !self.response_identity_matches(&first, qshell_abi::schema::MICROBLOSSOM_DECODE_RESULT) {
            return Err(QshellLinkError::MetadataMismatch);
        }
        if result_payload[..4] != DECODE_RESULT_MAGIC || get_u16(&result_payload, 4) != 1 {
            return Err(QshellLinkError::MalformedEnvelope);
        }
        let mut graph_id = [0_u8; 32];
        graph_id.copy_from_slice(&result_payload[8..40]);
        if graph_id != self.contract.graph_id() {
            return Err(QshellLinkError::ResultGraphMismatch);
        }
        let edge_count = get_u16(&result_payload, 40) as usize;
        if edge_count > self.contract.max_correction_edges() {
            return Err(QshellLinkError::MalformedEnvelope);
        }
        let mut correction_edges = Vec::with_capacity(edge_count);
        for index in 0..edge_count {
            let edge = get_u16(&result_payload, COPROCESSOR_RESULT_PREFIX_BYTES + 2 * index);
            if edge >= self.contract.edge_count() {
                return Err(QshellLinkError::InvalidCorrectionEdge(edge));
            }
            correction_edges.push(edge);
        }
        if result_payload[COPROCESSOR_RESULT_PREFIX_BYTES + 2 * edge_count..]
            .iter()
            .any(|byte| *byte != 0)
        {
            return Err(QshellLinkError::NonzeroPayloadPadding);
        }

        self.round_id = self.round_id.wrapping_add(1);
        Ok(DecodeResult {
            graph_id,
            status: get_u16(&result_payload, 6),
            accelerator_operations: get_u16(&result_payload, 42),
            correction_edges,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GRAPH_ID: GraphId = [
        0x4b, 0x07, 0x8d, 0x3b, 0x6c, 0x6d, 0xb2, 0x4e, 0xa9, 0x72, 0x64, 0x14, 0x56, 0x9a, 0x97,
        0xb3, 0x89, 0x9b, 0xe4, 0xe5, 0x32, 0xbe, 0x1c, 0x0e, 0xbd, 0x84, 0xb5, 0xfa, 0x87, 0x53,
        0x16, 0xc5,
    ];

    #[test]
    fn round_trips_all_record_classes() {
        let records = [
            Record::begin_job(GRAPH_ID, 7, 3),
            Record::mmio_write(GRAPH_ID, 7, 1, AccessWidth::DoubleWord, 0x1000, 0x1234),
            Record::mmio_read(GRAPH_ID, 7, 2, AccessWidth::Word, 0x20),
            Record::end_job(GRAPH_ID, 7, 3),
            Record::read_result(GRAPH_ID, 7, 2, AccessWidth::Word, 0x20, 0xfeed_beef),
            Record::completion(GRAPH_ID, 7, 3, CompletionCode::Success, 3),
            Record::error(GRAPH_ID, 7, 3, ErrorCode::GraphMismatch, 0),
        ];

        for record in records {
            assert_eq!(Record::decode(&record.encode()), Ok(record));
        }
    }

    #[test]
    fn write_wire_layout_is_stable() {
        let record = Record::mmio_write(
            GRAPH_ID,
            0x1122_3344,
            0x5566_7788,
            AccessWidth::DoubleWord,
            0x0102_0304_0506_0708,
            0x1112_1314_1516_1718,
        );
        let bytes = record.encode();

        assert_eq!(&bytes[0..4], b"MBQ1");
        assert_eq!(bytes[4], 1);
        assert_eq!(bytes[5], 2);
        assert_eq!(&bytes[6..8], &[3, 0]);
        assert_eq!(&bytes[8..12], &[0x44, 0x33, 0x22, 0x11]);
        assert_eq!(&bytes[12..16], &[0x88, 0x77, 0x66, 0x55]);
        assert_eq!(&bytes[16..48], &GRAPH_ID);
        assert_eq!(&bytes[48..56], &[8, 7, 6, 5, 4, 3, 2, 1]);
        assert_eq!(
            &bytes[56..64],
            &[0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11]
        );
        assert_eq!(record.access_width(), Some(AccessWidth::DoubleWord));
        assert!(!record.is_response());
    }

    #[test]
    fn rejects_bad_headers_and_flags() {
        let mut bytes = Record::begin_job(GRAPH_ID, 1, 0).encode();
        bytes[0] = b'X';
        assert_eq!(Record::decode(&bytes), Err(DecodeError::BadMagic));

        let mut bytes = Record::begin_job(GRAPH_ID, 1, 0).encode();
        bytes[4] = 2;
        assert_eq!(
            Record::decode(&bytes),
            Err(DecodeError::UnsupportedVersion(2))
        );

        let mut bytes = Record::begin_job(GRAPH_ID, 1, 0).encode();
        bytes[5] = 0x42;
        assert_eq!(
            Record::decode(&bytes),
            Err(DecodeError::UnknownOpcode(0x42))
        );

        let mut bytes = Record::begin_job(GRAPH_ID, 1, 0).encode();
        bytes[6..8].copy_from_slice(&0x8000_u16.to_le_bytes());
        assert_eq!(
            Record::decode(&bytes),
            Err(DecodeError::InvalidFlags(0x8000))
        );

        let mut bytes = Record::completion(GRAPH_ID, 1, 0, CompletionCode::Success, 0).encode();
        bytes[6..8].copy_from_slice(&0_u16.to_le_bytes());
        assert_eq!(Record::decode(&bytes), Err(DecodeError::InvalidFlags(0)));
    }

    #[derive(Default)]
    struct MockLink {
        sent: Vec<[u8; RECORD_BYTES]>,
        responses: std::collections::VecDeque<[u8; RECORD_BYTES]>,
    }

    impl RecordLink for MockLink {
        type Error = &'static str;

        fn send_record(&mut self, record: [u8; RECORD_BYTES]) -> Result<(), Self::Error> {
            self.sent.push(record);
            Ok(())
        }

        fn receive_record(&mut self) -> Result<[u8; RECORD_BYTES], Self::Error> {
            self.responses.pop_front().ok_or("response queue empty")
        }
    }

    #[test]
    fn native_transport_preserves_order_and_ignores_stale_responses() {
        let mut link = MockLink::default();
        link.responses.push_back(
            Record::read_result(GRAPH_ID, 99, 2, AccessWidth::Word, 0x24, 0xdead).encode(),
        );
        link.responses.push_back(
            Record::read_result(GRAPH_ID, 7, 2, AccessWidth::Word, 0x24, 0xfeed_beef).encode(),
        );
        link.responses
            .push_back(Record::completion(GRAPH_ID, 7, 3, CompletionCode::Success, 2).encode());

        let mut transport = QshellMmioTransport::new(link, GRAPH_ID);
        transport.begin_job(7, UNBOUNDED_OPERATIONS).unwrap();
        transport
            .mmio_write(AccessWidth::DoubleWord, 0x1000, 0x1234)
            .unwrap();
        assert_eq!(
            transport.mmio_read(AccessWidth::Word, 0x24).unwrap(),
            0xfeed_beef
        );
        assert_eq!(transport.end_job().unwrap(), 2);
        assert!(!transport.is_active());

        let link = transport.into_inner();
        let sent: Vec<_> = link
            .sent
            .iter()
            .map(|bytes| Record::decode(bytes).unwrap())
            .collect();
        assert_eq!(
            sent[0],
            Record::begin_job(GRAPH_ID, 7, UNBOUNDED_OPERATIONS)
        );
        assert_eq!(sent[0].sequence, 0);
        assert_eq!(sent[1].opcode, Opcode::MmioWrite);
        assert_eq!(sent[1].sequence, 1);
        assert_eq!(sent[2].opcode, Opcode::MmioRead);
        assert_eq!(sent[2].sequence, 2);
        assert_eq!(sent[3], Record::end_job(GRAPH_ID, 7, 3));
    }

    #[test]
    fn native_transport_surfaces_remote_and_malformed_responses() {
        let mut link = MockLink::default();
        link.responses
            .push_back(Record::error(GRAPH_ID, 8, 1, ErrorCode::AcceleratorFault, 2).encode());
        let mut transport = QshellMmioTransport::new(link, GRAPH_ID);
        transport.begin_job(8, UNBOUNDED_OPERATIONS).unwrap();
        assert!(matches!(
            transport.mmio_read(AccessWidth::DoubleWord, 0x100),
            Err(TransportError::RemoteError {
                sequence: 1,
                code: 7,
                detail: 2
            })
        ));

        let mut link = MockLink::default();
        let mut malformed =
            Record::read_result(GRAPH_ID, 9, 1, AccessWidth::DoubleWord, 0x100, 0).encode();
        malformed[0] = 0;
        link.responses.push_back(malformed);
        let mut transport = QshellMmioTransport::new(link, GRAPH_ID);
        transport.begin_job(9, UNBOUNDED_OPERATIONS).unwrap();
        assert!(matches!(
            transport.mmio_read(AccessWidth::DoubleWord, 0x100),
            Err(TransportError::Decode(DecodeError::BadMagic))
        ));
    }

    #[derive(Default)]
    struct MockBeatLink {
        sent: Vec<AxisBeat>,
        responses: std::collections::VecDeque<AxisBeat>,
    }

    impl BeatLink for MockBeatLink {
        type Error = &'static str;

        fn send_beat(&mut self, beat: AxisBeat) -> Result<(), Self::Error> {
            self.sent.push(beat);
            Ok(())
        }

        fn receive_beat(&mut self) -> Result<AxisBeat, Self::Error> {
            self.responses.pop_front().ok_or("beat queue empty")
        }
    }

    fn route() -> QshellRoute {
        QshellRoute {
            context_id: 7,
            initial_round_id: 42,
            source_endpoint_id: 0x12,
            route_capability_id: 0x8765_4321,
            expected_decoder_endpoint_id: Some(0x101),
        }
    }

    fn correction_beats(
        payload: [u8; RECORD_BYTES],
        sequence: u32,
        end_of_round: bool,
    ) -> [AxisBeat; 2] {
        let mut first = AxisBeat {
            data: [0; qshell_abi::BEAT_BYTES],
            keep: u64::MAX,
            last: false,
        };
        put_u32(
            &mut first.data,
            qshell_abi::offset::MAGIC,
            qshell_abi::MAGIC,
        );
        first.data[qshell_abi::offset::ABI_VERSION] = qshell_abi::VERSION;
        first.data[qshell_abi::offset::RECORD_CLASS] = qshell_abi::record_class::CORRECTION;
        put_u16(
            &mut first.data,
            qshell_abi::offset::FLAGS,
            if end_of_round {
                qshell_abi::flag::END_OF_ROUND
            } else {
                0
            },
        );
        put_u16(
            &mut first.data,
            qshell_abi::offset::HEADER_BYTES,
            qshell_abi::HEADER_BYTES as u16,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::PAYLOAD_BYTES,
            RECORD_BYTES as u32,
        );
        put_u32(&mut first.data, qshell_abi::offset::CONTEXT_ID, 7);
        put_u32(&mut first.data, qshell_abi::offset::ROUND_ID, 42);
        put_u32(
            &mut first.data,
            qshell_abi::offset::SCHEMA_ID,
            qshell_abi::schema::MICROBLOSSOM_RESPONSE,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::SOURCE_ENDPOINT_ID,
            0x101,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::DESTINATION_ENDPOINT_ID,
            0x12,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::ROUTE_CAPABILITY_ID,
            0x8765_4321,
        );
        put_u32(&mut first.data, qshell_abi::offset::ROUTE_VERSION, 9);
        put_u32(
            &mut first.data,
            qshell_abi::offset::RECORD_SEQUENCE,
            sequence,
        );
        first.data[qshell_abi::HEADER_BYTES..].copy_from_slice(&payload[..16]);

        let mut continuation = AxisBeat {
            data: [0; qshell_abi::BEAT_BYTES],
            keep: low_keep(48),
            last: true,
        };
        continuation.data[..48].copy_from_slice(&payload[16..]);
        [first, continuation]
    }

    fn qshell_error_beats(code: u16, scope: u8, detail: u32) -> [AxisBeat; 2] {
        let mut first = AxisBeat {
            data: [0; qshell_abi::BEAT_BYTES],
            keep: u64::MAX,
            last: false,
        };
        put_u32(
            &mut first.data,
            qshell_abi::offset::MAGIC,
            qshell_abi::MAGIC,
        );
        first.data[qshell_abi::offset::ABI_VERSION] = qshell_abi::VERSION;
        first.data[qshell_abi::offset::RECORD_CLASS] = qshell_abi::record_class::ERROR;
        put_u16(
            &mut first.data,
            qshell_abi::offset::HEADER_BYTES,
            qshell_abi::HEADER_BYTES as u16,
        );
        put_u32(&mut first.data, qshell_abi::offset::PAYLOAD_BYTES, 24);
        put_u32(
            &mut first.data,
            qshell_abi::offset::SCHEMA_ID,
            qshell_abi::schema::ERROR,
        );
        let payload = &mut first.data[qshell_abi::HEADER_BYTES..];
        payload[0..2].copy_from_slice(&code.to_le_bytes());
        payload[2] = scope;
        payload[3] = qshell_abi::record_class::SYNDROME;
        payload[4..8].copy_from_slice(&detail.to_le_bytes());

        let continuation = AxisBeat {
            data: [0; qshell_abi::BEAT_BYTES],
            keep: low_keep(8),
            last: true,
        };
        [first, continuation]
    }

    #[test]
    fn qshell_abi_link_frames_commands_and_validates_corrections() {
        let mut link = QshellRecordLink::new(MockBeatLink::default(), route());
        let begin = Record::begin_job(GRAPH_ID, 7, 1).encode();
        link.send_record(begin).unwrap();
        assert_eq!(link.command_sequence(), 1);
        assert_eq!(link.link().sent.len(), 2);
        let first = link.link().sent[0];
        assert_eq!(first.keep, u64::MAX);
        assert!(!first.last);
        assert_eq!(
            first.data[qshell_abi::offset::RECORD_CLASS],
            qshell_abi::record_class::SYNDROME
        );
        assert_eq!(
            get_u32(&first.data, qshell_abi::offset::SCHEMA_ID),
            qshell_abi::schema::MICROBLOSSOM_COMMAND
        );
        assert_eq!(get_u32(&first.data, qshell_abi::offset::ROUTE_VERSION), 0);
        assert_eq!(&first.data[qshell_abi::HEADER_BYTES..], &begin[..16]);
        assert_eq!(link.link().sent[1].keep, low_keep(48));
        assert!(link.link().sent[1].last);
        assert_eq!(&link.link().sent[1].data[..48], &begin[16..]);

        let read = Record::mmio_read(GRAPH_ID, 7, 1, AccessWidth::DoubleWord, 8).encode();
        link.send_record(read).unwrap();
        let read_result =
            Record::read_result(GRAPH_ID, 7, 1, AccessWidth::DoubleWord, 8, 0x2401_23c0).encode();
        link.link_mut()
            .responses
            .extend(correction_beats(read_result, 0, false));
        assert_eq!(link.receive_record().unwrap(), read_result);
        assert_eq!(link.correction_sequence(), 1);
        assert_eq!(link.round_id(), 42);

        let end = Record::end_job(GRAPH_ID, 7, 2).encode();
        link.send_record(end).unwrap();
        let end_first = link.link().sent[4];
        assert_eq!(
            get_u16(&end_first.data, qshell_abi::offset::FLAGS),
            qshell_abi::flag::END_OF_ROUND
        );
        let completion = Record::completion(GRAPH_ID, 7, 2, CompletionCode::Success, 1).encode();
        link.link_mut()
            .responses
            .extend(correction_beats(completion, 1, true));
        assert_eq!(link.receive_record().unwrap(), completion);
        assert_eq!(link.round_id(), 43);
        assert_eq!(link.command_sequence(), 0);
        assert_eq!(link.correction_sequence(), 0);
    }

    #[test]
    fn qshell_abi_link_rejects_bad_sequence_and_envelope() {
        let mut link = QshellRecordLink::new(MockBeatLink::default(), route());
        let wrong = Record::mmio_read(GRAPH_ID, 1, 1, AccessWidth::Byte, 0).encode();
        assert!(matches!(
            link.send_record(wrong),
            Err(QshellLinkError::CommandSequence {
                expected: 0,
                actual: 1
            })
        ));

        let begin = Record::begin_job(GRAPH_ID, 1, 0).encode();
        link.send_record(begin).unwrap();
        let response = Record::read_result(GRAPH_ID, 1, 0, AccessWidth::Byte, 0, 0).encode();
        let [mut first, second] = correction_beats(response, 0, false);
        first.keep = low_keep(63);
        link.link_mut().responses.extend([first, second]);
        assert!(matches!(
            link.receive_record(),
            Err(QshellLinkError::InvalidEnvelopeKeep { .. })
        ));
    }

    #[test]
    fn native_transport_composes_with_qshell_abi_beat_link() {
        let read_result =
            Record::read_result(GRAPH_ID, 77, 1, AccessWidth::DoubleWord, 8, 0x2401_23c0).encode();
        let completion = Record::completion(GRAPH_ID, 77, 2, CompletionCode::Success, 1).encode();
        let mut beats = MockBeatLink::default();
        beats
            .responses
            .extend(correction_beats(read_result, 0, false));
        beats
            .responses
            .extend(correction_beats(completion, 1, true));

        let link = QshellRecordLink::new(beats, route());
        let mut transport = QshellMmioTransport::new(link, GRAPH_ID);
        transport.begin_job(77, 1).unwrap();
        assert_eq!(
            transport.mmio_read(AccessWidth::DoubleWord, 8).unwrap(),
            0x2401_23c0
        );
        assert_eq!(transport.end_job().unwrap(), 1);
        let link = transport.into_inner();
        assert_eq!(link.round_id(), 43);
        assert_eq!(link.link().sent.len(), 6);
    }

    #[test]
    fn qshell_abi_link_surfaces_structured_qshell_errors() {
        let mut link = QshellRecordLink::new(MockBeatLink::default(), route());
        link.link_mut().responses.extend(qshell_error_beats(
            qshell_abi::error_code::SEQUENCE_MISMATCH,
            qshell_abi::error_scope::ABORT_ROUND,
            9,
        ));
        assert!(matches!(
            link.receive_record(),
            Err(QshellLinkError::RemoteQshellError {
                code: qshell_abi::error_code::SEQUENCE_MISMATCH,
                scope: qshell_abi::error_scope::ABORT_ROUND,
                detail: 9,
            })
        ));
    }

    const CIRCUIT_D3_GRAPH_ID: GraphId = [
        0x3e, 0x6b, 0xfd, 0xfe, 0xb3, 0xcf, 0xdb, 0x3d, 0x47, 0xbf, 0x29, 0xc5, 0xda, 0x33, 0x4d,
        0x84, 0x84, 0x9a, 0xac, 0xfc, 0x54, 0x8e, 0x01, 0x45, 0xb8, 0xdb, 0x60, 0xd7, 0xf9, 0x92,
        0xb0, 0x19,
    ];
    const CIRCUIT_D9_GRAPH_ID: GraphId = [
        0x95, 0x82, 0xb1, 0xc0, 0x53, 0x9c, 0x72, 0xa7, 0xea, 0x76, 0xe1, 0xa7, 0xca, 0x72, 0x90,
        0xdf, 0x36, 0xff, 0x89, 0xf8, 0xe8, 0x4f, 0x53, 0xf6, 0x5f, 0x77, 0xd8, 0x68, 0x99, 0xbb,
        0xa4, 0x1a,
    ];
    const CIRCUIT_D3_VIRTUAL_VERTICES: [u16; 7] = [1, 2, 5, 8, 9, 12, 15];
    const CIRCUIT_D9_VIRTUAL_VERTICES: [u16; 73] = [
        1, 5, 11, 19, 20, 29, 37, 43, 47, 50, 54, 60, 68, 69, 78, 86, 92, 96, 99, 103, 109, 117,
        118, 127, 135, 141, 145, 148, 152, 158, 166, 167, 176, 184, 190, 194, 197, 201, 207, 215,
        216, 225, 233, 239, 243, 246, 250, 256, 264, 265, 274, 282, 288, 292, 295, 299, 305, 313,
        314, 323, 331, 337, 341, 344, 348, 354, 362, 363, 372, 380, 386, 390, 393,
    ];

    fn coprocessor_response_beats(
        contract: &CoprocessorGraphContract,
        edges: &[u16],
    ) -> Vec<AxisBeat> {
        let mut payload = vec![0_u8; contract.response_payload_bytes()];
        payload[..4].copy_from_slice(&DECODE_RESULT_MAGIC);
        put_u16(&mut payload, 4, 1);
        payload[8..40].copy_from_slice(&contract.graph_id());
        put_u16(&mut payload, 40, edges.len() as u16);
        put_u16(&mut payload, 42, 10);
        for (index, edge) in edges.iter().enumerate() {
            put_u16(
                &mut payload,
                COPROCESSOR_RESULT_PREFIX_BYTES + 2 * index,
                *edge,
            );
        }

        let mut first = AxisBeat {
            data: [0; qshell_abi::BEAT_BYTES],
            keep: u64::MAX,
            last: false,
        };
        put_u32(
            &mut first.data,
            qshell_abi::offset::MAGIC,
            qshell_abi::MAGIC,
        );
        first.data[qshell_abi::offset::ABI_VERSION] = qshell_abi::VERSION;
        first.data[qshell_abi::offset::RECORD_CLASS] = qshell_abi::record_class::CORRECTION;
        put_u16(
            &mut first.data,
            qshell_abi::offset::FLAGS,
            qshell_abi::flag::END_OF_ROUND,
        );
        put_u16(
            &mut first.data,
            qshell_abi::offset::HEADER_BYTES,
            qshell_abi::HEADER_BYTES as u16,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::PAYLOAD_BYTES,
            payload.len() as u32,
        );
        put_u32(&mut first.data, qshell_abi::offset::CONTEXT_ID, 7);
        put_u32(&mut first.data, qshell_abi::offset::ROUND_ID, 42);
        put_u32(
            &mut first.data,
            qshell_abi::offset::SCHEMA_ID,
            qshell_abi::schema::MICROBLOSSOM_DECODE_RESULT,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::SOURCE_ENDPOINT_ID,
            0x101,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::DESTINATION_ENDPOINT_ID,
            0x12,
        );
        put_u32(
            &mut first.data,
            qshell_abi::offset::ROUTE_CAPABILITY_ID,
            0x8765_4321,
        );
        put_u32(&mut first.data, qshell_abi::offset::ROUTE_VERSION, 9);
        first.data[qshell_abi::HEADER_BYTES..].copy_from_slice(&payload[..16]);

        let mut beats = vec![first];
        let mut offset = 16;
        while offset < payload.len() {
            let valid = (payload.len() - offset).min(qshell_abi::BEAT_BYTES);
            let mut beat = AxisBeat {
                data: [0; qshell_abi::BEAT_BYTES],
                keep: low_keep(valid),
                last: offset + valid == payload.len(),
            };
            beat.data[..valid].copy_from_slice(&payload[offset..offset + valid]);
            beats.push(beat);
            offset += valid;
        }
        beats
    }

    fn circuit_contracts() -> [CoprocessorGraphContract; 2] {
        [
            CoprocessorGraphContract::new(
                CIRCUIT_D3_GRAPH_ID,
                19,
                39,
                &CIRCUIT_D3_VIRTUAL_VERTICES,
            )
            .unwrap(),
            CoprocessorGraphContract::new(
                CIRCUIT_D9_GRAPH_ID,
                433,
                1737,
                &CIRCUIT_D9_VIRTUAL_VERTICES,
            )
            .unwrap(),
        ]
    }

    fn decode_with_edges(
        contract: CoprocessorGraphContract,
        defects: Vec<u16>,
        edges: Vec<u16>,
    ) -> (DecodeResult, CoprocessorQshellLink<MockBeatLink>) {
        let mut beats = MockBeatLink::default();
        beats
            .responses
            .extend(coprocessor_response_beats(&contract, &edges));
        let graph_id = contract.graph_id();
        let mut link = CoprocessorQshellLink::new(beats, route(), contract, 9);
        let result = link.decode(&DecodeRequest { graph_id, defects }).unwrap();
        (result, link)
    }

    fn assert_poisoned_without_resend(
        link: &mut CoprocessorQshellLink<MockBeatLink>,
        request: &DecodeRequest,
        expected_request_beats: usize,
    ) {
        assert!(link.poisoned());
        assert_eq!(link.link().sent.len(), expected_request_beats);
        assert!(matches!(
            link.decode(request),
            Err(QshellLinkError::LinkPoisoned)
        ));
        assert_eq!(link.link().sent.len(), expected_request_beats);
    }

    #[test]
    fn coprocessor_contract_derives_frozen_circuit_bounds() {
        let d3 = CoprocessorGraphContract::new(
            CIRCUIT_D3_GRAPH_ID,
            19,
            39,
            &CIRCUIT_D3_VIRTUAL_VERTICES,
        )
        .unwrap();
        assert_eq!(d3.max_defects(), 12);
        assert_eq!(d3.request_payload_bytes(), 64);
        assert_eq!(d3.request_packet_bytes(), 112);
        assert_eq!(d3.request_beats(), 2);
        assert_eq!(d3.response_payload_bytes(), 122);
        assert_eq!(d3.response_packet_bytes(), 170);
        assert_eq!(d3.response_beats(), 3);
        assert!(d3.has_exact_graph_capacities());

        let legacy =
            CoprocessorGraphContract::new_with_capacities(GRAPH_ID, 4, 3, &[2, 3], 4, 2).unwrap();
        assert_eq!(legacy.request_packet_bytes(), 96);
        assert_eq!(legacy.response_packet_bytes(), 96);
        assert_eq!(legacy.request_beats(), 2);
        assert_eq!(legacy.response_beats(), 2);
        assert!(!legacy.has_exact_graph_capacities());

        let d9 = CoprocessorGraphContract::new(
            CIRCUIT_D9_GRAPH_ID,
            433,
            1737,
            &CIRCUIT_D9_VIRTUAL_VERTICES,
        )
        .unwrap();
        assert_eq!(d9.max_defects(), 360);
        assert_eq!(d9.request_payload_bytes(), 760);
        assert_eq!(d9.request_packet_bytes(), 808);
        assert_eq!(d9.request_beats(), 13);
        assert_eq!(d9.response_payload_bytes(), 3518);
        assert_eq!(d9.response_packet_bytes(), 3566);
        assert_eq!(d9.response_beats(), 56);
        assert!(d9.response_packet_bytes() <= MAX_QSHELL_PACKET_BYTES);

        assert_eq!(
            CoprocessorGraphContract::new(CIRCUIT_D9_GRAPH_ID, u16::MAX, u16::MAX, &[]),
            Err(CoprocessorContractError::PacketStorageExceeded)
        );
    }

    #[test]
    fn coprocessor_decode_preserves_multibeat_order_at_d9_bounds() {
        let contract = CoprocessorGraphContract::new(
            CIRCUIT_D9_GRAPH_ID,
            433,
            1737,
            &CIRCUIT_D9_VIRTUAL_VERTICES,
        )
        .unwrap();
        let defects: Vec<_> = (0..contract.vertex_count())
            .filter(|vertex| !contract.is_virtual_vertex(*vertex))
            .collect();
        let edges: Vec<_> = (0..contract.edge_count()).rev().collect();
        let (result, link) = decode_with_edges(contract, defects.clone(), edges.clone());

        assert_eq!(result.graph_id, CIRCUIT_D9_GRAPH_ID);
        assert_eq!(result.correction_edges, edges);
        assert_eq!(link.link().sent.len(), 13);
        assert!(link.link().sent[..12]
            .iter()
            .all(|beat| beat.keep == u64::MAX && !beat.last));
        assert_eq!(link.link().sent[12].keep, low_keep(40));
        assert!(link.link().sent[12].last);
        assert_eq!(
            get_u32(
                &link.link().sent[0].data,
                qshell_abi::offset::DESTINATION_ENDPOINT_ID,
            ),
            0
        );
        assert_eq!(
            get_u32(&link.link().sent[0].data, qshell_abi::offset::ROUTE_VERSION,),
            0
        );
        assert_eq!(link.expected_route_version(), 9);
        assert_eq!(
            get_u32(&link.link().sent[0].data, qshell_abi::offset::PAYLOAD_BYTES),
            760
        );
        let mut request_payload = Vec::with_capacity(760);
        request_payload.extend_from_slice(&link.link().sent[0].data[qshell_abi::HEADER_BYTES..]);
        for beat in &link.link().sent[1..] {
            request_payload.extend_from_slice(&beat.data[..beat.keep.count_ones() as usize]);
        }
        assert_eq!(request_payload.len(), 760);
        for (index, defect) in defects.iter().enumerate() {
            assert_eq!(
                get_u16(
                    &request_payload,
                    COPROCESSOR_REQUEST_PREFIX_BYTES + 2 * index,
                ),
                *defect
            );
        }
        assert_eq!(link.round_id, 43);
    }

    #[test]
    fn coprocessor_decode_poisons_after_malformed_accepted_round_without_resend() {
        for contract in circuit_contracts() {
            let request = DecodeRequest {
                graph_id: contract.graph_id(),
                defects: vec![0],
            };
            let mut malformed = coprocessor_response_beats(&contract, &[0]);
            malformed[1].keep = low_keep(63);

            let mut beats = MockBeatLink::default();
            beats.responses.extend(malformed);
            let mut link = CoprocessorQshellLink::new(beats, route(), contract.clone(), 9);
            assert!(matches!(
                link.decode(&request),
                Err(QshellLinkError::InvalidEnvelopeKeep { .. })
            ));
            assert_poisoned_without_resend(&mut link, &request, contract.request_beats());
        }
    }

    #[test]
    fn coprocessor_decode_rejects_72_byte_in_band_error_without_endpoint_semantics() {
        for contract in circuit_contracts() {
            let request = DecodeRequest {
                graph_id: contract.graph_id(),
                defects: vec![0],
            };
            let mut first = coprocessor_response_beats(&contract, &[]).remove(0);
            first.data[qshell_abi::offset::RECORD_CLASS] = qshell_abi::record_class::ERROR;
            put_u16(&mut first.data, qshell_abi::offset::FLAGS, 0);
            put_u32(&mut first.data, qshell_abi::offset::PAYLOAD_BYTES, 24);
            put_u32(
                &mut first.data,
                qshell_abi::offset::SCHEMA_ID,
                qshell_abi::schema::ERROR,
            );

            let mut beats = MockBeatLink::default();
            beats.responses.push_back(first);
            let mut link = CoprocessorQshellLink::new(beats, route(), contract.clone(), 9);
            assert!(matches!(
                link.decode(&request),
                Err(QshellLinkError::UnexpectedClass(class))
                    if class == qshell_abi::record_class::ERROR
            ));
            assert_poisoned_without_resend(&mut link, &request, contract.request_beats());
        }
    }

    #[test]
    fn coprocessor_decode_validates_normal_identity_and_poisons_session() {
        let contract = circuit_contracts()[0].clone();
        let request = DecodeRequest {
            graph_id: contract.graph_id(),
            defects: vec![0],
        };
        let header_mutations = [
            (qshell_abi::offset::CONTEXT_ID, 8),
            (qshell_abi::offset::ROUND_ID, 43),
            (qshell_abi::offset::SCHEMA_ID, qshell_abi::schema::ERROR),
            (qshell_abi::offset::SOURCE_ENDPOINT_ID, 0x102),
            (qshell_abi::offset::DESTINATION_ENDPOINT_ID, 0x13),
            (qshell_abi::offset::ROUTE_CAPABILITY_ID, 0x8765_4322),
            (qshell_abi::offset::ROUTE_VERSION, 0),
            (qshell_abi::offset::ROUTE_VERSION, 8),
            (qshell_abi::offset::RECORD_SEQUENCE, 1),
        ];
        for (offset, value) in header_mutations {
            let mut response = coprocessor_response_beats(&contract, &[0]);
            put_u32(&mut response[0].data, offset, value);
            let mut beats = MockBeatLink::default();
            beats.responses.extend(response);
            let mut link = CoprocessorQshellLink::new(beats, route(), contract.clone(), 9);
            assert!(matches!(
                link.decode(&request),
                Err(QshellLinkError::MetadataMismatch)
            ));
            assert_poisoned_without_resend(&mut link, &request, contract.request_beats());
        }

        let mut response = coprocessor_response_beats(&contract, &[0]);
        response[0].data[qshell_abi::offset::RECORD_CLASS] = qshell_abi::record_class::CONTROL;
        let mut beats = MockBeatLink::default();
        beats.responses.extend(response);
        let mut link = CoprocessorQshellLink::new(beats, route(), contract.clone(), 9);
        assert!(matches!(
            link.decode(&request),
            Err(QshellLinkError::UnexpectedClass(
                qshell_abi::record_class::CONTROL
            ))
        ));
        assert_poisoned_without_resend(&mut link, &request, contract.request_beats());

        let mut response = coprocessor_response_beats(&contract, &[0]);
        response[0].data[qshell_abi::HEADER_BYTES + 8] ^= 1;
        let mut beats = MockBeatLink::default();
        beats.responses.extend(response);
        let mut link = CoprocessorQshellLink::new(beats, route(), contract.clone(), 9);
        assert!(matches!(
            link.decode(&request),
            Err(QshellLinkError::ResultGraphMismatch)
        ));
        assert_poisoned_without_resend(&mut link, &request, contract.request_beats());

        let mut beats = MockBeatLink::default();
        beats
            .responses
            .extend(coprocessor_response_beats(&contract, &[0]));
        let mut link = CoprocessorQshellLink::new(beats, route(), contract.clone(), 0);
        assert!(matches!(
            link.decode(&request),
            Err(QshellLinkError::MetadataMismatch)
        ));
        assert_poisoned_without_resend(&mut link, &request, contract.request_beats());
    }

    #[test]
    fn coprocessor_decode_poisons_response_timeout_without_resend() {
        let contract = circuit_contracts()[0].clone();
        let request = DecodeRequest {
            graph_id: contract.graph_id(),
            defects: vec![0],
        };
        let mut link =
            CoprocessorQshellLink::new(MockBeatLink::default(), route(), contract.clone(), 9);
        assert!(matches!(
            link.decode(&request),
            Err(QshellLinkError::Link("beat queue empty"))
        ));
        assert_poisoned_without_resend(&mut link, &request, contract.request_beats());
    }

    #[test]
    fn coprocessor_decode_requires_fresh_epoch_and_capability_after_poison() {
        let contract = circuit_contracts()[0].clone();
        let request = DecodeRequest {
            graph_id: contract.graph_id(),
            defects: vec![0],
        };
        let mut malformed = coprocessor_response_beats(&contract, &[0]);
        malformed[0].data[qshell_abi::offset::MAGIC] ^= 1;
        let mut old_beats = MockBeatLink::default();
        old_beats.responses.extend(malformed);
        let mut old_link = CoprocessorQshellLink::new(old_beats, route(), contract.clone(), 9);
        assert!(matches!(
            old_link.decode(&request),
            Err(QshellLinkError::MalformedEnvelope)
        ));
        assert_poisoned_without_resend(&mut old_link, &request, contract.request_beats());

        let mut fresh_route = route();
        fresh_route.context_id = 8;
        fresh_route.initial_round_id = 100;
        fresh_route.route_capability_id = 0x8765_4322;
        let fresh_route_version = 10;
        let mut response = coprocessor_response_beats(&contract, &[0]);
        put_u32(
            &mut response[0].data,
            qshell_abi::offset::CONTEXT_ID,
            fresh_route.context_id,
        );
        put_u32(
            &mut response[0].data,
            qshell_abi::offset::ROUND_ID,
            fresh_route.initial_round_id,
        );
        put_u32(
            &mut response[0].data,
            qshell_abi::offset::ROUTE_CAPABILITY_ID,
            fresh_route.route_capability_id,
        );
        put_u32(
            &mut response[0].data,
            qshell_abi::offset::ROUTE_VERSION,
            fresh_route_version,
        );
        let mut fresh_beats = MockBeatLink::default();
        fresh_beats.responses.extend(response);
        let mut fresh_link = CoprocessorQshellLink::new(
            fresh_beats,
            fresh_route,
            contract.clone(),
            fresh_route_version,
        );
        assert_eq!(
            fresh_link.decode(&request).unwrap().correction_edges,
            vec![0]
        );
        assert!(!fresh_link.poisoned());
        assert_eq!(fresh_link.round_id, 101);
        assert_eq!(fresh_link.link().sent.len(), contract.request_beats());
    }

    #[test]
    fn coprocessor_decode_rejects_identity_bounds_and_nonzero_padding() {
        let contract = CoprocessorGraphContract::new(
            CIRCUIT_D3_GRAPH_ID,
            19,
            39,
            &CIRCUIT_D3_VIRTUAL_VERTICES,
        )
        .unwrap();
        let mut retryable_beats = MockBeatLink::default();
        retryable_beats
            .responses
            .extend(coprocessor_response_beats(&contract, &[0]));
        let mut link = CoprocessorQshellLink::new(retryable_beats, route(), contract.clone(), 9);
        assert!(matches!(
            link.decode(&DecodeRequest {
                graph_id: CIRCUIT_D9_GRAPH_ID,
                defects: vec![0],
            }),
            Err(QshellLinkError::RequestGraphMismatch)
        ));
        assert!(matches!(
            link.decode(&DecodeRequest {
                graph_id: CIRCUIT_D3_GRAPH_ID,
                defects: vec![0, 0],
            }),
            Err(QshellLinkError::InvalidDefects)
        ));
        assert!(matches!(
            link.decode(&DecodeRequest {
                graph_id: CIRCUIT_D3_GRAPH_ID,
                defects: vec![1],
            }),
            Err(QshellLinkError::InvalidDefects)
        ));
        assert!(link.link().sent.is_empty());
        assert!(!link.poisoned());
        assert_eq!(
            link.decode(&DecodeRequest {
                graph_id: CIRCUIT_D3_GRAPH_ID,
                defects: vec![0],
            })
            .unwrap()
            .correction_edges,
            vec![0]
        );

        let mut beats = MockBeatLink::default();
        let mut response = coprocessor_response_beats(&contract, &[0]);
        response[2].data[41] = 1;
        beats.responses.extend(response);
        let mut link = CoprocessorQshellLink::new(beats, route(), contract.clone(), 9);
        let request = DecodeRequest {
            graph_id: CIRCUIT_D3_GRAPH_ID,
            defects: vec![0],
        };
        assert!(matches!(
            link.decode(&request),
            Err(QshellLinkError::NonzeroPayloadPadding)
        ));
        assert_eq!(link.round_id, 42);
        assert_poisoned_without_resend(&mut link, &request, contract.request_beats());

        let mut beats = MockBeatLink::default();
        beats
            .responses
            .extend(coprocessor_response_beats(&contract, &[39]));
        let mut link = CoprocessorQshellLink::new(beats, route(), contract.clone(), 9);
        assert!(matches!(
            link.decode(&request),
            Err(QshellLinkError::InvalidCorrectionEdge(39))
        ));
        assert_poisoned_without_resend(&mut link, &request, contract.request_beats());
    }

    #[test]
    fn native_transport_rejects_stale_response_flood_and_bad_completion_count() {
        let mut link = MockLink::default();
        for request_id in 100..100 + MAX_STALE_RESPONSES as u32 {
            link.responses.push_back(
                Record::read_result(GRAPH_ID, request_id, 1, AccessWidth::Byte, 0, 0).encode(),
            );
        }
        let mut transport = QshellMmioTransport::new(link, GRAPH_ID);
        transport.begin_job(10, UNBOUNDED_OPERATIONS).unwrap();
        assert!(matches!(
            transport.mmio_read(AccessWidth::Byte, 0),
            Err(TransportError::StaleResponseLimit)
        ));

        let mut link = MockLink::default();
        link.responses
            .push_back(Record::completion(GRAPH_ID, 11, 1, CompletionCode::Success, 4).encode());
        let mut transport = QshellMmioTransport::new(link, GRAPH_ID);
        transport.begin_job(11, UNBOUNDED_OPERATIONS).unwrap();
        assert!(matches!(
            transport.end_job(),
            Err(TransportError::CompletionCount {
                expected: 0,
                actual: 4
            })
        ));
    }
}
