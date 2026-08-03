use clap::Parser;
use fusion_blossom::example_codes::{CodeCapacityRepetitionCode, ExampleCode};
use fusion_blossom::mwpm_solver::{PrimalDualSolver, SolverSerial};
use fusion_blossom::primal_module::SubGraphBuilder;
use micro_blossom::dual_module_qshell::SolverEmbeddedQshellCoyote;
use micro_blossom::resources::MicroBlossomSingle;
use serde_json::json;
use std::path::PathBuf;

const GRAPH_SHA256: &str = "4b078d3b6c6db24ea9726414569a97b3899be4e532be1c0ebd84b5fa875316c5";

#[derive(Debug, Parser)]
#[command(about = "Run the canonical d3 workload through a QShell Coyote beat bridge")]
struct Args {
    #[arg(long)]
    bridge: PathBuf,
    #[arg(long, default_value_t = 0)]
    vfpga: i32,
    #[arg(long, default_value_t = 10_000)]
    timeout_ms: u64,
    #[arg(long, default_value_t = 0)]
    context_id: u32,
    #[arg(long, default_value_t = 0)]
    initial_round_id: u32,
    #[arg(long, default_value_t = 0x4d42_0001)]
    source_endpoint_id: u32,
    #[arg(long, default_value_t = 0x4d42_0001)]
    route_capability_id: u32,
}

fn main() {
    let args = Args::parse();
    let mut code = CodeCapacityRepetitionCode::new(3, 0.1, 1);
    let initializer = code.get_initializer();
    let positions = code.get_positions();
    let defect_vertices = vec![0];
    code.set_defect_vertices(&defect_vertices);
    let syndrome = code.get_syndrome();

    let graph = MicroBlossomSingle::new(&initializer, &positions);
    let mut solver = SolverEmbeddedQshellCoyote::new(
        graph,
        json!({
            "dual": {
                "bridge_executable": args.bridge,
                "graph_sha256": GRAPH_SHA256,
                "request_id": 0x4d423031_u32,
                "context_id": args.context_id,
                "initial_round_id": args.initial_round_id,
                "source_endpoint_id": args.source_endpoint_id,
                "route_capability_id": args.route_capability_id,
                "expected_decoder_endpoint_id": null,
                "vfpga_id": args.vfpga,
                "timeout_ms": args.timeout_ms
            }
        }),
    );
    solver.solve_visualizer(&syndrome, None);
    let correction = solver.subgraph_visualizer(None);

    assert_eq!(correction, vec![2]);
    assert_eq!(initializer.syndrome_of(&correction), defect_vertices.into_iter().collect());

    let mut reference = SolverSerial::new(&initializer);
    reference.solve_visualizer(&syndrome, None);
    let reference_correction = reference.subgraph_visualizer(None);

    let mut subgraph_builder = SubGraphBuilder::new(&initializer);
    subgraph_builder.load_subgraph(&correction);
    let correction_weight = subgraph_builder.total_weight();
    subgraph_builder.load_subgraph(&reference_correction);
    assert_eq!(correction_weight, subgraph_builder.total_weight());

    let driver = &mut solver.dual_module.driver.driver;
    let operations = driver.operations();
    assert_eq!(driver.finish_job().unwrap(), operations);
    assert_eq!(operations, 14);

    println!(
        "MICROBLOSSOM_D3_QSHELL_COYOTE_PASS defects=[0] correction_edges={correction:?} total_weight={correction_weight} operations={operations}"
    );
}
