use super::*;
use fusion_blossom::mwpm_solver::{PrimalDualSolver, SolverSerial};
use fusion_blossom::util::{EdgeIndex, SolverInitializer, SyndromePattern, VertexIndex, Weight};
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
use std::collections::BTreeSet;
use std::ffi::c_void;

const HARDWARE_VERSION: u32 = 0x2401_23c0;
const HARDWARE_FLAGS: u16 = (1 << 0) | (1 << 3) | (1 << 5);
const CALLBACK_FAILURE: u16 = 1;

struct CorpusCase {
    name: &'static str,
    defects: &'static [u16],
    expect_blossom: bool,
}

const D3_CASES: &[CorpusCase] = &[
    CorpusCase {
        name: "empty",
        defects: &[],
        expect_blossom: false,
    },
    CorpusCase {
        name: "singleton-smoke-v0",
        defects: &[0],
        expect_blossom: false,
    },
    CorpusCase {
        name: "singleton-non-smoke-v18",
        defects: &[18],
        expect_blossom: false,
    },
    CorpusCase {
        name: "direct-pair-edge-1",
        defects: &[0, 3],
        expect_blossom: false,
    },
    CorpusCase {
        name: "four-defect-spread",
        defects: &[0, 7, 14, 18],
        expect_blossom: true,
    },
    CorpusCase {
        name: "blossom-producing-lexicographic-first",
        defects: &[0, 3, 4, 13],
        expect_blossom: true,
    },
    CorpusCase {
        name: "tie-exercising-alternate-policy-differs",
        defects: &[3, 6],
        expect_blossom: false,
    },
];

const D9_CASES: &[CorpusCase] = &[
    CorpusCase {
        name: "empty",
        defects: &[],
        expect_blossom: false,
    },
    CorpusCase {
        name: "singleton-smoke-v0",
        defects: &[0],
        expect_blossom: false,
    },
    CorpusCase {
        name: "singleton-non-smoke-v432",
        defects: &[432],
        expect_blossom: false,
    },
    CorpusCase {
        name: "direct-pair-edge-1",
        defects: &[0, 3],
        expect_blossom: false,
    },
    CorpusCase {
        name: "four-defect-spread",
        defects: &[0, 147, 294, 432],
        expect_blossom: false,
    },
    CorpusCase {
        name: "tie-exercising-two-defect-peer",
        defects: &[0, 6],
        expect_blossom: false,
    },
];

fn corpus() -> &'static [CorpusCase] {
    match (graph::VERTEX_COUNT, graph::EDGE_COUNT) {
        (19, 39) => D3_CASES,
        (433, 1737) => D9_CASES,
        _ => panic!("callback oracle is defined only for frozen circuit d3/d9"),
    }
}

fn initializer() -> SolverInitializer {
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
    value.option().map(|value| value.get() as u16).unwrap_or(u16::MAX)
}

struct SoftwareAccelerator {
    driver: DualModuleCombDriver,
    hardware_version: u32,
    hardware_vertex_bits: u8,
    hardware_flags: u16,
    hardware_num_layers: u8,
    maximum_growth: CompactWeight,
    pending_readout: Option<(u64, u64)>,
    callback_calls: u32,
    fail_callback_at: Option<u32>,
    set_blossom_writes: u32,
    stuck_growth: bool,
    aperture: BTreeSet<u16>,
}

impl SoftwareAccelerator {
    fn new() -> Self {
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
            callback_calls: 0,
            fail_callback_at: None,
            set_blossom_writes: 0,
            stuck_growth: false,
            aperture: BTreeSet::new(),
        }
    }

    fn begin_callback(&mut self, offset: u16) -> Result<(), ()> {
        self.callback_calls += 1;
        self.aperture.insert(offset);
        if self.fail_callback_at == Some(self.callback_calls) {
            return Err(());
        }
        Ok(())
    }

    fn encode_readout(&mut self) -> Result<(u64, u64), ()> {
        if self.stuck_growth {
            return Ok((0, (1u64 << 40) | (1u64 << 48)));
        }
        let (obstacle, grown) = DualTrackedDriver::find_conflict(
            &mut self.driver,
            self.maximum_growth,
        );
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

    fn hardware_info_word_1(&self) -> u64 {
        let weight_bits = graph::WEIGHTED_EDGES
            .iter()
            .map(|edge| edge.weight())
            .max()
            .unwrap()
            .ilog2()
            + 1;
        1u64
            | ((self.hardware_vertex_bits as u64) << 8)
            | ((weight_bits as u64) << 16)
            | (4u64 << 24)
            | ((self.hardware_flags as u64) << 32)
            | ((self.hardware_num_layers as u64) << 48)
    }

    fn read64(&mut self, offset: u16) -> Result<u64, ()> {
        self.begin_callback(offset)?;
        match offset {
            0x000 => Ok(self.hardware_version as u64 | (1u64 << 32)),
            0x008 => Ok(self.hardware_info_word_1()),
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

    fn write64(&mut self, offset: u16, value: u64, strobe: u8) -> Result<(), ()> {
        self.begin_callback(offset)?;
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
                        self.set_blossom_writes += 1;
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

unsafe extern "C" fn read_callback(
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

unsafe extern "C" fn write_callback(
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

fn callbacks(accelerator: &mut SoftwareAccelerator) -> MicroblossomRustMmio {
    MicroblossomRustMmio {
        context: (accelerator as *mut SoftwareAccelerator).cast(),
        read64: Some(read_callback),
        write64: Some(write_callback),
    }
}

fn defects_le(defects: &[u16]) -> Vec<u8> {
    defects
        .iter()
        .flat_map(|defect| defect.to_le_bytes())
        .collect()
}

fn decode(
    accelerator: &mut SoftwareAccelerator,
    defects: &[u16],
) -> (u16, Vec<u16>, u16) {
    let _guard = test_decode_guard();
    let encoded = defects_le(defects);
    let mut corrections = vec![0x55aa; graph::MAX_CORRECTION_EDGES];
    let mut correction_count = u16::MAX;
    let mut operations = u16::MAX;
    let mmio = callbacks(accelerator);
    let status = unsafe {
        microblossom_rust_service_decode(
            &mmio,
            encoded.as_ptr(),
            defects.len() as u16,
            corrections.as_mut_ptr(),
            corrections.len() as u16,
            &mut correction_count,
            &mut operations,
        )
    };
    corrections.truncate(correction_count as usize);
    (status, corrections, operations)
}

fn serial_minimum_weight(initializer: &SolverInitializer, defects: &[u16]) -> Weight {
    let syndrome = SyndromePattern::new_vertices(
        defects
            .iter()
            .map(|&vertex| vertex as VertexIndex)
            .collect(),
    );
    let mut solver = SolverSerial::new(initializer);
    solver.solve_visualizer(&syndrome, None);
    solver
        .subgraph_visualizer(None)
        .iter()
        .map(|&edge| initializer.weighted_edges[edge as usize].2)
        .sum()
}

fn assert_semantic_correction(
    initializer: &SolverInitializer,
    case: &CorpusCase,
    corrections: &[u16],
) {
    assert!(
        corrections.windows(2).all(|pair| pair[0] < pair[1]),
        "{}: correction is not sorted and unique",
        case.name
    );
    assert!(corrections
        .iter()
        .all(|&edge| (edge as usize) < graph::EDGE_COUNT));
    let typed_edges: Vec<EdgeIndex> = corrections
        .iter()
        .map(|&edge| edge as EdgeIndex)
        .collect();
    let reconstructed: Vec<u16> = initializer
        .syndrome_of(&typed_edges)
        .into_iter()
        .map(|vertex| vertex as u16)
        .collect();
    assert_eq!(reconstructed, case.defects, "{}: syndrome differs", case.name);
    let actual_weight: Weight = corrections
        .iter()
        .map(|&edge| initializer.weighted_edges[edge as usize].2)
        .sum();
    assert_eq!(
        actual_weight,
        serial_minimum_weight(initializer, case.defects),
        "{}: minimum weight differs from SolverSerial",
        case.name
    );
}

#[test]
fn callback_accelerator_matches_solver_serial_corpus() {
    let initializer = initializer();
    let mut reference_blossom_cases = 0usize;
    for case in corpus() {
        let mut accelerator = SoftwareAccelerator::new();
        let (status, corrections, operations) = decode(&mut accelerator, case.defects);
        assert_eq!(status, MICROBLOSSOM_DECODE_OK, "{}", case.name);
        assert!(operations > 0, "{}: no MMIO operations", case.name);
        assert_semantic_correction(&initializer, case, &corrections);
        reference_blossom_cases += usize::from(case.expect_blossom);
        if !case.defects.is_empty() {
            assert_eq!(
                accelerator.aperture,
                BTreeSet::from([0x000, 0x008, 0x010, 0x018, 0x020, 0x028, 0x030]),
                "{}: driver did not use the exact seven-register aperture",
                case.name
            );
        }
    }
    assert_eq!(
        reference_blossom_cases,
        if graph::VERTEX_COUNT == 19 { 2 } else { 0 }
    );
    println!(
        "MICROBLOSSOM_R5_CALLBACK_ORACLE_PASS graph={} cases={}",
        graph::GRAPH_ID,
        corpus().len()
    );
}

#[test]
fn callback_driver_exercises_blossom_updates() {
    if graph::VERTEX_COUNT != 19 {
        return;
    }
    let initializer = initializer();
    let case = CorpusCase {
        name: "embedded-primal-blossom-update",
        defects: &[0, 3, 6, 10],
        expect_blossom: true,
    };
    let mut accelerator = SoftwareAccelerator::new();
    let (status, corrections, _) = decode(&mut accelerator, case.defects);
    assert_eq!(status, MICROBLOSSOM_DECODE_OK);
    assert_semantic_correction(&initializer, &case, &corrections);
    assert!(accelerator.set_blossom_writes > 0);
}

#[test]
fn hardware_identity_and_mmio_faults_fail_closed() {
    let actual_word = u64::from_str_radix(
        option_env!("MICROBLOSSOM_R5_ACTUAL_HARDWARE_INFO_WORD_1")
            .expect("actual generated hardware-info word 1 was not supplied"),
        16,
    )
    .expect("actual generated hardware-info word 1 is not hexadecimal");
    let mut accelerator = SoftwareAccelerator::new();
    assert_eq!(accelerator.hardware_info_word_1(), actual_word);
    assert_eq!((actual_word >> 48) as u8, graph::NUM_LAYERS);
    assert_ne!(graph::NUM_LAYERS, 0);
    let (status, _, _) = decode(&mut accelerator, &[0]);
    assert_eq!(status, MICROBLOSSOM_DECODE_OK);

    for mutate in 0..5 {
        let mut accelerator = SoftwareAccelerator::new();
        match mutate {
            0 => accelerator.hardware_version ^= 1,
            1 => accelerator.hardware_vertex_bits ^= 1,
            2 => accelerator.hardware_flags |= 1 << 1,
            3 => accelerator.hardware_num_layers ^= 1,
            4 => accelerator.hardware_num_layers = 0,
            _ => unreachable!(),
        }
        let (status, corrections, operations) = decode(&mut accelerator, &[0]);
        assert_eq!(status, MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE);
        assert!(corrections.is_empty());
        assert!(operations <= 2);
    }

    println!(
        "MICROBLOSSOM_R5_HARDWARE_IDENTITY_PASS graph={} word_1=0x{actual_word:016x} layers={}",
        graph::GRAPH_ID,
        graph::NUM_LAYERS
    );

    let mut accelerator = SoftwareAccelerator::new();
    accelerator.fail_callback_at = Some(5);
    let (status, corrections, _operations) = decode(&mut accelerator, &[0, 3]);
    assert_eq!(status, MICROBLOSSOM_DECODE_ACCELERATOR_FAILURE);
    assert!(corrections.is_empty());
    assert_eq!(accelerator.callback_calls, 5, "fault was not sticky");
}

#[test]
fn malformed_inputs_and_nonconvergence_are_bounded() {
    let _guard = test_decode_guard();
    let mut accelerator = SoftwareAccelerator::new();
    let encoded = defects_le(&[3, 0]);
    let mut corrections = vec![0x55aa; graph::MAX_CORRECTION_EDGES];
    let mut correction_count = u16::MAX;
    let mut operations = u16::MAX;
    let mmio = callbacks(&mut accelerator);
    let status = unsafe {
        microblossom_rust_service_decode(
            &mmio,
            encoded.as_ptr(),
            2,
            corrections.as_mut_ptr(),
            corrections.len() as u16,
            &mut correction_count,
            &mut operations,
        )
    };
    assert_eq!(status, MICROBLOSSOM_DECODE_INVALID_SYNDROME);
    assert_eq!(correction_count, 0);
    assert_eq!(operations, 0);
    assert!(corrections.iter().all(|&edge| edge == 0));
    assert_eq!(accelerator.callback_calls, 0);

    drop(_guard);
    let mut accelerator = SoftwareAccelerator::new();
    accelerator.stuck_growth = true;
    let (status, corrections, operations) = decode(&mut accelerator, &[0]);
    assert_eq!(status, MICROBLOSSOM_DECODE_ACCELERATOR_INCOMPLETE);
    assert!(corrections.is_empty());
    assert_eq!(operations as u32, MAX_MMIO_OPERATIONS);
    assert_eq!(accelerator.callback_calls, MAX_MMIO_OPERATIONS);
}
