use microblossom_qshell_protocol::{
    CoprocessorGraphContract, CoprocessorQshellLink, CoyoteProcessBeatLink, DecodeRequest, GraphId,
    QshellRoute,
};

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

fn graph_id(value: &str) -> GraphId {
    assert_eq!(value.len(), 64, "graph identity must contain 64 hex digits");
    let mut result = [0_u8; 32];
    for (index, byte) in result.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&value[2 * index..2 * index + 2], 16)
            .expect("graph identity must be lowercase hexadecimal");
    }
    assert_eq!(
        value,
        value.to_ascii_lowercase(),
        "graph identity must be lowercase"
    );
    result
}

fn u16_list(value: &str, name: &str) -> Vec<u16> {
    if value.is_empty() {
        return Vec::new();
    }
    value
        .split(',')
        .map(|item| {
            item.parse()
                .unwrap_or_else(|_| panic!("{name} must be a comma-separated u16 list"))
        })
        .collect()
}

fn usage(program: &str) {
    println!(
        "usage: {program} --bridge PATH --graph-id SHA256 --vertices N --edges N \\\n         --virtual-vertices V0,V1,... [--defects V0,V1,...] [route options]"
    );
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|argument| argument == "--help") {
        usage(&args[0]);
        return;
    }

    let bridge = value(&args, "--bridge", None);
    let vfpga = number(&args, "--vfpga", 0) as i32;
    let timeout_ms = number(&args, "--timeout-ms", 5000) as u64;
    let decoder_endpoint = number(&args, "--decoder-endpoint", 1);
    let route_version = number(&args, "--route-version", 1);
    assert_ne!(route_version, 0, "expected route version must be nonzero");
    let virtual_vertices = u16_list(
        &value(&args, "--virtual-vertices", None),
        "virtual vertices",
    );
    let contract = CoprocessorGraphContract::new(
        graph_id(&value(&args, "--graph-id", None)),
        number(&args, "--vertices", 0)
            .try_into()
            .expect("vertex count does not fit u16"),
        number(&args, "--edges", 0)
            .try_into()
            .expect("edge count does not fit u16"),
        &virtual_vertices,
    )
    .expect("invalid graph contract");
    let request = DecodeRequest {
        graph_id: contract.graph_id(),
        defects: u16_list(&value(&args, "--defects", Some("0")), "defects"),
    };
    let beats = CoyoteProcessBeatLink::spawn_with_response_bytes(
        bridge,
        vfpga,
        timeout_ms,
        contract.response_packet_bytes(),
    )
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
        contract,
        route_version,
    );
    let result = link.decode(&request).expect("co-processor decode failed");
    assert_eq!(
        result.graph_id,
        link.contract().graph_id(),
        "firmware graph identity mismatch"
    );
    assert_eq!(result.status, 0, "firmware returned decode failure");
    println!(
        "MICROBLOSSOM_COPROCESSOR_PASS graph={} defects={:?} correction_edges={:?} operations={} request_beats={} response_beats={}",
        value(&args, "--graph-id", None),
        request.defects,
        result.correction_edges,
        result.accelerator_operations,
        link.contract().request_beats(),
        link.contract().response_beats(),
    );
}
