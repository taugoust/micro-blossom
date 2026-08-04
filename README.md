# Micro Blossom

A highly configurable hardware-accelerated Minimum-Weight Perfect Matching (MWPM) decoder for Quantum Error Correction (QEC).

Paper coming soon!!! Stay tuned!!!

Micro Blossom is a heterogeneous architecture that solves **exact** MWPM decoding problem in sub-microsecond latency by
taking advantage of vertex and edge-level fine-grained hardware acceleration.
At the heart of Micro Blossom is an algorithm (equivalent to the original blossom algorithm) specifically optimized for resource-efficient RTL (register transfer level) implementation, with compact combinational logic and pipeline design.
Given an arbitrary decoding graph, Micro Blossom automatically generates a hardware implementation (either Verilog or VHDL depending on your needs).
The architecture of Micro Blossom is shown below:

![](./tutorial/src/img/architecture.png)

## Benchmark Highlights

**Correctness**: Like Fusion Blossom, we have not only mathematically proven the optimality of the MWPM it generates, but also done massive correctness tests in cycle-accurate Verilog simulators under various conditions.

**14x latency reduction**: On a surface code of code distance $d=9$ and physical error rate of $p=0.001$ circuit-level noise model, we reduce the average
latency from $5.1 \mu s$ using Parity Blossom on CPU (Apple M1 Max) to $367 ns$ using Micro Blossom on FPGA (VMK180), a 14x reduction in **latency**.
Although [Sparse Blossom (PyMatching V2)](https://github.com/oscarhiggott/PyMatching) is generally faster than Parity Blossom, it still incurs $3.2 \mu s$ latency considering the $2.4 \mu s$ average CPU runtime (even with batch mode) and at least $0.8 \mu s$ CPU-hardware communication latency (PCIe round-trip-time) when using powerful CPUs (would be even higher when using Apple chips with thunderbolt). In practice, the CPU-hardware communication will incur even higher latency due to at least two transactions of CPU read (syndrome) and CPU write (correction).

**Better effective error rate** than both Helios (hardware UF decoder, which runs faster but loses accuracy) and Parity Blossom (running on M1 Max) on various code distances $d$ and physical error rates $p$. It is only at very large code distances ($d \ge 13$) and physical error rates ($p \ge 0.005$) that Helios starts to outperform Micro Blossom. The higher complexity at high $d$ and $p$ is inherent to the optimality of the blossom algorithm though. As a side note, when trading accuracy for decoding speed, one could modify the software to seamlessly tune between UF and MWPM (see the [`max_tree_size` feature](https://github.com/yuewuo/fusion-blossom/issues/31) in the Fusion Blossom library) because [UF and MWPM decoders share the same mathematical foundation](https://arxiv.org/abs/2211.03288).

**Better worst-case time complexity and thus smaller tail in latency distribution**: We observe an exponential tail of the latency distribution for Micro Blossom. The software implementation has similar behavior but it has a much longer tail in the distribution. Micro Blossom has a better latency distribution for two reasons. First, Micro Blossom has a better worst-case time complexity of $O(|V|^3)$ than Sparse Blossom's $O(|V|^4)$. (We also propose a design that further reduces latency to $O(|V|^2 \log |V|)$ when using more complicated/costly, but still viable, software and hardware designs.) Second, the memory footprint of Micro Blossom is much smaller than both Sparse Blossom and Parity Blossom due to the fact that the decoding graph is not stored in the CPU at all. The CPU only has an active memory region that scales with $O(p^2 |V|)$ (Yes!!! not $O(p|V|)$ which is the average number of defect vertices, but rather $O(p^2 |V|)$ because most of the defects are not even reported to the CPU and solely handled by the accelerator).

Note that an improvement of latency is generally harder than an improvement of throughput because the latter can be achieved by
increasing the number of cores using coarse-grained parallelism (see our [Fusion Blossom paper](https://arxiv.org/abs/2305.08307)) but the latency is bounded by how much the algorithm is sequential at its core. Given the complexity and sequential nature of the blossom
algorithm, it was even believed in the community that hardware acceleration of exact MWPM decoding is impractical. Yet we re-design the algorithm
to exploit the finest parallelism possible (vertex and edge parallelism) and achieve a significant reduction in latency.
Note that this doesn't mean we are sacrificing the decoding throughput: in fact, thanks to the pipeline design, the hardware accelerator
has a large decoding throughput capability that supports real-time decoding of at most 110 logical qubits ($d=9, p=0.001$) while achieving the throughput requirement of 1 million measurement
rounds per second.
While Micro Blossom does use more resources (152k LUT, 4-bit weighted circuit-level noise) than [Helios](https://github.com/NamiLiy/Helios_scalable_QEC) (94k LUT, unweighted circuit-level noise),
the resource usage per logical qubit is 1.4k LUT, lower than the 2.1k LUT per logical qubit for Helios.
This is due to the more efficient CPU-hardware collaboration of Micro Blossom where the hardware focuses on massive yet simple parallel computation while the
CPU focuses on complicated yet rare computation.
Note that Micro Blossom does require an additional CPU which is overall more expensive than Helios using pure FPGA, which is kind of expected due to the higher complexity of the blossom algorithm.

![](./tutorial/src/img/benchmark.png)

For people concerned about why we evaluate the average latency rather than worst-case latency: we believe only the average case matters for several reasons below. Note that when we evaluate the decoding latency distribution, we accumulate 1000 logical errors (2.5e8 samples in total) to make sure we capture the latencies with probability at or even below the logical error rate $p_L$. This doesn't change the average latency value by much though. For all other cases that only require average latency value, we just run 1e5 samples.

- Adding "idle QEC cycle" support at the lowest control layer is not hard, and is favorable for various reasons beyond QEC decoding: for example, some logical feedforward branches may have longer execution paths and we should just let other idle logical qubits run their idle QEC cycles while waiting for a longer branch to run.
- Mathematically, only average case matters. The ultimate goal is that the overall logical error rate of a quantum circuit (including the added idle time due to decoding latency and feedforward) is low. Let's calculate the overall logical error rate including the latency-induced idle errors: Suppose the latency distribution is $P(L)$, then $\int_0^\infty P(L) dL = 1$ and $\int_0^\infty P(L) L dL = \bar{L}$ (aka average latency). Let's calculate the overall logical error rate. $p_L = \int_0^\infty P(L) p_{L0} (1 + L/d) dL = p_{L0} (1 + \bar{L}/d)$. This argument can be extended to more complicated circuits as well, but the idea is pretty intuitive: logical error rate is also a statistical value that is linearly related to the latency.
- It is difficult to scale up QEC decoding to distributed systems while meeting hard deadline requirements, even though there are existing decoders that achieve hard real-time for simple memory experiments at a very low physical error rate and code distance. We believe that in the long run when scaling up, all QEC decoding systems will face the problem of not being able to achieve a hard $1 \mu s$ deadline, but it doesn't matter that much according to the two points above.

## Project Structure

- src: source code
  - fpga: the FPGA source code, including generator scripts
    - microblossom: Scala code for MicroBlossom module using SpinalHDL library
    - Xilinx: Xilinx project build scripts
  - cpu: the CPU source code
    - blossom: code for development and testing on a host machine
    - blossom-nostd: nostd code that is designed to run in an embedded environment but can also run in OS
    - embedded: build binary for embedded system
- benchmark: evaluation results that can be reproduced using the scripts included (and VMK180 Xilinx evaluation board)
  - behavior: CPU simulation, with exactly the same RTL logic
  - hardware: evaluation of hardware
    - bram_speed: understand the CPU-FPGA communication cost under various clock frequencies
    - decoding_speed: evaluate the decoding latency under various conditions and its distribution on real VMK180 hardware
    - resource_estimate: post-implementation resource usage


## Reproducible Nix baseline

The first QShell migration stage provides a pinned, board-independent Nix baseline before adding U280 and V80 application packages. Current outputs are:

- `microblossom-host`: native Rust primal decoder and deterministic graph tool, built with nightly `2023-11-16`;
- `microblossom-scala`: offline-built Scala/SpinalHDL generator JAR;
- `microblossom-qshell-protocol`: tested MBQ1 codec, QShell ABI-2 beat adapter, and process-backed Coyote beat link;
- `microblossom-qshell-coyote-bridge`: packaged one-sided Coyote bridge for exact stream beat boundaries (`LOCAL_READ` host-to-FPGA, `LOCAL_WRITE` FPGA-to-host);
- `microblossom-d3-qshell-coyote-run`: canonical native Rust d3 workload connected to the physical Coyote driver bridge;
- `coyote-driver-{ultrascale_plus,versal}-<host>`: pinned Coyote kernel modules built for Doctor's declared host kernels;
- `microblossom-d3-graph`: canonical code-capacity repetition d3 graph, configuration, and provenance manifest;
- `microblossom-d3-rtl`: generated 64-bit AXI4 `MicroBlossomBus.v` and graph/generator/RTL hashes;
- `microblossom-d3-qshell-core`: provenance-carrying ABI-2 envelope, MBQ1 frontend, generated d3 accelerator, and application clock composition;
- `qshell-u280-shell`: the exact pinned full QShell U280 shell required before loading the application partial;
- `microblossom-d3-qshell-{u280,v80}-app-synth`: early synthesis stages against the exact pinned QShell shells;
- `microblossom-d3-qshell-{u280,v80}-app`: complete separately routed application/partial-image packages;
- `microblossom-d3-qshell-{u280,v80}-sim`: packaged Coyote/QShell behavioral simulation runtimes;
- `microblossom-d3-qshell-{u280,v80}-xdb-run`: canonical host workload runners for active xdb sessions;
- `microblossom-d3-sim-runner`: native half of the packaged Rust/Scala/Verilator accelerator smoke;
- `microblossom-d3-golden-decode`: a full d3 primal/AXI4-dual decode checked against the serial reference solver;
- `microblossom-d3-qshell-golden-decode`: the same canonical decode through ordered protocol-v1 records and the native QShell MMIO transport;
- `verilator-5_014`: the simulator version validated by the upstream MicroBlossom workflow.

```sh
nix build .#microblossom-host
nix build .#microblossom-scala
nix build .#microblossom-qshell-protocol
nix build .#checks.x86_64-linux.qshell-coyote-bridge
nix run .#microblossom-d3-qshell-coyote-run -- --help
nix build .#microblossom-d3-graph
nix build .#microblossom-d3-rtl
nix build .#checks.x86_64-linux.d3-behavior-smoke
nix build .#checks.x86_64-linux.d3-golden-decode
nix build .#checks.x86_64-linux.qshell-frontend
nix build .#checks.x86_64-linux.qshell-clock
nix build .#checks.x86_64-linux.qshell-envelope
nix build .#checks.x86_64-linux.qshell-rust-abi-generated
nix build .#checks.x86_64-linux.qshell-core
nix build .#checks.x86_64-linux.qshell-application
nix build .#checks.x86_64-linux.d3-qshell-golden-decode
nix build .#checks.x86_64-linux.qshell-u280-xdb-d3
nix build .#microblossom-d3-qshell-u280-app-synth
nix build .#microblossom-d3-qshell-v80-app-synth
nix flake check

# Regenerate the checked Rust ABI constants from the pinned QShell spec.
nix run .#update-qshell-rust-abi

# Format migration-owned Nix and Rust sources through treefmt-nix.
nix fmt -- flake.nix src/cpu/embedded/build.rs \
  src/cpu/blossom/src/bin/generate_nix_d3_fixture.rs
```

Before authorized U280 deployment on `rose`, materialize the pinned driver and exact full QShell shell:

```sh
nix build .#coyote-driver-ultrascale_plus-rose
nix build --out-link qshell-u280-shell .#qshell-u280-shell
```

Full-device programming and application partial reconfiguration are deliberately separate. `deploy-hw` accepts only a full `.bit`/`.pdi`; it must never receive `vfpga_c0_0.bin`. Program the full shell and reinsert the driver, then load the MicroBlossom partial through Coyote:

```sh
deploy-hw qshell-u280-shell/bitstreams/cyt_top.bit
reconfigure-app --device 0 --vfpga 0 \
  /path/to/microblossom-u280-app/bitstreams/config_0/vfpga_c0_0.bin
```

A failed `deploy-hw` attempt has already unloaded the driver if it reached step 1; deploying the full shell restores the programmed image and driver before `reconfigure-app`. Once vFPGA 0 is available as `/dev/coyote_fpga_0_v0`, run the physical host path with:

```sh
nix run .#microblossom-d3-qshell-coyote-run -- --vfpga 0 --timeout-ms 10000
```

The accepted result is exactly `MICROBLOSSOM_D3_QSHELL_COYOTE_PASS defects=[0] correction_edges=[2] total_weight=2 operations=14`. This command runs the native Rust primal solver locally, spawns the packaged C++ Coyote bridge, allocates driver-backed huge-page memory, and exchanges two-beat QShell ABI-2/MBQ1 records over Coyote's host streams. The complete path passed on the physical U280 in `rose`: `reconfigure-app` loaded the timing-clean application into vFPGA 0 and the native host runner returned the accepted 14-operation result. Twenty consecutive fresh host processes then completed the same result without reconfiguration, proving process-level cleanup and reuse. Multiple jobs over one persistent Coyote connection and induced fault recovery remain separate.

The canonical fixture is declared in `nix/fixtures/code-capacity-repetition-d3.json`. Its graph hash and dimensions are checked during the build so generator/configuration changes cannot silently alter downstream hardware. The behavior smoke runs the embedded Rust hardware contract against a Scala-generated 64-bit AXI4 accelerator under Verilator 5.014 and preserves its instruction/readout log as the check output. The golden decode uses defect vertex `[0]`, produces correction edge `[2]` with weight `2`, verifies that correction's syndrome, and compares its weight with the serial MWPM reference. The board-independent QShell frontend check validates MBQ1 record framing, lifecycle, AXI translation, backpressure, reset, errors, and timeout quarantine. The clock check verifies the simulation model for an application-local Xilinx `BUFGCE_DIV/2` slow domain with asynchronous reset assertion and synchronized deassertion; the accepted U280 route closes setup, hold, and pulse-width timing. The envelope check consumes generated constants from pinned QShell ABI 2 and verifies two-beat request/response framing, metadata transformation, sequencing, backpressure, and malformed-record recovery. The core check exercises MBQ1 directly against the generated accelerator. The application check combines the envelope, clock, frontend, and accelerator and verifies hardware-info and completion transactions through the complete shell-facing hierarchy. The QShell golden check runs the same d3 primal result through the native `RecordLink` transport against the generated accelerator. The U280 xdb check launches the packaged resident-QShell/MicroBlossom Coyote simulation and runs all 14 operations through the process-backed ABI-2 transport. Its output retains the canonical PASS marker, simulation time, Coyote status, xdb provenance, and a debug bundle as normal Nix check artifacts.

Rust derivations use the locked GitHub release of Crane to vendor dependencies and share one dependency-artifact build across the native host, simulator runner, and golden decode. Fenix still supplies the pinned nightly `2023-11-16` toolchain; Crane does not replace the toolchain pin. The standalone QShell protocol crate has a separate dependency artifact and package contract.

The baseline accelerator does not require a RISC-V CPU. The optional VexRiscv-dependent Blinky demos remain in the repository but are excluded from the generator JAR and its dependency closure. The planned V80 CPU migration targets the card's hard Arm processing system.

## Usage

Micro Blossom consists of two parts: the CPU program in Rust and the FPGA program in Scala.
The FPGA part has a CLI program that generates Verilog/VHDL files given a decoding graph input.
The decoding graph input is defined by a JSON format in `src/fpga/microblossom/utils/SingleGraph.scala`.
A few examples of how to generate and use this decoding graph are below

```sh
# 1. generate example graphs in ./resources/graphs/*.json
cd src/cpu/blossom
cargo run --release --bin generate_example_graphs
cd ..
# (if you want to use the visualization tool to see these graphs, check src/cpu/blossom/bin/generate_example_graphs.rs)

# 2. use one graph to generate a Verilog
# you need to install Java and sbt build tool first, check:
# https://spinalhdl.github.io/SpinalDoc-RTD/master/SpinalHDL/Getting%20Started/Install%20and%20setup.html
mkdir gen
sbt "runMain microblossom.MicroBlossomBusGenerator --graph ./resources/graphs/example_code_capacity_d3.json"
# (for a complete list of supported arguments, sbt "runMain microblossom.MicroBlossomBusGenerator --help"
# this command generates Verilog file at `./gen/MicroBlossomBus.v` with a default AXI4 interface.
```

The generated Verilog can be used either in simulation (see test cases in `src/cpu/blossom/src/dual_module_axi4.rs` and `benchmark/behavior/tests/run.py`) or real hardware evaluation (see test cases in `benchmark/hardware/tests/run.py` which runs the same behavior tests but on real FPGA hardware).

The benchmark scripts automate this process of generating the graphs, Verilog, and the Xilinx project.
For any questions about how to use the project, please [email me](mailto:wuyue16pku@gmail.com).


### Docker

It is recommended to use the docker file to create an environment.

```sh
docker build --tag 'micro-blossom' .
docker run -itd --name 'mb' -v .:/root/micro-blossom 'micro-blossom'
docker exec -it mb bash  # into the bash environment
```
