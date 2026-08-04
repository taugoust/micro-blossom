{
  description = "Reproducible MicroBlossom software, generated RTL, and QShell integration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    crane.url = "github:ipetkov/crane/v0.23.4";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    qshell = {
      url = "git+ssh://git@github.com/TUM-DSE/QShell.git?ref=master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    coyote.follows = "qshell/coyote";
    coyote-nix = {
      url = "github:TUM-DSE/coyote-nix/57ccabd8f6aac883ab916ead842561fcde2d5262";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    doctor-cluster-xilinx.follows = "qshell/doctor-cluster-xilinx";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      crane,
      fenix,
      treefmt-nix,
      qshell,
      coyote,
      ...
    }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      rustManifestSha256 = "sha256-R2zRGLfpNU1h0eHjWkzsSSOQ5brgxA++DAe5i891Lyg=";
      mkVerilator_5_014 =
        pkgs:
        pkgs.verilator.overrideAttrs (_old: rec {
          version = "5.014";
          VERILATOR_SRC_VERSION = "v${version}";
          src = pkgs.fetchFromGitHub {
            owner = "verilator";
            repo = "verilator";
            tag = "v${version}";
            hash = "sha256-cNNVE4JBQGTVNwd6uAjaP0QhsNSbBnZYjD2EAGwxnDw=";
          };
          patches = [ ];
          doCheck = false;
        });
      treefmtEval =
        system:
        treefmt-nix.lib.evalModule (import nixpkgs { inherit system; }) {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true;
          programs.rustfmt = {
            enable = true;
            edition = "2021";
          };
          settings.formatter.nixfmt.includes = [ "*.nix" ];
          settings.formatter.rustfmt.includes = nixpkgs.lib.mkForce [
            "src/cpu/blossom/src/bin/generate_nix_d3_fixture.rs"
            "src/cpu/blossom/src/bin/microblossom_d3_qshell_coyote.rs"
            "src/cpu/blossom/src/dual_module_qshell.rs"
            "src/cpu/blossom/src/util.rs"
            "src/cpu/blossom/tests/nix_d3_golden.rs"
            "src/cpu/blossom/tests/nix_d3_qshell_golden.rs"
            "src/cpu/embedded/build.rs"
            "src/qshell/**/*.rs"
          ];
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = pkgs.lib;
          microblossomSbt = pkgs.sbt.override { jre = pkgs.jdk11; };
          verilator_5_014 = mkVerilator_5_014 pkgs;
          qshellLib = qshell.lib.${system};
          qshellAbiSource = qshellLib.qshellAbiSource;
          qshellContractSource = qshellLib.qshellContractSource;
          qshellHostPackage = qshell.packages.${system}.qshell-host;
          qshellU280Shell = qshell.packages.${system}.qshell-u280-shell;
          coyoteNix = inputs."coyote-nix";
          doctor = inputs."doctor-cluster-xilinx".lib.mkXilinxContext { inherit pkgs system; };
          xilinxShareRoot = doctor.xilinxShareRoot;
          coyoteTools = coyoteNix.lib.mkTools {
            inherit pkgs xilinxShareRoot;
            coyoteRoot = coyote;
            platforms = systems;
          };
          coyoteDriverPackages = coyoteNix.lib.mkCoyoteDriverPackages {
            inherit pkgs;
            coyoteRoot = coyote;
            inherit (doctor) driverKernels targetPlatforms;
          };

          rustToolchain = fenix.packages.${system}.fromToolchainFile {
            file = ./src/cpu/blossom/rust-toolchain.toml;
            sha256 = rustManifestSha256;
          };
          craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;
          # Crane's default dummy uses syntax newer than the pinned 2023 nightly.
          craneDummySource = pkgs.writeText "microblossom-crane-dummy.rs" ''
            fn main() { }
          '';

          rustSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./src/cpu/blossom
              ./src/cpu/blossom-nostd
              ./src/cpu/embedded
              ./src/qshell/protocol
            ];
          };

          protocolSource = lib.fileset.toSource {
            root = ./src/qshell/protocol;
            fileset = craneLib.fileset.commonCargoSources ./src/qshell/protocol;
          };

          scalaSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./build.sbt
              ./project
              ./src/fpga
            ];
          };

          sbtDeps = pkgs.stdenvNoCC.mkDerivation {
            pname = "microblossom-sbt-dependencies";
            version = "1.0";
            src = scalaSource;

            nativeBuildInputs = [
              pkgs.cacert
              pkgs.jdk11
              pkgs.strip-nondeterminism
              microblossomSbt
            ];

            dontConfigure = true;
            buildPhase = ''
              runHook preBuild

              export HOME="$TMPDIR/home"
              export COURSIER_CACHE="$out/coursier"
              export SBT_OPTS="-Dsbt.global.base=$out/global -Dsbt.boot.directory=$out/boot -Dsbt.ivy.home=$out/ivy -Dsbt.coursier.home=$out/coursier"
              mkdir -p "$HOME" "$out/coursier" "$out/global" "$out/boot" "$out/ivy"

              # Compiling once in the fixed-output dependency fetch is required
              # because sbt resolves the Scala compiler bridge sources lazily.
              sbt -batch update Test/update assembly

              find "$out" -type f \( -name '*.lock' -o -name '*.checked' \) -delete
              # sbt generates a Java runtime JAR whose ZIP timestamps otherwise vary.
              find "$out" -type f -name '*.jar' -exec strip-nondeterminism '{}' +
              runHook postBuild
            '';
            installPhase = "true";

            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = "sha256-34duI1MezoN3VCZfnRGm9M9K18qJ5VgwZjkgwuFvzKw=";
          };

          microblossomScala = pkgs.stdenvNoCC.mkDerivation {
            pname = "microblossom-scala";
            version = "1.0-${self.shortRev or "dirty"}";
            src = scalaSource;

            nativeBuildInputs = [
              pkgs.jdk11
              pkgs.strip-nondeterminism
              microblossomSbt
            ];

            dontConfigure = true;
            buildPhase = ''
              runHook preBuild

              export HOME="$TMPDIR/home"
              cache="$TMPDIR/sbt-cache"
              cp -R ${sbtDeps}/. "$cache"
              chmod -R u+w "$cache"
              export COURSIER_CACHE="$cache/coursier"
              export COURSIER_MODE=offline
              export SBT_OPTS="-Dsbt.offline=true -Dsbt.global.base=$cache/global -Dsbt.boot.directory=$cache/boot -Dsbt.ivy.home=$cache/ivy -Dsbt.coursier.home=$cache/coursier"
              mkdir -p "$HOME"

              sbt -batch assembly
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              install -Dm644 target/scala-2.12/microblossom.jar \
                "$out/share/java/microblossom.jar"
              runHook postInstall
            '';

            postFixup = ''
              strip-nondeterminism "$out/share/java/microblossom.jar"
            '';

            meta = {
              description = "MicroBlossom SpinalHDL generator and simulation JAR";
              license = lib.licenses.mit;
              platforms = systems;
            };
          };

          protocolCommonArgs = {
            pname = "microblossom-qshell-protocol";
            version = "0.1.0";
            src = protocolSource;
            cargoLock = ./src/qshell/protocol/Cargo.lock;
            strictDeps = true;
          };

          protocolCargoArtifacts = craneLib.buildDepsOnly (
            protocolCommonArgs
            // {
              doCheck = true;
              dummyrs = craneDummySource;
              dummyBuildrs = craneDummySource;
            }
          );

          microblossomQshellProtocol = craneLib.mkCargoDerivation (
            protocolCommonArgs
            // {
              cargoArtifacts = protocolCargoArtifacts;
              buildPhaseCargoCommand = "cargo test --profile release --locked --no-run";
              doCheck = true;
              checkPhaseCargoCommand = "cargo test --profile release --locked";
              doInstallCargoArtifacts = false;
              installPhaseCommand = ''
                contract="$out/share/microblossom/qshell-protocol"
                mkdir -p "$contract/src"
                cp Cargo.toml Cargo.lock "$contract/"
                cp src/lib.rs src/qshell_abi_generated.rs "$contract/src/"
                cp ${./src/qshell/README.md} "$contract/README.md"
              '';

              meta = {
                description = "64-byte record codec for the host-driven MicroBlossom QShell baseline";
                license = lib.licenses.mit;
                platforms = systems;
              };
            }
          );

          hostCommonArgs = {
            pname = "microblossom-host";
            version = "0.0.0-${self.shortRev or "dirty"}";
            src = rustSource;
            cargoLock = ./src/cpu/blossom/Cargo.lock;
            strictDeps = true;
            postUnpack = ''
              sourceRoot="$sourceRoot/src/cpu/blossom"
            '';
            MICROBLOSSOM_SKIP_CBINDGEN = "1";
          };

          hostCargoArtifacts = craneLib.buildDepsOnly (
            hostCommonArgs
            // {
              version = "0.0.0";
              cargoExtraArgs = "--locked";
              doCheck = true;
              dummyrs = craneDummySource;
              dummyBuildrs = craneDummySource;
            }
          );

          baseHostCargoExtraArgs = "--locked --bin micro_blossom --bin generate_nix_d3_fixture";
          hostCargoExtraArgs = "${baseHostCargoExtraArgs} --bin microblossom_d3_qshell_coyote";
          simulatorCargoExtraArgs = "${baseHostCargoExtraArgs} --bin embedded_simulator";

          microblossomHost = craneLib.buildPackage (
            hostCommonArgs
            // {
              cargoArtifacts = hostCargoArtifacts;
              cargoExtraArgs = hostCargoExtraArgs;
              doCheck = false;
              installPhaseCommand = ''
                install -Dm755 target/release/micro_blossom "$out/bin/micro_blossom"
                install -Dm755 target/release/generate_nix_d3_fixture \
                  "$out/bin/generate_nix_d3_fixture"
                install -Dm755 target/release/microblossom_d3_qshell_coyote \
                  "$out/bin/microblossom_d3_qshell_coyote"
              '';

              meta = {
                description = "Native MicroBlossom primal decoder and deterministic graph tools";
                license = lib.licenses.mit;
                platforms = systems;
                mainProgram = "micro_blossom";
              };
            }
          );

          microblossomD3SimRunner = craneLib.buildPackage (
            hostCommonArgs
            // {
              pname = "microblossom-d3-sim-runner";
              cargoArtifacts = hostCargoArtifacts;
              cargoExtraArgs = simulatorCargoExtraArgs;
              doCheck = false;
              EMBEDDED_BLOSSOM_MAIN = "test_micro_blossom";
              EDGE_0_LEFT = "1";
              EDGE_0_VIRTUAL = "2";
              EDGE_0_WEIGHT = "2";
              installPhaseCommand = ''
                install -Dm755 target/release/micro_blossom "$out/bin/micro_blossom"
                install -Dm755 target/release/generate_nix_d3_fixture \
                  "$out/bin/generate_nix_d3_fixture"
                install -Dm755 target/release/embedded_simulator \
                  "$out/bin/embedded_simulator"
              '';

              meta = {
                description = "Native runner for the canonical d3 MicroBlossom RTL smoke";
                license = lib.licenses.mit;
                platforms = systems;
                mainProgram = "embedded_simulator";
              };
            }
          );

          d3GoldenDecode = craneLib.mkCargoDerivation (
            hostCommonArgs
            // {
              pname = "microblossom-d3-golden-decode";
              cargoArtifacts = hostCargoArtifacts;
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.gnumake
                pkgs.jdk11
                pkgs.stdenv.cc
                verilator_5_014
              ];
              buildPhaseCargoCommand = "cargo test --profile release --locked --test nix_d3_golden --no-run";
              doCheck = true;
              checkPhaseCargoCommand = ''
                export JAVA=${pkgs.jdk11}/bin/java
                export MICROBLOSSOM_SCALA_JAR=${microblossomScala}/share/java/microblossom.jar
                export MICROBLOSSOM_SIM_WORKDIR="$TMPDIR/sim"
                export MICROBLOSSOM_JAVA_HEAP=4G
                mkdir -p "$MICROBLOSSOM_SIM_WORKDIR"

                timeout 600 cargo test --profile release --locked \
                  --test nix_d3_golden -- --nocapture 2>&1 | tee "$TMPDIR/golden.log"
                grep -F 'NIX_D3_GOLDEN defects=[0] correction_edges=[2] total_weight=2' \
                  "$TMPDIR/golden.log" >/dev/null
              '';
              doInstallCargoArtifacts = false;
              installPhaseCommand = ''
                mkdir -p "$out"
                cp "$TMPDIR/golden.log" "$out/golden.log"
                verilator --version > "$out/verilator-version.txt"
              '';
              meta = {
                description = "Golden d3 primal/AXI4-dual decode comparison";
                license = lib.licenses.mit;
                platforms = systems;
              };
            }
          );

          d3QshellGoldenDecode = craneLib.mkCargoDerivation (
            hostCommonArgs
            // {
              pname = "microblossom-d3-qshell-golden-decode";
              cargoArtifacts = hostCargoArtifacts;
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.gnumake
                pkgs.jdk11
                pkgs.stdenv.cc
                verilator_5_014
              ];
              buildPhaseCargoCommand = "cargo test --profile release --locked --test nix_d3_qshell_golden --no-run";
              doCheck = true;
              checkPhaseCargoCommand = ''
                export JAVA=${pkgs.jdk11}/bin/java
                export MICROBLOSSOM_SCALA_JAR=${microblossomScala}/share/java/microblossom.jar
                export MICROBLOSSOM_SIM_WORKDIR="$TMPDIR/sim"
                export MICROBLOSSOM_JAVA_HEAP=4G
                mkdir -p "$MICROBLOSSOM_SIM_WORKDIR"

                timeout 600 cargo test --profile release --locked \
                  --test nix_d3_qshell_golden -- --nocapture 2>&1 | tee "$TMPDIR/golden.log"
                grep -F 'NIX_D3_QSHELL_GOLDEN defects=[0] correction_edges=[2] total_weight=2' \
                  "$TMPDIR/golden.log" >/dev/null
              '';
              doInstallCargoArtifacts = false;
              installPhaseCommand = ''
                mkdir -p "$out"
                cp "$TMPDIR/golden.log" "$out/golden.log"
                verilator --version > "$out/verilator-version.txt"
              '';
              meta = {
                description = "Golden d3 decode through the native QShell record transport";
                license = lib.licenses.mit;
                platforms = systems;
              };
            }
          );

          d3Fixture =
            pkgs.runCommand "microblossom-code-capacity-repetition-d3-v1"
              {
                nativeBuildInputs = [
                  microblossomHost
                  pkgs.coreutils
                  pkgs.jq
                ];
              }
              ''
                mkdir -p "$out/share/microblossom/fixtures/code-capacity-repetition-d3-v1"
                fixture="$out/share/microblossom/fixtures/code-capacity-repetition-d3-v1"

                generate_nix_d3_fixture "$fixture/graph.json"
                cp ${./nix/fixtures/code-capacity-repetition-d3.json} "$fixture/config.json"

                graph_sha256="$(sha256sum "$fixture/graph.json" | cut -d' ' -f1)"
                vertex_num="$(jq -er '.vertex_num' "$fixture/graph.json")"
                edge_num="$(jq -er '.weighted_edges | length' "$fixture/graph.json")"
                virtual_vertex_num="$(jq -er '.virtual_vertices | length' "$fixture/graph.json")"

                test "$graph_sha256" = "$(jq -er '.expectedGraph.sha256' "$fixture/config.json")"
                test "$vertex_num" = "$(jq -er '.expectedGraph.vertexNum' "$fixture/config.json")"
                test "$edge_num" = "$(jq -er '.expectedGraph.edgeNum' "$fixture/config.json")"
                test "$virtual_vertex_num" = "$(jq -er '.expectedGraph.virtualVertexNum' "$fixture/config.json")"

                smoke_left="$(jq -er '.smoke.edge.left' "$fixture/config.json")"
                smoke_virtual="$(jq -er '.smoke.edge.virtual' "$fixture/config.json")"
                smoke_weight="$(jq -er '.smoke.edge.weight' "$fixture/config.json")"
                jq -e \
                  --argjson left "$smoke_left" \
                  --argjson virtual "$smoke_virtual" \
                  --argjson weight "$smoke_weight" \
                  '.weighted_edges | any(.l == $left and .r == $virtual and .w == $weight)' \
                  "$fixture/graph.json" >/dev/null
                jq -e --argjson virtual "$smoke_virtual" \
                  '.virtual_vertices | index($virtual) != null' \
                  "$fixture/graph.json" >/dev/null

                jq -n \
                  --slurpfile config "$fixture/config.json" \
                  --arg graphSha256 "$graph_sha256" \
                  --arg sourceRevision '${self.rev or "dirty"}' \
                  --arg rustToolchain 'nightly-2023-11-16' \
                  --argjson vertexNum "$vertex_num" \
                  --argjson edgeNum "$edge_num" \
                  --argjson virtualVertexNum "$virtual_vertex_num" \
                  '{
                    schemaVersion: 1,
                    fixture: $config[0],
                    generated: {
                      graphFile: "graph.json",
                      graphSha256: $graphSha256,
                      vertexNum: $vertexNum,
                      edgeNum: $edgeNum,
                      virtualVertexNum: $virtualVertexNum
                    },
                    provenance: {
                      microblossomRevision: $sourceRevision,
                      rustToolchain: $rustToolchain
                    }
                  }' > "$fixture/manifest.json"
              '';

          d3Rtl =
            pkgs.runCommand "microblossom-code-capacity-repetition-d3-rtl-v1"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.jdk11
                  pkgs.jq
                ];
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME" "$TMPDIR/generated"
                fixture=${d3Fixture}/share/microblossom/fixtures/code-capacity-repetition-d3-v1

                java -Xmx4G \
                  -cp ${microblossomScala}/share/java/microblossom.jar \
                  microblossom.MicroBlossomBusGenerator \
                  --graph "$fixture/graph.json" \
                  --output-dir "$TMPDIR/generated" \
                  --bus-type Axi4 \
                  --language-hdl verilog \
                  --base-address 0 \
                  --broadcast-delay 0 \
                  --convergecast-delay 1 \
                  --context-depth 1 \
                  --conflict-channels 1 \
                  --clock-divide-by 2

                test -s "$TMPDIR/generated/MicroBlossomBus.v"
                mkdir -p "$out/share/microblossom/rtl/code-capacity-repetition-d3-v1"
                rtl="$out/share/microblossom/rtl/code-capacity-repetition-d3-v1"
                cp -R "$TMPDIR/generated"/. "$rtl/"
                cp "$fixture/manifest.json" "$rtl/graph-manifest.json"

                rtl_sha256="$(sha256sum "$rtl/MicroBlossomBus.v" | cut -d' ' -f1)"
                jar_sha256="$(sha256sum ${microblossomScala}/share/java/microblossom.jar | cut -d' ' -f1)"
                jq -n \
                  --arg rtlSha256 "$rtl_sha256" \
                  --arg generatorJarSha256 "$jar_sha256" \
                  --arg graphSha256 "$(jq -er '.generated.graphSha256' "$fixture/manifest.json")" \
                  '{
                    schemaVersion: 1,
                    fixtureId: "code-capacity-repetition-d3-v1",
                    topModule: "MicroBlossomBus",
                    busType: "Axi4",
                    graphSha256: $graphSha256,
                    rtlSha256: $rtlSha256,
                    generatorJarSha256: $generatorJarSha256
                  }' > "$rtl/rtl-manifest.json"
              '';

          d3QshellCore =
            pkgs.runCommand "microblossom-d3-qshell-core-v1"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.jq
                ];
              }
              ''
                src=${d3Rtl}/share/microblossom/rtl/code-capacity-repetition-d3-v1
                core="$out/share/microblossom/qshell-core/code-capacity-repetition-d3-v1"
                mkdir -p "$core"
                cp "$src/MicroBlossomBus.v" "$core/"
                cp "$src/graph-manifest.json" "$src/rtl-manifest.json" "$core/"
                cp ${./src/qshell/rtl/microblossom_qshell_frontend.sv} \
                  "$core/microblossom_qshell_frontend.sv"
                cp ${./src/qshell/rtl/microblossom_qshell_core.sv} \
                  "$core/microblossom_qshell_core.sv"
                cp ${./src/qshell/rtl/microblossom_qshell_clock_div2.sv} \
                  "$core/microblossom_qshell_clock_div2.sv"
                cp ${./src/qshell/rtl/microblossom_qshell_envelope.sv} \
                  "$core/microblossom_qshell_envelope.sv"
                cp ${./src/qshell/rtl/microblossom_qshell_application.sv} \
                  "$core/microblossom_qshell_application.sv"
                cp ${qshellAbiSource}/src/abi/hdl/qshell_abi_generated.svh \
                  "$core/qshell_abi_generated.svh"
                cp ${./src/qshell/README.md} "$core/protocol.md"

                jq -n \
                  --arg graphSha256 "$(jq -er '.graphSha256' "$src/rtl-manifest.json")" \
                  --arg acceleratorRtlSha256 "$(sha256sum "$core/MicroBlossomBus.v" | cut -d' ' -f1)" \
                  --arg frontendSha256 "$(sha256sum "$core/microblossom_qshell_frontend.sv" | cut -d' ' -f1)" \
                  --arg coreSha256 "$(sha256sum "$core/microblossom_qshell_core.sv" | cut -d' ' -f1)" \
                  --arg clockDividerSha256 "$(sha256sum "$core/microblossom_qshell_clock_div2.sv" | cut -d' ' -f1)" \
                  --arg timingConstraintsSha256 "$(sha256sum ${./src/qshell/app/src/microblossom/microblossom_qshell_timing.xdc} | cut -d' ' -f1)" \
                  --arg envelopeSha256 "$(sha256sum "$core/microblossom_qshell_envelope.sv" | cut -d' ' -f1)" \
                  --arg applicationSha256 "$(sha256sum "$core/microblossom_qshell_application.sv" | cut -d' ' -f1)" \
                  --arg qshellAbiSha256 "$(sha256sum "$core/qshell_abi_generated.svh" | cut -d' ' -f1)" \
                  --arg qshellRevision '${qshell.rev}' \
                  '{
                    schemaVersion: 1,
                    fixtureId: "code-capacity-repetition-d3-v1",
                    topModule: "microblossom_qshell_application",
                    protocol: "MBQ1",
                    protocolVersion: 1,
                    streamDataBits: 512,
                    internalRecordBytes: 64,
                    axiDataBits: 64,
                    axiAddressBits: 23,
                    timeoutCyclesDefault: 1024,
                    acceleratorClockDivideBy: 2,
                    acceleratorClockInput: "slow_clk",
                    acceleratorResetStrategy: "independent-fast-slow",
                    acceleratorCdcPayloadMemory: "dual-clock-block-ram",
                    applicationClockInputMHz: {
                      u280: 250,
                      v80: 333
                    },
                    applicationClockStrategy: "BUFGCE_DIV/2",
                    outerQshellEnvelope: "QShell ABI 2",
                    outerQshellRequestBeats: 2,
                    outerQshellResponseBeats: 2,
                    qshellRevision: $qshellRevision,
                    graphSha256: $graphSha256,
                    acceleratorRtlSha256: $acceleratorRtlSha256,
                    frontendSha256: $frontendSha256,
                    coreSha256: $coreSha256,
                    clockDividerSha256: $clockDividerSha256,
                    timingConstraintsSha256: $timingConstraintsSha256,
                    envelopeSha256: $envelopeSha256,
                    applicationSha256: $applicationSha256,
                    qshellAbiSha256: $qshellAbiSha256
                  }' > "$core/core-manifest.json"
              '';

          d3QshellAppHwSource = pkgs.runCommand "microblossom-d3-qshell-app-hw-source-v1" { } ''
            cp -R ${./src/qshell/app}/. "$out"
            chmod -R u+w "$out"
            app="$out/src/microblossom"
            hdl="$app/hdl"
            core=${d3QshellCore}/share/microblossom/qshell-core/code-capacity-repetition-d3-v1
            mkdir -p "$hdl"
            cp "$core/MicroBlossomBus.v" "$hdl/"
            cp "$core/microblossom_qshell_frontend.sv" "$hdl/"
            cp "$core/microblossom_qshell_core.sv" "$hdl/"
            cp "$core/microblossom_qshell_clock_div2.sv" "$hdl/"
            cp "$core/microblossom_qshell_envelope.sv" "$hdl/"
            cp "$core/microblossom_qshell_application.sv" "$hdl/"
            cp "$core/qshell_abi_generated.svh" "$hdl/"
            cp "$core/core-manifest.json" "$out/"
          '';

          d3QshellSimulationHwSource = pkgs.runCommand "microblossom-d3-qshell-simulation-hw-source-v1" { } ''
            cp -R ${qshellLib.qshellShellHwSource}/. "$out"
            chmod -R u+w "$out"
            rm -rf "$out/src/app/service"
            mkdir -p "$out/src/app/microblossom"
            cp -R ${d3QshellAppHwSource}/src/microblossom/. \
              "$out/src/app/microblossom/"
            vfpga="$out/src/app/microblossom/vfpga_top.svh"
            mv "$vfpga" "$vfpga.body"
            printf '`define MICROBLOSSOM_SIM_CLOCK_DIVIDER\n' > "$vfpga"
            for source in \
              MicroBlossomBus.v \
              microblossom_qshell_frontend.sv \
              microblossom_qshell_core.sv \
              microblossom_qshell_clock_div2.sv \
              microblossom_qshell_envelope.sv \
              microblossom_qshell_application.sv; do
              printf '`include "hdl/%s"\n' "$source" >> "$vfpga"
            done
            cat "$vfpga.body" >> "$vfpga"
            rm "$vfpga.body"
            substituteInPlace "$out/CMakeLists.txt" \
              --replace-fail \
                'VFPGA_C0_0 "src/app/service src/abi"' \
                'VFPGA_C0_0 "src/app/microblossom"'
            cp ${d3QshellAppHwSource}/core-manifest.json "$out/"
          '';

          d3QshellSimulationPackages = coyoteNix.lib.mkCoyoteBoardPackages {
            inherit pkgs xilinxShareRoot;
            tools = coyoteTools;
            coyoteRoot = coyote;
            xilinxShell = doctor.xilinxShell;
            hwSource = d3QshellSimulationHwSource;
            pnamePrefix = "microblossom-d3-qshell-simulation";
            projectName = "qshell-fpga";
            version = "0.1.0";
            boards = lib.mapAttrs (
              board: cfg:
              cfg
              // {
                simPname = "microblossom-d3-qshell-${board}-sim";
                simCmakeFlags = [
                  "-DBUILD_APP:STRING=0"
                  "-DBUILD_STATIC:STRING=0"
                  "-DBUILD_SHELL:STRING=1"
                  "-DEN_PR:STRING=1"
                  "-DEN_SHELL_PBLOCK:STRING=${if board == "u280" then "1" else "0"}"
                  "-DSIM_EXTERNAL_DYNAMIC_SERVICE:STRING=1"
                ];
              }
            ) qshellLib.boards;
          };

          mkD3QshellApp =
            board:
            qshellLib.mkQshellAppPackage {
              pname = "microblossom-d3-qshell-${board}-app";
              hwSource = d3QshellAppHwSource;
              inherit board;
              provenance = {
                application = "microblossom-d3-host-baseline";
                graphSha256 = "4b078d3b6c6db24ea9726414569a97b3899be4e532be1c0ebd84b5fa875316c5";
                qshellRecordAbi = 2;
                mbqProtocol = 1;
                acceleratorClockDivideBy = 2;
              };
            };

          d3QshellApps = {
            u280 = mkD3QshellApp "u280";
            v80 = mkD3QshellApp "v80";
          };

          microblossomQshellCoyoteBridge = pkgs.stdenv.mkDerivation {
            pname = "microblossom-qshell-coyote-bridge";
            version = "0.1.0";
            src = ./src/qshell/host/microblossom_qshell_coyote_bridge.cpp;
            dontUnpack = true;
            nativeBuildInputs = [ pkgs.patchelf ];
            buildInputs = [ pkgs.boost ];
            buildPhase = ''
              runHook preBuild
              $CXX -std=c++20 -O2 -Wall -Wextra -Werror \
                -isystem ${qshellHostPackage}/include \
                "$src" \
                -L${qshellHostPackage}/lib -lcoyote -pthread \
                -o microblossom-qshell-coyote-bridge
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              install -Dm755 microblossom-qshell-coyote-bridge \
                "$out/bin/microblossom-qshell-coyote-bridge"
              patchelf --set-rpath \
                ${qshellHostPackage}/lib:${lib.makeLibraryPath [ pkgs.stdenv.cc.cc ]} \
                "$out/bin/microblossom-qshell-coyote-bridge"
              runHook postInstall
            '';
            meta = {
              description = "One-sided Coyote beat bridge for MicroBlossom QShell ABI 2";
              license = lib.licenses.mit;
              platforms = systems;
              mainProgram = "microblossom-qshell-coyote-bridge";
            };
          };

          microblossomD3QshellCoyoteRun = pkgs.writeShellApplication {
            name = "microblossom-d3-qshell-coyote-run";
            runtimeInputs = [
              microblossomHost
              microblossomQshellCoyoteBridge
            ];
            text = ''
              exec microblossom_d3_qshell_coyote \
                --bridge ${microblossomQshellCoyoteBridge}/bin/microblossom-qshell-coyote-bridge \
                "$@"
            '';
            meta = {
              description = "Canonical d3 MicroBlossom workload through the physical Coyote driver";
              license = lib.licenses.mit;
              platforms = systems;
              mainProgram = "microblossom-d3-qshell-coyote-run";
            };
          };

          mkMicroblossomXdb =
            board:
            let
              qshellXdb = qshell.packages.${system}."qshell-xdb-${board}";
            in
            pkgs.writeShellApplication {
              name = "microblossom-xdb-${board}";
              runtimeInputs = [
                pkgs.git
                qshellXdb
              ];
              text = ''
                repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
                export XDB_ROOT="''${XDB_ROOT:-$repo_root/.xdb}"
                export XDB_SIM_WORKSPACE="''${XDB_SIM_WORKSPACE:-$repo_root/.build/xdb-microblossom-${board}}"
                export XDB_SIM_SESSION="''${XDB_SIM_SESSION:-microblossom-${board}}"
                exec ${qshellXdb}/bin/qshell-xdb-${board} "$@"
              '';
              meta = {
                description = "Pinned xdb wrapper for MicroBlossom ${board} simulation";
                license = lib.licenses.mit;
                platforms = systems;
                mainProgram = "microblossom-xdb-${board}";
              };
            };

          microblossomXdb = {
            u280 = mkMicroblossomXdb "u280";
            v80 = mkMicroblossomXdb "v80";
          };

          mkQshellXdbBridge =
            board:
            let
              qshellXdb = microblossomXdb.${board};
            in
            pkgs.writeShellApplication {
              name = "microblossom-qshell-${board}-xdb-bridge";
              runtimeInputs = [ pkgs.python3 ];
              text = ''
                exec python3 ${./src/qshell/host/microblossom_qshell_xdb_bridge.py} \
                  --xdb ${qshellXdb}/bin/microblossom-xdb-${board} "$@"
              '';
              meta = {
                description = "xdb simulation beat bridge for MicroBlossom QShell on ${board}";
                license = lib.licenses.mit;
                platforms = systems;
                mainProgram = "microblossom-qshell-${board}-xdb-bridge";
              };
            };

          qshellXdbBridges = {
            u280 = mkQshellXdbBridge "u280";
            v80 = mkQshellXdbBridge "v80";
          };

          mkD3QshellXdbRunner =
            board:
            pkgs.writeShellApplication {
              name = "microblossom-d3-qshell-${board}-xdb-run";
              runtimeInputs = [ microblossomHost ];
              text = ''
                exec microblossom_d3_qshell_coyote \
                  --bridge ${qshellXdbBridges.${board}}/bin/microblossom-qshell-${board}-xdb-bridge \
                  "$@"
              '';
              meta = {
                description = "Canonical d3 MicroBlossom workload for an active ${board} xdb session";
                license = lib.licenses.mit;
                platforms = systems;
                mainProgram = "microblossom-d3-qshell-${board}-xdb-run";
              };
            };

          qshellXdbRunners = {
            u280 = mkD3QshellXdbRunner "u280";
            v80 = mkD3QshellXdbRunner "v80";
          };

          updateQshellRustAbi = pkgs.writeShellApplication {
            name = "update-qshell-rust-abi";
            runtimeInputs = [
              pkgs.git
              pkgs.python3
            ];
            text = ''
              root="$(git rev-parse --show-toplevel)"
              python3 "$root/src/qshell/tools/generate_qshell_rust_abi.py" \
                --spec ${qshellContractSource}/abi/qshell-abi.json \
                --out "$root/src/qshell/protocol/src/qshell_abi_generated.rs"
            '';
          };
        in
        {
          default = microblossomHost;
          microblossom-host = microblossomHost;
          microblossom-scala = microblossomScala;
          microblossom-qshell-protocol = microblossomQshellProtocol;
          microblossom-qshell-coyote-bridge = microblossomQshellCoyoteBridge;
          microblossom-d3-qshell-coyote-run = microblossomD3QshellCoyoteRun;
          microblossom-xdb-u280 = microblossomXdb.u280;
          microblossom-xdb-v80 = microblossomXdb.v80;
          microblossom-qshell-u280-xdb-bridge = qshellXdbBridges.u280;
          microblossom-qshell-v80-xdb-bridge = qshellXdbBridges.v80;
          microblossom-d3-qshell-u280-xdb-run = qshellXdbRunners.u280;
          microblossom-d3-qshell-v80-xdb-run = qshellXdbRunners.v80;
          microblossom-d3-sim-runner = microblossomD3SimRunner;
          microblossom-d3-golden-decode = d3GoldenDecode;
          microblossom-d3-qshell-golden-decode = d3QshellGoldenDecode;
          microblossom-d3-graph = d3Fixture;
          microblossom-d3-rtl = d3Rtl;
          microblossom-d3-qshell-core = d3QshellCore;
          microblossom-d3-qshell-app-hw-source = d3QshellAppHwSource;
          microblossom-d3-qshell-simulation-hw-source = d3QshellSimulationHwSource;
          microblossom-d3-qshell-u280-sim = d3QshellSimulationPackages."microblossom-d3-qshell-u280-sim";
          microblossom-d3-qshell-v80-sim = d3QshellSimulationPackages."microblossom-d3-qshell-v80-sim";
          qshell-u280-shell = qshellU280Shell;
          microblossom-d3-qshell-u280-app = d3QshellApps.u280;
          microblossom-d3-qshell-v80-app = d3QshellApps.v80;
          microblossom-d3-qshell-u280-app-synth = d3QshellApps.u280.coyoteTwoStage.stages.synth;
          microblossom-d3-qshell-v80-app-synth = d3QshellApps.v80.coyoteTwoStage.stages.synth;
          update-qshell-rust-abi = updateQshellRustAbi;
          verilator-5_014 = verilator_5_014;
        }
        // coyoteDriverPackages
      );

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          coyoteNix = inputs."coyote-nix";
          doctor = inputs."doctor-cluster-xilinx".lib.mkXilinxContext { inherit pkgs system; };
          xilinxShareRoot = doctor.xilinxShareRoot;
          coyoteTools = coyoteNix.lib.mkTools {
            inherit pkgs xilinxShareRoot;
            coyoteRoot = coyote;
            platforms = systems;
          };
          qshellLib = qshell.lib.${system};
          verilator_5_014 = mkVerilator_5_014 pkgs;
          host = self.packages.${system}.microblossom-host;
          fixture = self.packages.${system}.microblossom-d3-graph;
          protocol = self.packages.${system}.microblossom-qshell-protocol;
          coyoteBridge = self.packages.${system}.microblossom-qshell-coyote-bridge;
          coyoteRunner = self.packages.${system}.microblossom-d3-qshell-coyote-run;
          scala = self.packages.${system}.microblossom-scala;
          simRunner = self.packages.${system}.microblossom-d3-sim-runner;
          rtl = self.packages.${system}.microblossom-d3-rtl;
          qshellCore = self.packages.${system}.microblossom-d3-qshell-core;
          qshellAppHwSource = self.packages.${system}.microblossom-d3-qshell-app-hw-source;
          qshellSimulationHwSource = self.packages.${system}.microblossom-d3-qshell-simulation-hw-source;
          qshellXdbBridge = self.packages.${system}.microblossom-qshell-u280-xdb-bridge;
          qshellU280Simulation = self.packages.${system}.microblossom-d3-qshell-u280-sim;
          qshellAbiSource = qshell.lib.${system}.qshellAbiSource;
          qshellContractSource = qshell.lib.${system}.qshellContractSource;
        in
        {
          formatting = (treefmtEval system).config.build.check self;
          qshell-protocol = self.packages.${system}.microblossom-qshell-protocol;
          qshell-u280-xdb-d3 =
            pkgs.runCommand "microblossom-d3-qshell-u280-xdb-check"
              {
                nativeBuildInputs = [
                  coyoteTools.vivado
                  doctor.xilinxShell
                  host
                  pkgs.jq
                  qshell.packages.${system}.qshell-xdb-u280
                ];
                COYOTE_NIX_XILINX_SHELL = "${doctor.xilinxShell}/bin/xilinx-shell";
                COYOTE_NIX_XILINX_SHARE_ROOT = toString xilinxShareRoot;
                COYOTE_NIX_XILINX_VERSION = qshellLib.boards.u280.simXilinxVersion;
                COYOTE_NIX_NCURSES6_LIB = "${pkgs.ncurses6}/lib/libtinfo.so.6";
                __impureHostDeps = [ (toString xilinxShareRoot) ];
              }
              ''
                mkdir -p "$out" "$TMPDIR/home" "$TMPDIR/xdb" "$TMPDIR/workspace"
                export HOME="$TMPDIR/home"
                export XDB_ROOT="$TMPDIR/xdb"
                export XDB_SIM_WORKSPACE="$TMPDIR/workspace"
                export XDB_SIM_SIMSET=sim_1
                export XDB_SIM_TOP=tb_user
                export XDB_SIM_MODE=behavioral
                export XDB_SIM_SESSION=microblossom-u280-check

                cleanup() {
                  qshell-xdb-u280 sim close --force >/dev/null 2>&1 || true
                }
                trap cleanup EXIT

                if ! qshell-xdb-u280 --debug sim launch \
                  ${qshellU280Simulation}; then
                  find "$XDB_SIM_WORKSPACE" "$XDB_ROOT" -type f \
                    \( -name '*.log' -o -name '*.jou' \) -print -exec tail -n 200 '{}' \;
                  exit 1
                fi
                if ! microblossom_d3_qshell_coyote \
                  --bridge ${qshellXdbBridge}/bin/microblossom-qshell-u280-xdb-bridge \
                  --timeout-ms 30000 \
                  2>&1 | tee "$out/workload.log"; then
                  qshell-xdb-u280 sim time || true
                  qshell-xdb-u280 sim read \
                    /tb_user/aresetn \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/slow_clk \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/slow_aresetn \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/m_axi_arvalid \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/m_axi_arready \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/m_axi_rvalid \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_frontend/state \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/reset \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/unburstify_result_rValid \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/rawFactory_readDataStage_valid \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/rawFactory_readHaltRequest \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/rawFactory_readDataStage_ready \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/counter_value \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/fsm_stateReg \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/streamFifoCC_2_io_push_valid \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/streamFifoCC_2_io_push_ready \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/streamFifoCC_2_io_pop_valid \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/fsmIsLastFindObstacle_data \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/fsmPushId_data \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/fsmPopId_data \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/streamFifoCC_2_io_pop_valid \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/slow_microBlossom_io_push_ready \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/slow_microBlossom_io_pop_valid \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/streamFifoCC_3_io_push_ready \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/streamFifoCC_3_io_pop_valid \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/streamFifoCC_3_io_pop_ready \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/streamFifoCC_3_io_pushOccupancy \
                    /tb_user/inst_DUT/inst_microblossom_qshell_application/inst_core/inst_accelerator/streamFifoCC_3_io_popOccupancy \
                    || true
                  qshell-xdb-u280 sim coyote-status || true
                  exit 1
                fi
                grep -F \
                  'MICROBLOSSOM_D3_QSHELL_COYOTE_PASS defects=[0] correction_edges=[2] total_weight=2 operations=14' \
                  "$out/workload.log" >/dev/null
                qshell-xdb-u280 sim time > "$out/simulation-time.json"
                qshell-xdb-u280 sim coyote-status > "$out/coyote-status.json"
                qshell-xdb-u280 sim provenance > "$out/provenance.json"
                qshell-xdb-u280 sim bundle --out "$out/bundle" >/dev/null
                jq -e \
                  '.host_write_count == 14 and .last_protocol_error == ""' \
                  "$out/coyote-status.json" >/dev/null
                test -s "$out/simulation-time.json"
                test -s "$out/provenance.json"
                test -s "$out/bundle/manifest.json"
                cleanup
                trap - EXIT
              '';

          qshell-coyote-bridge = pkgs.runCommand "microblossom-qshell-coyote-bridge-check" { } ''
            ${coyoteBridge}/bin/microblossom-qshell-coyote-bridge --self-test \
              | tee bridge.log
            grep -F 'MICROBLOSSOM_QSHELL_COYOTE_BRIDGE_PASS' bridge.log >/dev/null
            touch "$out"
          '';

          qshell-xdb-bridge = pkgs.runCommand "microblossom-qshell-xdb-bridge-check" { } ''
            ${qshellXdbBridge}/bin/microblossom-qshell-u280-xdb-bridge --self-test \
              | tee bridge.log
            grep -F 'MICROBLOSSOM_QSHELL_XDB_BRIDGE_PASS' bridge.log >/dev/null
            touch "$out"
          '';

          qshell-rust-abi-generated =
            pkgs.runCommand "microblossom-qshell-rust-abi-generated"
              {
                nativeBuildInputs = [
                  pkgs.diffutils
                  pkgs.python3
                ];
              }
              ''
                python3 ${./src/qshell/tools/generate_qshell_rust_abi.py} \
                  --spec ${qshellContractSource}/abi/qshell-abi.json \
                  --out generated.rs
                diff -u ${./src/qshell/protocol/src/qshell_abi_generated.rs} generated.rs
                python3 ${./src/qshell/tools/check_qshell_wire_fixture.py} \
                  --spec ${qshellContractSource}/abi/qshell-abi.json \
                  --fixtures ${qshellContractSource}/abi/golden-fixtures.json
                touch "$out"
              '';
          d3-golden-decode = self.packages.${system}.microblossom-d3-golden-decode;
          d3-qshell-golden-decode = self.packages.${system}.microblossom-d3-qshell-golden-decode;

          qshell-clock =
            pkgs.runCommand "microblossom-qshell-clock"
              {
                nativeBuildInputs = [
                  pkgs.gnumake
                  pkgs.stdenv.cc
                  verilator_5_014
                ];
              }
              ''
                mkdir -p "$out"
                verilator --binary --timing --assert -Wno-fatal \
                  -DMICROBLOSSOM_SIM_CLOCK_DIVIDER \
                  --top-module tb_clock_div2 \
                  ${./src/qshell/rtl/microblossom_qshell_clock_div2.sv} \
                  ${./src/qshell/tests/microblossom_qshell_clock_div2_tb.sv}
                ./obj_dir/Vtb_clock_div2 2>&1 | tee "$out/test.log"
                grep -F 'MICROBLOSSOM_QSHELL_CLOCK_DIV2_PASS' "$out/test.log" >/dev/null
                verilator --version > "$out/verilator-version.txt"
              '';

          qshell-envelope =
            pkgs.runCommand "microblossom-qshell-envelope"
              {
                nativeBuildInputs = [
                  pkgs.gnumake
                  pkgs.jq
                  pkgs.stdenv.cc
                  verilator_5_014
                ];
              }
              ''
                abi=${qshellAbiSource}/src/abi/hdl
                test -s "$abi/qshell_abi_generated.svh"
                test "$(jq -er '.nodes.qshell.locked.rev' ${./flake.lock})" = \
                  b75accf48107a023be3fc5268afeec43a7f5adbc
                mkdir -p "$out"
                verilator --binary --timing --assert -Wno-fatal \
                  -I"$abi" \
                  --top-module tb_envelope \
                  ${./src/qshell/rtl/microblossom_qshell_envelope.sv} \
                  ${./src/qshell/tests/microblossom_qshell_envelope_tb.sv}
                ./obj_dir/Vtb_envelope 2>&1 | tee "$out/test.log"
                grep -F 'MICROBLOSSOM_QSHELL_ENVELOPE_PASS' "$out/test.log" >/dev/null
                cp "$abi/qshell_abi_generated.svh" "$out/"
                verilator --version > "$out/verilator-version.txt"
              '';

          qshell-app-source =
            pkgs.runCommand "microblossom-qshell-app-source" { nativeBuildInputs = [ pkgs.jq ]; }
              ''
                app=${qshellAppHwSource}/src/microblossom
                hdl="$app/hdl"
                test -s ${qshellAppHwSource}/CMakeLists.txt
                test -s ${qshellSimulationHwSource}/CMakeLists.txt
                grep -F 'VFPGA_C0_0 "src/app/microblossom"' \
                  ${qshellSimulationHwSource}/CMakeLists.txt >/dev/null
                test -s ${qshellSimulationHwSource}/src/shell/hdl/qshell_dynamic_service.sv
                test -s ${qshellSimulationHwSource}/src/app/microblossom/vfpga_top.svh
                test -s "$app/vfpga_top.svh"
                test -s "$app/init_ip.tcl"
                test -s "$app/microblossom_qshell_timing.xdc"
                grep -F 'set_false_path -to $mb_local_reset_clear_pins' \
                  "$app/microblossom_qshell_timing.xdc" >/dev/null
                grep -F 'set_max_delay -datapath_only 4.000' \
                  "$app/microblossom_qshell_timing.xdc" >/dev/null
                grep -F 'set_bus_skew 8.000' \
                  "$app/microblossom_qshell_timing.xdc" >/dev/null
                grep -F 'USED_IN_IMPLEMENTATION true' "$app/init_ip.tcl" >/dev/null
                grep -F 'vfpga_src_dir/hdl' \
                  ${coyote}/scripts/cr_prjcts/cr_user.tcl.in >/dev/null
                test ! -e "$app/microblossom_qshell_application.sv"
                for source in \
                  MicroBlossomBus.v \
                  microblossom_qshell_frontend.sv \
                  microblossom_qshell_core.sv \
                  microblossom_qshell_clock_div2.sv \
                  microblossom_qshell_envelope.sv \
                  microblossom_qshell_application.sv \
                  qshell_abi_generated.svh; do
                  test -s "$hdl/$source"
                done
                grep -F 'load_apps(VFPGA_C0_0 "src/microblossom")' \
                  ${qshellAppHwSource}/CMakeLists.txt >/dev/null
                test "$(jq -er '.graphSha256' ${qshellAppHwSource}/core-manifest.json)" = \
                  4b078d3b6c6db24ea9726414569a97b3899be4e532be1c0ebd84b5fa875316c5
                test "$(jq -er '.qshellRevision' ${qshellAppHwSource}/core-manifest.json)" = \
                  b75accf48107a023be3fc5268afeec43a7f5adbc
                touch "$out"
              '';

          qshell-application =
            pkgs.runCommand "microblossom-qshell-application"
              {
                nativeBuildInputs = [
                  pkgs.gnumake
                  pkgs.stdenv.cc
                  verilator_5_014
                ];
              }
              ''
                core=${qshellCore}/share/microblossom/qshell-core/code-capacity-repetition-d3-v1
                mkdir -p "$out"
                verilator --binary --timing --assert -Wno-fatal \
                  -DMICROBLOSSOM_SIM_CLOCK_DIVIDER \
                  -I"$core" \
                  --top-module tb_application \
                  "$core/MicroBlossomBus.v" \
                  "$core/microblossom_qshell_frontend.sv" \
                  "$core/microblossom_qshell_core.sv" \
                  "$core/microblossom_qshell_clock_div2.sv" \
                  "$core/microblossom_qshell_envelope.sv" \
                  "$core/microblossom_qshell_application.sv" \
                  ${./src/qshell/tests/microblossom_qshell_application_tb.sv}
                timeout 120 ./obj_dir/Vtb_application 2>&1 | tee "$out/test.log"
                grep -F 'MICROBLOSSOM_QSHELL_APPLICATION_PASS' "$out/test.log" >/dev/null
                cp "$core/core-manifest.json" "$out/"
                verilator --version > "$out/verilator-version.txt"
              '';

          qshell-core =
            pkgs.runCommand "microblossom-qshell-core"
              {
                nativeBuildInputs = [
                  pkgs.gnumake
                  pkgs.jq
                  pkgs.stdenv.cc
                  verilator_5_014
                ];
              }
              ''
                core=${qshellCore}/share/microblossom/qshell-core/code-capacity-repetition-d3-v1
                test "$(jq -er '.outerQshellEnvelope' "$core/core-manifest.json")" = 'QShell ABI 2'
                test "$(jq -er '.qshellRevision' "$core/core-manifest.json")" = \
                  b75accf48107a023be3fc5268afeec43a7f5adbc
                test "$(sha256sum "$core/MicroBlossomBus.v" | cut -d' ' -f1)" = \
                  "$(jq -er '.acceleratorRtlSha256' "$core/core-manifest.json")"
                test "$(sha256sum "$core/microblossom_qshell_clock_div2.sv" | cut -d' ' -f1)" = \
                  "$(jq -er '.clockDividerSha256' "$core/core-manifest.json")"
                test "$(sha256sum "$core/microblossom_qshell_envelope.sv" | cut -d' ' -f1)" = \
                  "$(jq -er '.envelopeSha256' "$core/core-manifest.json")"
                test "$(sha256sum "$core/microblossom_qshell_application.sv" | cut -d' ' -f1)" = \
                  "$(jq -er '.applicationSha256' "$core/core-manifest.json")"
                test "$(sha256sum "$core/qshell_abi_generated.svh" | cut -d' ' -f1)" = \
                  "$(jq -er '.qshellAbiSha256' "$core/core-manifest.json")"
                mkdir -p "$out"
                verilator --binary --timing --assert -Wno-fatal \
                  --top-module tb_core \
                  "$core/MicroBlossomBus.v" \
                  "$core/microblossom_qshell_frontend.sv" \
                  "$core/microblossom_qshell_core.sv" \
                  ${./src/qshell/tests/microblossom_qshell_core_tb.sv}
                timeout 120 ./obj_dir/Vtb_core 2>&1 | tee "$out/test.log"
                grep -F 'MICROBLOSSOM_QSHELL_CORE_PASS' "$out/test.log" >/dev/null
                verilator --lint-only -Wno-fatal \
                  -DMICROBLOSSOM_SIM_CLOCK_DIVIDER \
                  -I"$core" \
                  --top-module microblossom_qshell_application \
                  "$core/MicroBlossomBus.v" \
                  "$core/microblossom_qshell_frontend.sv" \
                  "$core/microblossom_qshell_core.sv" \
                  "$core/microblossom_qshell_clock_div2.sv" \
                  "$core/microblossom_qshell_envelope.sv" \
                  "$core/microblossom_qshell_application.sv"
                cp "$core/core-manifest.json" "$out/"
                verilator --version > "$out/verilator-version.txt"
              '';

          qshell-frontend =
            pkgs.runCommand "microblossom-qshell-frontend"
              {
                nativeBuildInputs = [
                  pkgs.gnumake
                  pkgs.stdenv.cc
                  verilator_5_014
                ];
              }
              ''
                mkdir -p "$out"
                verilator --binary --timing --assert -Wno-fatal \
                  --top-module tb \
                  ${./src/qshell/rtl/microblossom_qshell_frontend.sv} \
                  ${./src/qshell/tests/microblossom_qshell_frontend_tb.sv}
                ./obj_dir/Vtb 2>&1 | tee "$out/test.log"
                grep -F 'MICROBLOSSOM_QSHELL_FRONTEND_PASS' "$out/test.log" >/dev/null
                verilator --version > "$out/verilator-version.txt"
              '';

          rust-package-contract = pkgs.runCommand "microblossom-rust-package-contract" { } ''
            test -x ${coyoteBridge}/bin/microblossom-qshell-coyote-bridge
            test -x ${coyoteRunner}/bin/microblossom-d3-qshell-coyote-run
            ${coyoteRunner}/bin/microblossom-d3-qshell-coyote-run --help \
              | grep -F 'Run the canonical d3 workload through a QShell Coyote beat bridge' >/dev/null
            test -x ${host}/bin/micro_blossom
            test -x ${host}/bin/generate_nix_d3_fixture
            test -x ${host}/bin/microblossom_d3_qshell_coyote
            test ! -e ${host}/lib

            test -x ${simRunner}/bin/micro_blossom
            test -x ${simRunner}/bin/generate_nix_d3_fixture
            test -x ${simRunner}/bin/embedded_simulator
            test ! -e ${simRunner}/lib

            contract=${protocol}/share/microblossom/qshell-protocol
            test -s "$contract/Cargo.toml"
            test -s "$contract/Cargo.lock"
            test -s "$contract/README.md"
            test -s "$contract/src/lib.rs"
            test -s "$contract/src/qshell_abi_generated.rs"
            cmp ${./src/qshell/protocol/src/lib.rs} "$contract/src/lib.rs"
            cmp ${./src/qshell/protocol/src/qshell_abi_generated.rs} \
              "$contract/src/qshell_abi_generated.rs"
            cmp ${./src/qshell/README.md} "$contract/README.md"
            touch "$out"
          '';

          scala-package-contract =
            pkgs.runCommand "microblossom-scala-package-contract"
              {
                nativeBuildInputs = [ pkgs.unzip ];
              }
              ''
                jar=${scala}/share/java/microblossom.jar
                test -s "$jar"
                unzip -l "$jar" > "$TMPDIR/jar-contents"
                grep -F 'microblossom/MicroBlossomBusGenerator' "$TMPDIR/jar-contents" >/dev/null
                if grep -E 'Blinky(Asm|Power)|vexriscv/' "$TMPDIR/jar-contents" >/dev/null; then
                  echo "VexRiscv demo classes leaked into the baseline generator JAR" >&2
                  exit 1
                fi
                touch "$out"
              '';

          d3-behavior-smoke =
            pkgs.runCommand "microblossom-d3-behavior-smoke"
              {
                nativeBuildInputs = [
                  simRunner
                  pkgs.coreutils
                  pkgs.gnumake
                  pkgs.jdk11
                  pkgs.stdenv.cc
                  verilator_5_014
                ];
              }
              ''
                fixture=${fixture}/share/microblossom/fixtures/code-capacity-repetition-d3-v1
                export JAVA=${pkgs.jdk11}/bin/java
                export MICROBLOSSOM_SCALA_JAR=${scala}/share/java/microblossom.jar
                export MICROBLOSSOM_SIM_WORKDIR="$TMPDIR/work"
                export MICROBLOSSOM_JAVA_HEAP=4G
                export BUS_TYPE=Axi4
                export USE_64_BUS=1
                export CLOCK_DIVIDE_BY=2
                export NO_WAVEFORM=1
                export NO_DEBUGGER_FILES=1
                mkdir -p "$MICROBLOSSOM_SIM_WORKDIR" "$out"

                timeout 600 embedded_simulator "$fixture/graph.json" 2>&1 | \
                  tee "$out/smoke.log"
                grep -F 'Test MicroBlossom' "$out/smoke.log" >/dev/null
                grep -F '9. Test Context Switching' "$out/smoke.log" >/dev/null
                verilator --version > "$out/verilator-version.txt"
                cp "$fixture/manifest.json" "$out/fixture-manifest.json"
              '';

          rtl-contract =
            pkgs.runCommand "microblossom-d3-rtl-contract"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.jq
                  verilator_5_014
                ];
              }
              ''
                root=${rtl}/share/microblossom/rtl/code-capacity-repetition-d3-v1
                test -s "$root/MicroBlossomBus.v"
                test -s "$root/graph-manifest.json"
                test -s "$root/rtl-manifest.json"
                grep -E '^module MicroBlossomBus([ (]|$)' "$root/MicroBlossomBus.v" >/dev/null
                grep -E '^  input +slow_reset[, ]' "$root/MicroBlossomBus.v" >/dev/null
                test "$(grep -c 'ram_style = \"block\"' "$root/MicroBlossomBus.v")" = 2
                test "$(jq -er '.graphSha256' "$root/rtl-manifest.json")" = \
                  "$(jq -er '.generated.graphSha256' "$root/graph-manifest.json")"
                test "$(sha256sum "$root/MicroBlossomBus.v" | cut -d' ' -f1)" = \
                  "$(jq -er '.rtlSha256' "$root/rtl-manifest.json")"
                verilator --lint-only -Wno-fatal --top-module MicroBlossomBus \
                  "$root/MicroBlossomBus.v"
                touch "$out"
              '';

          fixture-contract =
            pkgs.runCommand "microblossom-fixture-contract"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.jq
                ];
              }
              ''
                root=${fixture}/share/microblossom/fixtures/code-capacity-repetition-d3-v1
                test -s "$root/graph.json"
                test -s "$root/config.json"
                test -s "$root/manifest.json"

                test "$(jq -er '.fixture.fixtureId' "$root/manifest.json")" = \
                  'code-capacity-repetition-d3-v1'
                test "$(jq -er '.fixture.code.distance' "$root/manifest.json")" = 3
                test "$(jq -er '.fixture.accelerator.busType' "$root/manifest.json")" = Axi4
                test "$(jq -er '.provenance.rustToolchain' "$root/manifest.json")" = \
                  nightly-2023-11-16

                expected="$(jq -er '.fixture.expectedGraph.sha256' "$root/manifest.json")"
                recorded="$(jq -er '.generated.graphSha256' "$root/manifest.json")"
                actual="$(sha256sum "$root/graph.json" | cut -d' ' -f1)"
                test "$actual" = "$expected"
                test "$actual" = "$recorded"

                test "$(jq -er '.generated.vertexNum' "$root/manifest.json")" = \
                  "$(jq -er '.fixture.expectedGraph.vertexNum' "$root/manifest.json")"
                test "$(jq -er '.generated.edgeNum' "$root/manifest.json")" = \
                  "$(jq -er '.fixture.expectedGraph.edgeNum' "$root/manifest.json")"
                test "$(jq -er '.generated.virtualVertexNum' "$root/manifest.json")" = \
                  "$(jq -er '.fixture.expectedGraph.virtualVertexNum' "$root/manifest.json")"
                touch "$out"
              '';

          crane-input-contract =
            pkgs.runCommand "microblossom-crane-input-contract"
              {
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                lock=${./flake.lock}
                test "$(jq -er '.nodes.crane.locked.type' "$lock")" = github
                test "$(jq -er '.nodes.crane.locked.owner' "$lock")" = ipetkov
                test "$(jq -er '.nodes.crane.locked.repo' "$lock")" = crane
                test "$(jq -er '.nodes.crane.locked.rev' "$lock")" = \
                  10e6e3cb966f7cfcc789fe5eee7a85f3188ce08b
                test "$(jq -er '.nodes.crane.original.ref' "$lock")" = v0.23.4
                test -n "$(jq -er '.nodes.crane.locked.narHash' "$lock")"

                test "$(jq -r '[.nodes[] | .locked.type? // empty] | any(. == "path")' "$lock")" = false
                touch "$out"
              '';

          toolchain-contract = pkgs.runCommand "microblossom-toolchain-contract" { } ''
            grep -Fx 'channel = "nightly-2023-11-16"' \
              ${./src/cpu/blossom/rust-toolchain.toml} >/dev/null
            grep -Fx 'channel = "nightly-2023-11-16"' \
              ${./src/cpu/blossom-nostd/rust-toolchain.toml} >/dev/null
            grep -Fx 'channel = "nightly-2023-11-16"' \
              ${./src/cpu/embedded/rust-toolchain} >/dev/null
            touch "$out"
          '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          microblossomSbt = pkgs.sbt.override { jre = pkgs.jdk11; };
          verilator_5_014 = mkVerilator_5_014 pkgs;
          rustToolchain = fenix.packages.${system}.fromToolchainFile {
            file = ./src/cpu/blossom/rust-toolchain.toml;
            sha256 = rustManifestSha256;
          };
          coyoteNix = inputs."coyote-nix";
          doctor = inputs."doctor-cluster-xilinx".lib.mkXilinxContext { inherit pkgs system; };
          coyoteTools = coyoteNix.lib.mkTools {
            inherit pkgs;
            coyoteRoot = coyote;
            xilinxShareRoot = doctor.xilinxShareRoot;
            platforms = systems;
          };
          mkXdbDevShell =
            board:
            coyoteNix.lib.mkCoyoteDevShell {
              inherit pkgs;
              tools = coyoteTools;
              coyoteRoot = coyote;
              shellHook = doctor.hostFpgaEnvShellFragment;
              withXilinx = true;
              board = doctor.boards.${board} // {
                xilinxVersion = doctor.boards.${board}.simXilinxVersion;
              };
              packages = [
                qshell.packages.${system}."qshell-xdb-${board}"
                self.packages.${system}.microblossom-d3-qshell-coyote-run
                self.packages.${system}."microblossom-xdb-${board}"
                self.packages.${system}."microblossom-d3-qshell-${board}-xdb-run"
              ];
              sim = {
                workspaceSuffix = "microblossom-${board}";
                projectName = "qshell-fpga.xpr";
                simset = "sim_1";
                top = "tb_user";
                mode = "behavioral";
                session = "microblossom-${board}";
              };
            };
        in
        {
          default = pkgs.mkShell {
            packages = [
              rustToolchain
              pkgs.cargo-nextest
              pkgs.jdk11
              pkgs.jq
              microblossomSbt
              verilator_5_014
            ];
          };
          ultrascale = mkXdbDevShell "u280";
          versal = mkXdbDevShell "v80";
        }
      );

      formatter = forAllSystems (system: (treefmtEval system).config.build.wrapper);
    };

  nixConfig = {
    extra-sandbox-paths = [
      "/share/xilinx"
      "/bin/touch=/run/current-system/sw/bin/touch"
      "/bin/lscpu=/run/current-system/sw/bin/lscpu"
    ];
  };
}
