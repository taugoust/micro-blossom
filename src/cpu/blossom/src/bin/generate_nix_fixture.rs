//! Generate deterministic graph fixtures for Nix/QShell application packages.

use fusion_blossom::example_codes::{
    CodeCapacityPlanarCode, CodeCapacityRepetitionCode, CodeCapacityRotatedCode, ExampleCode, PhenomenologicalRotatedCode,
};
use micro_blossom::example_codes::QECPlaygroundCode;
use micro_blossom::resources::MicroBlossomSingle;
use serde_json::json;
use std::path::PathBuf;

const PHYSICAL_ERROR_RATE: f64 = 0.1;
const MAX_HALF_WEIGHT: isize = 1;

fn write_graph(output: PathBuf, code: impl ExampleCode) {
    let graph = MicroBlossomSingle::new_code(&code);
    let encoded = serde_json::to_vec(&graph).expect("serialize graph fixture");

    if let Some(parent) = output.parent() {
        std::fs::create_dir_all(parent).expect("create graph output directory");
    }
    std::fs::write(output, encoded).expect("write graph fixture");
}

fn usage() -> ! {
    eprintln!("usage: generate_nix_fixture OUTPUT.json FAMILY DISTANCE");
    std::process::exit(2);
}

fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 3 {
        usage();
    }

    let output = PathBuf::from(&args[0]);
    let variant = args[1].to_str().unwrap_or_else(|| usage());
    let distance: usize = args[2]
        .to_str()
        .and_then(|value| value.parse().ok())
        .filter(|value| *value >= 3 && value % 2 == 1)
        .unwrap_or_else(|| usage());

    match variant {
        "repetition" => write_graph(
            output,
            CodeCapacityRepetitionCode::new(distance, PHYSICAL_ERROR_RATE, MAX_HALF_WEIGHT),
        ),
        "planar" => write_graph(
            output,
            CodeCapacityPlanarCode::new(distance, PHYSICAL_ERROR_RATE, MAX_HALF_WEIGHT),
        ),
        "rotated" => write_graph(
            output,
            CodeCapacityRotatedCode::new(distance, PHYSICAL_ERROR_RATE, MAX_HALF_WEIGHT),
        ),
        "phenomenological" => write_graph(
            output,
            PhenomenologicalRotatedCode::new(distance, distance, PHYSICAL_ERROR_RATE, MAX_HALF_WEIGHT),
        ),
        "circuit" => {
            let config = json!({
                "code_type": qecp::code_builder::CodeType::RotatedPlanarCode,
                "qubit_type": qecp::types::QubitType::StabZ,
                "max_half_weight": 7,
                "parallel_init": num_cpus::get().saturating_sub(1).max(1),
                "nm": distance - 1,
            });
            write_graph(output, QECPlaygroundCode::new(distance, 0.001, config));
        }
        _ => usage(),
    }
}
