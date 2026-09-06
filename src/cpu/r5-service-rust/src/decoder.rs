use crate::graph;
use crate::materializer::{
    materialize_correction, MatchingEndpoint, MaterializationError, MaterializerWorkspace,
};
use crate::{
    MicroblossomRustMmio, MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE,
    MICROBLOSSOM_DECODE_ACCELERATOR_INCOMPLETE, MICROBLOSSOM_DECODE_INVALID_SYNDROME,
    MICROBLOSSOM_DECODE_OK, MAX_MMIO_OPERATIONS,
};
use core::cell::UnsafeCell;
use core::mem::{self, MaybeUninit};
use core::ptr;
use core::sync::atomic::{AtomicBool, Ordering};
use micro_blossom_nostd::blossom_tracker::BlossomTracker;
use micro_blossom_nostd::dual_driver_tracked::{DualDriverTracked, DualTrackedDriver};
use micro_blossom_nostd::dual_module_stackless::{
    DualModuleStackless, DualStacklessDriver,
};
use micro_blossom_nostd::instruction::Instruction32;
use micro_blossom_nostd::interface::{CompactObstacle, DualInterface, PrimalInterface};
use micro_blossom_nostd::layer_fusion::LayerFusionData;
use micro_blossom_nostd::primal_module_embedded::PrimalModuleEmbedded;
use micro_blossom_nostd::primal_nodes::PrimalNodes;
use micro_blossom_nostd::util::{
    CompactGrowState, CompactMatchTarget, CompactNodeIndex, CompactNodeNum,
    CompactVertexIndex, CompactWeight,
};

const HARDWARE_VERSION: u32 = 0x2401_23c0;
const HARDWARE_CONTEXT_DEPTH: u32 = 1;
const HARDWARE_CONFLICT_CHANNELS: u8 = 1;
const HARDWARE_INSTRUCTION_BUFFER_DEPTH: u8 = 4;
const HARDWARE_FLAGS: u16 = (1 << 0) | (1 << 3) | (1 << 5);
const HARDWARE_NUM_LAYERS: u8 = graph::NUM_LAYERS;

const MMIO_HARDWARE_INFO_0: u16 = 0x000;
const MMIO_HARDWARE_INFO_1: u16 = 0x008;
const MMIO_INSTRUCTION: u16 = 0x010;
const MMIO_CLEAR_GROWN: u16 = 0x018;
const MMIO_MAXIMUM_GROWTH: u16 = 0x020;
const MMIO_READOUT_LOW: u16 = 0x028;
const MMIO_READOUT_HIGH: u16 = 0x030;

const MAX_PRIMAL_OBSTACLES: u32 = MAX_MMIO_OPERATIONS;

type Primal = PrimalModuleEmbedded<{ graph::NODE_CAPACITY }>;
type Dual = DualModuleStackless<
    DualDriverTracked<CallbackDriver, { graph::NODE_CAPACITY }>,
>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DriverFault {
    Accelerator,
    OperationCapacity,
}

impl DriverFault {
    fn status(self) -> u16 {
        match self {
            Self::Accelerator => MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE,
            Self::OperationCapacity => MICROBLOSSOM_DECODE_ACCELERATOR_INCOMPLETE,
        }
    }
}

struct CallbackDriver {
    mmio: MicroblossomRustMmio,
    operations: u32,
    fault: Option<DriverFault>,
}

impl CallbackDriver {
    const fn new() -> Self {
        Self {
            mmio: MicroblossomRustMmio::empty(),
            operations: 0,
            fault: None,
        }
    }

    fn begin(&mut self, mmio: MicroblossomRustMmio) {
        self.mmio = mmio;
        self.operations = 0;
        self.fault = None;
        if self.mmio.context.is_null()
            || self.mmio.read64.is_none()
            || self.mmio.write64.is_none()
        {
            self.fail(DriverFault::Accelerator);
        }
    }

    fn fail(&mut self, fault: DriverFault) {
        if self.fault.is_none() {
            self.fault = Some(fault);
        }
    }

    fn account_operation(&mut self) -> bool {
        if self.fault.is_some() {
            return false;
        }
        if self.operations >= MAX_MMIO_OPERATIONS {
            self.fail(DriverFault::OperationCapacity);
            return false;
        }
        self.operations += 1;
        true
    }

    fn read64(&mut self, offset: u16) -> Option<u64> {
        if !self.account_operation() {
            return None;
        }
        let Some(callback) = self.mmio.read64 else {
            self.fail(DriverFault::Accelerator);
            return None;
        };
        let mut value = 0u64;
        let status = unsafe { callback(self.mmio.context, offset, &mut value) };
        if status != 0 {
            self.fail(DriverFault::Accelerator);
            None
        } else {
            Some(value)
        }
    }

    fn write64(&mut self, offset: u16, value: u64, strobe: u8) -> bool {
        if !self.account_operation() {
            return false;
        }
        let Some(callback) = self.mmio.write64 else {
            self.fail(DriverFault::Accelerator);
            return false;
        };
        let status = unsafe { callback(self.mmio.context, offset, value, strobe) };
        if status != 0 {
            self.fail(DriverFault::Accelerator);
            false
        } else {
            true
        }
    }

    fn verify_hardware(&mut self) -> bool {
        let Some(word_0) = self.read64(MMIO_HARDWARE_INFO_0) else {
            return false;
        };
        let Some(word_1) = self.read64(MMIO_HARDWARE_INFO_1) else {
            return false;
        };
        let version = word_0 as u32;
        let context_depth = (word_0 >> 32) as u32;
        let conflict_channels = word_1 as u8;
        let vertex_bits = (word_1 >> 8) as u8;
        let weight_bits = (word_1 >> 16) as u8;
        let instruction_buffer_depth = (word_1 >> 24) as u8;
        let flags = (word_1 >> 32) as u16;
        let num_layers = (word_1 >> 48) as u8;
        let reserved = (word_1 >> 56) as u8;
        let valid = version == HARDWARE_VERSION
            && context_depth == HARDWARE_CONTEXT_DEPTH
            && conflict_channels == HARDWARE_CONFLICT_CHANNELS
            && vertex_bits as usize == graph::VERTEX_BITS
            && weight_bits == expected_weight_bits()
            && instruction_buffer_depth == HARDWARE_INSTRUCTION_BUFFER_DEPTH
            && flags == HARDWARE_FLAGS
            && flags & (1 << 1) == 0
            && num_layers == HARDWARE_NUM_LAYERS
            && reserved == 0;
        if !valid {
            self.fail(DriverFault::Accelerator);
        }
        valid
    }

    fn read_obstacle(&mut self) -> (CompactObstacle, CompactWeight) {
        let Some(low) = self.read64(MMIO_READOUT_LOW) else {
            return (CompactObstacle::None, 0);
        };
        let Some(high) = self.read64(MMIO_READOUT_HIGH) else {
            return (CompactObstacle::None, 0);
        };
        if !self.write64(MMIO_CLEAR_GROWN, 0, 0x03) {
            return (CompactObstacle::None, 0);
        }

        let node_1 = low as u16;
        let node_2 = (low >> 16) as u16;
        let touch_1 = (low >> 32) as u16;
        let touch_2 = (low >> 48) as u16;
        let vertex_1 = high as u16;
        let vertex_2 = (high >> 16) as u16;
        let conflict_valid = (high >> 32) as u8;
        let max_growable = (high >> 40) as u8;
        let grown = (high >> 48) as u16;

        if conflict_valid > 1 || grown > CompactWeight::MAX as u16 {
            self.fail(DriverFault::Accelerator);
            return (CompactObstacle::None, 0);
        }
        let grown = grown as CompactWeight;
        if max_growable == u8::MAX {
            if conflict_valid != 0 {
                self.fail(DriverFault::Accelerator);
                return (CompactObstacle::None, 0);
            }
            return (CompactObstacle::None, grown);
        }
        if max_growable != 0 {
            if conflict_valid != 0 {
                self.fail(DriverFault::Accelerator);
                return (CompactObstacle::None, 0);
            }
            return (
                CompactObstacle::GrowLength {
                    length: max_growable as CompactWeight,
                },
                grown,
            );
        }
        if conflict_valid == 0 {
            return (CompactObstacle::GrowLength { length: 0 }, grown);
        }

        let Some(node_1) = compact_node(node_1) else {
            self.fail(DriverFault::Accelerator);
            return (CompactObstacle::None, 0);
        };
        let Some(touch_1) = compact_node(touch_1) else {
            self.fail(DriverFault::Accelerator);
            return (CompactObstacle::None, 0);
        };
        let node_2 = if node_2 == u16::MAX {
            None.into()
        } else if let Some(node) = compact_node(node_2) {
            node.option()
        } else {
            self.fail(DriverFault::Accelerator);
            return (CompactObstacle::None, 0);
        };
        let touch_2 = if touch_2 == u16::MAX {
            None.into()
        } else if let Some(node) = compact_node(touch_2) {
            node.option()
        } else {
            self.fail(DriverFault::Accelerator);
            return (CompactObstacle::None, 0);
        };
        let Some(vertex_1) = compact_vertex(vertex_1) else {
            self.fail(DriverFault::Accelerator);
            return (CompactObstacle::None, 0);
        };
        let Some(vertex_2) = compact_vertex(vertex_2) else {
            self.fail(DriverFault::Accelerator);
            return (CompactObstacle::None, 0);
        };
        if node_2.is_none() != touch_2.is_none() {
            self.fail(DriverFault::Accelerator);
            return (CompactObstacle::None, 0);
        }
        (
            CompactObstacle::Conflict {
                node_1: node_1.option(),
                node_2,
                touch_1: touch_1.option(),
                touch_2,
                vertex_1,
                vertex_2,
            },
            grown,
        )
    }

    fn status(&self) -> Option<u16> {
        self.fault.map(DriverFault::status)
    }
}

impl DualStacklessDriver for CallbackDriver {
    fn reset(&mut self) {
        if self.write64(
            MMIO_INSTRUCTION,
            Instruction32::reset().0 as u64,
            0xff,
        ) {
            let _ = self.read_obstacle();
        }
    }

    fn set_speed(
        &mut self,
        _is_blossom: bool,
        node: CompactNodeIndex,
        speed: CompactGrowState,
    ) {
        let _ = self.write64(
            MMIO_INSTRUCTION,
            Instruction32::set_speed(node, speed).0 as u64,
            0xff,
        );
    }

    fn set_blossom(&mut self, node: CompactNodeIndex, blossom: CompactNodeIndex) {
        let _ = self.write64(
            MMIO_INSTRUCTION,
            Instruction32::set_blossom(node, blossom).0 as u64,
            0xff,
        );
    }

    fn find_obstacle(&mut self) -> (CompactObstacle, CompactWeight) {
        self.read_obstacle()
    }

    fn add_defect(&mut self, vertex: CompactVertexIndex, node: CompactNodeIndex) {
        let _ = self.write64(
            MMIO_INSTRUCTION,
            Instruction32::add_defect_vertex(vertex, node).0 as u64,
            0xff,
        );
    }
}

impl DualTrackedDriver for CallbackDriver {
    fn find_conflict(
        &mut self,
        maximum_growth: CompactWeight,
    ) -> (CompactObstacle, CompactWeight) {
        if maximum_growth < 0 {
            self.fail(DriverFault::Accelerator);
            return (CompactObstacle::None, 0);
        }
        if !self.write64(
            MMIO_MAXIMUM_GROWTH,
            maximum_growth as u16 as u64,
            0x03,
        ) {
            return (CompactObstacle::None, 0);
        }
        self.read_obstacle()
    }
}

fn compact_node(value: u16) -> Option<CompactNodeIndex> {
    CompactNodeIndex::new(value as CompactNodeNum).option()
}

fn compact_vertex(value: u16) -> Option<CompactVertexIndex> {
    if value as usize >= graph::VERTEX_COUNT {
        None
    } else {
        CompactVertexIndex::new(value as CompactNodeNum).option()
    }
}

fn expected_weight_bits() -> u8 {
    let mut maximum = 0u8;
    let mut index = 0usize;
    while index < graph::EDGE_COUNT {
        maximum = maximum.max(graph::WEIGHTED_EDGES[index].weight());
        index += 1;
    }
    (u8::BITS - maximum.leading_zeros()) as u8
}

struct ServiceWorkspace {
    primal: Primal,
    dual: Dual,
    materializer: MaterializerWorkspace,
    defects: [u16; graph::MAX_DEFECTS],
    matching: [MatchingEndpoint; graph::MAX_DEFECTS],
}

pub(crate) const SERVICE_WORKSPACE_BYTES: usize = mem::size_of::<ServiceWorkspace>();
pub(crate) const SERVICE_WORKSPACE_ALIGNMENT: usize = mem::align_of::<ServiceWorkspace>();
pub(crate) const PRIMAL_WORKSPACE_BYTES: usize = mem::size_of::<Primal>();
pub(crate) const DUAL_WORKSPACE_BYTES: usize = mem::size_of::<Dual>();
pub(crate) const MATERIALIZER_WORKSPACE_BYTES: usize = mem::size_of::<MaterializerWorkspace>();
pub(crate) const DEFECT_WORKSPACE_BYTES: usize = mem::size_of::<[u16; graph::MAX_DEFECTS]>();
pub(crate) const MATCHING_WORKSPACE_BYTES: usize =
    mem::size_of::<[MatchingEndpoint; graph::MAX_DEFECTS]>();

impl ServiceWorkspace {
    /// Initializes every field directly in static storage so the graph-sized
    /// workspace is never materialized as a temporary R5 stack frame.
    ///
    /// # Safety
    ///
    /// `destination` must be aligned, writable, and valid for one `Self`.
    /// It must not point to a live value, and callers must not expose it until
    /// this function returns.
    unsafe fn initialize_in_place(destination: *mut Self) {
        unsafe {
            let primal = ptr::addr_of_mut!((*destination).primal);
            PrimalNodes::initialize_in_place(ptr::addr_of_mut!((*primal).nodes));
            LayerFusionData::initialize_in_place(ptr::addr_of_mut!((*primal).layer_fusion));

            let dual = ptr::addr_of_mut!((*destination).dual);
            let tracked = ptr::addr_of_mut!((*dual).driver);
            ptr::addr_of_mut!((*tracked).driver).write(CallbackDriver::new());
            BlossomTracker::initialize_in_place(ptr::addr_of_mut!((*tracked).blossom_tracker));

            MaterializerWorkspace::initialize_in_place(ptr::addr_of_mut!(
                (*destination).materializer
            ));
            ptr::write_bytes(ptr::addr_of_mut!((*destination).defects), 0, 1);

            let matching =
                ptr::addr_of_mut!((*destination).matching).cast::<MatchingEndpoint>();
            let mut index = 0;
            while index < graph::MAX_DEFECTS {
                matching.add(index).write(MatchingEndpoint::peer(0, 0));
                index += 1;
            }
        }
    }
}

struct WorkspaceCell(UnsafeCell<MaybeUninit<ServiceWorkspace>>);

unsafe impl Sync for WorkspaceCell {}

static WORKSPACE: WorkspaceCell = WorkspaceCell(UnsafeCell::new(MaybeUninit::uninit()));
static WORKSPACE_INITIALIZED: AtomicBool = AtomicBool::new(false);
static WORKSPACE_BUSY: AtomicBool = AtomicBool::new(false);

struct WorkspaceGuard;

impl WorkspaceGuard {
    fn acquire() -> Option<Self> {
        WORKSPACE_BUSY
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .ok()
            .map(|_| Self)
    }
}

impl Drop for WorkspaceGuard {
    fn drop(&mut self) {
        WORKSPACE_BUSY.store(false, Ordering::Release);
    }
}

pub struct DecodeOutcome {
    pub status: u16,
    pub correction_count: usize,
    pub operations: u16,
}

pub fn decode(
    mmio: MicroblossomRustMmio,
    defects_le: &[u8],
    defect_count: usize,
    correction_edges: &mut [u16],
) -> DecodeOutcome {
    if defect_count > graph::MAX_DEFECTS
        || defects_le.len() != defect_count.saturating_mul(2)
    {
        return outcome(MICROBLOSSOM_DECODE_INVALID_SYNDROME, 0, 0);
    }
    let Some(_guard) = WorkspaceGuard::acquire() else {
        return outcome(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE, 0, 0);
    };
    let workspace = unsafe {
        if !WORKSPACE_INITIALIZED.load(Ordering::Relaxed) {
            ServiceWorkspace::initialize_in_place((*WORKSPACE.0.get()).as_mut_ptr());
            WORKSPACE_INITIALIZED.store(true, Ordering::Release);
        }
        (&mut *WORKSPACE.0.get()).assume_init_mut()
    };
    decode_with_workspace(
        workspace,
        mmio,
        defects_le,
        defect_count,
        correction_edges,
    )
}

fn decode_with_workspace(
    workspace: &mut ServiceWorkspace,
    mmio: MicroblossomRustMmio,
    defects_le: &[u8],
    defect_count: usize,
    correction_edges: &mut [u16],
) -> DecodeOutcome {
    if correction_edges.len() != graph::MAX_CORRECTION_EDGES {
        return outcome(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE, 0, 0);
    }
    let mut previous = None;
    let mut index = 0usize;
    while index < defect_count {
        let defect = u16::from_le_bytes([defects_le[2 * index], defects_le[2 * index + 1]]);
        if defect as usize >= graph::VERTEX_COUNT
            || graph::is_virtual(defect)
            || previous.is_some_and(|value| value >= defect)
        {
            return outcome(MICROBLOSSOM_DECODE_INVALID_SYNDROME, 0, 0);
        }
        workspace.defects[index] = defect;
        previous = Some(defect);
        index += 1;
    }

    let driver = &mut workspace.dual.driver.driver;
    driver.begin(mmio);
    if !driver.verify_hardware() {
        return outcome(
            driver
                .status()
                .unwrap_or(MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE),
            0,
            driver.operations as u16,
        );
    }

    workspace.primal.reset();
    workspace.primal.nodes.blossom_begin = graph::DEFECT_NODE_CAPACITY;
    workspace.dual.reset();
    if let Some(status) = workspace.dual.driver.driver.status() {
        return failed_cleanup(workspace, status, correction_edges);
    }

    index = 0;
    while index < defect_count {
        let Some(vertex) = compact_vertex(workspace.defects[index]) else {
            return failed_cleanup(
                workspace,
                MICROBLOSSOM_DECODE_INVALID_SYNDROME,
                correction_edges,
            );
        };
        let Some(node) = compact_node(index as u16) else {
            return failed_cleanup(
                workspace,
                MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE,
                correction_edges,
            );
        };
        workspace.dual.add_defect(vertex, node);
        if let Some(status) = workspace.dual.driver.driver.status() {
            return failed_cleanup(workspace, status, correction_edges);
        }
        index += 1;
    }

    let mut obstacle_count = 0u32;
    loop {
        let (obstacle, _) = workspace.dual.find_obstacle();
        if let Some(status) = workspace.dual.driver.driver.status() {
            return failed_cleanup(workspace, status, correction_edges);
        }
        if obstacle.is_none() {
            break;
        }
        if obstacle.is_finite_growth()
            || obstacle_count >= MAX_PRIMAL_OBSTACLES
            || !obstacle_is_safe(&workspace.primal, &obstacle, defect_count)
        {
            return failed_cleanup(
                workspace,
                MICROBLOSSOM_DECODE_ACCELERATOR_INCOMPLETE,
                correction_edges,
            );
        }
        if !workspace.primal.resolve(&mut workspace.dual, obstacle) {
            return failed_cleanup(
                workspace,
                MICROBLOSSOM_DECODE_ACCELERATOR_INCOMPLETE,
                correction_edges,
            );
        }
        if let Some(status) = workspace.dual.driver.driver.status() {
            return failed_cleanup(workspace, status, correction_edges);
        }
        obstacle_count += 1;
    }

    let mut matching_count = 0usize;
    let mut matching_invalid = false;
    workspace
        .primal
        .iterate_perfect_matching(|_, source, target, _| {
            if matching_invalid || matching_count >= workspace.matching.len() {
                matching_invalid = true;
                return;
            }
            let source = source.get() as usize;
            if source >= defect_count {
                matching_invalid = true;
                return;
            }
            let endpoint = match target {
                CompactMatchTarget::Peer(peer) => {
                    let peer = peer.get() as usize;
                    if peer >= defect_count || peer == source {
                        matching_invalid = true;
                        return;
                    }
                    MatchingEndpoint::peer(source as u16, peer as u16)
                }
                CompactMatchTarget::VirtualVertex(vertex) => {
                    let vertex = vertex.get() as u16;
                    if !graph::is_virtual(vertex) {
                        matching_invalid = true;
                        return;
                    }
                    MatchingEndpoint::virtual_vertex(source as u16, vertex)
                }
            };
            workspace.matching[matching_count] = endpoint;
            matching_count += 1;
        });
    if matching_invalid {
        return failed_cleanup(
            workspace,
            MICROBLOSSOM_DECODE_ACCELERATOR_INCOMPLETE,
            correction_edges,
        );
    }

    let materialization = materialize_correction(
        &mut workspace.materializer,
        &workspace.defects[..defect_count],
        &workspace.matching[..matching_count],
        correction_edges,
    );
    let edge_count = match materialization {
        Ok(result) => result.edge_count,
        Err(error) => {
            return failed_cleanup(
                workspace,
                materialization_status(error),
                correction_edges,
            );
        }
    };

    workspace.primal.reset();
    workspace.dual.reset();
    if let Some(status) = workspace.dual.driver.driver.status() {
        clear_edges(correction_edges);
        return outcome(status, 0, workspace.dual.driver.driver.operations as u16);
    }
    outcome(
        MICROBLOSSOM_DECODE_OK,
        edge_count,
        workspace.dual.driver.driver.operations as u16,
    )
}

fn failed_cleanup(
    workspace: &mut ServiceWorkspace,
    status: u16,
    correction_edges: &mut [u16],
) -> DecodeOutcome {
    clear_edges(correction_edges);
    workspace.primal.reset();
    workspace.dual.reset();
    let driver = &workspace.dual.driver.driver;
    outcome(driver.status().unwrap_or(status), 0, driver.operations as u16)
}

fn clear_edges(edges: &mut [u16]) {
    for edge in edges {
        *edge = 0;
    }
}

fn outcome(status: u16, correction_count: usize, operations: u16) -> DecodeOutcome {
    DecodeOutcome {
        status,
        correction_count,
        operations,
    }
}

fn materialization_status(error: MaterializationError) -> u16 {
    match error {
        MaterializationError::TooManyDefects
        | MaterializationError::DefectsNotStrictlyIncreasing
        | MaterializationError::InvalidDefectVertex => MICROBLOSSOM_DECODE_INVALID_SYNDROME,
        MaterializationError::TooManyMatchingEndpoints
        | MaterializationError::InvalidMatchingNode
        | MaterializationError::InvalidMatchingTarget
        | MaterializationError::MatchingDoesNotCoverDefects
        | MaterializationError::TargetUnreachable
        | MaterializationError::InvalidPredecessorChain => {
            MICROBLOSSOM_DECODE_ACCELERATOR_INCOMPLETE
        }
        MaterializationError::GraphInvariant
        | MaterializationError::DistanceOverflow
        | MaterializationError::OutputCapacity => MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE,
    }
}

fn obstacle_is_safe(primal: &Primal, obstacle: &CompactObstacle, defect_count: usize) -> bool {
    let CompactObstacle::Conflict {
        node_1,
        node_2,
        touch_1,
        touch_2,
        vertex_1,
        vertex_2,
    } = obstacle
    else {
        return matches!(obstacle, CompactObstacle::BlossomNeedExpand { blossom } if valid_node(primal, *blossom, defect_count));
    };
    let Some(node_1) = node_1.option() else {
        return false;
    };
    let Some(touch_1) = touch_1.option() else {
        return false;
    };
    if !valid_node(primal, node_1, defect_count)
        || !valid_node(primal, touch_1, defect_count)
        || vertex_1.get() as usize >= graph::VERTEX_COUNT
        || vertex_2.get() as usize >= graph::VERTEX_COUNT
    {
        return false;
    }
    match (node_2.option(), touch_2.option()) {
        (None, None) => graph::is_virtual(vertex_2.get() as u16),
        (Some(node_2), Some(touch_2)) => {
            node_1 != node_2
                && valid_node(primal, node_2, defect_count)
                && valid_node(primal, touch_2, defect_count)
        }
        _ => false,
    }
}

fn valid_node(primal: &Primal, node: CompactNodeIndex, defect_count: usize) -> bool {
    let node = node.get() as usize;
    if node < graph::DEFECT_NODE_CAPACITY {
        node < defect_count
    } else {
        node < graph::NODE_CAPACITY
            && node - graph::DEFECT_NODE_CAPACITY < primal.nodes.count_blossoms
    }
}

const _: () = assert!(graph::VERTEX_BITS <= 15);
const _: () = assert!(graph::NODE_CAPACITY == 1usize << graph::VERTEX_BITS);
const _: () = assert!(graph::DEFECT_NODE_CAPACITY == graph::NODE_CAPACITY / 2);
const _: () = assert!(graph::MAX_DEFECTS <= graph::DEFECT_NODE_CAPACITY);
const _: () = assert!(MAX_MMIO_OPERATIONS <= u16::MAX as u32);
