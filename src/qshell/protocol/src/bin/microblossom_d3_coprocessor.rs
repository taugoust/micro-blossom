use microblossom_qshell_protocol::{
    CoprocessorQshellLink, CoyoteProcessBeatLink, DecodeRequest, QshellRoute,
};

const GRAPH_ID: [u8; 32] = [
    0x4b, 0x07, 0x8d, 0x3b, 0x6c, 0x6d, 0xb2, 0x4e, 0xa9, 0x72, 0x64, 0x14, 0x56, 0x9a, 0x97, 0xb3,
    0x89, 0x9b, 0xe4, 0xe5, 0x32, 0xbe, 0x1c, 0x0e, 0xbd, 0x84, 0xb5, 0xfa, 0x87, 0x53, 0x16, 0xc5,
];

fn value(args: &[String], name: &str, default: Option<&str>) -> String {
    args.windows(2)
        .find(|pair| pair[0] == name)
        .map(|pair| pair[1].clone())
        .or_else(|| default.map(str::to_owned))
        .unwrap_or_else(|| panic!("missing required argument {name}"))
}

fn number(args: &[String], name: &str, default: u32) -> u32 {
    value(args, name, Some(&default.to_string()))
        .parse()
        .unwrap_or_else(|_| panic!("invalid integer for {name}"))
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let bridge = value(&args, "--bridge", None);
    let vfpga = number(&args, "--vfpga", 0) as i32;
    let timeout_ms = number(&args, "--timeout-ms", 5000) as u64;
    let decoder_endpoint = number(&args, "--decoder-endpoint", 1);
    let beats = CoyoteProcessBeatLink::spawn_with_continuation(bridge, vfpga, timeout_ms, 32)
        .expect("failed to start Coyote bridge");
    let mut link = CoprocessorQshellLink::new(
        beats,
        QshellRoute {
            context_id: number(&args, "--context", 1),
            initial_round_id: number(&args, "--round", 1),
            source_endpoint_id: number(&args, "--source-endpoint", 1),
            route_capability_id: number(&args, "--capability", 1),
            expected_decoder_endpoint_id: Some(decoder_endpoint),
        },
    );
    let result = link
        .decode(&DecodeRequest {
            graph_id: GRAPH_ID,
            defects: vec![0],
        })
        .expect("co-processor decode failed");
    assert_eq!(
        result.graph_id, GRAPH_ID,
        "firmware graph identity mismatch"
    );
    assert_eq!(result.status, 0, "firmware returned decode failure");
    assert_eq!(result.correction_edges, vec![2], "unexpected d3 correction");
    println!(
        "MICROBLOSSOM_D3_COPROCESSOR_PASS defects=[0] correction_edges=[2] operations={}",
        result.accelerator_operations
    );
}
