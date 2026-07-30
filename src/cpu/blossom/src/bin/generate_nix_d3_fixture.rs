//! Generate the canonical graph used by the first Nix/QShell integration slice.
//!
//! Keep this binary intentionally narrow: changing its code or parameters must
//! be accompanied by a fixture-manifest schema/version update.

use fusion_blossom::example_codes::CodeCapacityRepetitionCode;
use micro_blossom::resources::MicroBlossomSingle;
use std::path::PathBuf;

const DISTANCE: usize = 3;
const PHYSICAL_ERROR_RATE: f64 = 0.1;
const MAX_HALF_WEIGHT: isize = 1;

fn main() {
    let output = std::env::args_os().nth(1).map(PathBuf::from).unwrap_or_else(|| {
        eprintln!("usage: generate_nix_d3_fixture OUTPUT.json");
        std::process::exit(2);
    });

    if std::env::args_os().nth(2).is_some() {
        eprintln!("usage: generate_nix_d3_fixture OUTPUT.json");
        std::process::exit(2);
    }

    let code = CodeCapacityRepetitionCode::new(DISTANCE, PHYSICAL_ERROR_RATE, MAX_HALF_WEIGHT);
    let graph = MicroBlossomSingle::new_code(&code);
    let encoded = serde_json::to_vec(&graph).expect("serialize canonical d3 graph");

    if let Some(parent) = output.parent() {
        std::fs::create_dir_all(parent).expect("create graph output directory");
    }
    std::fs::write(&output, encoded).expect("write canonical d3 graph");
}
