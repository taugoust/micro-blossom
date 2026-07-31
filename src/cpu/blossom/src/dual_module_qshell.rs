//! Native protocol-v1 QShell transport for the AXI4 MicroBlossom dual module.
//!
//! The primal algorithm continues to use `DualStacklessDriver`; only the MMIO
//! transport changes from simulator text commands to ordered 64-byte records.

use crate::mwpm_solver::*;
use crate::resources::*;
use crate::simulation_tcp_client::*;
use crate::util::*;
use embedded_blossom::extern_c::{SingleReadout, SingleReadoutUnion};
use fusion_blossom::visualize::*;
use micro_blossom_nostd::dual_driver_tracked::*;
use micro_blossom_nostd::dual_module_stackless::*;
use micro_blossom_nostd::instruction::*;
use micro_blossom_nostd::interface::*;
use micro_blossom_nostd::util::*;
use microblossom_qshell_protocol::{
    AccessWidth, CompletionCode, GraphId, Opcode, QshellMmioTransport, Record, RecordLink, TransportError,
    UNBOUNDED_OPERATIONS,
};
use scan_fmt::*;
use serde::*;
use std::collections::VecDeque;
use std::fmt;
use std::io;

pub const READOUT_BASE: usize = 128 * 1024;

pub struct DualModuleQshellDriver<Link: RecordLink> {
    pub transport: QshellMmioTransport<Link>,
    pub context_id: u16,
}

impl<Link> DualModuleQshellDriver<Link>
where
    Link: RecordLink,
    Link::Error: fmt::Debug + fmt::Display,
{
    pub fn new(link: Link, graph_id: GraphId, request_id: u32) -> io::Result<Self> {
        let mut transport = QshellMmioTransport::new(link, graph_id);
        transport
            .begin_job(request_id, UNBOUNDED_OPERATIONS)
            .map_err(transport_error)?;
        let mut value = Self {
            transport,
            context_id: 0,
        };
        value.reset();
        Ok(value)
    }

    pub fn finish_job(&mut self) -> io::Result<u64> {
        self.transport.end_job().map_err(transport_error)
    }

    pub fn memory_write_64(&mut self, address: usize, data: u64) -> io::Result<()> {
        self.write(AccessWidth::DoubleWord, address, data)
    }

    pub fn memory_write_32(&mut self, address: usize, data: u32) -> io::Result<()> {
        self.write(AccessWidth::Word, address, data as u64)
    }

    pub fn memory_write_16(&mut self, address: usize, data: u16) -> io::Result<()> {
        self.write(AccessWidth::HalfWord, address, data as u64)
    }

    pub fn memory_read_64(&mut self, address: usize) -> io::Result<u64> {
        self.read(AccessWidth::DoubleWord, address)
    }

    pub fn memory_read_16(&mut self, address: usize) -> io::Result<u16> {
        self.read(AccessWidth::HalfWord, address).map(|value| value as u16)
    }

    fn write(&mut self, width: AccessWidth, address: usize, data: u64) -> io::Result<()> {
        self.transport
            .mmio_write(width, address as u64, data)
            .map_err(transport_error)
    }

    fn read(&mut self, width: AccessWidth, address: usize) -> io::Result<u64> {
        self.transport.mmio_read(width, address as u64).map_err(transport_error)
    }

    pub fn execute_instruction(&mut self, instruction: Instruction32) -> io::Result<()> {
        let data = (instruction.0 as u64) | ((self.context_id as u64) << 32);
        self.memory_write_64(4096, data)
    }

    pub fn context_base_address(&self) -> usize {
        READOUT_BASE + 128 * self.context_id as usize
    }

    pub fn clear_grown(&mut self) -> io::Result<()> {
        self.memory_write_16(self.context_base_address(), 0)
    }

    pub fn get_single_readout(&mut self) -> io::Result<SingleReadout> {
        let address = self.context_base_address() + 32;
        let readout = unsafe {
            let mut union = SingleReadoutUnion { raw: [0, 0] };
            union.raw[0] = self.memory_read_64(address)?;
            union.raw[1] = self.memory_read_64(address + 8)?;
            union.readout
        };
        self.clear_grown()?;
        Ok(readout)
    }

    pub fn set_maximum_growth(&mut self, maximum_growth: u16) -> io::Result<()> {
        self.memory_write_16(self.context_base_address() + 16, maximum_growth)
    }
}

fn transport_error<LinkError>(error: TransportError<LinkError>) -> io::Error
where
    LinkError: fmt::Debug + fmt::Display,
{
    io::Error::new(io::ErrorKind::Other, error.to_string())
}

impl<Link> DualStacklessDriver for DualModuleQshellDriver<Link>
where
    Link: RecordLink,
    Link::Error: fmt::Debug + fmt::Display,
{
    fn reset(&mut self) {
        self.execute_instruction(Instruction32::reset()).unwrap();
        self.get_single_readout().unwrap();
    }

    fn set_speed(&mut self, _is_blossom: bool, node: CompactNodeIndex, speed: CompactGrowState) {
        self.execute_instruction(Instruction32::set_speed(node, speed)).unwrap();
    }

    fn set_blossom(&mut self, node: CompactNodeIndex, blossom: CompactNodeIndex) {
        self.execute_instruction(Instruction32::set_blossom(node, blossom)).unwrap();
    }

    fn find_obstacle(&mut self) -> (CompactObstacle, CompactWeight) {
        let readout = self.get_single_readout().unwrap();
        let grown = readout.accumulated_grown as CompactWeight;
        let growable = readout.max_growable;
        if growable == u8::MAX {
            (CompactObstacle::None, grown)
        } else if growable != 0 {
            (
                CompactObstacle::GrowLength {
                    length: growable as CompactWeight,
                },
                grown,
            )
        } else if readout.conflict_valid != 0 {
            (
                CompactObstacle::Conflict {
                    node_1: ni!(readout.node_1).option(),
                    node_2: if readout.node_2 == u16::MAX {
                        None.into()
                    } else {
                        ni!(readout.node_2).option()
                    },
                    touch_1: ni!(readout.touch_1).option(),
                    touch_2: if readout.touch_2 == u16::MAX {
                        None.into()
                    } else {
                        ni!(readout.touch_2).option()
                    },
                    vertex_1: ni!(readout.vertex_1),
                    vertex_2: ni!(readout.vertex_2),
                },
                grown,
            )
        } else {
            (CompactObstacle::GrowLength { length: 0 }, grown)
        }
    }

    fn add_defect(&mut self, vertex: CompactVertexIndex, node: CompactNodeIndex) {
        self.execute_instruction(Instruction32::add_defect_vertex(vertex, node))
            .unwrap();
    }
}

impl<Link> DualTrackedDriver for DualModuleQshellDriver<Link>
where
    Link: RecordLink,
    Link::Error: fmt::Debug + fmt::Display,
{
    fn find_conflict(&mut self, maximum_growth: CompactWeight) -> (CompactObstacle, CompactWeight) {
        self.set_maximum_growth(maximum_growth as u16).unwrap();
        self.find_obstacle()
    }
}

impl<Link> FusionVisualizer for DualModuleQshellDriver<Link>
where
    Link: RecordLink,
    Link::Error: fmt::Debug + fmt::Display,
{
    fn snapshot(&self, _abbrev: bool) -> serde_json::Value {
        json!({
            "transport": "qshell-record-v1",
            "context_id": self.context_id,
            "operations": self.transport.operations(),
        })
    }
}

/// Simulation-only ordered link used to validate the native record transport
/// against the same generated accelerator as the existing AXI4 driver.
pub struct SimulationRecordLink {
    client: SimulationTcpClient,
    graph_id: GraphId,
    active_request_id: Option<u32>,
    expected_sequence: u32,
    expected_operations: u64,
    completed_operations: u64,
    responses: VecDeque<[u8; microblossom_qshell_protocol::RECORD_BYTES]>,
    sent_records: Vec<Record>,
}

impl SimulationRecordLink {
    fn new(graph: MicroBlossomSingle, name: String, sim_config: SimulationConfig, graph_id: GraphId) -> io::Result<Self> {
        if !sim_config.use_64_bus {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "QShell protocol-v1 requires the 64-bit MicroBlossom AXI4 bus",
            ));
        }
        Ok(Self {
            client: SimulationTcpClient::new("MicroBlossomHost", graph, name, sim_config)?,
            graph_id,
            active_request_id: None,
            expected_sequence: 0,
            expected_operations: 0,
            completed_operations: 0,
            responses: VecDeque::new(),
            sent_records: Vec::new(),
        })
    }

    pub fn sent_records(&self) -> &[Record] {
        &self.sent_records
    }

    fn invalid(message: impl Into<String>) -> io::Error {
        io::Error::new(io::ErrorKind::InvalidData, message.into())
    }
}

impl RecordLink for SimulationRecordLink {
    type Error = io::Error;

    fn send_record(&mut self, bytes: [u8; microblossom_qshell_protocol::RECORD_BYTES]) -> Result<(), Self::Error> {
        let record = Record::decode(&bytes).map_err(|error| Self::invalid(error.to_string()))?;
        self.sent_records.push(record);
        if record.graph_id != self.graph_id {
            return Err(Self::invalid("graph identifier mismatch"));
        }
        match record.opcode {
            Opcode::BeginJob => {
                if self.active_request_id.is_some() || record.sequence != 0 {
                    return Err(Self::invalid("invalid BeginJob state"));
                }
                self.active_request_id = Some(record.request_id);
                self.expected_sequence = 1;
                self.expected_operations = record.argument0;
                self.completed_operations = 0;
            }
            Opcode::MmioWrite | Opcode::MmioRead => {
                if self.active_request_id != Some(record.request_id) || record.sequence != self.expected_sequence {
                    return Err(Self::invalid("invalid MMIO job or sequence"));
                }
                let width = record.access_width().unwrap();
                let bytes = width.bytes() as usize;
                let address = record.argument0 as usize;
                if record.opcode == Opcode::MmioWrite {
                    self.client
                        .write_line(format!("write({bytes}, {address}, {})", record.argument1))?;
                } else {
                    let line = self.client.read_line(format!("read({bytes}, {address})"))?;
                    let value = scan_fmt!(&line, "{d}", u64).unwrap();
                    self.responses.push_back(
                        Record::read_result(
                            self.graph_id,
                            record.request_id,
                            record.sequence,
                            width,
                            record.argument0,
                            value,
                        )
                        .encode(),
                    );
                }
                self.expected_sequence = self
                    .expected_sequence
                    .checked_add(1)
                    .ok_or_else(|| Self::invalid("sequence overflow"))?;
                self.completed_operations += 1;
            }
            Opcode::EndJob => {
                if self.active_request_id != Some(record.request_id) || record.sequence != self.expected_sequence {
                    return Err(Self::invalid("invalid EndJob state or sequence"));
                }
                if self.expected_operations != UNBOUNDED_OPERATIONS && self.expected_operations != self.completed_operations
                {
                    return Err(Self::invalid("operation-count mismatch"));
                }
                self.responses.push_back(
                    Record::completion(
                        self.graph_id,
                        record.request_id,
                        record.sequence,
                        CompletionCode::Success,
                        self.completed_operations,
                    )
                    .encode(),
                );
                self.active_request_id = None;
            }
            _ => return Err(Self::invalid("host sent a response opcode")),
        }
        Ok(())
    }

    fn receive_record(&mut self) -> Result<[u8; microblossom_qshell_protocol::RECORD_BYTES], Self::Error> {
        self.responses
            .pop_front()
            .ok_or_else(|| Self::invalid("response queue empty"))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct DualQshellSimulationConfig {
    #[serde(default = "Default::default")]
    sim_config: SimulationConfig,
    #[serde(default = "random_name_16")]
    name: String,
    graph_sha256: String,
    request_id: u32,
}

fn decode_graph_id(value: &str) -> io::Result<GraphId> {
    if value.len() != 64 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "graph_sha256 must contain exactly 64 hexadecimal digits",
        ));
    }
    let mut graph_id = [0_u8; 32];
    for (index, byte) in graph_id.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&value[index * 2..index * 2 + 2], 16)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "graph_sha256 contains a non-hexadecimal digit"))?;
    }
    Ok(graph_id)
}

pub type DualModuleQshellSimulationDriver = DualModuleQshellDriver<SimulationRecordLink>;
pub type DualModuleQshell = DualModuleStackless<DualDriverTracked<DualModuleQshellSimulationDriver, MAX_NODE_NUM>>;
pub type SolverEmbeddedQshell = SolverEmbeddedBoxed<DualModuleQshellSimulationDriver>;

impl SolverTrackedDual for DualModuleQshellSimulationDriver {
    fn new_from_graph_config(graph: MicroBlossomSingle, config: serde_json::Value) -> Self {
        let config: DualQshellSimulationConfig = serde_json::from_value(config).unwrap();
        let graph_id = decode_graph_id(&config.graph_sha256).unwrap();
        let link = SimulationRecordLink::new(graph, config.name, config.sim_config, graph_id).unwrap();
        Self::new(link, graph_id, config.request_id).unwrap()
    }

    fn fuse_layer(&mut self, layer_id: usize) {
        self.execute_instruction(Instruction32::load_syndrome_external(ni!(layer_id)))
            .unwrap();
    }
}
