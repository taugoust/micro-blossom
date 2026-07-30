use fusion_blossom::example_codes::{CodeCapacityRepetitionCode, ExampleCode};
use fusion_blossom::mwpm_solver::{PrimalDualSolver, SolverSerial};
use fusion_blossom::primal_module::SubGraphBuilder;
use micro_blossom::mwpm_solver::SolverEmbeddedAxi4;
use micro_blossom::resources::MicroBlossomSingle;
use serde_json::json;

#[test]
fn nix_d3_golden_correction() {
    let mut code = CodeCapacityRepetitionCode::new(3, 0.1, 1);
    let initializer = code.get_initializer();
    let positions = code.get_positions();
    let defect_vertices = vec![0];
    code.set_defect_vertices(&defect_vertices);
    let syndrome = code.get_syndrome();

    let graph = MicroBlossomSingle::new(&initializer, &positions);
    let mut solver = SolverEmbeddedAxi4::new(
        graph,
        json!({
            "dual": {
                "name": "nix_d3_golden_correction",
                "sim_config": {
                    "with_waveform": false,
                    "dump_debugger_files": false,
                    "bus_type": "Axi4",
                    "use_64_bus": true,
                    "context_depth": 1,
                    "broadcast_delay": 0,
                    "convergecast_delay": 1,
                    "conflict_channels": 1,
                    "hard_code_weights": true,
                    "support_add_defect_vertex": true,
                    "support_offloading": false,
                    "support_layer_fusion": false,
                    "support_load_stall_emulator": false,
                    "inject_registers": [],
                    "clock_divide_by": 2.0
                }
            }
        }),
    );
    solver.solve_visualizer(&syndrome, None);
    let correction = solver.subgraph_visualizer(None);

    let expected_correction = vec![2];
    assert_eq!(correction, expected_correction);
    assert_eq!(initializer.syndrome_of(&correction), defect_vertices.into_iter().collect());

    let mut reference = SolverSerial::new(&initializer);
    reference.solve_visualizer(&syndrome, None);
    let reference_correction = reference.subgraph_visualizer(None);

    let mut subgraph_builder = SubGraphBuilder::new(&initializer);
    subgraph_builder.load_subgraph(&correction);
    let correction_weight = subgraph_builder.total_weight();
    subgraph_builder.load_subgraph(&reference_correction);
    let reference_weight = subgraph_builder.total_weight();
    assert_eq!(correction_weight, reference_weight);

    println!("NIX_D3_GOLDEN defects=[0] correction_edges={correction:?} total_weight={correction_weight}");
}
