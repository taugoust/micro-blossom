use crate::graph;
use core::ptr;

const NONE: u16 = u16::MAX;

pub const MATCH_TARGET_PEER_NODE: u16 = 0;
pub const MATCH_TARGET_VIRTUAL_VERTEX: u16 = 1;

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MatchingEndpoint {
    pub source_node: u16,
    pub target: u16,
    pub target_kind: u16,
}

impl MatchingEndpoint {
    pub const fn peer(source_node: u16, target_node: u16) -> Self {
        Self {
            source_node,
            target: target_node,
            target_kind: MATCH_TARGET_PEER_NODE,
        }
    }

    pub const fn virtual_vertex(source_node: u16, target_vertex: u16) -> Self {
        Self {
            source_node,
            target: target_vertex,
            target_kind: MATCH_TARGET_VIRTUAL_VERTEX,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MaterializationError {
    TooManyDefects,
    DefectsNotStrictlyIncreasing,
    InvalidDefectVertex,
    TooManyMatchingEndpoints,
    InvalidMatchingNode,
    InvalidMatchingTarget,
    MatchingDoesNotCoverDefects,
    GraphInvariant,
    DistanceOverflow,
    TargetUnreachable,
    InvalidPredecessorChain,
    OutputCapacity,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Materialization {
    pub edge_count: usize,
    pub total_weight: u32,
}

#[repr(C)]
pub struct MaterializerWorkspace {
    distance: [u16; graph::VERTEX_COUNT],
    predecessor_vertex: [u16; graph::VERTEX_COUNT],
    predecessor_edge: [u16; graph::VERTEX_COUNT],
    settled_bitmap: [u8; graph::VIRTUAL_BITMAP_BYTES],
    correction_bitmap: [u8; (graph::EDGE_COUNT + 7) / 8],
}

impl MaterializerWorkspace {
    pub const fn new() -> Self {
        Self {
            distance: [0; graph::VERTEX_COUNT],
            predecessor_vertex: [0; graph::VERTEX_COUNT],
            predecessor_edge: [0; graph::VERTEX_COUNT],
            settled_bitmap: [0; graph::VIRTUAL_BITMAP_BYTES],
            correction_bitmap: [0; (graph::EDGE_COUNT + 7) / 8],
        }
    }

    /// Initializes the integer-only workspace directly at `destination`.
    ///
    /// # Safety
    ///
    /// `destination` must be aligned, writable, and valid for one `Self`.
    /// It must not point to a live value.
    pub unsafe fn initialize_in_place(destination: *mut Self) {
        unsafe {
            ptr::write_bytes(destination, 0, 1);
        }
    }

    fn clear_shortest_path_state(&mut self, source: usize) {
        let mut vertex = 0;
        while vertex < graph::VERTEX_COUNT {
            self.distance[vertex] = NONE;
            self.predecessor_vertex[vertex] = NONE;
            self.predecessor_edge[vertex] = NONE;
            vertex += 1;
        }
        for byte in &mut self.settled_bitmap {
            *byte = 0;
        }
        self.distance[source] = 0;
    }

    fn clear_correction(&mut self) {
        for byte in &mut self.correction_bitmap {
            *byte = 0;
        }
    }

    fn is_settled(&self, vertex: usize) -> bool {
        self.settled_bitmap[vertex / 8] & (1u8 << (vertex % 8)) != 0
    }

    fn settle(&mut self, vertex: usize) {
        self.settled_bitmap[vertex / 8] |= 1u8 << (vertex % 8);
    }

    fn toggle_correction_edge(&mut self, edge: usize) {
        self.correction_bitmap[edge / 8] ^= 1u8 << (edge % 8);
    }

    fn correction_contains(&self, edge: usize) -> bool {
        self.correction_bitmap[edge / 8] & (1u8 << (edge % 8)) != 0
    }

    fn shortest_path_xor(&mut self, source: u16, target: u16) -> Result<(), MaterializationError> {
        let source = source as usize;
        let target = target as usize;
        if source >= graph::VERTEX_COUNT || target >= graph::VERTEX_COUNT || source == target {
            return Err(MaterializationError::InvalidMatchingTarget);
        }
        self.clear_shortest_path_state(source);

        let mut iteration = 0;
        while iteration < graph::VERTEX_COUNT {
            let mut selected = NONE;
            let mut vertex = 0;
            while vertex < graph::VERTEX_COUNT {
                if !self.is_settled(vertex) && self.distance[vertex] != NONE {
                    let current = selected as usize;
                    if selected == NONE
                        || self.distance[vertex] < self.distance[current]
                        || (self.distance[vertex] == self.distance[current] && vertex < current)
                    {
                        selected = vertex as u16;
                    }
                }
                vertex += 1;
            }
            if selected == NONE {
                break;
            }

            let vertex = selected as usize;
            self.settle(vertex);
            let start = *graph::CSR_ROW_OFFSETS
                .get(vertex)
                .ok_or(MaterializationError::GraphInvariant)? as usize;
            let end = *graph::CSR_ROW_OFFSETS
                .get(vertex + 1)
                .ok_or(MaterializationError::GraphInvariant)? as usize;
            if start > end || end > graph::ARC_COUNT {
                return Err(MaterializationError::GraphInvariant);
            }
            for &edge_index in &graph::CSR_EDGE_INDICES[start..end] {
                let edge = graph::WEIGHTED_EDGES
                    .get(edge_index as usize)
                    .copied()
                    .ok_or(MaterializationError::GraphInvariant)?;
                let neighbor = edge
                    .neighbor(selected)
                    .ok_or(MaterializationError::GraphInvariant)?
                    as usize;
                if neighbor >= graph::VERTEX_COUNT || self.is_settled(neighbor) {
                    continue;
                }
                let candidate = self.distance[vertex]
                    .checked_add(edge.weight() as u16)
                    .ok_or(MaterializationError::DistanceOverflow)?;
                if candidate == NONE || candidate > graph::SIMPLE_PATH_DISTANCE_UPPER_BOUND {
                    return Err(MaterializationError::DistanceOverflow);
                }
                let existing = self.distance[neighbor];
                let tie_is_better = candidate == existing
                    && (edge_index < self.predecessor_edge[neighbor]
                        || (edge_index == self.predecessor_edge[neighbor]
                            && selected < self.predecessor_vertex[neighbor]));
                if candidate < existing || tie_is_better {
                    self.distance[neighbor] = candidate;
                    self.predecessor_vertex[neighbor] = selected;
                    self.predecessor_edge[neighbor] = edge_index;
                }
            }
            iteration += 1;
        }

        if self.distance[target] == NONE {
            return Err(MaterializationError::TargetUnreachable);
        }
        let mut current = target;
        let mut path_edges = 0;
        while current != source {
            if path_edges >= graph::VERTEX_COUNT {
                return Err(MaterializationError::InvalidPredecessorChain);
            }
            let predecessor = self.predecessor_vertex[current];
            let edge_index = self.predecessor_edge[current];
            if predecessor == NONE || edge_index == NONE {
                return Err(MaterializationError::InvalidPredecessorChain);
            }
            let edge = graph::WEIGHTED_EDGES
                .get(edge_index as usize)
                .copied()
                .ok_or(MaterializationError::GraphInvariant)?;
            if edge.neighbor(current as u16) != Some(predecessor)
                || self.distance[predecessor as usize] >= self.distance[current]
            {
                return Err(MaterializationError::InvalidPredecessorChain);
            }
            self.toggle_correction_edge(edge_index as usize);
            current = predecessor as usize;
            path_edges += 1;
        }
        Ok(())
    }
}

impl Default for MaterializerWorkspace {
    fn default() -> Self {
        Self::new()
    }
}

fn validate_defects(defects: &[u16]) -> Result<(), MaterializationError> {
    if defects.len() > graph::MAX_DEFECTS || defects.len() > graph::DEFECT_NODE_CAPACITY {
        return Err(MaterializationError::TooManyDefects);
    }
    let mut previous = None;
    for &defect in defects {
        if defect as usize >= graph::VERTEX_COUNT || graph::is_virtual(defect) {
            return Err(MaterializationError::InvalidDefectVertex);
        }
        if previous.is_some_and(|value| value >= defect) {
            return Err(MaterializationError::DefectsNotStrictlyIncreasing);
        }
        previous = Some(defect);
    }
    Ok(())
}

fn endpoint_vertices(
    defects: &[u16],
    endpoint: MatchingEndpoint,
) -> Result<(u16, u16), MaterializationError> {
    let source = *defects
        .get(endpoint.source_node as usize)
        .ok_or(MaterializationError::InvalidMatchingNode)?;
    let target = match endpoint.target_kind {
        MATCH_TARGET_PEER_NODE => {
            if endpoint.target == endpoint.source_node {
                return Err(MaterializationError::InvalidMatchingTarget);
            }
            *defects
                .get(endpoint.target as usize)
                .ok_or(MaterializationError::InvalidMatchingNode)?
        }
        MATCH_TARGET_VIRTUAL_VERTEX => {
            if endpoint.target as usize >= graph::VERTEX_COUNT
                || !graph::is_virtual(endpoint.target)
            {
                return Err(MaterializationError::InvalidMatchingTarget);
            }
            endpoint.target
        }
        _ => return Err(MaterializationError::InvalidMatchingTarget),
    };
    Ok((source, target))
}

fn validate_matching(
    defects: &[u16],
    matching: &[MatchingEndpoint],
) -> Result<(), MaterializationError> {
    if matching.len() > defects.len() {
        return Err(MaterializationError::TooManyMatchingEndpoints);
    }
    for &endpoint in matching {
        endpoint_vertices(defects, endpoint)?;
    }

    let mut node = 0;
    while node < defects.len() {
        let mut occurrences = 0usize;
        for endpoint in matching {
            if endpoint.source_node as usize == node {
                occurrences += 1;
            }
            if endpoint.target_kind == MATCH_TARGET_PEER_NODE && endpoint.target as usize == node {
                occurrences += 1;
            }
        }
        if occurrences != 1 {
            return Err(MaterializationError::MatchingDoesNotCoverDefects);
        }
        node += 1;
    }
    Ok(())
}

pub fn materialize_correction(
    workspace: &mut MaterializerWorkspace,
    defects: &[u16],
    matching: &[MatchingEndpoint],
    correction_edges: &mut [u16],
) -> Result<Materialization, MaterializationError> {
    validate_defects(defects)?;
    validate_matching(defects, matching)?;
    workspace.clear_correction();

    for &endpoint in matching {
        let (source, target) = endpoint_vertices(defects, endpoint)?;
        workspace.shortest_path_xor(source, target)?;
    }

    let mut edge_count = 0usize;
    let mut total_weight = 0u32;
    let mut edge_index = 0usize;
    while edge_index < graph::EDGE_COUNT {
        if workspace.correction_contains(edge_index) {
            edge_count += 1;
            total_weight = total_weight
                .checked_add(graph::WEIGHTED_EDGES[edge_index].weight() as u32)
                .ok_or(MaterializationError::DistanceOverflow)?;
        }
        edge_index += 1;
    }
    if edge_count > correction_edges.len() || edge_count > graph::MAX_CORRECTION_EDGES {
        return Err(MaterializationError::OutputCapacity);
    }

    let mut output_index = 0usize;
    edge_index = 0;
    while edge_index < graph::EDGE_COUNT {
        if workspace.correction_contains(edge_index) {
            correction_edges[output_index] = edge_index as u16;
            output_index += 1;
        }
        edge_index += 1;
    }
    Ok(Materialization {
        edge_count,
        total_weight,
    })
}

const _: [(); 6] = [(); core::mem::size_of::<MatchingEndpoint>()];
const _: [(); 2] = [(); core::mem::align_of::<MatchingEndpoint>()];
const _: [(); (graph::MATERIALIZER_FIXED_ARRAY_BYTES + 1) & !1] =
    [(); core::mem::size_of::<MaterializerWorkspace>()];
const _: () = assert!(
    core::mem::size_of::<MaterializerWorkspace>() <= graph::MATERIALIZER_PROJECTED_WORKSPACE_BYTES
);
const _: () = assert!(core::mem::align_of::<MaterializerWorkspace>() <= 8);

#[cfg(test)]
mod tests {
    use super::*;

    struct CorpusCase {
        name: &'static str,
        defects: &'static [u16],
        matching: &'static [MatchingEndpoint],
        solver_serial_minimum_weight: u32,
    }

    const D3_CASES: &[CorpusCase] = &[
        CorpusCase {
            name: "empty",
            defects: &[],
            matching: &[],
            solver_serial_minimum_weight: 0,
        },
        CorpusCase {
            name: "singleton-smoke-v0",
            defects: &[0],
            matching: &[MatchingEndpoint::virtual_vertex(0, 1)],
            solver_serial_minimum_weight: 12,
        },
        CorpusCase {
            name: "singleton-non-smoke-v18",
            defects: &[18],
            matching: &[MatchingEndpoint::virtual_vertex(0, 12)],
            solver_serial_minimum_weight: 12,
        },
        CorpusCase {
            name: "direct-pair-edge-1",
            defects: &[0, 3],
            matching: &[MatchingEndpoint::peer(0, 1)],
            solver_serial_minimum_weight: 14,
        },
        CorpusCase {
            name: "four-defect-spread",
            defects: &[0, 7, 14, 18],
            matching: &[
                MatchingEndpoint::peer(1, 2),
                MatchingEndpoint::virtual_vertex(0, 1),
                MatchingEndpoint::virtual_vertex(3, 12),
            ],
            solver_serial_minimum_weight: 36,
        },
        CorpusCase {
            name: "blossom-producing-lexicographic-first",
            defects: &[0, 3, 4, 13],
            matching: &[
                MatchingEndpoint::peer(0, 1),
                MatchingEndpoint::peer(2, 3),
            ],
            solver_serial_minimum_weight: 28,
        },
        CorpusCase {
            name: "tie-exercising-alternate-policy-differs",
            defects: &[3, 6],
            matching: &[MatchingEndpoint::peer(0, 1)],
            solver_serial_minimum_weight: 26,
        },
    ];

    const D9_CASES: &[CorpusCase] = &[
        CorpusCase {
            name: "empty",
            defects: &[],
            matching: &[],
            solver_serial_minimum_weight: 0,
        },
        CorpusCase {
            name: "singleton-smoke-v0",
            defects: &[0],
            matching: &[MatchingEndpoint::virtual_vertex(0, 1)],
            solver_serial_minimum_weight: 12,
        },
        CorpusCase {
            name: "singleton-non-smoke-v432",
            defects: &[432],
            matching: &[MatchingEndpoint::virtual_vertex(0, 390)],
            solver_serial_minimum_weight: 12,
        },
        CorpusCase {
            name: "direct-pair-edge-1",
            defects: &[0, 3],
            matching: &[MatchingEndpoint::peer(0, 1)],
            solver_serial_minimum_weight: 14,
        },
        CorpusCase {
            name: "four-defect-spread",
            defects: &[0, 147, 294, 432],
            matching: &[
                MatchingEndpoint::virtual_vertex(0, 1),
                MatchingEndpoint::virtual_vertex(1, 148),
                MatchingEndpoint::virtual_vertex(2, 295),
                MatchingEndpoint::virtual_vertex(3, 390),
            ],
            solver_serial_minimum_weight: 48,
        },
        CorpusCase {
            name: "tie-exercising-two-defect-peer",
            defects: &[0, 6],
            matching: &[MatchingEndpoint::peer(0, 1)],
            solver_serial_minimum_weight: 52,
        },
    ];

    fn corpus() -> &'static [CorpusCase] {
        match (graph::VERTEX_COUNT, graph::EDGE_COUNT) {
            (19, 39) => D3_CASES,
            (433, 1737) => D9_CASES,
            _ => panic!("the correction corpus is defined only for frozen circuit d3/d9"),
        }
    }

    fn assert_reconstructed_syndrome(defects: &[u16], edges: &[u16]) {
        let mut syndrome = [0u8; graph::VIRTUAL_BITMAP_BYTES];
        for &edge_index in edges {
            let edge = graph::WEIGHTED_EDGES[edge_index as usize];
            for vertex in [edge.left(), edge.right()] {
                if !graph::is_virtual(vertex) {
                    syndrome[vertex as usize / 8] ^= 1u8 << (vertex as usize % 8);
                }
            }
        }
        let mut expected_offset = 0usize;
        for vertex in 0..graph::VERTEX_COUNT {
            let actual = syndrome[vertex / 8] & (1u8 << (vertex % 8)) != 0;
            let expected = expected_offset < defects.len()
                && defects[expected_offset] as usize == vertex;
            assert_eq!(actual, expected, "syndrome mismatch at vertex {vertex}");
            if expected {
                expected_offset += 1;
            }
        }
        assert_eq!(expected_offset, defects.len());
    }

    #[test]
    fn generated_graph_has_compact_deterministic_csr() {
        let expected = match (graph::VERTEX_COUNT, graph::EDGE_COUNT) {
            (19, 39) => (6, 64, 394, 160),
            (433, 1737) => (10, 1024, 16_556, 2_904),
            _ => panic!("unexpected graph"),
        };
        assert_eq!(graph::VERTEX_BITS, expected.0);
        assert_eq!(graph::NODE_CAPACITY, expected.1);
        assert_eq!(graph::GRAPH_RODATA_BYTES, expected.2);
        assert_eq!(graph::MATERIALIZER_PROJECTED_WORKSPACE_BYTES, expected.3);
        assert_eq!(graph::ARC_COUNT, graph::EDGE_COUNT * 2);
        assert_eq!(graph::CSR_ROW_OFFSETS[0], 0);
        assert_eq!(
            graph::CSR_ROW_OFFSETS[graph::VERTEX_COUNT] as usize,
            graph::ARC_COUNT
        );
        for vertex in 0..graph::VERTEX_COUNT {
            let start = graph::CSR_ROW_OFFSETS[vertex] as usize;
            let end = graph::CSR_ROW_OFFSETS[vertex + 1] as usize;
            let row = &graph::CSR_EDGE_INDICES[start..end];
            assert!(row.windows(2).all(|pair| pair[0] < pair[1]));
            for &edge_index in row {
                assert!(graph::WEIGHTED_EDGES[edge_index as usize]
                    .neighbor(vertex as u16)
                    .is_some());
            }
        }
    }

    #[test]
    fn materializes_frozen_semantic_corpus() {
        let mut workspace = MaterializerWorkspace::new();
        let mut correction = [u16::MAX; graph::MAX_CORRECTION_EDGES];
        for case in corpus() {
            let result = materialize_correction(
                &mut workspace,
                case.defects,
                case.matching,
                &mut correction,
            )
            .unwrap_or_else(|error| panic!("{}: {error:?}", case.name));
            let edges = &correction[..result.edge_count];
            assert!(edges.windows(2).all(|pair| pair[0] < pair[1]));
            assert!(edges
                .iter()
                .all(|&edge| (edge as usize) < graph::EDGE_COUNT));
            assert_reconstructed_syndrome(case.defects, edges);
            assert_eq!(
                result.total_weight, case.solver_serial_minimum_weight,
                "{}: minimum weight differs from SolverSerial",
                case.name
            );
        }
        println!(
            "MICROBLOSSOM_R5_MATERIALIZER_PASS graph={} cases={}",
            graph::GRAPH_ID,
            corpus().len()
        );
    }

    #[test]
    fn rejects_noncanonical_or_incomplete_inputs_without_partial_output() {
        let mut workspace = MaterializerWorkspace::new();
        let mut output = [0x55aau16; 1];
        assert_eq!(
            materialize_correction(
                &mut workspace,
                &[3, 0],
                &[MatchingEndpoint::peer(0, 1)],
                &mut output,
            ),
            Err(MaterializationError::DefectsNotStrictlyIncreasing)
        );
        assert_eq!(output, [0x55aa]);
        assert_eq!(
            materialize_correction(&mut workspace, &[0, 3], &[], &mut output),
            Err(MaterializationError::MatchingDoesNotCoverDefects)
        );
        assert_eq!(output, [0x55aa]);
        assert_eq!(
            materialize_correction(
                &mut workspace,
                &[0, 3],
                &[MatchingEndpoint::peer(0, 1)],
                &mut [],
            ),
            Err(MaterializationError::OutputCapacity)
        );
    }
}
