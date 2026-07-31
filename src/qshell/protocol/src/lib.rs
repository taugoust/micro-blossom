//! Fixed-size record codec for the phase-1 host-driven QShell baseline.

use core::fmt;

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
