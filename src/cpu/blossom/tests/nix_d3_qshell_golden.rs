use fusion_blossom::example_codes::{CodeCapacityRepetitionCode, ExampleCode};
use fusion_blossom::mwpm_solver::{PrimalDualSolver, SolverSerial};
use fusion_blossom::primal_module::SubGraphBuilder;
use micro_blossom::dual_module_qshell::SolverEmbeddedQshell;
use micro_blossom::resources::MicroBlossomSingle;
use microblossom_qshell_protocol::Opcode;
use serde_json::json;

const GRAPH_SHA256: &str = "4b078d3b6c6db24ea9726414569a97b3899be4e532be1c0ebd84b5fa875316c5";

#[test]
fn nix_d3_qshell_transport_correction() {
    let mut code = CodeCapacityRepetitionCode::new(3, 0.1, 1);
    let initializer = code.get_initializer();
    let positions = code.get_positions();
    let defect_vertices = vec![0];
    code.set_defect_vertices(&defect_vertices);
    let syndrome = code.get_syndrome();

    let graph = MicroBlossomSingle::new(&initializer, &positions);
    let mut solver = SolverEmbeddedQshell::new(
        graph,
        json!({
            "dual": {
                "name": "nix_d3_qshell_transport_correction",
                "graph_sha256": GRAPH_SHA256,
                "request_id": 0x4d423031,
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

    let driver = &mut solver.dual_module.driver.driver;
    let operations = driver.transport.operations();
    let sent_records = driver.transport.link().sent_records();
    assert_eq!(sent_records.first().unwrap().opcode, Opcode::BeginJob);
    assert!(sent_records
        .iter()
        .skip(1)
        .all(|record| matches!(record.opcode, Opcode::MmioWrite | Opcode::MmioRead)));
    assert_eq!(sent_records.len() as u64, operations + 1);
    assert_eq!(driver.finish_job().unwrap(), operations);
    assert_eq!(driver.transport.link().sent_records().last().unwrap().opcode, Opcode::EndJob);

    println!(
        "NIX_D3_QSHELL_GOLDEN defects=[0] correction_edges={correction:?} total_weight={correction_weight} operations={operations}"
    );
}
