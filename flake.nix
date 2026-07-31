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
  };

  outputs =
    {
      self,
      nixpkgs,
      crane,
      fenix,
      treefmt-nix,
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
                cp src/lib.rs "$contract/src/"
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

          hostCargoExtraArgs = "--locked --bin micro_blossom --bin generate_nix_d3_fixture";
          simulatorCargoExtraArgs = "${hostCargoExtraArgs} --bin embedded_simulator";

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
        in
        {
          default = microblossomHost;
          microblossom-host = microblossomHost;
          microblossom-scala = microblossomScala;
          microblossom-qshell-protocol = microblossomQshellProtocol;
          microblossom-d3-sim-runner = microblossomD3SimRunner;
          microblossom-d3-golden-decode = d3GoldenDecode;
          microblossom-d3-qshell-golden-decode = d3QshellGoldenDecode;
          microblossom-d3-graph = d3Fixture;
          microblossom-d3-rtl = d3Rtl;
          verilator-5_014 = verilator_5_014;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          verilator_5_014 = mkVerilator_5_014 pkgs;
          host = self.packages.${system}.microblossom-host;
          fixture = self.packages.${system}.microblossom-d3-graph;
          protocol = self.packages.${system}.microblossom-qshell-protocol;
          scala = self.packages.${system}.microblossom-scala;
          simRunner = self.packages.${system}.microblossom-d3-sim-runner;
          rtl = self.packages.${system}.microblossom-d3-rtl;
        in
        {
          formatting = (treefmtEval system).config.build.check self;
          qshell-protocol = self.packages.${system}.microblossom-qshell-protocol;
          d3-golden-decode = self.packages.${system}.microblossom-d3-golden-decode;
          d3-qshell-golden-decode = self.packages.${system}.microblossom-d3-qshell-golden-decode;

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
            test -x ${host}/bin/micro_blossom
            test -x ${host}/bin/generate_nix_d3_fixture
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
            cmp ${./src/qshell/protocol/src/lib.rs} "$contract/src/lib.rs"
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
        }
      );

      formatter = forAllSystems (system: (treefmtEval system).config.build.wrapper);
    };
}
