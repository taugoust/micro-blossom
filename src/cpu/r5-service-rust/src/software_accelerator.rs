use crate::graph;
use fusion_blossom::util::{SolverInitializer, VertexIndex, Weight};
use fusion_blossom::visualize::VisualizePosition;
use micro_blossom::dual_module_comb::{DualCombConfig, DualModuleCombDriver};
use micro_blossom::resources::MicroBlossomSingle;
use micro_blossom_nostd::dual_driver_tracked::DualTrackedDriver;
use micro_blossom_nostd::dual_module_stackless::DualStacklessDriver;
use micro_blossom_nostd::interface::CompactObstacle;
use micro_blossom_nostd::util::{
    CompactGrowState, CompactNodeIndex, CompactNodeNum, CompactWeight,
    CompactVertexIndex,
};
use std::ffi::c_void;

const HARDWARE_VERSION: u32 = 0x2401_23c0;
const HARDWARE_FLAGS: u16 = (1 << 0) | (1 << 3) | (1 << 5);
const CALLBACK_FAILURE: u16 = 1;

pub(crate) fn initializer() -> SolverInitializer {
    SolverInitializer {
        vertex_num: graph::VERTEX_COUNT,
        weighted_edges: graph::WEIGHTED_EDGES
            .iter()
            .map(|edge| {
                (
                    edge.left() as VertexIndex,
                    edge.right() as VertexIndex,
                    edge.weight() as Weight,
                )
            })
            .collect(),
        virtual_vertices: (0..graph::VERTEX_COUNT)
            .filter(|&vertex| graph::is_virtual(vertex as u16))
            .map(|vertex| vertex as VertexIndex)
            .collect(),
    }
}

fn node(value: u16) -> Option<CompactNodeIndex> {
    CompactNodeIndex::new(value as CompactNodeNum).option()
}

fn vertex(value: u16) -> Option<CompactVertexIndex> {
    CompactVertexIndex::new(value as CompactNodeNum).option()
}

fn optional_node(value: micro_blossom_nostd::util::OptionCompactNodeIndex) -> u16 {
    value
        .option()
        .map(|value| value.get() as u16)
        .unwrap_or(u16::MAX)
}

pub(crate) struct SoftwareAccelerator {
    driver: DualModuleCombDriver,
    pub(crate) hardware_version: u32,
    pub(crate) hardware_vertex_bits: u8,
    pub(crate) hardware_flags: u16,
    pub(crate) hardware_num_layers: u8,
    maximum_growth: CompactWeight,
    pending_readout: Option<(u64, u64)>,
    pub(crate) stuck_growth: bool,
}

impl SoftwareAccelerator {
    pub(crate) fn new() -> Self {
        let initializer = initializer();
        let positions = vec![VisualizePosition::new(0.0, 0.0, 0.0); graph::VERTEX_COUNT];
        let accelerator_graph = MicroBlossomSingle::new(&initializer, &positions);
        let mut config = DualCombConfig::default();
        config.log_instructions = true;
        config.sim_config.support_offloading = false;
        config.sim_config.support_layer_fusion = false;
        Self {
            driver: DualModuleCombDriver::new(accelerator_graph, config),
            hardware_version: HARDWARE_VERSION,
            hardware_vertex_bits: graph::VERTEX_BITS as u8,
            hardware_flags: HARDWARE_FLAGS,
            hardware_num_layers: graph::NUM_LAYERS,
            maximum_growth: CompactWeight::MAX,
            pending_readout: None,
            stuck_growth: false,
        }
    }


    fn encode_readout(&mut self) -> Result<(u64, u64), ()> {
        if self.stuck_growth {
            return Ok((0, (1u64 << 40) | (1u64 << 48)));
        }
        let (obstacle, grown) =
            DualTrackedDriver::find_conflict(&mut self.driver, self.maximum_growth);
        if grown < 0 {
            return Err(());
        }
        let mut node_1 = u16::MAX;
        let mut node_2 = u16::MAX;
        let mut touch_1 = u16::MAX;
        let mut touch_2 = u16::MAX;
        let mut vertex_1 = 0u16;
        let mut vertex_2 = 0u16;
        let (conflict_valid, max_growable) = match obstacle {
            CompactObstacle::None => (0u8, u8::MAX),
            CompactObstacle::GrowLength { length } => {
                if !(0..=u8::MAX as CompactWeight - 1).contains(&length) {
                    return Err(());
                }
                (0, length as u8)
            }
            CompactObstacle::Conflict {
                node_1: first_node,
                node_2: second_node,
                touch_1: first_touch,
                touch_2: second_touch,
                vertex_1: first_vertex,
                vertex_2: second_vertex,
            } => {
                node_1 = optional_node(first_node);
                node_2 = optional_node(second_node);
                touch_1 = optional_node(first_touch);
                touch_2 = optional_node(second_touch);
                vertex_1 = first_vertex.get() as u16;
                vertex_2 = second_vertex.get() as u16;
                (1, 0)
            }
            CompactObstacle::BlossomNeedExpand { .. } => return Err(()),
        };
        let low = node_1 as u64
            | ((node_2 as u64) << 16)
            | ((touch_1 as u64) << 32)
            | ((touch_2 as u64) << 48);
        let high = vertex_1 as u64
            | ((vertex_2 as u64) << 16)
            | ((conflict_valid as u64) << 32)
            | ((max_growable as u64) << 40)
            | ((grown as u16 as u64) << 48);
        Ok((low, high))
    }

    pub(crate) fn read64(&mut self, offset: u16) -> Result<u64, ()> {
        match offset {
            0x000 => Ok(self.hardware_version as u64 | (1u64 << 32)),
            0x008 => {
                let weight_bits = graph::WEIGHTED_EDGES
                    .iter()
                    .map(|edge| edge.weight())
                    .max()
                    .unwrap()
                    .ilog2()
                    + 1;
                Ok(1u64
                    | ((self.hardware_vertex_bits as u64) << 8)
                    | ((weight_bits as u64) << 16)
                    | (4u64 << 24)
                    | ((self.hardware_flags as u64) << 32)
                    | ((self.hardware_num_layers as u64) << 48))
            }
            0x028 => {
                if self.pending_readout.is_some() {
                    return Err(());
                }
                let readout = self.encode_readout()?;
                self.pending_readout = Some(readout);
                Ok(readout.0)
            }
            0x030 => self.pending_readout.map(|readout| readout.1).ok_or(()),
            _ => Err(()),
        }
    }

    pub(crate) fn write64(
        &mut self,
        offset: u16,
        value: u64,
        strobe: u8,
    ) -> Result<(), ()> {
        match offset {
            0x010 if strobe == 0xff && value >> 48 == 0 && (value >> 32) as u16 == 0 => {
                let instruction = value as u32;
                if instruction == 0x24 {
                    DualStacklessDriver::reset(&mut self.driver);
                    self.pending_readout = None;
                    self.maximum_growth = CompactWeight::MAX;
                    return Ok(());
                }
                match instruction & 0x3 {
                    0 if instruction & 0x4 == 0 => {
                        let node = node((instruction >> 17) as u16).ok_or(())?;
                        let speed = match (instruction >> 15) & 0x3 {
                            0 => CompactGrowState::Stay,
                            1 => CompactGrowState::Grow,
                            2 => CompactGrowState::Shrink,
                            _ => return Err(()),
                        };
                        DualStacklessDriver::set_speed(&mut self.driver, false, node, speed);
                    }
                    1 => {
                        let child = node((instruction >> 17) as u16).ok_or(())?;
                        let blossom = node(((instruction >> 2) & 0x7fff) as u16).ok_or(())?;
                        DualStacklessDriver::set_blossom(&mut self.driver, child, blossom);
                    }
                    2 => {
                        let defect_vertex = vertex((instruction >> 17) as u16).ok_or(())?;
                        let defect_node = node(((instruction >> 2) & 0x7fff) as u16).ok_or(())?;
                        DualStacklessDriver::add_defect(
                            &mut self.driver,
                            defect_vertex,
                            defect_node,
                        );
                    }
                    _ => return Err(()),
                }
                Ok(())
            }
            0x018 if strobe == 0x03 && value == 0 => {
                self.pending_readout.take().ok_or(())?;
                Ok(())
            }
            0x020 if strobe == 0x03 && value <= CompactWeight::MAX as u64 => {
                self.maximum_growth = value as CompactWeight;
                Ok(())
            }
            _ => Err(()),
        }
    }
}

pub(crate) unsafe extern "C" fn read_callback(
    context: *mut c_void,
    offset: u16,
    value: *mut u64,
) -> u16 {
    if context.is_null() || value.is_null() {
        return CALLBACK_FAILURE;
    }
    let accelerator = unsafe { &mut *context.cast::<SoftwareAccelerator>() };
    match accelerator.read64(offset) {
        Ok(result) => {
            unsafe { value.write(result) };
            0
        }
        Err(()) => CALLBACK_FAILURE,
    }
}

pub(crate) unsafe extern "C" fn write_callback(
    context: *mut c_void,
    offset: u16,
    value: u64,
    strobe: u8,
) -> u16 {
    if context.is_null() {
        return CALLBACK_FAILURE;
    }
    let accelerator = unsafe { &mut *context.cast::<SoftwareAccelerator>() };
    accelerator
        .write64(offset, value, strobe)
        .map_or(CALLBACK_FAILURE, |()| 0)
}

#[cfg(feature = "service-model")]
#[no_mangle]
pub extern "C" fn microblossom_rust_software_accelerator_create() -> *mut c_void {
    Box::into_raw(Box::new(SoftwareAccelerator::new())).cast()
}

#[cfg(feature = "service-model")]
#[no_mangle]
pub unsafe extern "C" fn microblossom_rust_software_accelerator_destroy(context: *mut c_void) {
    if !context.is_null() {
        drop(unsafe { Box::from_raw(context.cast::<SoftwareAccelerator>()) });
    }
}

#[cfg(feature = "service-model")]
#[no_mangle]
pub unsafe extern "C" fn microblossom_rust_software_accelerator_read64(
    context: *mut c_void,
    offset: u16,
    value: *mut u64,
) -> u16 {
    unsafe { read_callback(context, offset, value) }
}

#[cfg(feature = "service-model")]
#[no_mangle]
pub unsafe extern "C" fn microblossom_rust_software_accelerator_write64(
    context: *mut c_void,
    offset: u16,
    value: u64,
    strobe: u8,
) -> u16 {
    unsafe { write_callback(context, offset, value, strobe) }
}

#[cfg(feature = "service-model")]
#[no_mangle]
pub unsafe extern "C" fn microblossom_rust_software_accelerator_set_identity_fault(
    context: *mut c_void,
    fault: u16,
) -> u16 {
    if context.is_null() || !(1..=5).contains(&fault) {
        return CALLBACK_FAILURE;
    }
    let accelerator = unsafe { &mut *context.cast::<SoftwareAccelerator>() };
    match fault {
        1 => accelerator.hardware_version ^= 1,
        2 => accelerator.hardware_vertex_bits ^= 1,
        3 => accelerator.hardware_flags |= 1 << 1,
        4 => accelerator.hardware_num_layers ^= 1,
        5 => accelerator.hardware_num_layers = 0,
        _ => return CALLBACK_FAILURE,
    }
    0
}

#[cfg(feature = "service-model")]
#[no_mangle]
pub unsafe extern "C" fn microblossom_rust_software_accelerator_set_stuck_growth(
    context: *mut c_void,
    stuck: u16,
) -> u16 {
    if context.is_null() || stuck > 1 {
        return CALLBACK_FAILURE;
    }
    let accelerator = unsafe { &mut *context.cast::<SoftwareAccelerator>() };
    accelerator.stuck_growth = stuck != 0;
    0
}

#[cfg(feature = "service-model")]
#[no_mangle]
pub unsafe extern "C" fn microblossom_rust_software_accelerator_edge(
    edge_index: u16,
    left: *mut u16,
    right: *mut u16,
    weight: *mut u16,
) -> u16 {
    let Some(edge) = graph::WEIGHTED_EDGES.get(edge_index as usize) else {
        return CALLBACK_FAILURE;
    };
    if left.is_null() || right.is_null() || weight.is_null() {
        return CALLBACK_FAILURE;
    }
    unsafe {
        left.write(edge.left());
        right.write(edge.right());
        weight.write(edge.weight() as u16);
    }
    0
}
