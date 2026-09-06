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
    qshell.url = "git+ssh://git@github.com/TUM-DSE/QShell.git?ref=r5-report-source-preflight&rev=226b95d3f05420462ef3ecdd972d2b5ba699019f";
    coyote.follows = "qshell/coyote";
    coyote-nix.follows = "qshell/coyote-nix";
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
      v80R5QshellRevision = qshell.rev;
      v80R5CoyoteRevision = coyote.rev;
      v80R5CoyoteNixRevision = qshell.inputs.coyote-nix.rev;
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
            "src/cpu/blossom/src/bin/generate_nix_fixture.rs"
            "src/cpu/blossom/src/bin/microblossom_d3_qshell_coyote.rs"
            "src/cpu/blossom/src/dual_module_qshell.rs"
            "src/cpu/blossom/src/util.rs"
            "src/cpu/blossom/tests/nix_d3_golden.rs"
            "src/cpu/blossom/tests/nix_d3_qshell_golden.rs"
            "src/cpu/embedded/build.rs"
            "src/cpu/r5-service-rust/**/*.rs"
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
          qshellAbiSpec = builtins.fromJSON (builtins.readFile "${qshellContractSource}/abi/qshell-abi.json");
          qshellHostPackage = qshell.packages.${system}.qshell-host;
          qshellU280Shell = qshell.packages.${system}.qshell-u280-shell;
          qshellV80CoprocessorShell = qshell.packages.${system}.qshell-v80-r5-shell-nonstrict;
          coyoteNix = inputs."coyote-nix";
          doctor = inputs."doctor-cluster-xilinx".lib.mkXilinxContext { inherit pkgs system; };
          xilinxShareRoot = doctor.xilinxShareRoot;
          coyoteTools = coyoteNix.lib.mkTools {
            inherit pkgs xilinxShareRoot;
            coyoteRoot = coyote;
            platforms = systems;
            extraRuntimeInputs = lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [
              doctor.xilinxShell
            ];
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
          r5RustTarget = "armv7r-none-eabi";
          r5RustTargetToolchain = fenix.packages.${system}.targets.${r5RustTarget}.toolchainOf {
            channel = "nightly";
            date = "2023-11-16";
            sha256 = rustManifestSha256;
          };
          r5RustToolchain = fenix.packages.${system}.combine [
            rustToolchain
            r5RustTargetToolchain.rust-std
          ];
          r5CraneLib = (crane.mkLib pkgs).overrideToolchain r5RustToolchain;
          r5PolicyPython = pkgs.python3.withPackages (packages: [ packages.pyelftools ]);
          # Crane's default dummy uses syntax newer than the pinned 2023 nightly.
          craneDummySource = pkgs.writeText "microblossom-crane-dummy.rs" ''
            fn main() { }
          '';
          r5CraneDummySource = pkgs.writeText "microblossom-r5-crane-dummy.rs" ''
            #![no_std]
            use core::panic::PanicInfo;
            #[panic_handler]
            fn panic(_information: &PanicInfo<'_>) -> ! { loop { } }
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

          r5RustSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              (r5CraneLib.fileset.commonCargoSources ./src/cpu/r5-service-rust)
              ./src/cpu/r5-service-rust/include/microblossom_rust_service.h
              ./src/cpu/r5-service-rust/rust-toolchain.toml
              ./src/cpu/blossom
              ./src/cpu/blossom-nostd
              ./src/cpu/embedded
              ./src/qshell/protocol
            ];
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
              buildPhaseCargoCommand = "cargo build --profile release --locked --bin microblossom_d3_coprocessor --bin microblossom_coprocessor && cargo test --profile release --locked --no-run";
              doCheck = true;
              checkPhaseCargoCommand = "cargo test --profile release --locked";
              doInstallCargoArtifacts = false;
              installPhaseCommand = ''
                contract="$out/share/microblossom/qshell-protocol"
                mkdir -p "$out/bin" "$contract/src/bin"
                install -m755 target/release/microblossom_d3_coprocessor "$out/bin/"
                install -m755 target/release/microblossom_coprocessor "$out/bin/"
                cp Cargo.toml Cargo.lock "$contract/"
                cp src/lib.rs src/qshell_abi_generated.rs "$contract/src/"
                cp src/bin/microblossom_d3_coprocessor.rs "$contract/src/bin/"
                cp src/bin/microblossom_coprocessor.rs "$contract/src/bin/"
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

          baseHostCargoExtraArgs = "--locked --bin micro_blossom --bin generate_nix_d3_fixture --bin generate_nix_fixture";
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
                install -Dm755 target/release/generate_nix_fixture \
                  "$out/bin/generate_nix_fixture"
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
                  "-DQSHELL_APPLICATION_SOURCE_DIRS:STRING=src/app/microblossom"
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
                qshellRecordAbi = qshellAbiSpec.version;
                mbqProtocol = 1;
                acceleratorClockDivideBy = 2;
              };
            };

          d3QshellApps = {
            u280 = mkD3QshellApp "u280";
            v80 = mkD3QshellApp "v80";
          };

          graphSpecs = import ./nix/microblossom-graph-specs.nix;

          mkGraphFixture =
            spec:
            pkgs.runCommand "microblossom-${spec.id}-graph-v1"
              {
                nativeBuildInputs = [
                  microblossomHost
                  pkgs.coreutils
                  pkgs.jq
                ];
              }
              ''
                fixture="$out/share/microblossom/fixtures/${spec.id}-v1"
                mkdir -p "$fixture"
                generate_nix_fixture \
                  "$fixture/graph.json" \
                  ${spec.generatorVariant} \
                  ${toString spec.distance}

                graph_sha256="$(sha256sum "$fixture/graph.json" | cut -d' ' -f1)"
                vertex_num="$(jq -er '.vertex_num' "$fixture/graph.json")"
                edge_num="$(jq -er '.weighted_edges | length' "$fixture/graph.json")"
                virtual_vertex_num="$(jq -er '.virtual_vertices | length' "$fixture/graph.json")"
                test "$graph_sha256" = ${spec.graphSha256}
                test "$vertex_num" = ${toString spec.vertexNum}
                test "$edge_num" = ${toString spec.edgeNum}
                test "$virtual_vertex_num" = ${toString spec.virtualVertexNum}

                jq -n \
                  --arg fixtureId '${spec.id}-v1' \
                  --arg family ${spec.generatorVariant} \
                  --argjson distance ${toString spec.distance} \
                  --argjson physicalErrorRate ${toString spec.physicalErrorRate} \
                  --argjson maxHalfWeight ${toString spec.maxHalfWeight} \
                  --argjson measurementRounds '${builtins.toJSON spec.measurementRounds}' \
                  --arg graphSha256 "$graph_sha256" \
                  --arg sourceRevision '${self.rev or "dirty"}' \
                  --argjson vertexNum "$vertex_num" \
                  --argjson edgeNum "$edge_num" \
                  --argjson virtualVertexNum "$virtual_vertex_num" \
                  '{
                    schemaVersion: 1,
                    fixture: {
                      id: $fixtureId,
                      family: $family,
                      distance: $distance,
                      physicalErrorRate: $physicalErrorRate,
                      maxHalfWeight: $maxHalfWeight,
                      measurementRounds: $measurementRounds
                    },
                    generated: {
                      graphFile: "graph.json",
                      graphSha256: $graphSha256,
                      vertexNum: $vertexNum,
                      edgeNum: $edgeNum,
                      virtualVertexNum: $virtualVertexNum
                    },
                    provenance: {
                      microblossomRevision: $sourceRevision,
                      rustToolchain: "nightly-2023-11-16"
                    }
                  }' > "$fixture/manifest.json"
              '';

          mkGraphRtl =
            spec: fixture:
            pkgs.runCommand "microblossom-${spec.id}-rtl-v1"
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
                fixture=${fixture}/share/microblossom/fixtures/${spec.id}-v1

                java -Xmx16G \
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
                rtl="$out/share/microblossom/rtl/${spec.id}-v1"
                mkdir -p "$rtl"
                cp -R "$TMPDIR/generated"/. "$rtl/"
                cp "$fixture/manifest.json" "$rtl/graph-manifest.json"

                jq -n \
                  --arg fixtureId '${spec.id}-v1' \
                  --arg graphSha256 ${spec.graphSha256} \
                  --arg rtlSha256 "$(sha256sum "$rtl/MicroBlossomBus.v" | cut -d' ' -f1)" \
                  --arg generatorJarSha256 "$(sha256sum ${microblossomScala}/share/java/microblossom.jar | cut -d' ' -f1)" \
                  '{
                    schemaVersion: 1,
                    fixtureId: $fixtureId,
                    topModule: "MicroBlossomBus",
                    busType: "Axi4",
                    graphSha256: $graphSha256,
                    rtlSha256: $rtlSha256,
                    generatorJarSha256: $generatorJarSha256
                  }' > "$rtl/rtl-manifest.json"
              '';

          mkGraphQshellCore =
            spec: rtl:
            pkgs.runCommand "microblossom-${spec.id}-qshell-core-v1"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.jq
                ];
              }
              ''
                src=${rtl}/share/microblossom/rtl/${spec.id}-v1
                core="$out/share/microblossom/qshell-core/${spec.id}-v1"
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
                  --arg fixtureId '${spec.id}-v1' \
                  --arg family ${spec.generatorVariant} \
                  --argjson distance ${toString spec.distance} \
                  --argjson physicalErrorRate ${toString spec.physicalErrorRate} \
                  --argjson maxHalfWeight ${toString spec.maxHalfWeight} \
                  --argjson measurementRounds '${builtins.toJSON spec.measurementRounds}' \
                  --arg graphSha256 ${spec.graphSha256} \
                  --arg acceleratorRtlSha256 "$(sha256sum "$core/MicroBlossomBus.v" | cut -d' ' -f1)" \
                  --arg qshellRevision '${qshell.rev}' \
                  '{
                    schemaVersion: 1,
                    fixtureId: $fixtureId,
                    graphFamily: $family,
                    codeDistance: $distance,
                    physicalErrorRate: $physicalErrorRate,
                    maxHalfWeight: $maxHalfWeight,
                    measurementRounds: $measurementRounds,
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
                    acceleratorClockStrategy: "BUFGCE_DIV/2",
                    outerQshellEnvelope: "QShell ABI 2",
                    outerQshellRequestBeats: 2,
                    outerQshellResponseBeats: 2,
                    qshellRevision: $qshellRevision,
                    graphSha256: $graphSha256,
                    acceleratorRtlSha256: $acceleratorRtlSha256
                  }' > "$core/core-manifest.json"
              '';

          mkGraphQshellAppHwSource =
            spec: core:
            pkgs.runCommand "microblossom-${spec.id}-qshell-app-hw-source-v1" { } ''
              cp -R ${./src/qshell/app}/. "$out"
              chmod -R u+w "$out"
              hdl="$out/src/microblossom/hdl"
              core=${core}/share/microblossom/qshell-core/${spec.id}-v1
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

          mkGraphEntry =
            spec:
            let
              fixture = mkGraphFixture spec;
              rtl = mkGraphRtl spec fixture;
              core = mkGraphQshellCore spec rtl;
              hwSource = mkGraphQshellAppHwSource spec core;
              mkApp =
                board:
                qshellLib.mkQshellAppPackage {
                  pname = "microblossom-${spec.id}-qshell-${board}-app";
                  inherit hwSource board;
                  provenance = {
                    application = "microblossom-host-driven";
                    graphFamily = spec.generatorVariant;
                    codeDistance = spec.distance;
                    physicalErrorRate = spec.physicalErrorRate;
                    maxHalfWeight = spec.maxHalfWeight;
                    measurementRounds = spec.measurementRounds;
                    graphSha256 = spec.graphSha256;
                    qshellRecordAbi = qshellAbiSpec.version;
                    mbqProtocol = 1;
                    acceleratorClockDivideBy = 2;
                  };
                };
            in
            {
              inherit
                spec
                fixture
                rtl
                core
                hwSource
                ;
              apps = {
                u280 = mkApp "u280";
                v80 = mkApp "v80";
              };
            };

          graphMatrix = lib.listToAttrs (
            map (spec: lib.nameValuePair spec.id (mkGraphEntry spec)) graphSpecs
          );

          graphMatrixPackages = lib.foldl' (
            packages: entry:
            let
              prefix = "microblossom-${entry.spec.id}";
            in
            packages
            // {
              "${prefix}-graph" = entry.fixture;
              "${prefix}-rtl" = entry.rtl;
              "${prefix}-qshell-core" = entry.core;
              "${prefix}-qshell-app-hw-source" = entry.hwSource;
              "${prefix}-qshell-u280-app" = entry.apps.u280;
              "${prefix}-qshell-u280-app-synth" = entry.apps.u280.coyoteTwoStage.stages.synth;
              "${prefix}-qshell-v80-app" = entry.apps.v80;
              "${prefix}-qshell-v80-app-synth" = entry.apps.v80.coyoteTwoStage.stages.synth;
            }
          ) { } (lib.attrValues graphMatrix);

          graphSpecById =
            id:
            lib.findFirst (spec: spec.id == id) (throw "missing MicroBlossom graph spec: ${id}") graphSpecs;
          packetBeats = bytes: builtins.div (bytes + 63) 64;
          mkR5ServiceDefinition =
            {
              key,
              specId,
              outputPrefix,
              runnerBinary,
              maxDefects ? null,
              maxCorrectionEdges ? null,
              rustService ? false,
              rustArchiveSha256 ? null,
            }:
            let
              spec = graphSpecById specId;
              effectiveMaxDefects =
                if maxDefects == null then spec.vertexNum - spec.virtualVertexNum else maxDefects;
              effectiveMaxCorrectionEdges =
                if maxCorrectionEdges == null then spec.edgeNum else maxCorrectionEdges;
              requestPayloadBytes = 40 + 2 * effectiveMaxDefects;
              responsePayloadBytes = 44 + 2 * effectiveMaxCorrectionEdges;
              requestPacketBytes = 48 + requestPayloadBytes;
              responsePacketBytes = 48 + responsePayloadBytes;
            in
            {
              inherit
                key
                spec
                outputPrefix
                runnerBinary
                effectiveMaxDefects
                effectiveMaxCorrectionEdges
                requestPayloadBytes
                responsePayloadBytes
                requestPacketBytes
                responsePacketBytes
                rustService
                rustArchiveSha256
                ;
              requestBeats = packetBeats requestPacketBytes;
              responseBeats = packetBeats responsePacketBytes;
              legacyCompatible = maxDefects != null || maxCorrectionEdges != null;
            };
          r5ServiceDefinitions = lib.listToAttrs (
            map
              (definition: lib.nameValuePair definition.key definition)
              [
                (mkR5ServiceDefinition {
                  key = "legacy-d3";
                  specId = "code-capacity-repetition-d3";
                  outputPrefix = "microblossom-d3";
                  runnerBinary = "microblossom_d3_coprocessor";
                  maxDefects = 4;
                  maxCorrectionEdges = 2;
                })
                (mkR5ServiceDefinition {
                  key = "circuit-level-d3";
                  specId = "circuit-level-d3";
                  outputPrefix = "microblossom-circuit-level-d3";
                  runnerBinary = "microblossom_circuit_d3_coprocessor";
                  rustService = true;
                  rustArchiveSha256 = "c7fea40eb54a2f67bd4c331428cf49e1adc7b5700e87732fe5626e955ab9503b";
                })
                (mkR5ServiceDefinition {
                  key = "circuit-level-d9";
                  specId = "circuit-level-d9";
                  outputPrefix = "microblossom-circuit-level-d9";
                  runnerBinary = "microblossom_circuit_d9_coprocessor";
                  rustService = true;
                  rustArchiveSha256 = "a56765e31ead4713babbcbbea8371c2b3853579db5a202158c063b7e50d8677a";
                })
              ]
          );
          mkR5RustService =
            name: definition:
            let
              graphContract = graphServiceContracts.${name};
              graphContractRoot =
                "${graphContract}/share/microblossom/r5-service/${definition.spec.id}-v1";
              graphModule = "${graphContractRoot}/microblossom_graph.rs";
              expectedArchiveSha256 =
                if definition.rustArchiveSha256 == null then "" else definition.rustArchiveSha256;
              archiveBuildIdentity = builtins.hashString "sha256" (
                lib.concatStringsSep "\n" [
                  "microblossom-r5-rust-service-archive-v3"
                  "features=default-disabled,service-model-forbidden"
                  "undefined-allowlist=fmaxl,logbl,scalbnl"
                  r5RustTarget
                  "nightly-2023-11-16"
                  rustManifestSha256
                  fenix.rev
                  crane.rev
                  definition.spec.id
                  definition.spec.graphSha256
                  (toString definition.spec.vertexNum)
                  (toString definition.spec.edgeNum)
                  (toString definition.effectiveMaxDefects)
                  (toString definition.effectiveMaxCorrectionEdges)
                  (builtins.hashFile "sha256" ./src/cpu/r5-service-rust/Cargo.toml)
                  (builtins.hashFile "sha256" ./src/cpu/r5-service-rust/Cargo.lock)
                  (builtins.hashFile "sha256" ./src/cpu/r5-service-rust/rust-toolchain.toml)
                  (builtins.hashFile "sha256" ./src/cpu/r5-service-rust/src/lib.rs)
                  (builtins.hashFile "sha256" ./src/cpu/r5-service-rust/src/materializer.rs)
                  (builtins.hashString "sha256" (toString r5RustSource))
                  (builtins.hashFile "sha256" ./src/cpu/r5-service-rust/include/microblossom_rust_service.h)
                  (builtins.hashFile "sha256" ./src/cpu/r5-service/check_r5_binary.py)
                  (builtins.hashFile "sha256" ./src/qshell/tools/build_graph_service_contract.py)
                ]
              );
            in
            assert definition.rustService;
            r5CraneLib.buildPackage {
              pname = "${definition.outputPrefix}-r5-rust-service";
              version = "0.1.0";
              src = r5RustSource;
              cargoLock = ./src/cpu/r5-service-rust/Cargo.lock;
              strictDeps = true;
              postUnpack = ''
                sourceRoot="$sourceRoot/src/cpu/r5-service-rust"
              '';
              nativeBuildInputs = [
                coyoteTools.armr5
                pkgs.jq
                r5PolicyPython
              ];
              COYOTE_NIX_XILINX_VERSION = r5PlatformContract.xilinxVersion;
              CARGO_BUILD_TARGET = r5RustTarget;
              CARGO_TARGET_ARMV7R_NONE_EABI_LINKER = "armr5-none-eabi-gcc";
              CARGO_INCREMENTAL = "0";
              SOURCE_DATE_EPOCH = "1";
              MICROBLOSSOM_R5_GRAPH_MODULE = graphModule;
              RUSTFLAGS = lib.concatStringsSep " " [
                "-C target-cpu=cortex-r5"
                "-C force-unwind-tables=no"
                "-C relocation-model=static"
                "-C code-model=small"
                "-C debuginfo=0"
                "-Z emit-stack-sizes"
                "--remap-path-prefix=${r5RustSource}=."
              ];
              cargoExtraArgs = "--locked --lib --no-default-features";
              dummyrs = r5CraneDummySource;
              dummyBuildrs = craneDummySource;
              doCheck = false;
              doInstallCargoArtifacts = false;
              dontStrip = true;
              installPhaseCommand = ''
                raw_archive=target/${r5RustTarget}/release/libmicroblossom_r5_service.a
                archive=libmicroblossom_r5_service.a
                test -s "$raw_archive"

                rustc --version --verbose > rustc-version.txt
                rustc -Z unstable-options --print target-spec-json \
                  --target ${r5RustTarget} > target-spec.json
                rustc --print cfg --target ${r5RustTarget} | LC_ALL=C sort > target-cfg.txt
                jq -e '
                  .["is-builtin"] == true and
                  .["llvm-target"] == "armv7r-none-eabi" and
                  .abi == "eabi" and
                  .arch == "arm" and
                  .["target-pointer-width"] == "32" and
                  .["panic-strategy"] == "abort" and
                  .["relocation-model"] == "static"
                ' target-spec.json >/dev/null
                grep -Fx 'target_abi="eabi"' target-cfg.txt >/dev/null
                grep -Fx 'target_arch="arm"' target-cfg.txt >/dev/null
                grep -Fx 'target_endian="little"' target-cfg.txt >/dev/null
                grep -Fx 'target_feature="rclass"' target-cfg.txt >/dev/null
                grep -Fx 'target_os="none"' target-cfg.txt >/dev/null
                grep -Fx 'target_pointer_width="32"' target-cfg.txt >/dev/null
                if grep -E 'target_feature="(neon|vfp[^" ]*)"' target-cfg.txt; then
                  echo 'armv7r-none-eabi unexpectedly enables a hardware-float feature' >&2
                  exit 1
                fi

                ${r5PolicyPython}/bin/python ${./src/cpu/r5-service/check_r5_binary.py} \
                  --kind archive --input "$raw_archive" --allow-cantunwind \
                  --allow-undefined fmaxl --allow-undefined logbl \
                  --allow-undefined scalbnl \
                  --require-function microblossom_rust_service_decode \
                  --require-object microblossom_rust_service_contract \
                  --output raw-archive-policy.json
                armr5-none-eabi-readelf -h -S -A "$raw_archive" > raw-readelf.txt
                armr5-none-eabi-objcopy \
                  '--remove-section=.ARM.exidx*' '--remove-section=.ARM.extab*' \
                  "$raw_archive" "$archive"
                ${r5PolicyPython}/bin/python ${./src/cpu/r5-service/check_r5_binary.py} \
                  --kind archive --input "$archive" \
                  --allow-undefined fmaxl --allow-undefined logbl \
                  --allow-undefined scalbnl \
                  --require-function microblossom_rust_service_decode \
                  --require-object microblossom_rust_service_contract \
                  --output archive-policy.json
                armr5-none-eabi-ar t "$archive" > archive-members.txt
                armr5-none-eabi-readelf -h -S -A "$archive" > readelf.txt
                armr5-none-eabi-nm -A -g "$archive" > symbols.txt
                armr5-none-eabi-nm -A -u "$archive" > undefined-symbols.txt
                armr5-none-eabi-size -A "$archive" > size.txt
                armr5-none-eabi-objdump -d "$archive" > disassembly.txt
                ${pkgs.llvmPackages.llvm}/bin/llvm-readobj --stack-sizes "$archive" \
                  > rust-stack-sizes.txt
                grep -F 'microblossom_rust_service_decode' symbols.txt >/dev/null
                if grep -E \
                  'microblossom_rust_software_accelerator_|fusion_blossom|dual_module_comb' \
                  symbols.txt; then
                  echo 'target archive contains a test-only service-model symbol' >&2
                  exit 1
                fi
                grep -E 'Tag_CPU_arch_profile:[[:space:]]+Realtime' readelf.txt >/dev/null
                grep -E 'Tag_CPU_arch:[[:space:]]+v7' readelf.txt >/dev/null
                if grep -E 'Tag_ABI_VFP_args:.*VFP registers' readelf.txt; then
                  echo 'Rust archive uses the hard-float parameter ABI' >&2
                  exit 1
                fi

                archive_sha256="$(sha256sum "$archive" | cut -d' ' -f1)"
                expected_archive_sha256='${expectedArchiveSha256}'
                if [ -n "$expected_archive_sha256" ]; then
                  test "$archive_sha256" = "$expected_archive_sha256"
                fi

                mkdir -p "$out/lib" "$out/include" "$out/analysis" "$out/metadata" \
                  "$out/share/microblossom/r5-service"
                cp "$archive" "$out/lib/"
                cp ${./src/cpu/r5-service-rust/include/microblossom_rust_service.h} \
                  "$out/include/microblossom_rust_service.h"
                cp ${graphModule} \
                  "$out/share/microblossom/r5-service/microblossom_graph.rs"
                cp archive-members.txt archive-policy.json disassembly.txt raw-archive-policy.json \
                  raw-readelf.txt readelf.txt rustc-version.txt rust-stack-sizes.txt \
                  size.txt symbols.txt target-cfg.txt target-spec.json \
                  undefined-symbols.txt "$out/analysis/"
                printf '%s\n' "$archive_sha256" > "$out/metadata/archive-sha256"
                printf '%s\n' '${archiveBuildIdentity}' > "$out/metadata/build-identity"
                jq -n \
                  --arg api 'microblossom.r5-rust-service/v1' \
                  --arg graphId '${definition.spec.id}' \
                  --arg graphSha256 '${definition.spec.graphSha256}' \
                  --arg target '${r5RustTarget}' \
                  --arg toolchain 'nightly-2023-11-16' \
                  --arg archive 'lib/libmicroblossom_r5_service.a' \
                  --arg archiveSha256 "$archive_sha256" \
                  --arg buildIdentity '${archiveBuildIdentity}' \
                  --argjson vertexCount ${toString definition.spec.vertexNum} \
                  --argjson edgeCount ${toString definition.spec.edgeNum} \
                  --argjson maxDefects ${toString definition.effectiveMaxDefects} \
                  --argjson maxCorrectionEdges ${toString definition.effectiveMaxCorrectionEdges} \
                  --argjson vertexBits "$(jq -er '.graph.vertexBits' \
                    ${graphContractRoot}/graph-service-contract.json)" \
                  --argjson nodeCapacity "$(jq -er '.graph.nodeCapacity' \
                    ${graphContractRoot}/graph-service-contract.json)" \
                  --argjson graphRodataBytes "$(jq -er '.graph.materializer.rodataBytes' \
                    ${graphContractRoot}/graph-service-contract.json)" \
                  --argjson materializerWorkspaceBytes "$(jq -er \
                    '.graph.materializer.projectedWorkspaceBytes' \
                    ${graphContractRoot}/graph-service-contract.json)" \
                  '{api:$api, graphId:$graphId, graphSha256:$graphSha256,
                    target:$target, toolchain:$toolchain, archive:$archive,
                    archiveSha256:$archiveSha256, buildIdentity:$buildIdentity,
                    vertexCount:$vertexCount, edgeCount:$edgeCount,
                    vertexBits:$vertexBits, nodeCapacity:$nodeCapacity,
                    maxDefects:$maxDefects, maxCorrectionEdges:$maxCorrectionEdges,
                    materializer:{algorithm:"bounded-csr-dijkstra-xor-edge-bitmap",
                      graphRodataBytes:$graphRodataBytes,
                      projectedWorkspaceBytes:$materializerWorkspaceBytes},
                    features:[], defaultFeatures:false, serviceModel:false,
                    stackFrames:{path:"analysis/rust-stack-sizes.txt",
                      scope:"compiler-emitted-fixed-frames-only"},
                    allocator:false, unwind:false, panic:"abort"}' \
                  > "$out/metadata/rust-service.json"
                (cd "$out" && find analysis include lib metadata share -type f \
                  ! -name artifacts.sha256 -print0 | sort -z | xargs -0 sha256sum) \
                  > "$out/metadata/artifacts.sha256"
              '';
              passthru.microblossomR5RustService = {
                api = "microblossom.r5-rust-service/v1";
                target = r5RustTarget;
                toolchain = "nightly-2023-11-16";
                inherit archiveBuildIdentity;
                archiveSha256 = definition.rustArchiveSha256;
                archive = "lib/libmicroblossom_r5_service.a";
                header = "include/microblossom_rust_service.h";
                graphModule = "share/microblossom/r5-service/microblossom_graph.rs";
              };
              meta = {
                description = "Graph-bound no-std soft-float R5 service archive";
                license = lib.licenses.mit;
                platforms = systems;
              };
            };
          r5RustServices = lib.mapAttrs mkR5RustService (
            lib.filterAttrs (_name: definition: definition.rustService) r5ServiceDefinitions
          );
          mkR5RustMaterializerTest =
            name: definition:
            let
              graphContract = graphServiceContracts.${name};
              graphContractRoot =
                "${graphContract}/share/microblossom/r5-service/${definition.spec.id}-v1";
              graphModule = "${graphContractRoot}/microblossom_graph.rs";
              rtlRoot = "${graphMatrix.${definition.spec.id}.rtl}/share/microblossom/rtl/${definition.spec.id}-v1";
              expectedCases = if name == "circuit-level-d3" then 7 else 6;
            in
            craneLib.mkCargoDerivation {
              pname = "${definition.outputPrefix}-r5-rust-materializer-test";
              version = "0.1.0";
              src = r5RustSource;
              cargoLock = ./src/cpu/r5-service-rust/Cargo.lock;
              cargoArtifacts = null;
              strictDeps = true;
              nativeBuildInputs = [ pkgs.python3 ];
              postUnpack = ''
                sourceRoot="$sourceRoot/src/cpu/r5-service-rust"
              '';
              MICROBLOSSOM_R5_GRAPH_MODULE = graphModule;
              MICROBLOSSOM_SKIP_CBINDGEN = "1";
              RUSTFLAGS = "--remap-path-prefix=${r5RustSource}=.";
              buildPhaseCargoCommand = ''
                export MICROBLOSSOM_R5_ACTUAL_HARDWARE_INFO_WORD_1="$(${pkgs.python3}/bin/python3 - ${rtlRoot}/MicroBlossomBus.v <<'PY'
                import re
                import sys
                from pathlib import Path

                rtl = Path(sys.argv[1]).read_text()
                fields = re.search(
                    r"assign _zz_rawFactory_readRsp_data_2 = "
                    r"\{\{\{\{\{8'h([0-9a-fA-F]{2}),configurationBits\},"
                    r"8'h([0-9a-fA-F]{2})\},8'h([0-9a-fA-F]{2})\},"
                    r"8'h([0-9a-fA-F]{2})\},8'h([0-9a-fA-F]{2})\};",
                    rtl,
                )
                assert fields is not None, "generated hardware-info word 1 was not found"
                layer_count, instruction_depth, weight_bits, vertex_bits, conflicts = (
                    int(value, 16) for value in fields.groups()
                )
                flag_assignments = re.findall(
                    r"zz_configurationBits\[([0-9]+)\] = 1'b([01]);", rtl
                )
                assert len(flag_assignments) == 7
                flags = sum(int(value) << int(index) for index, value in flag_assignments)
                word = (
                    conflicts
                    | (vertex_bits << 8)
                    | (weight_bits << 16)
                    | (instruction_depth << 24)
                    | (flags << 32)
                    | (layer_count << 48)
                )
                print(f"{word:016x}")
                PY
                )"
                printf '%s\n' "$MICROBLOSSOM_R5_ACTUAL_HARDWARE_INFO_WORD_1" \
                  > actual-hardware-info-word-1.txt
                cargo test --profile release --locked --lib --no-run
              '';
              doCheck = true;
              checkPhaseCargoCommand = ''
                cargo test --profile release --locked --lib -- --nocapture 2>&1 \
                  | tee materializer-test.log
                grep -F \
                  'MICROBLOSSOM_R5_MATERIALIZER_PASS graph=${definition.spec.id}-v1 cases=${toString expectedCases}' \
                  materializer-test.log >/dev/null
                grep -F \
                  "MICROBLOSSOM_R5_HARDWARE_IDENTITY_PASS graph=${definition.spec.id}-v1 word_1=0x$MICROBLOSSOM_R5_ACTUAL_HARDWARE_INFO_WORD_1 layers=" \
                  materializer-test.log >/dev/null
              '';
              doInstallCargoArtifacts = false;
              installPhaseCommand = ''
                mkdir -p "$out"
                cp actual-hardware-info-word-1.txt materializer-test.log "$out/"
                cp ${graphModule} "$out/microblossom_graph.rs"
              '';
              meta = {
                description = "Native fixed-capacity correction materializer test for ${definition.spec.id}";
                license = lib.licenses.mit;
                platforms = systems;
              };
            };
          r5RustMaterializerTests = lib.mapAttrs mkR5RustMaterializerTest (
            lib.filterAttrs (_name: definition: definition.rustService) r5ServiceDefinitions
          );
          mkR5RustServiceModelLibrary =
            name: definition:
            let
              graphContract = graphServiceContracts.${name};
              graphContractRoot =
                "${graphContract}/share/microblossom/r5-service/${definition.spec.id}-v1";
              graphModule = "${graphContractRoot}/microblossom_graph.rs";
            in
            craneLib.mkCargoDerivation {
              pname = "${definition.outputPrefix}-r5-rust-service-model-library";
              version = "0.1.0";
              src = r5RustSource;
              cargoLock = ./src/cpu/r5-service-rust/Cargo.lock;
              cargoArtifacts = null;
              strictDeps = true;
              postUnpack = ''
                sourceRoot="$sourceRoot/src/cpu/r5-service-rust"
              '';
              MICROBLOSSOM_R5_GRAPH_MODULE = graphModule;
              MICROBLOSSOM_SKIP_CBINDGEN = "1";
              RUSTFLAGS = "--remap-path-prefix=${r5RustSource}=.";
              buildPhaseCargoCommand =
                "cargo build --profile release --locked --lib --features service-model";
              doCheck = false;
              doInstallCargoArtifacts = false;
              installPhaseCommand = ''
                mkdir -p "$out/lib"
                cp target/release/libmicroblossom_r5_service.a "$out/lib/"
              '';
              meta = {
                description = "Native production service plus software accelerator model for ${definition.spec.id}";
                license = lib.licenses.mit;
                platforms = systems;
              };
            };
          r5RustServiceModelLibraries = lib.mapAttrs mkR5RustServiceModelLibrary (
            lib.filterAttrs (_name: definition: definition.rustService) r5ServiceDefinitions
          );
          mkGraphServiceContract =
            definition:
            let
              fixture = graphMatrix.${definition.spec.id}.fixture;
              fixtureRoot = "${fixture}/share/microblossom/fixtures/${definition.spec.id}-v1";
              capacityArguments = lib.optionals definition.legacyCompatible [
                "--max-defects ${toString definition.effectiveMaxDefects}"
                "--max-correction-edges ${toString definition.effectiveMaxCorrectionEdges}"
              ];
            in
            pkgs.runCommand "${definition.outputPrefix}-r5-service-contract"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.python3
                ];
                passthru = {
                  inherit (definition)
                    requestPayloadBytes
                    responsePayloadBytes
                    requestPacketBytes
                    responsePacketBytes
                    requestBeats
                    responseBeats
                    ;
                  graphSha256 = definition.spec.graphSha256;
                  graphId = definition.spec.id;
                  maxPacketBeats = lib.max definition.requestBeats definition.responseBeats;
                };
              }
              ''
                root="$out/share/microblossom/r5-service/${definition.spec.id}-v1"
                python3 ${./src/qshell/tools/build_graph_service_contract.py} \
                  --graph ${fixtureRoot}/graph.json \
                  --manifest ${fixtureRoot}/manifest.json \
                  --output "$root" \
                  ${lib.concatStringsSep " \\\n                  " capacityArguments}
                contract="$root/graph-service-contract.json"
                header="$root/microblossom_graph_contract.h"
                rust_module="$root/microblossom_graph.rs"
                test -s "$contract"
                test -s "$header"
                test -s "$rust_module"
                test "$(jq -er '.graph.sha256' "$contract")" = ${definition.spec.graphSha256}
                test "$(jq -er '.graph.vertexCount' "$contract")" = ${toString definition.spec.vertexNum}
                test "$(jq -er '.graph.edgeCount' "$contract")" = ${toString definition.spec.edgeNum}
                test "$(jq -er '.graph.virtualVertexCount' "$contract")" = ${toString definition.spec.virtualVertexNum}
                test "$(jq -er '.protocol.request.packetBytes' "$contract")" = ${toString definition.requestPacketBytes}
                test "$(jq -er '.protocol.response.packetBytes' "$contract")" = ${toString definition.responsePacketBytes}
                test "$(jq -er '.protocol.request.beats' "$contract")" = ${toString definition.requestBeats}
                test "$(jq -er '.protocol.response.beats' "$contract")" = ${toString definition.responseBeats}
                python3 - ${fixtureRoot}/graph.json "$contract" "$header" "$rust_module" <<'PY'
                import json
                import re
                import sys

                graph = json.load(open(sys.argv[1], encoding="utf-8"))
                contract = json.load(open(sys.argv[2], encoding="utf-8"))
                header = open(sys.argv[3], encoding="utf-8").read()
                rust_module = open(sys.argv[4], encoding="utf-8").read()
                bitmap = bytearray((graph["vertex_num"] + 7) // 8)
                for vertex in graph["virtual_vertices"]:
                    bitmap[vertex // 8] |= 1 << (vertex % 8)
                assert contract["graph"]["virtualVertices"] == graph["virtual_vertices"]
                assert contract["graph"]["virtualVertexBitmapHex"] == bitmap.hex()
                layer_fusion = graph.get("layer_fusion")
                num_layers = 0 if layer_fusion is None else layer_fusion["num_layers"]
                assert contract["graph"]["numLayers"] == num_layers
                assert f"#define MICROBLOSSOM_GRAPH_NUM_LAYERS UINT8_C({num_layers})" in header
                assert f"pub const NUM_LAYERS: u8 = {num_layers};" in rust_module
                initializer = re.search(
                    r"microblossom_virtual_vertex_bitmap\[[0-9]+\] = \{([^}]*)\}",
                    header,
                )
                assert initializer is not None
                header_bitmap = bytes(
                    int(value, 16)
                    for value in re.findall(r"UINT8_C\(0x([0-9a-f]{2})\)", initializer.group(1))
                )
                assert header_bitmap == bitmap
                vertex_bits = max(5, (2 * graph["vertex_num"] - 1).bit_length())
                assert contract["graph"]["vertexBits"] == vertex_bits
                assert contract["graph"]["nodeCapacity"] == 1 << vertex_bits
                assert contract["graph"]["defectNodeCapacity"] == 1 << (vertex_bits - 1)
                assert contract["graph"]["materializer"]["arcCount"] == 2 * len(graph["weighted_edges"])
                assert f'pub const GRAPH_SHA256: &str = "{contract["graph"]["sha256"]}";' in rust_module
                assert f"pub const VERTEX_BITS: usize = {vertex_bits};" in rust_module
                assert "pub static WEIGHTED_EDGES" in rust_module
                assert "pub static CSR_ROW_OFFSETS" in rust_module
                assert "pub static CSR_EDGE_INDICES" in rust_module
                PY
              '';
          graphServiceContracts = lib.mapAttrs (
            _name: definition: mkGraphServiceContract definition
          ) r5ServiceDefinitions;

          r5PlatformContract = {
            api = "coyote.v80-r5-platform/v1";
            xilinxVersion = doctor.boards.v80.xilinxVersion;
            processor = "psv_cortexr5_0";
            core = "r5-0";
            hardwareContractSha256 = builtins.hashFile "sha256" (
              coyote + "/scripts/v80-r5-platform-export.cmake.in"
            );
            entry = "0x00000000";
            atcm = {
              base = "0x00000000";
              bytes = "0x00010000";
            };
            btcm = {
              base = "0x00020000";
              bytes = "0x00010000";
            };
            scratch = {
              base = "0x80000000";
              bytes = "0x00001000";
            };
            bootState = {
              coldResetRequired = true;
              armExceptions = true;
              littleEndian = true;
              cachesDisabled = true;
              delayedHandoff = true;
              warmRehandoffSupported = false;
              tcmEcc = "platform-managed-unverified";
            };
            vectorsBytes = 32;
            statusAddress = "0x00020000";
            statusBytes = 64;
            requiredSymbols = [
              "_start"
              "r5_main"
              "r5_exception_trap"
              "r5_internal_trap"
            ];
            absoluteSymbols = {
              __stack_floor = "0x0002c800";
              __svc_stack_top = "0x0002f800";
              __abt_stack_top = "0x0002fa00";
              __und_stack_top = "0x0002fc00";
              __irq_stack_top = "0x0002fe00";
              __fiq_stack_top = "0x00030000";
            };
          };
          r5ServiceIdentityFiles = [
            ./src/cpu/r5-service/Makefile
            ./src/cpu/r5-service/check_r5_binary.py
            ./src/cpu/r5-service/linker.ld
            ./src/cpu/r5-service/service.c
            ./src/cpu/r5-service/service.h
            ./src/cpu/r5-service/qshell_abi_generated.h
            ./src/cpu/r5-service/startup.S
            ./src/qshell/tools/build_graph_service_contract.py
            "${coyote}/sw/firmware/coprocessor/provider.c"
            "${coyote}/sw/firmware/coprocessor/provider.h"
            "${coyote}/sw/firmware/coprocessor/provider_internal.h"
            "${coyote}/sw/firmware/coprocessor/provider_platform.h"
            "${coyote}/sw/firmware/coprocessor/provider_protocol.h"
            "${coyote}/sw/firmware/coprocessor/provider_transport_r5.c"
          ];
          mkR5FirmwareEntry =
            name: definition:
            let
              graphContract = graphServiceContracts.${name};
              contractRoot = "${graphContract}/share/microblossom/r5-service/${definition.spec.id}-v1";
              rustService = if definition.rustService then r5RustServices.${name} else null;
              runtimeIdentity = builtins.hashString "sha256" (
                lib.concatStringsSep "\n" (
                  [
                    "microblossom-graph-r5-service-runtime-v1"
                    definition.spec.graphSha256
                    (builtins.toJSON {
                      inherit (definition)
                        effectiveMaxDefects
                        effectiveMaxCorrectionEdges
                        requestPacketBytes
                        responsePacketBytes
                        requestBeats
                        responseBeats
                        ;
                    })
                    (builtins.toJSON r5PlatformContract)
                  ]
                  ++ lib.optionals (rustService != null) [
                    "microblossom-r5-rust-service-staticlib"
                    rustService.microblossomR5RustService.archiveBuildIdentity
                    (if definition.rustArchiveSha256 == null then
                      "archive-sha256-pending"
                    else
                      definition.rustArchiveSha256)
                  ]
                  ++ map (path: builtins.hashFile "sha256" path) r5ServiceIdentityFiles
                )
              );
              identityFlags = lib.concatStringsSep " " (
                lib.genList (
                  index:
                  "-DCYT_PROVIDER_IDENTITY_WORD_${toString index}=0x${
                    builtins.substring (index * 8) 8 runtimeIdentity
                  }"
                ) 8
              );
              source = pkgs.runCommand "${definition.outputPrefix}-r5-service-source" { } ''
                mkdir -p "$out/coyote/sw/firmware" "$out/metadata"
                cp -r ${./src/cpu/r5-service}/. "$out/"
                cp ${contractRoot}/microblossom_graph_contract.h "$out/"
                cp ${contractRoot}/microblossom_graph.rs "$out/metadata/"
                cp ${contractRoot}/graph-service-contract.json "$out/metadata/"
                cp -r ${coyote}/sw/firmware/coprocessor "$out/coyote/sw/firmware/"
                ${lib.optionalString (rustService != null) ''
                  mkdir -p "$out/rust-service"
                  cp ${rustService}/lib/libmicroblossom_r5_service.a \
                    "$out/rust-service/"
                  cp ${rustService}/include/microblossom_rust_service.h "$out/"
                  cp ${rustService}/metadata/rust-service.json \
                    "$out/metadata/rust-service.json"
                ''}
              '';
              firmwareAbi = "microblossom-${definition.spec.id}-coprocessor-v1";
              firmwareBase = coyoteNix.lib.mkCoyoteR5FirmwarePackage {
                inherit pkgs;
                tools = coyoteTools;
                pname = "${definition.outputPrefix}-r5-service-firmware";
                src = source;
                platformContract = r5PlatformContract;
                inherit firmwareAbi runtimeIdentity;
                extraMakeFlags = [
                  "COYOTE_ROOT=./coyote"
                  "EXTRA_CFLAGS=${identityFlags}${lib.optionalString (rustService != null) " -DMICROBLOSSOM_PRODUCTION_FIRMWARE=1"}"
                ]
                ++ lib.optionals (rustService != null) [
                  "RUST_SERVICE_ARCHIVE=rust-service/libmicroblossom_r5_service.a"
                ];
                extraAttrs = lib.optionalAttrs (rustService != null) {
                  postCheck = ''
                    python3 check_r5_binary.py \
                      --kind elf --input build/r5.elf \
                      --require-function microblossom_rust_service_decode \
                      --require-object microblossom_rust_service_contract \
                      --output r5-binary-policy.json
                    grep -F 'rust-service/libmicroblossom_r5_service.a' build/r5.map >/dev/null
                    armr5-none-eabi-nm -a build/r5.elf > final-symbols.txt
                    if grep -E \
                      'microblossom_rust_software_accelerator_|fusion_blossom|dual_module_comb' \
                      final-symbols.txt; then
                      echo 'target ELF contains a test-only service-model symbol' >&2
                      exit 1
                    fi
                  '';
                  postInstall = ''
                    cp r5-binary-policy.json "$out/metadata/binary-policy.json"
                    cp final-symbols.txt "$out/analysis/final-symbols.txt"
                    mkdir -p "$out/analysis/c-stack-usage"
                    cp build/*.su "$out/analysis/c-stack-usage/"
                    cp metadata/rust-service.json "$out/metadata/rust-service.json"
                    archive_sha256="$(sha256sum \
                      rust-service/libmicroblossom_r5_service.a | cut -d' ' -f1)"
                    recorded_archive_sha256="$(jq -er '.archiveSha256' \
                      metadata/rust-service.json)"
                    test "$archive_sha256" = "$recorded_archive_sha256"
                    jq --arg archiveSha256 "$archive_sha256" \
                      --arg archiveBuildIdentity \
                        '${rustService.microblossomR5RustService.archiveBuildIdentity}' \
                      --arg target '${r5RustTarget}' \
                      '. + {rustService: {
                        api: "microblossom.r5-rust-service/v1",
                        target: $target,
                        archiveSha256: $archiveSha256,
                        archiveBuildIdentity: $archiveBuildIdentity,
                        decodeEnabled: true
                      }}' \
                      "$out/metadata/firmware.json" > "$out/metadata/firmware.json.tmp"
                    mv "$out/metadata/firmware.json.tmp" "$out/metadata/firmware.json"
                    (cd "$out" && find firmware analysis metadata -type f \
                      ! -name artifacts.sha256 -print0 | sort -z | xargs -0 sha256sum) \
                      > "$out/metadata/artifacts.sha256"
                  '';
                };
              };
              firmware = firmwareBase.overrideAttrs (old: {
                passthru = (old.passthru or { }) // {
                  microblossomGraphService = {
                    inherit graphContract runtimeIdentity firmwareAbi rustService;
                    graphSha256 = definition.spec.graphSha256;
                    graphId = definition.spec.id;
                    inherit (definition)
                      requestPacketBytes
                      responsePacketBytes
                      requestBeats
                      responseBeats
                      ;
                  };
                };
              });
              runnerPackage =
                if definition.legacyCompatible then
                  microblossomQshellProtocol
                else
                  pkgs.writeShellApplication {
                    name = definition.runnerBinary;
                    runtimeInputs = [ pkgs.jq ];
                    text = ''
                      contract=${contractRoot}/graph-service-contract.json
                      exec ${microblossomQshellProtocol}/bin/microblossom_coprocessor \
                        --graph-id "$(jq -er '.graph.sha256' "$contract")" \
                        --vertices "$(jq -er '.graph.vertexCount' "$contract")" \
                        --edges "$(jq -er '.graph.edgeCount' "$contract")" \
                        --virtual-vertices \
                          "$(jq -er '.graph.virtualVertices | map(tostring) | join(",")' "$contract")" \
                        "$@"
                    '';
                    meta = {
                      description = "Frozen ${definition.spec.id} MicroBlossom co-processor runner";
                      license = lib.licenses.mit;
                      platforms = systems;
                      mainProgram = definition.runnerBinary;
                    };
                  };
            in
            definition
            // {
              inherit
                graphContract
                contractRoot
                runtimeIdentity
                identityFlags
                source
                firmwareAbi
                firmware
                rustService
                runnerPackage
                ;
            };
          r5FirmwareEntries = lib.mapAttrs mkR5FirmwareEntry r5ServiceDefinitions;
          legacyR5FirmwareEntry = r5FirmwareEntries."legacy-d3";
          r5ServiceRuntimeIdentity = legacyR5FirmwareEntry.runtimeIdentity;
          r5ServiceSource = legacyR5FirmwareEntry.source;
          r5ServiceFirmware = legacyR5FirmwareEntry.firmware;

          coprocessorContractTemplate = ./src/qshell/contracts/microblossom-d3-coprocessor.template.json;

          microblossomV80Floorplan = pkgs.runCommand "microblossom-v80-application-floorplan.xdc" { } ''
            cp ${./src/qshell/app/src/microblossom-coprocessor/microblossom_v80_floorplan_extension.xdc} \
              "$out"
          '';

          d3QshellCoprocessorAppHwSource =
            pkgs.runCommand "microblossom-d3-qshell-coprocessor-app-hw-source" { }
              ''
                cp -R ${d3QshellAppHwSource}/. "$out"
                chmod -R u+w "$out"
                mkdir -p "$out/src/microblossom-coprocessor"
                cp ${./src/qshell/app/src/microblossom-coprocessor/vfpga_top.svh} \
                  "$out/src/microblossom-coprocessor/vfpga_top.svh"
                cp ${./src/qshell/rtl/microblossom_coprocessor_mmio.sv} \
                  "$out/src/microblossom/hdl/microblossom_coprocessor_mmio.sv"
                cp ${./src/qshell/rtl/microblossom_coprocessor_application.sv} \
                  "$out/src/microblossom/hdl/microblossom_coprocessor_application.sv"
                mkdir -p "$out/metadata"
                cp ${legacyR5FirmwareEntry.contractRoot}/graph-service-contract.json \
                  "$out/metadata/graph-service-contract.json"
                substituteInPlace "$out/CMakeLists.txt" \
                  --replace-fail \
                    'load_apps(VFPGA_C0_0 "src/microblossom")' \
                    'load_apps(VFPGA_C0_0 "src/microblossom-coprocessor src/microblossom")'
                # validation_checks_hw imports the shell contract, including its
                # base floorplan. Override it afterwards with the composed
                # application floorplan before create_hw renders Tcl.
                sed -i \
                  '/load_apps(/i set(FPLAN_PATH "${microblossomV80Floorplan}")' \
                  "$out/CMakeLists.txt"
                ${pkgs.jq}/bin/jq \
                  '. + {
                    coprocessor: {
                      logicalPort: 0,
                      streamAbi: 1,
                      mmioAbi: 1,
                      applicationMmioAbi: "microblossom-code-capacity-repetition-d3-accelerator-v1",
                      integrationState: "connected",
                      graphServiceContract: "metadata/graph-service-contract.json",
                      requestPacketBytes: 96,
                      responsePacketBytes: 96,
                      requestBeats: 2,
                      responseBeats: 2
                    }
                  }' \
                  "$out/core-manifest.json" > "$out/core-manifest.json.tmp"
                mv "$out/core-manifest.json.tmp" "$out/core-manifest.json"
              '';

          d3QshellCoprocessorApp = coyoteNix.lib.mkCoyoteAppPackage {
            inherit pkgs xilinxShareRoot;
            tools = coyoteTools;
            coyoteRoot = coyote;
            xilinxShell = doctor.xilinxShell;
            hwSource = d3QshellCoprocessorAppHwSource;
            pname = "microblossom-d3-qshell-v80-coprocessor-app";
            board = "v80";
            shellPackage = qshellV80CoprocessorShell;
            cmakeFlags = [
              "-DCYT_DIR:PATH=${coyote}"
              "-DSCLK_F:STRING=333"
              "-DN_COPROCESSOR_PORTS:STRING=1"
              "-DEN_V80_R5_PLATFORM:STRING=0"
              "-DPCIE_GEN:STRING=5"
            ];
            # Match the accepted V80 shell's serialized physical flow; Vivado
            # 2025.1 repeatedly crashed while constructing a parallel router.
            implementation.resources.cores = 1;
            provenance = {
              application = "microblossom-d3-coprocessor-integration";
              graphSha256 = "4b078d3b6c6db24ea9726414569a97b3899be4e532be1c0ebd84b5fa875316c5";
              qshellRecordAbi = qshellAbiSpec.version;
              mbqProtocol = 1;
              coprocessorLogicalPort = 0;
              coprocessorStreamAbi = 1;
              coprocessorMmioAbi = 1;
              provider = "v80-r5-0";
              integrationState = "logical-port-connected";
            };
          };

          d3CoprocessorCompatibilityBundle =
            pkgs.runCommand "microblossom-d3-v80-coprocessor-compatibility-bundle"
              {
                nativeBuildInputs = [ pkgs.python3Packages.jsonschema ];
              }
              ''
                mkdir -p "$out/metadata" "$out/packages"
                python3 ${./src/qshell/tools/build_coprocessor_bundle.py} \
                  --template ${coprocessorContractTemplate} \
                  --graph-contract ${legacyR5FirmwareEntry.contractRoot}/graph-service-contract.json \
                  --schema ${qshellContractSource}/contracts/decoder-contract.schema.json \
                  --abi-spec ${qshellContractSource}/abi/qshell-abi.json \
                  --application-metadata ${d3QshellCoprocessorApp}/metadata/app.json \
                  --firmware-metadata ${r5ServiceFirmware}/metadata/firmware.json \
                  --output "$out" \
                  --qshell-revision ${v80R5QshellRevision} \
                  --coyote-revision ${v80R5CoyoteRevision} \
                  --coyote-nix-revision ${v80R5CoyoteNixRevision} \
                  --implementation-revision ${self.rev or "c17e888982b8641986266be35e8fc0d9c91dcd64"}
                ln -s ${d3QshellCoprocessorApp} "$out/packages/application"
                ln -s ${qshellV80CoprocessorShell} "$out/packages/shell"
                ln -s ${r5ServiceFirmware} "$out/packages/firmware"
                ln -s ${microblossomQshellProtocol} "$out/packages/host-protocol"
                ln -s ${microblossomQshellCoyoteBridge} "$out/packages/coyote-bridge"
                cp ${d3QshellCoprocessorApp}/metadata/app.json "$out/metadata/"
                cp ${r5ServiceFirmware}/metadata/firmware.json "$out/metadata/"
                (cd "$out" && sha256sum decoder-contract.json manifest.json \
                  metadata/app.json metadata/firmware.json) \
                  > "$out/metadata/artifacts.sha256"
              '';

          d3V80R5App =
            pkgs.runCommand "microblossom-d3-v80-r5-app"
              {
                nativeBuildInputs = [ pkgs.jq ];
                passthru = {
                  coyoteTwoStage = d3QshellCoprocessorApp.coyoteTwoStage;
                  qshellPackage = qshellV80CoprocessorShell;
                  applicationPackage = d3QshellCoprocessorApp;
                  firmwarePackage = r5ServiceFirmware;
                };
              }
              ''
                mkdir -p "$out/bitstreams" "$out/firmware" "$out/bin" \
                  "$out/metadata" "$out/packages"
                ln -s ${d3QshellCoprocessorApp}/bitstreams/config_0/vfpga_c0_0.pdi \
                  "$out/bitstreams/microblossom-d3-v80-r5.pdi"
                ln -s ${r5ServiceFirmware}/firmware/r5.elf "$out/firmware/r5.elf"
                ln -s ${microblossomQshellProtocol}/bin/microblossom_d3_coprocessor \
                  "$out/bin/microblossom_d3_coprocessor"
                ln -s ${microblossomQshellCoyoteBridge}/bin/microblossom-qshell-coyote-bridge \
                  "$out/bin/microblossom-qshell-coyote-bridge"
                ln -s ${qshellHostPackage}/bin/qshell "$out/bin/qshell"
                ln -s ${d3QshellCoprocessorApp} "$out/packages/vfpga"
                ln -s ${r5ServiceFirmware} "$out/packages/firmware"
                cp ${d3CoprocessorCompatibilityBundle}/decoder-contract.json "$out/metadata/"
                cp ${d3CoprocessorCompatibilityBundle}/manifest.json "$out/metadata/"
                cp ${d3QshellCoprocessorApp}/metadata/app.json "$out/metadata/"
                cp ${d3QshellCoprocessorApp}/metadata/shell.json "$out/metadata/"
                cp ${r5ServiceFirmware}/metadata/firmware.json "$out/metadata/"
                cat > "$out/README.txt" <<'EOF'
                MicroBlossom d3 V80 R5 application for QShell

                1. Build the matching QShell output qshell-v80-r5-shell-nonstrict; qualify its timing before deployment.
                2. Load bitstreams/microblossom-d3-v80-r5.pdi as the vFPGA application.
                3. Start firmware/r5.elf on the shell's R5 provider.
                4. Use bin/qshell to bind/configure the service and
                   bin/microblossom_d3_coprocessor to run the workload.

                This package contains no QShell implementation output. app.json and shell.json
                identify the exact separately built QShell shell used to route this application.
                EOF
                (cd "$out" && find bitstreams firmware bin metadata \
                  \( -type f -o -type l \) ! -name artifacts.sha256 \
                  | sort | xargs sha256sum) > "$out/metadata/artifacts.sha256"
              '';

          mkCircuitR5ApplicationEntry =
            name:
            let
              service = r5FirmwareEntries.${name};
              inherit (service) spec outputPrefix runnerBinary;
              baseHwSource = graphMatrix.${spec.id}.hwSource;
              hwSource = pkgs.runCommand "${outputPrefix}-qshell-coprocessor-app-hw-source" { } ''
                cp -R ${baseHwSource}/. "$out"
                chmod -R u+w "$out"
                mkdir -p "$out/src/microblossom-coprocessor" "$out/metadata"
                cp ${./src/qshell/app/src/microblossom-coprocessor/vfpga_top.svh} \
                  "$out/src/microblossom-coprocessor/vfpga_top.svh"
                cp ${./src/qshell/rtl/microblossom_coprocessor_mmio.sv} \
                  "$out/src/microblossom/hdl/microblossom_coprocessor_mmio.sv"
                cp ${./src/qshell/rtl/microblossom_coprocessor_application.sv} \
                  "$out/src/microblossom/hdl/microblossom_coprocessor_application.sv"
                cp ${service.contractRoot}/graph-service-contract.json \
                  "$out/metadata/graph-service-contract.json"
                substituteInPlace "$out/CMakeLists.txt" \
                  --replace-fail \
                    'load_apps(VFPGA_C0_0 "src/microblossom")' \
                    'load_apps(VFPGA_C0_0 "src/microblossom-coprocessor src/microblossom")'
                sed -i \
                  '/load_apps(/i set(FPLAN_PATH "${microblossomV80Floorplan}")' \
                  "$out/CMakeLists.txt"
                ${pkgs.jq}/bin/jq \
                  --arg applicationMmioAbi "microblossom-${spec.id}-accelerator-v1" \
                  --arg graphServiceContract "metadata/graph-service-contract.json" \
                  --argjson requestPacketBytes ${toString service.requestPacketBytes} \
                  --argjson responsePacketBytes ${toString service.responsePacketBytes} \
                  --argjson requestBeats ${toString service.requestBeats} \
                  --argjson responseBeats ${toString service.responseBeats} \
                  '. + {
                    coprocessor: {
                      logicalPort: 0,
                      streamAbi: 1,
                      mmioAbi: 1,
                      applicationMmioAbi: $applicationMmioAbi,
                      integrationState: "connected",
                      graphServiceContract: $graphServiceContract,
                      requestPacketBytes: $requestPacketBytes,
                      responsePacketBytes: $responsePacketBytes,
                      requestBeats: $requestBeats,
                      responseBeats: $responseBeats
                    }
                  }' \
                  "$out/core-manifest.json" > "$out/core-manifest.json.tmp"
                mv "$out/core-manifest.json.tmp" "$out/core-manifest.json"
              '';
              application = coyoteNix.lib.mkCoyoteAppPackage {
                inherit pkgs xilinxShareRoot;
                tools = coyoteTools;
                coyoteRoot = coyote;
                xilinxShell = doctor.xilinxShell;
                inherit hwSource;
                pname = "${outputPrefix}-qshell-v80-coprocessor-app";
                requiresVitisHls = false;
                board = "v80";
                shellPackage = qshellV80CoprocessorShell;
                cmakeFlags = [
                  "-DCYT_DIR:PATH=${coyote}"
                  "-DSCLK_F:STRING=333"
                  "-DN_COPROCESSOR_PORTS:STRING=1"
                  "-DEN_V80_R5_PLATFORM:STRING=0"
                  "-DPCIE_GEN:STRING=5"
                  "-DEN_TIMING_CHECK:BOOL=OFF"
                ];
                implementation = {
                  resources.cores = 1;
                  enforceTiming = false;
                };
                provenance = {
                  application = "microblossom-${spec.id}-coprocessor-integration";
                  graphSha256 = spec.graphSha256;
                  qshellRecordAbi = qshellAbiSpec.version;
                  mbqProtocol = 1;
                  coprocessorLogicalPort = 0;
                  coprocessorStreamAbi = 1;
                  coprocessorMmioAbi = 1;
                  provider = "v80-r5-0";
                  integrationState = "logical-port-connected";
                  requestBeats = service.requestBeats;
                  responseBeats = service.responseBeats;
                };
              };
              compatibilityBundle =
                pkgs.runCommand "${outputPrefix}-v80-coprocessor-compatibility-bundle"
                  {
                    nativeBuildInputs = [ pkgs.python3Packages.jsonschema ];
                  }
                  ''
                    mkdir -p "$out/metadata" "$out/packages"
                    python3 ${./src/qshell/tools/build_coprocessor_bundle.py} \
                      --template ${coprocessorContractTemplate} \
                      --graph-contract ${service.contractRoot}/graph-service-contract.json \
                      --schema ${qshellContractSource}/contracts/decoder-contract.schema.json \
                      --abi-spec ${qshellContractSource}/abi/qshell-abi.json \
                      --application-metadata ${application}/metadata/app.json \
                      --firmware-metadata ${service.firmware}/metadata/firmware.json \
                      --output "$out" \
                      --qshell-revision ${v80R5QshellRevision} \
                      --coyote-revision ${v80R5CoyoteRevision} \
                      --coyote-nix-revision ${v80R5CoyoteNixRevision} \
                      --implementation-revision ${self.rev or "c17e888982b8641986266be35e8fc0d9c91dcd64"}
                    ln -s ${application} "$out/packages/application"
                    ln -s ${qshellV80CoprocessorShell} "$out/packages/shell"
                    ln -s ${service.firmware} "$out/packages/firmware"
                    ln -s ${service.graphContract} "$out/packages/graph-contract"
                    ln -s ${microblossomQshellProtocol} "$out/packages/host-protocol"
                    ln -s ${microblossomQshellCoyoteBridge} "$out/packages/coyote-bridge"
                    cp ${application}/metadata/app.json "$out/metadata/"
                    cp ${service.firmware}/metadata/firmware.json "$out/metadata/"
                    cp ${service.contractRoot}/graph-service-contract.json "$out/metadata/"
                    (cd "$out" && sha256sum decoder-contract.json manifest.json \
                      metadata/app.json metadata/firmware.json \
                      metadata/graph-service-contract.json) \
                      > "$out/metadata/artifacts.sha256"
                  '';
              v80R5App =
                pkgs.runCommand "${outputPrefix}-v80-r5-app"
                  {
                    nativeBuildInputs = [ pkgs.jq ];
                    passthru = {
                      coyoteTwoStage = application.coyoteTwoStage;
                      qshellPackage = qshellV80CoprocessorShell;
                      applicationPackage = application;
                      firmwarePackage = service.firmware;
                      graphContractPackage = service.graphContract;
                    };
                  }
                  ''
                    mkdir -p "$out/bitstreams" "$out/firmware" "$out/bin" \
                      "$out/metadata" "$out/packages"
                    ln -s ${application}/bitstreams/config_0/vfpga_c0_0.pdi \
                      "$out/bitstreams/${spec.id}-v80-r5.pdi"
                    ln -s ${service.firmware}/firmware/r5.elf "$out/firmware/r5.elf"
                    ln -s ${service.runnerPackage}/bin/${runnerBinary} \
                      "$out/bin/${runnerBinary}"
                    ln -s ${microblossomQshellProtocol}/bin/microblossom_coprocessor \
                      "$out/bin/microblossom_coprocessor"
                    ln -s ${microblossomQshellCoyoteBridge}/bin/microblossom-qshell-coyote-bridge \
                      "$out/bin/microblossom-qshell-coyote-bridge"
                    ln -s ${qshellHostPackage}/bin/qshell "$out/bin/qshell"
                    ln -s ${application} "$out/packages/vfpga"
                    ln -s ${service.firmware} "$out/packages/firmware"
                    ln -s ${service.graphContract} "$out/packages/graph-contract"
                    cp ${compatibilityBundle}/decoder-contract.json "$out/metadata/"
                    cp ${compatibilityBundle}/manifest.json "$out/metadata/"
                    cp ${application}/metadata/app.json "$out/metadata/"
                    cp ${application}/metadata/shell.json "$out/metadata/"
                    cp ${service.firmware}/metadata/firmware.json "$out/metadata/"
                    cp ${service.contractRoot}/graph-service-contract.json "$out/metadata/"
                    cat > "$out/README.txt" <<EOF
                    MicroBlossom ${spec.id} V80 R5 application for QShell

                    This graph-specific package contains ${toString service.requestBeats}-beat
                    requests, ${toString service.responseBeats}-beat responses, the independently
                    packaged R5 firmware and vFPGA application, and their immutable contracts.
                    Qualify timing and deploy the matching qshell-v80-r5-shell-nonstrict separately, load
                    bitstreams/${spec.id}-v80-r5.pdi, start firmware/r5.elf, bind the exact
                    provider generation, and run bin/${runnerBinary} through the packaged bridge.
                    EOF
                    (cd "$out" && find bitstreams firmware bin metadata \
                      \( -type f -o -type l \) ! -name artifacts.sha256 \
                      | sort | xargs sha256sum) > "$out/metadata/artifacts.sha256"
                  '';
            in
            service
            // {
              inherit
                hwSource
                application
                compatibilityBundle
                v80R5App
                ;
            };
          circuitR5Applications = lib.genAttrs [
            "circuit-level-d3"
            "circuit-level-d9"
          ] mkCircuitR5ApplicationEntry;

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
              description = "One-sided Coyote beat bridge for MicroBlossom current QSH2 records";
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
                export PYTHONPATH=${./src/qshell/host}
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

          circuitR5Packages = lib.foldl' (
            packages: service:
            let
              prefix = service.outputPrefix;
            in
            packages
            // {
              "${prefix}-r5-service-contract" = service.graphContract;
              "${prefix}-r5-service-source" = service.source;
              "${prefix}-r5-rust-service" = service.rustService;
              "${prefix}-r5-rust-materializer-test" =
                r5RustMaterializerTests.${service.key};
              "${prefix}-r5-rust-service-model-library" =
                r5RustServiceModelLibraries.${service.key};
              "${prefix}-r5-service-firmware" = service.firmware;
              "${prefix}-coprocessor-run" = service.runnerPackage;
              "${prefix}-qshell-coprocessor-app-hw-source" = service.hwSource;
              "${prefix}-qshell-v80-coprocessor-app" = service.application;
              "${prefix}-v80-coprocessor-compatibility-bundle" = service.compatibilityBundle;
              "${prefix}-v80-r5-app" = service.v80R5App;
              "${prefix}-v80-r5-app-synth" = service.application.coyoteTwoStage.stages.synth;
              "${prefix}-v80-r5-app-routed" = service.application.coyoteTwoStage.stages.routed;
              "${prefix}-v80-r5-firmware" = service.firmware;
            }
          ) { } (lib.attrValues circuitR5Applications);

          updateQshellAbi = pkgs.writeShellApplication {
            name = "update-qshell-abi";
            runtimeInputs = [
              pkgs.git
              pkgs.python3
            ];
            text = ''
              root="$(git rev-parse --show-toplevel)"
              python3 "$root/src/qshell/tools/generate_qshell_abi.py" \
                --spec ${qshellContractSource}/abi/qshell-abi.json \
                --rust-out "$root/src/qshell/protocol/src/qshell_abi_generated.rs" \
                --c-out "$root/src/cpu/r5-service/qshell_abi_generated.h" \
                --python-out "$root/src/qshell/host/qshell_abi_generated.py"
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
          microblossom-d3-qshell-coprocessor-app-hw-source = d3QshellCoprocessorAppHwSource;
          microblossom-d3-qshell-simulation-hw-source = d3QshellSimulationHwSource;
          microblossom-d3-qshell-u280-sim = d3QshellSimulationPackages."microblossom-d3-qshell-u280-sim";
          microblossom-d3-qshell-v80-sim = d3QshellSimulationPackages."microblossom-d3-qshell-v80-sim";
          qshell-u280-shell = qshellU280Shell;
          qshell-u280-shell-synth = qshellU280Shell.coyoteTwoStage.stages.synth;
          microblossom-d3-qshell-u280-app = d3QshellApps.u280;
          microblossom-d3-qshell-v80-app = d3QshellApps.v80;
          microblossom-d3-qshell-v80-coprocessor-app = d3QshellCoprocessorApp;
          microblossom-d3-r5-service-contract = legacyR5FirmwareEntry.graphContract;
          microblossom-d3-r5-service-source = r5ServiceSource;
          microblossom-d3-r5-service-firmware = r5ServiceFirmware;
          microblossom-d3-v80-coprocessor-compatibility-bundle = d3CoprocessorCompatibilityBundle;
          microblossom-d3-v80-r5-app = d3V80R5App;
          microblossom-d3-v80-r5-app-synth = d3QshellCoprocessorApp.coyoteTwoStage.stages.synth;
          microblossom-d3-v80-r5-app-routed = d3QshellCoprocessorApp.coyoteTwoStage.stages.routed;
          microblossom-d3-v80-r5-firmware = r5ServiceFirmware;
          microblossom-d3-qshell-u280-app-synth = d3QshellApps.u280.coyoteTwoStage.stages.synth;
          microblossom-d3-qshell-v80-app-synth = d3QshellApps.v80.coyoteTwoStage.stages.synth;
          microblossom-d3-qshell-v80-coprocessor-app-synth =
            d3QshellCoprocessorApp.coyoteTwoStage.stages.synth;
          update-qshell-abi = updateQshellAbi;
          verilator-5_014 = verilator_5_014;
        }
        // graphMatrixPackages
        // circuitR5Packages
        // coyoteDriverPackages
      );

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = pkgs.lib;
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
          qshellCoprocessorAppHwSource =
            self.packages.${system}.microblossom-d3-qshell-coprocessor-app-hw-source;
          qshellCoprocessorApp = self.packages.${system}.microblossom-d3-qshell-v80-coprocessor-app;
          qshellSimulationHwSource = self.packages.${system}.microblossom-d3-qshell-simulation-hw-source;
          qshellXdbBridge = self.packages.${system}.microblossom-qshell-u280-xdb-bridge;
          qshellU280Simulation = self.packages.${system}.microblossom-d3-qshell-u280-sim;
          qshellAbiSource = qshell.lib.${system}.qshellAbiSource;
          qshellContractSource = qshell.lib.${system}.qshellContractSource;
          qshellAbiSpec = builtins.fromJSON (builtins.readFile "${qshellContractSource}/abi/qshell-abi.json");
          graphSpecs = import ./nix/microblossom-graph-specs.nix;
          graphOutputNames = lib.concatMap (
            spec:
            let
              prefix = "microblossom-${spec.id}";
            in
            [
              "${prefix}-graph"
              "${prefix}-rtl"
              "${prefix}-qshell-core"
              "${prefix}-qshell-app-hw-source"
              "${prefix}-qshell-u280-app"
              "${prefix}-qshell-u280-app-synth"
              "${prefix}-qshell-v80-app"
              "${prefix}-qshell-v80-app-synth"
            ]
          ) graphSpecs;
          graphOutputsPresent = lib.all (
            name: builtins.hasAttr name self.packages.${system}
          ) graphOutputNames;
          r5ServiceCases = [
            {
              name = "legacy-d3";
              graphId = "code-capacity-repetition-d3";
              packagePrefix = "microblossom-d3";
              graphSha256 = "4b078d3b6c6db24ea9726414569a97b3899be4e532be1c0ebd84b5fa875316c5";
              requestPayloadBytes = 48;
              responsePayloadBytes = 48;
              requestPacketBytes = 96;
              responsePacketBytes = 96;
              requestBeats = 2;
              responseBeats = 2;
              exactCapacity = false;
              rustService = false;
            }
            {
              name = "circuit-d3";
              graphId = "circuit-level-d3";
              packagePrefix = "microblossom-circuit-level-d3";
              graphSha256 = "3e6bfdfeb3cfdb3d47bf29c5da334d84849aacfc548e0145b8db60d7f992b019";
              requestPayloadBytes = 64;
              responsePayloadBytes = 122;
              requestPacketBytes = 112;
              responsePacketBytes = 170;
              requestBeats = 2;
              responseBeats = 3;
              exactCapacity = true;
              rustService = true;
            }
            {
              name = "circuit-d9";
              graphId = "circuit-level-d9";
              packagePrefix = "microblossom-circuit-level-d9";
              graphSha256 = "9582b1c0539c72a7ea76e1a7ca7290df36ff89f8e84f53f65f77d86899bba41a";
              requestPayloadBytes = 760;
              responsePayloadBytes = 3518;
              requestPacketBytes = 808;
              responsePacketBytes = 3566;
              requestBeats = 13;
              responseBeats = 56;
              exactCapacity = true;
              rustService = true;
            }
          ];
          r5CasePackages =
            service:
            let
              prefix = service.packagePrefix;
            in
            service
            // {
              contract = self.packages.${system}."${prefix}-r5-service-contract";
              source = self.packages.${system}."${prefix}-r5-service-source";
              firmware = self.packages.${system}."${prefix}-r5-service-firmware";
              rustArchive =
                if service.rustService then
                  self.packages.${system}."${prefix}-r5-rust-service"
                else
                  null;
              rustModelLibrary =
                if service.rustService then
                  self.packages.${system}."${prefix}-r5-rust-service-model-library"
                else
                  null;
            };
          r5Services = map r5CasePackages r5ServiceCases;
          r5ServiceByName = name: lib.findFirst (service: service.name == name) (throw "missing R5 service case") r5Services;
          mkR5ServiceModelCheck =
            service:
            let
              contractRoot = "${service.contract}/share/microblossom/r5-service/${service.graphId}-v1";
              rustModelLibrary = service.rustModelLibrary;
              decoderFlags =
                if service.rustService then
                  "-DMICROBLOSSOM_RUST_DECODER_LINKED=1 -DMICROBLOSSOM_RUST_SOFTWARE_ACCELERATOR_LINKED=1 -DMICROBLOSSOM_SERVICE_MODEL=1 -I${service.rustArchive}/include"
                else
                  "-DMICROBLOSSOM_TEST_SMOKE_DECODER=1";
              decoderLibrary =
                if service.rustService then
                  "${rustModelLibrary}/lib/libmicroblossom_r5_service.a -lpthread -ldl -lm"
                else
                  "";
            in
            pkgs.runCommand "microblossom-r5-service-model-${service.name}"
              {
                nativeBuildInputs = [ pkgs.stdenv.cc ];
              }
              ''
                identity_flags=""
                for index in $(seq 0 7); do
                  identity_flags="$identity_flags -DCYT_PROVIDER_IDENTITY_WORD_$index=0"
                done
                cc -std=c11 -Wall -Wextra -Werror $identity_flags \
                  ${decoderFlags} \
                  -I${coyote}/sw/firmware/coprocessor \
                  -I${service.source} \
                  -I${contractRoot} \
                  ${service.source}/service.c ${service.source}/service_test.c \
                  ${decoderLibrary} -o service-test
                ./service-test | tee service-test.log
                grep -F \
                  'MICROBLOSSOM_R5_SERVICE_PASS graph=${service.graphId}-v1 request_beats=${toString service.requestBeats} response_beats=${toString service.responseBeats} storage_bytes=4096' \
                  service-test.log >/dev/null
                grep -F \
                  'request_storage_bytes=${toString (service.requestBeats * 64)} response_storage_bytes=4096' \
                  service-test.log >/dev/null
                grep -F \
                  'static uint8_t request_packet[MICROBLOSSOM_REQUEST_BEATS * QSHELL_BEAT_BYTES]' \
                  ${service.source}/service.c >/dev/null
                grep -F 'static uint8_t response_packet[MICROBLOSSOM_PACKET_STORAGE_BYTES]' \
                  ${service.source}/service.c >/dev/null
                grep -F 'static uint16_t correction_edges[MICROBLOSSOM_MAX_CORRECTION_EDGES]' \
                  ${service.source}/service.c >/dev/null
                ${lib.optionalString service.rustService ''
                  if grep -Eq \
                    '^[[:space:]]*uint16_t[[:space:]]+microblossom_rust_service_decode[[:space:]]*\(' \
                    ${service.source}/service_test.c; then
                    echo 'hosted service model defines a mock Rust decoder' >&2
                    exit 1
                  fi
                  ${pkgs.binutils}/bin/nm -A service-test > linked-symbols.txt
                  grep -E '[[:space:]][Tt][[:space:]]+microblossom_rust_service_decode$' \
                    linked-symbols.txt >/dev/null
                  grep -E '[[:space:]][Tt][[:space:]]+microblossom_rust_software_accelerator_create$' \
                    linked-symbols.txt >/dev/null
                  grep -F \
                    'MICROBLOSSOM_R5_PRODUCTION_TRACE graph=${service.graphId}-v1 case=empty operations=14 reads=8 writes=6 correction_edges=0 weight=0' \
                    service-test.log >/dev/null
                  grep -F \
                    'MICROBLOSSOM_R5_PRODUCTION_TRACE graph=${service.graphId}-v1 case=singleton-smoke operations=20 reads=10 writes=10 correction_edges=1 weight=12' \
                    service-test.log >/dev/null
                ''}
                mkdir -p "$out"
                cp service-test.log "$out/"
                ${lib.optionalString service.rustService ''
                  cp linked-symbols.txt "$out/"
                ''}
              '';
        in
        {
          formatting = (treefmtEval system).config.build.check self;
          graph-matrix-contract =
            assert builtins.length graphSpecs == 34;
            assert builtins.length (lib.unique (map (spec: spec.id) graphSpecs)) == 34;
            assert graphOutputsPresent;
            pkgs.runCommand "microblossom-graph-matrix-contract" { nativeBuildInputs = [ pkgs.jq ]; } ''
              cat > specs.json <<'EOF'
              ${builtins.toJSON graphSpecs}
              EOF
              jq -e '
                length == 34 and
                ([.[] | select(.generatorVariant == "repetition")] | length == 2) and
                ([.[] | select(.generatorVariant == "planar")] | length == 3) and
                ([.[] | select(.generatorVariant == "rotated")] | length == 13) and
                ([.[] | select(.generatorVariant == "phenomenological")] | length == 8) and
                ([.[] | select(.generatorVariant == "circuit")] | length == 8) and
                all(.[]; (.distance >= 3 and (.distance % 2) == 1) and
                  (.physicalErrorRate > 0) and (.maxHalfWeight > 0) and
                  (.graphSha256 | test("^[0-9a-f]{64}$")))
              ' specs.json >/dev/null
              cp specs.json "$out"
            '';
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

          qshell-abi-generated =
            pkgs.runCommand "microblossom-qshell-abi-generated"
              {
                nativeBuildInputs = [
                  pkgs.diffutils
                  pkgs.python3
                ];
              }
              ''
                python3 ${./src/qshell/tools/generate_qshell_abi.py} \
                  --spec ${qshellContractSource}/abi/qshell-abi.json \
                  --rust-out generated.rs \
                  --c-out generated.h \
                  --python-out generated.py
                diff -u ${./src/qshell/protocol/src/qshell_abi_generated.rs} generated.rs
                diff -u ${./src/cpu/r5-service/qshell_abi_generated.h} generated.h
                diff -u ${./src/qshell/host/qshell_abi_generated.py} generated.py
                if grep -n -E \
                    '#define QSHELL_(MAGIC|ABI|HEADER_BYTES|CLASS|FLAG|.*SCHEMA)' \
                    ${./src/cpu/r5-service/service.c}; then
                  echo "R5 service contains a hand-written QSH2 definition" >&2
                  exit 1
                fi
                if grep -n -E \
                    '0x32485351|qshell_magic|QSHELL_MAGIC|BEAT_BYTES = [0-9]' \
                    ${./src/qshell/host/microblossom_qshell_coyote_bridge.cpp} \
                    ${./src/qshell/host/microblossom_qshell_xdb_bridge.py}; then
                  echo "host bridge contains a hand-written QSH2 definition" >&2
                  exit 1
                fi
                python3 ${./src/qshell/tools/check_qshell_wire_fixture.py} \
                  --spec ${qshellContractSource}/abi/qshell-abi.json \
                  --fixtures ${qshellContractSource}/abi/golden-fixtures.json
                touch "$out"
              '';
          qshell-coprocessor-mmio =
            pkgs.runCommand "microblossom-qshell-coprocessor-mmio-check"
              { nativeBuildInputs = [ pkgs.iverilog ]; }
              ''
                iverilog -g2012 -DSYNTHESIS -s tb_coprocessor_mmio -o simulation \
                  ${./src/qshell/rtl/microblossom_coprocessor_mmio.sv} \
                  ${./src/qshell/tests/microblossom_coprocessor_mmio_tb.sv}
                vvp simulation | tee simulation.log
                grep -F MICROBLOSSOM_COPROCESSOR_MMIO_PASS simulation.log >/dev/null
                touch "$out"
              '';

          qshell-coprocessor-application =
            pkgs.runCommand "microblossom-qshell-coprocessor-application-check"
              { nativeBuildInputs = [ verilator_5_014 ]; }
              ''
                core=${qshellCore}/share/microblossom/qshell-core/code-capacity-repetition-d3-v1
                verilator --lint-only --timing --assert -Wno-fatal \
                  -DMICROBLOSSOM_SIM_CLOCK_DIVIDER \
                  --top-module microblossom_coprocessor_application \
                  "$core/MicroBlossomBus.v" \
                  "$core/microblossom_qshell_clock_div2.sv" \
                  ${./src/qshell/rtl/microblossom_coprocessor_mmio.sv} \
                  ${./src/qshell/rtl/microblossom_coprocessor_application.sv}
                touch "$out"
              '';

          qshell-coprocessor-contract =
            pkgs.runCommand "microblossom-qshell-coprocessor-contract-check"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.python3Packages.jsonschema
                ];
              }
              ''
                mkdir -p "$out"
                template=${./src/qshell/contracts/microblossom-d3-coprocessor.template.json}
                ${lib.concatMapStringsSep "\n" (
                  service:
                  let
                    contractRoot = "${service.contract}/share/microblossom/r5-service/${service.graphId}-v1";
                    runtimeIdentity = service.firmware.coyoteR5Firmware.runtimeIdentity;
                    firmwareAbi = service.firmware.coyoteR5Firmware.firmwareAbi;
                  in
                  ''
                    mkdir -p ${service.name}
                    jq -n \
                      --arg graphSha256 ${service.graphSha256} \
                      '{
                        application: {id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
                        shell: {compatibilityId: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
                        provenance: {caller: {graphSha256: $graphSha256}}
                      }' > ${service.name}/app.json
                    jq -n \
                      --arg firmwareAbi ${firmwareAbi} \
                      --arg runtimeIdentity ${runtimeIdentity} \
                      '{firmwareAbi: $firmwareAbi, runtimeIdentity: $runtimeIdentity}' \
                      > ${service.name}/firmware.json
                    python3 ${./src/qshell/tools/build_coprocessor_bundle.py} \
                      --template "$template" \
                      --graph-contract ${contractRoot}/graph-service-contract.json \
                      --schema ${qshellContractSource}/contracts/decoder-contract.schema.json \
                      --abi-spec ${qshellContractSource}/abi/qshell-abi.json \
                      --application-metadata ${service.name}/app.json \
                      --firmware-metadata ${service.name}/firmware.json \
                      --output ${service.name}/generated \
                      --qshell-revision ${v80R5QshellRevision} \
                      --coyote-revision ${v80R5CoyoteRevision} \
                      --coyote-nix-revision ${v80R5CoyoteNixRevision} \
                      --implementation-revision ${self.rev or "c17e888982b8641986266be35e8fc0d9c91dcd64"}
                    generated=${service.name}/generated
                    test "$(jq -er '.graphSha256' "$generated/manifest.json")" = ${service.graphSha256}
                    test "$(jq -er '.abi.request.payloadBytes' "$generated/manifest.json")" = ${toString service.requestPayloadBytes}
                    test "$(jq -er '.abi.response.payloadBytes' "$generated/manifest.json")" = ${toString service.responsePayloadBytes}
                    test "$(jq -er '.abi.request.beats' "$generated/manifest.json")" = ${toString service.requestBeats}
                    test "$(jq -er '.abi.response.beats' "$generated/manifest.json")" = ${toString service.responseBeats}
                    test "$(jq -er '.auxiliary.coprocessor.max_packet_beats' "$generated/decoder-contract.json")" = ${toString (lib.max service.requestBeats service.responseBeats)}
                    test "$(jq -er '.auxiliary.coprocessor.firmware_abi' "$generated/decoder-contract.json")" = ${firmwareAbi}
                    test "$(jq -er '.identities.firmwareRuntime' "$generated/manifest.json")" = ${runtimeIdentity}
                    test "$(jq -er '.dependencies.qshell' "$generated/manifest.json")" = ${v80R5QshellRevision}
                    jq '.provenance.caller.graphSha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
                      ${service.name}/app.json > ${service.name}/wrong-app.json
                    if python3 ${./src/qshell/tools/build_coprocessor_bundle.py} \
                      --template "$template" \
                      --graph-contract ${contractRoot}/graph-service-contract.json \
                      --schema ${qshellContractSource}/contracts/decoder-contract.schema.json \
                      --abi-spec ${qshellContractSource}/abi/qshell-abi.json \
                      --application-metadata ${service.name}/wrong-app.json \
                      --firmware-metadata ${service.name}/firmware.json \
                      --output ${service.name}/wrong-generated \
                      --qshell-revision ${v80R5QshellRevision} \
                      --coyote-revision ${v80R5CoyoteRevision} \
                      --coyote-nix-revision ${v80R5CoyoteNixRevision} \
                      --implementation-revision ${self.rev or "c17e888982b8641986266be35e8fc0d9c91dcd64"}; then
                      echo 'bundle builder accepted a graph-mismatched application' >&2
                      exit 1
                    fi
                    cp -r "$generated" "$out/${service.name}"
                  ''
                ) r5Services}
              '';

          r5-service-contract = (r5ServiceByName "legacy-d3").contract;
          r5-service-contract-circuit-d3 = (r5ServiceByName "circuit-d3").contract;
          r5-service-contract-circuit-d9 = (r5ServiceByName "circuit-d9").contract;
          r5-service-model = mkR5ServiceModelCheck (r5ServiceByName "legacy-d3");
          r5-service-model-circuit-d3 = mkR5ServiceModelCheck (r5ServiceByName "circuit-d3");
          r5-service-model-circuit-d9 = mkR5ServiceModelCheck (r5ServiceByName "circuit-d9");
          r5-rust-service-circuit-d3 = (r5ServiceByName "circuit-d3").rustArchive;
          r5-rust-service-circuit-d9 = (r5ServiceByName "circuit-d9").rustArchive;
          r5-rust-materializer-circuit-d3 =
            self.packages.${system}.microblossom-circuit-level-d3-r5-rust-materializer-test;
          r5-rust-materializer-circuit-d9 =
            self.packages.${system}.microblossom-circuit-level-d9-r5-rust-materializer-test;
          r5-service-firmware = (r5ServiceByName "legacy-d3").firmware;
          r5-service-firmware-circuit-d3 = (r5ServiceByName "circuit-d3").firmware;
          r5-service-firmware-circuit-d9 = (r5ServiceByName "circuit-d9").firmware;
          r5-firmware-storage-contract =
            pkgs.runCommand "microblossom-r5-firmware-storage-contract"
              { nativeBuildInputs = [ pkgs.jq ]; }
              ''
                ${lib.concatMapStringsSep "\n" (service: ''
                  firmware=${service.firmware}
                  symbols="$firmware/analysis/symbols.txt"
                  map="$firmware/firmware/r5.map"
                  grep -E '[[:space:]][bB][[:space:]]+request_packet$' "$symbols" >/dev/null
                  grep -E '[[:space:]][bB][[:space:]]+response_packet$' "$symbols" >/dev/null
                  grep -E '[[:space:]][bB][[:space:]]+correction_edges$' "$symbols" >/dev/null
                  grep -F '__bss_end' "$map" >/dev/null
                  grep -F 'rust-service/libmicroblossom_r5_service.a' "$map" >/dev/null
                  test -s "$firmware/metadata/binary-policy.json"
                  test "$(jq -er '.firmwareAbi' "$firmware/metadata/firmware.json")" = \
                    '${service.firmware.coyoteR5Firmware.firmwareAbi}'
                  test "$(jq -er '.runtimeIdentity' "$firmware/metadata/firmware.json")" = \
                    '${service.firmware.coyoteR5Firmware.runtimeIdentity}'
                  archive_sha256="$(cat ${service.rustArchive}/metadata/archive-sha256)"
                  test "$(jq -er '.rustService.archiveSha256' \
                    "$firmware/metadata/firmware.json")" = "$archive_sha256"
                  test "$(jq -er '.rustService.decodeEnabled' \
                    "$firmware/metadata/firmware.json")" = true
                  jq -e '
                    .hardFloatAbi == false and .unwind == false and
                    .allocator == false and .dynamic == false and .tls == false and
                    .initializedWritableData == false and
                    (.unresolvedSymbols | length) == 0
                  ' "$firmware/metadata/binary-policy.json" >/dev/null
                '') [ (r5ServiceByName "circuit-d3") (r5ServiceByName "circuit-d9") ]}
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
                  ${v80R5QshellRevision}
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
                grep -F 'QSHELL_APPLICATION_SOURCE_DIRS' \
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
                grep -F 'get_cells -quiet -hierarchical' \
                  "$app/microblossom_qshell_timing.xdc" >/dev/null
                if grep -E '^(if|foreach) ' "$app/microblossom_qshell_timing.xdc"; then
                  echo 'timing XDC contains unsupported Tcl control flow' >&2
                  exit 1
                fi
                grep -F 'USED_IN_IMPLEMENTATION true' "$app/init_ip.tcl" >/dev/null
                grep -F 'MICROBLOSSOM_VERSAL_HBM' "$app/init_ip.tcl" >/dev/null
                grep -F 'xcv80*' "$app/init_ip.tcl" >/dev/null
                grep -F '.SIM_DEVICE("VERSAL_HBM")' \
                  "$hdl/microblossom_qshell_clock_div2.sv" >/dev/null
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
                  ${v80R5QshellRevision}
                touch "$out"
              '';

          qshell-coprocessor-package =
            assert qshell.rev == v80R5QshellRevision;
            assert coyote.rev == v80R5CoyoteRevision;
            assert coyoteNix.rev == v80R5CoyoteNixRevision;
            assert qshellLib.applicationContract.recordAbi == qshellAbiSpec.version;
            assert qshellLib.applicationContract.controlAbi == "qshell-control";
            assert qshellLib.applicationContract.coyoteExternalServiceInterface == 1;
            assert qshellLib.applicationContract.coyoteResidentControlInterface == 1;
            assert qshellCoprocessorApp.coyoteTwoStage.kind == "app";
            assert qshellCoprocessorApp.coyoteTwoStage.board == "v80";
            assert
              qshell.packages.${system}.qshell-v80-r5-shell
              == qshell.packages.${system}.qshell-v80-coprocessor-shell;
            assert
              qshellCoprocessorApp.coyoteTwoStage.shellPackage == qshell.packages.${system}.qshell-v80-r5-shell-nonstrict;
            pkgs.runCommand "microblossom-qshell-coprocessor-package" { nativeBuildInputs = [ pkgs.jq ]; } ''
              test "$(jq -er '.nodes.qshell.locked.rev' ${./flake.lock})" = \
                ${v80R5QshellRevision}
              test "$(jq -er '.coprocessor.logicalPort' \
                ${qshellCoprocessorAppHwSource}/core-manifest.json)" = 0
              test "$(jq -er '.coprocessor.streamAbi' \
                ${qshellCoprocessorAppHwSource}/core-manifest.json)" = 1
              test "$(jq -er '.coprocessor.mmioAbi' \
                ${qshellCoprocessorAppHwSource}/core-manifest.json)" = 1
              test "$(jq -er '.coprocessor.integrationState' \
                ${qshellCoprocessorAppHwSource}/core-manifest.json)" = connected
              grep -F 'microblossom_coprocessor_application' \
                ${qshellCoprocessorAppHwSource}/src/microblossom-coprocessor/vfpga_top.svh >/dev/null
              grep -F 'axis_coprocessor_recv[0]' \
                ${qshellCoprocessorAppHwSource}/src/microblossom-coprocessor/vfpga_top.svh >/dev/null
              test -s ${qshellCoprocessorAppHwSource}/src/microblossom/hdl/microblossom_coprocessor_mmio.sv
              test -s ${qshellCoprocessorAppHwSource}/src/microblossom/hdl/microblossom_coprocessor_application.sv
              coprocessor_cmake=${qshellCoprocessorAppHwSource}/CMakeLists.txt
              floorplan="$(sed -n 's/^set(FPLAN_PATH "\(.*\)")$/\1/p' \
                "$coprocessor_cmake")"
              validation_line="$(grep -n '^validation_checks_hw()' "$coprocessor_cmake" | cut -d: -f1)"
              floorplan_line="$(grep -n '^set(FPLAN_PATH ' "$coprocessor_cmake" | cut -d: -f1)"
              create_line="$(grep -n '^create_hw()' "$coprocessor_cmake" | cut -d: -f1)"
              test "$validation_line" -lt "$floorplan_line"
              test "$floorplan_line" -lt "$create_line"
              test -s "$floorplan"
              parent_floorplan=${qshell.outPath}/hw/floorplans/qshell_v80.xdc
              grep -F 'BUFGCE_DIV_X6Y0:BUFGCE_DIV_X6Y3' "$parent_floorplan" >/dev/null
              grep -F 'set_property NOC_HIGH_ID_MIN 6' "$parent_floorplan" >/dev/null
              grep -F 'set_property NOC_HIGH_ID_MAX 63' "$parent_floorplan" >/dev/null
              if grep -E 'BUFGCE_DIV_X(5|7)' "$parent_floorplan"; then
                echo 'V80 parent floorplan captures a static clock tile' >&2
                exit 1
              fi
              floorplan_extension=${./src/qshell/app/src/microblossom-coprocessor/microblossom_v80_floorplan_extension.xdc}
              if grep -F 'resize_pblock' "$floorplan_extension"; then
                echo 'packaged application attempts to resize the routed parent pblock' >&2
                exit 1
              fi
              if grep -E '^(if|foreach) ' "$floorplan_extension"; then
                echo 'floorplan XDC contains unsupported Tcl control flow' >&2
                exit 1
              fi
              app_link=${coyote}/scripts/dyn/flow_app_link.tcl.in
              grep -F 'add_files -fileset [get_filesets constrs_1] "$cfg(fplan_path)"' \
                "$app_link" >/dev/null
              grep -F 'set_property PROCESSING_ORDER LATE' "$app_link" >/dev/null
              test -s ${qshellCoprocessorAppHwSource}/metadata/graph-service-contract.json
              test "$(jq -er '.coprocessor.requestBeats' \
                ${qshellCoprocessorAppHwSource}/core-manifest.json)" = 2
              test "$(jq -er '.coprocessor.responseBeats' \
                ${qshellCoprocessorAppHwSource}/core-manifest.json)" = 2
              touch "$out"
            '';

          r5-graph-package-contract =
            let
              d3 = r5ServiceByName "circuit-d3";
              d9 = r5ServiceByName "circuit-d9";
              d3App = self.packages.${system}.microblossom-circuit-level-d3-qshell-v80-coprocessor-app;
              d9App = self.packages.${system}.microblossom-circuit-level-d9-qshell-v80-coprocessor-app;
            in
            assert d3.firmware.coyoteR5Firmware.runtimeIdentity != d9.firmware.coyoteR5Firmware.runtimeIdentity;
            assert d3.firmware.coyoteR5Firmware.firmwareAbi != d9.firmware.coyoteR5Firmware.firmwareAbi;
            assert d3App.coyoteTwoStage.kind == "app";
            assert d9App.coyoteTwoStage.kind == "app";
            assert d3App.coyoteTwoStage.board == "v80";
            assert d9App.coyoteTwoStage.board == "v80";
            assert d3App.coyoteTwoStage.shellPackage == qshell.packages.${system}.qshell-v80-r5-shell-nonstrict;
            assert d9App.coyoteTwoStage.shellPackage == qshell.packages.${system}.qshell-v80-r5-shell-nonstrict;
            pkgs.runCommand "microblossom-r5-graph-package-contract"
              { nativeBuildInputs = [ pkgs.jq ]; }
              ''
                ${lib.concatMapStringsSep "\n" (
                  service:
                  let
                    appSource = self.packages.${system}."${service.packagePrefix}-qshell-coprocessor-app-hw-source";
                    runner = self.packages.${system}."${service.packagePrefix}-coprocessor-run";
                    contractRoot = "${service.contract}/share/microblossom/r5-service/${service.graphId}-v1";
                  in
                  ''
                    test -x ${runner}/bin/${
                      if service.name == "circuit-d3" then
                        "microblossom_circuit_d3_coprocessor"
                      else
                        "microblossom_circuit_d9_coprocessor"
                    }
                    ${runner}/bin/${
                      if service.name == "circuit-d3" then
                        "microblossom_circuit_d3_coprocessor"
                      else
                        "microblossom_circuit_d9_coprocessor"
                    } --help | grep -F 'usage:' >/dev/null
                    test "$(jq -er '.graphSha256' ${appSource}/core-manifest.json)" = ${service.graphSha256}
                    test "$(jq -er '.coprocessor.requestPacketBytes' ${appSource}/core-manifest.json)" = ${toString service.requestPacketBytes}
                    test "$(jq -er '.coprocessor.responsePacketBytes' ${appSource}/core-manifest.json)" = ${toString service.responsePacketBytes}
                    test "$(jq -er '.coprocessor.requestBeats' ${appSource}/core-manifest.json)" = ${toString service.requestBeats}
                    test "$(jq -er '.coprocessor.responseBeats' ${appSource}/core-manifest.json)" = ${toString service.responseBeats}
                    cmp ${appSource}/metadata/graph-service-contract.json \
                      ${contractRoot}/graph-service-contract.json
                    test -s ${service.source}/microblossom_graph_contract.h
                    test -s ${service.source}/service.h
                    cmp ${service.source}/microblossom_graph_contract.h \
                      ${contractRoot}/microblossom_graph_contract.h
                    test -s ${service.rustArchive}/lib/libmicroblossom_r5_service.a
                    cmp ${service.source}/microblossom_rust_service.h \
                      ${service.rustArchive}/include/microblossom_rust_service.h
                    test "$(sha256sum \
                      ${service.rustArchive}/lib/libmicroblossom_r5_service.a | cut -d' ' -f1)" = \
                      "$(cat ${service.rustArchive}/metadata/archive-sha256)"
                    test "$(jq -er '.graphSha256' \
                      ${service.rustArchive}/metadata/rust-service.json)" = \
                      ${service.graphSha256}
                    test "$(jq -er '.target' \
                      ${service.rustArchive}/metadata/rust-service.json)" = \
                      armv7r-none-eabi
                    grep -F 'MICROBLOSSOM_RUST_DECODER_LINKED=1' \
                      ${service.source}/Makefile >/dev/null
                    grep -F 'RUST_SERVICE_ARCHIVE=rust-service/libmicroblossom_r5_service.a' \
                      ${service.firmware.drvPath} >/dev/null
                  ''
                ) [ d3 d9 ]}
                test '${d3.firmware.coyoteR5Firmware.runtimeIdentity}' != \
                  '${d9.firmware.coyoteR5Firmware.runtimeIdentity}'
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
                  ${v80R5QshellRevision}
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
            test -x ${protocol}/bin/microblossom_d3_coprocessor
            test -x ${protocol}/bin/microblossom_coprocessor
            test -s "$contract/src/bin/microblossom_d3_coprocessor.rs"
            test -s "$contract/src/bin/microblossom_coprocessor.rs"
            cmp ${./src/qshell/protocol/src/lib.rs} "$contract/src/lib.rs"
            cmp ${./src/qshell/protocol/src/qshell_abi_generated.rs} \
              "$contract/src/qshell_abi_generated.rs"
            cmp ${./src/qshell/protocol/src/bin/microblossom_d3_coprocessor.rs} \
              "$contract/src/bin/microblossom_d3_coprocessor.rs"
            cmp ${./src/qshell/protocol/src/bin/microblossom_coprocessor.rs} \
              "$contract/src/bin/microblossom_coprocessor.rs"
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
            grep -Fx 'channel = "nightly-2023-11-16"' \
              ${./src/cpu/r5-service-rust/rust-toolchain.toml} >/dev/null
            grep -Fx 'targets = ["armv7r-none-eabi"]' \
              ${./src/cpu/r5-service-rust/rust-toolchain.toml} >/dev/null
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
      "/usr/bin/lscpu=/run/current-system/sw/bin/lscpu"
    ];
  };
}
