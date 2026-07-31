//! Fixed-size record codec for the phase-1 host-driven QShell baseline.

use core::fmt;

pub mod qshell_abi_generated;

use qshell_abi_generated as qshell_v2;

pub const RECORD_BYTES: usize = 64;
pub const MAGIC: [u8; 4] = *b"MBQ1";
pub const VERSION: u8 = 1;
pub const UNBOUNDED_OPERATIONS: u64 = u64::MAX;
pub const MAX_STALE_RESPONSES: usize = 16;

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
    pub data: [u8; qshell_v2::BEAT_BYTES],
    pub keep: u64,
    pub last: bool,
}

/// Blocking transport for individual 64-byte AXI-stream beats.
///
/// Implementations must preserve beat order and the exact low-lane `keep`
/// mask. A Coyote implementation can map each two-beat record to one 112-byte
/// transfer, but it must not pad the final continuation to 128 valid bytes.
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

/// Process-backed beat transport for the packaged Coyote C++ bridge.
///
/// Keeping the Coyote driver boundary in a separately packaged process avoids
/// adding C++ ABI assumptions to the Rust protocol crate. The bridge maps the
/// first/final beat pair to one-sided `LOCAL_WRITE` and `LOCAL_READ` sequences.
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
        use std::process::Stdio;

        let mut child = std::process::Command::new(executable)
            .arg("--vfpga")
            .arg(vfpga_id.to_string())
            .arg("--timeout-ms")
            .arg(timeout_ms.to_string())
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
        let mut data = [0_u8; qshell_v2::BEAT_BYTES];
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
pub struct QshellV2Route {
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
pub enum QshellV2LinkError<LinkError> {
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
    CorrectionSequence { expected: u32, actual: u32 },
    EndOfRoundMismatch,
    RemoteQshellError { code: u16, scope: u8, detail: u32 },
}

impl<LinkError: fmt::Display> fmt::Display for QshellV2LinkError<LinkError> {
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
            Self::CorrectionSequence { expected, actual } => write!(
                formatter,
                "QShell correction sequence mismatch: expected {expected}, received {actual}"
            ),
            Self::EndOfRoundMismatch => {
                formatter.write_str("QShell and MBQ1 terminal markers disagree")
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

impl<LinkError: fmt::Debug + fmt::Display> std::error::Error for QshellV2LinkError<LinkError> {}

/// Converts the internal fixed-size MBQ1 `RecordLink` contract to canonical
/// QShell ABI-2 beats without owning a second copy of the ABI constants.
pub struct QshellV2RecordLink<Link> {
    link: Link,
    route: QshellV2Route,
    round_id: u32,
    command_sequence: u32,
    correction_sequence: u32,
}

impl<Link> QshellV2RecordLink<Link> {
    pub fn new(link: Link, route: QshellV2Route) -> Self {
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

impl<Link: BeatLink> QshellV2RecordLink<Link> {
    fn send_command(
        &mut self,
        bytes: [u8; RECORD_BYTES],
    ) -> Result<(), QshellV2LinkError<Link::Error>> {
        let record = Record::decode(&bytes).map_err(QshellV2LinkError::InnerRecord)?;
        if record.is_response() {
            return Err(QshellV2LinkError::UnexpectedInnerResponse);
        }
        if record.sequence != self.command_sequence {
            return Err(QshellV2LinkError::CommandSequence {
                expected: self.command_sequence,
                actual: record.sequence,
            });
        }

        let end_of_round = record.opcode == Opcode::EndJob;
        let mut first = AxisBeat {
            data: [0; qshell_v2::BEAT_BYTES],
            keep: u64::MAX,
            last: false,
        };
        put_u32(&mut first.data, qshell_v2::offset::MAGIC, qshell_v2::MAGIC);
        first.data[qshell_v2::offset::ABI_VERSION] = qshell_v2::VERSION;
        first.data[qshell_v2::offset::RECORD_CLASS] = qshell_v2::record_class::SYNDROME;
        put_u16(
            &mut first.data,
            qshell_v2::offset::FLAGS,
            if end_of_round {
                qshell_v2::flag::END_OF_ROUND
            } else {
                0
            },
        );
        put_u16(
            &mut first.data,
            qshell_v2::offset::HEADER_BYTES,
            qshell_v2::HEADER_BYTES as u16,
        );
        put_u32(
            &mut first.data,
            qshell_v2::offset::PAYLOAD_BYTES,
            RECORD_BYTES as u32,
        );
        put_u32(
            &mut first.data,
            qshell_v2::offset::CONTEXT_ID,
            self.route.context_id,
        );
        put_u32(&mut first.data, qshell_v2::offset::ROUND_ID, self.round_id);
        put_u32(
            &mut first.data,
            qshell_v2::offset::SCHEMA_ID,
            qshell_v2::schema::MICROBLOSSOM_COMMAND_V1,
        );
        put_u32(
            &mut first.data,
            qshell_v2::offset::SOURCE_ENDPOINT_ID,
            self.route.source_endpoint_id,
        );
        put_u32(
            &mut first.data,
            qshell_v2::offset::ROUTE_CAPABILITY_ID,
            self.route.route_capability_id,
        );
        put_u32(
            &mut first.data,
            qshell_v2::offset::RECORD_SEQUENCE,
            record.sequence,
        );
        first.data[qshell_v2::HEADER_BYTES..].copy_from_slice(&bytes[..16]);

        let mut continuation = AxisBeat {
            data: [0; qshell_v2::BEAT_BYTES],
            keep: low_keep(RECORD_BYTES - 16),
            last: true,
        };
        continuation.data[..RECORD_BYTES - 16].copy_from_slice(&bytes[16..]);

        self.link
            .send_beat(first)
            .map_err(QshellV2LinkError::Link)?;
        self.link
            .send_beat(continuation)
            .map_err(QshellV2LinkError::Link)?;
        if !end_of_round {
            self.command_sequence = self.command_sequence.wrapping_add(1);
        }
        Ok(())
    }

    fn receive_response(&mut self) -> Result<[u8; RECORD_BYTES], QshellV2LinkError<Link::Error>> {
        let first = self.link.receive_beat().map_err(QshellV2LinkError::Link)?;
        if first.keep != u64::MAX {
            return Err(QshellV2LinkError::InvalidEnvelopeKeep {
                expected: u64::MAX,
                actual: first.keep,
            });
        }
        if first.last
            || get_u32(&first.data, qshell_v2::offset::MAGIC) != qshell_v2::MAGIC
            || first.data[qshell_v2::offset::ABI_VERSION] != qshell_v2::VERSION
            || get_u16(&first.data, qshell_v2::offset::HEADER_BYTES)
                != qshell_v2::HEADER_BYTES as u16
            || get_u16(&first.data, qshell_v2::offset::RESERVED) != 0
        {
            return Err(QshellV2LinkError::MalformedEnvelope);
        }

        let record_class = first.data[qshell_v2::offset::RECORD_CLASS];
        let flags = get_u16(&first.data, qshell_v2::offset::FLAGS);
        let payload_bytes = get_u32(&first.data, qshell_v2::offset::PAYLOAD_BYTES);
        if record_class == qshell_v2::record_class::ERROR {
            return self.receive_qshell_error(first, payload_bytes, flags);
        }
        if record_class != qshell_v2::record_class::CORRECTION {
            return Err(QshellV2LinkError::UnexpectedClass(record_class));
        }
        if flags & !qshell_v2::flag::END_OF_ROUND != 0 {
            return Err(QshellV2LinkError::InvalidEnvelopeFlags(flags));
        }
        if payload_bytes != RECORD_BYTES as u32 {
            return Err(QshellV2LinkError::InvalidEnvelopeLength(payload_bytes));
        }
        if get_u32(&first.data, qshell_v2::offset::CONTEXT_ID) != self.route.context_id
            || get_u32(&first.data, qshell_v2::offset::ROUND_ID) != self.round_id
            || get_u32(&first.data, qshell_v2::offset::SCHEMA_ID)
                != qshell_v2::schema::MICROBLOSSOM_RESPONSE_V1
            || get_u32(&first.data, qshell_v2::offset::DESTINATION_ENDPOINT_ID)
                != self.route.source_endpoint_id
            || get_u32(&first.data, qshell_v2::offset::ROUTE_CAPABILITY_ID)
                != self.route.route_capability_id
            || self
                .route
                .expected_decoder_endpoint_id
                .is_some_and(|endpoint| {
                    get_u32(&first.data, qshell_v2::offset::SOURCE_ENDPOINT_ID) != endpoint
                })
        {
            return Err(QshellV2LinkError::MetadataMismatch);
        }
        let actual_sequence = get_u32(&first.data, qshell_v2::offset::RECORD_SEQUENCE);
        if actual_sequence != self.correction_sequence {
            return Err(QshellV2LinkError::CorrectionSequence {
                expected: self.correction_sequence,
                actual: actual_sequence,
            });
        }

        let continuation = self.link.receive_beat().map_err(QshellV2LinkError::Link)?;
        let expected_keep = low_keep(RECORD_BYTES - 16);
        if continuation.keep != expected_keep {
            return Err(QshellV2LinkError::InvalidEnvelopeKeep {
                expected: expected_keep,
                actual: continuation.keep,
            });
        }
        if !continuation.last {
            return Err(QshellV2LinkError::MalformedEnvelope);
        }

        let mut payload = [0; RECORD_BYTES];
        payload[..16].copy_from_slice(&first.data[qshell_v2::HEADER_BYTES..]);
        payload[16..].copy_from_slice(&continuation.data[..RECORD_BYTES - 16]);
        let inner = Record::decode(&payload).map_err(QshellV2LinkError::InnerRecord)?;
        let envelope_eor = flags & qshell_v2::flag::END_OF_ROUND != 0;
        let inner_terminal = matches!(inner.opcode, Opcode::Completion | Opcode::Error);
        if envelope_eor != inner_terminal {
            return Err(QshellV2LinkError::EndOfRoundMismatch);
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
    ) -> Result<[u8; RECORD_BYTES], QshellV2LinkError<Link::Error>> {
        if flags != 0 {
            return Err(QshellV2LinkError::InvalidEnvelopeFlags(flags));
        }
        if payload_bytes != 24 {
            return Err(QshellV2LinkError::InvalidEnvelopeLength(payload_bytes));
        }
        let continuation = self.link.receive_beat().map_err(QshellV2LinkError::Link)?;
        if continuation.keep != low_keep(8) || !continuation.last {
            return Err(QshellV2LinkError::MalformedEnvelope);
        }
        let payload = &first.data[qshell_v2::HEADER_BYTES..];
        Err(QshellV2LinkError::RemoteQshellError {
            code: u16::from_le_bytes(payload[0..2].try_into().unwrap()),
            scope: payload[2],
            detail: u32::from_le_bytes(payload[4..8].try_into().unwrap()),
        })
    }
}

impl<Link: BeatLink> RecordLink for QshellV2RecordLink<Link> {
    type Error = QshellV2LinkError<Link::Error>;

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

    fn route() -> QshellV2Route {
        QshellV2Route {
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
            data: [0; qshell_v2::BEAT_BYTES],
            keep: u64::MAX,
            last: false,
        };
        put_u32(&mut first.data, qshell_v2::offset::MAGIC, qshell_v2::MAGIC);
        first.data[qshell_v2::offset::ABI_VERSION] = qshell_v2::VERSION;
        first.data[qshell_v2::offset::RECORD_CLASS] = qshell_v2::record_class::CORRECTION;
        put_u16(
            &mut first.data,
            qshell_v2::offset::FLAGS,
            if end_of_round {
                qshell_v2::flag::END_OF_ROUND
            } else {
                0
            },
        );
        put_u16(
            &mut first.data,
            qshell_v2::offset::HEADER_BYTES,
            qshell_v2::HEADER_BYTES as u16,
        );
        put_u32(
            &mut first.data,
            qshell_v2::offset::PAYLOAD_BYTES,
            RECORD_BYTES as u32,
        );
        put_u32(&mut first.data, qshell_v2::offset::CONTEXT_ID, 7);
        put_u32(&mut first.data, qshell_v2::offset::ROUND_ID, 42);
        put_u32(
            &mut first.data,
            qshell_v2::offset::SCHEMA_ID,
            qshell_v2::schema::MICROBLOSSOM_RESPONSE_V1,
        );
        put_u32(
            &mut first.data,
            qshell_v2::offset::SOURCE_ENDPOINT_ID,
            0x101,
        );
        put_u32(
            &mut first.data,
            qshell_v2::offset::DESTINATION_ENDPOINT_ID,
            0x12,
        );
        put_u32(
            &mut first.data,
            qshell_v2::offset::ROUTE_CAPABILITY_ID,
            0x8765_4321,
        );
        put_u32(&mut first.data, qshell_v2::offset::ROUTE_VERSION, 9);
        put_u32(
            &mut first.data,
            qshell_v2::offset::RECORD_SEQUENCE,
            sequence,
        );
        first.data[qshell_v2::HEADER_BYTES..].copy_from_slice(&payload[..16]);

        let mut continuation = AxisBeat {
            data: [0; qshell_v2::BEAT_BYTES],
            keep: low_keep(48),
            last: true,
        };
        continuation.data[..48].copy_from_slice(&payload[16..]);
        [first, continuation]
    }

    fn qshell_error_beats(code: u16, scope: u8, detail: u32) -> [AxisBeat; 2] {
        let mut first = AxisBeat {
            data: [0; qshell_v2::BEAT_BYTES],
            keep: u64::MAX,
            last: false,
        };
        put_u32(&mut first.data, qshell_v2::offset::MAGIC, qshell_v2::MAGIC);
        first.data[qshell_v2::offset::ABI_VERSION] = qshell_v2::VERSION;
        first.data[qshell_v2::offset::RECORD_CLASS] = qshell_v2::record_class::ERROR;
        put_u16(
            &mut first.data,
            qshell_v2::offset::HEADER_BYTES,
            qshell_v2::HEADER_BYTES as u16,
        );
        put_u32(&mut first.data, qshell_v2::offset::PAYLOAD_BYTES, 24);
        put_u32(
            &mut first.data,
            qshell_v2::offset::SCHEMA_ID,
            qshell_v2::schema::ERROR_V1,
        );
        let payload = &mut first.data[qshell_v2::HEADER_BYTES..];
        payload[0..2].copy_from_slice(&code.to_le_bytes());
        payload[2] = scope;
        payload[3] = qshell_v2::record_class::SYNDROME;
        payload[4..8].copy_from_slice(&detail.to_le_bytes());

        let continuation = AxisBeat {
            data: [0; qshell_v2::BEAT_BYTES],
            keep: low_keep(8),
            last: true,
        };
        [first, continuation]
    }

    #[test]
    fn qshell_v2_link_frames_commands_and_validates_corrections() {
        let mut link = QshellV2RecordLink::new(MockBeatLink::default(), route());
        let begin = Record::begin_job(GRAPH_ID, 7, 1).encode();
        link.send_record(begin).unwrap();
        assert_eq!(link.command_sequence(), 1);
        assert_eq!(link.link().sent.len(), 2);
        let first = link.link().sent[0];
        assert_eq!(first.keep, u64::MAX);
        assert!(!first.last);
        assert_eq!(
            first.data[qshell_v2::offset::RECORD_CLASS],
            qshell_v2::record_class::SYNDROME
        );
        assert_eq!(
            get_u32(&first.data, qshell_v2::offset::SCHEMA_ID),
            qshell_v2::schema::MICROBLOSSOM_COMMAND_V1
        );
        assert_eq!(get_u32(&first.data, qshell_v2::offset::ROUTE_VERSION), 0);
        assert_eq!(&first.data[qshell_v2::HEADER_BYTES..], &begin[..16]);
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
            get_u16(&end_first.data, qshell_v2::offset::FLAGS),
            qshell_v2::flag::END_OF_ROUND
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
    fn qshell_v2_link_rejects_bad_sequence_and_envelope() {
        let mut link = QshellV2RecordLink::new(MockBeatLink::default(), route());
        let wrong = Record::mmio_read(GRAPH_ID, 1, 1, AccessWidth::Byte, 0).encode();
        assert!(matches!(
            link.send_record(wrong),
            Err(QshellV2LinkError::CommandSequence {
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
            Err(QshellV2LinkError::InvalidEnvelopeKeep { .. })
        ));
    }

    #[test]
    fn native_transport_composes_with_qshell_v2_beat_link() {
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

        let link = QshellV2RecordLink::new(beats, route());
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
    fn qshell_v2_link_surfaces_structured_qshell_errors() {
        let mut link = QshellV2RecordLink::new(MockBeatLink::default(), route());
        link.link_mut().responses.extend(qshell_error_beats(
            qshell_v2::error_code::SEQUENCE_MISMATCH,
            qshell_v2::error_scope::ABORT_ROUND,
            9,
        ));
        assert!(matches!(
            link.receive_record(),
            Err(QshellV2LinkError::RemoteQshellError {
                code: qshell_v2::error_code::SEQUENCE_MISMATCH,
                scope: qshell_v2::error_scope::ABORT_ROUND,
                detail: 9,
            })
        ));
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
