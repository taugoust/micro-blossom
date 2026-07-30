{
  description = "Reproducible MicroBlossom software, generated RTL, and QShell integration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
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
      fenix,
      treefmt-nix,
      ...
    }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      rustManifestSha256 = "sha256-R2zRGLfpNU1h0eHjWkzsSSOQ5brgxA++DAe5i891Lyg=";
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

          rustToolchain = fenix.packages.${system}.fromToolchainFile {
            file = ./src/cpu/blossom/rust-toolchain.toml;
            sha256 = rustManifestSha256;
          };
          rustPlatform = pkgs.makeRustPlatform {
            cargo = rustToolchain;
            rustc = rustToolchain;
          };

          rustSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./src/cpu/blossom
              ./src/cpu/blossom-nostd
              ./src/cpu/embedded
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
              runHook postBuild
            '';
            installPhase = "true";

            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = "sha256-b220Xwt5ZyrktdTwMXHI+848ybdOMulHTWTTgC3yAeo=";
          };

          microblossomScala = pkgs.stdenvNoCC.mkDerivation {
            pname = "microblossom-scala";
            version = "1.0-${self.shortRev or "dirty"}";
            src = scalaSource;

            nativeBuildInputs = [
              pkgs.jdk11
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

            meta = {
              description = "MicroBlossom SpinalHDL generator and simulation JAR";
              license = lib.licenses.mit;
              platforms = systems;
            };
          };

          microblossomHost = rustPlatform.buildRustPackage {
            pname = "microblossom-host";
            version = "0.0.0-${self.shortRev or "dirty"}";
            src = rustSource;

            postUnpack = ''
              sourceRoot="$sourceRoot/src/cpu/blossom"
            '';

            cargoLock.lockFile = ./src/cpu/blossom/Cargo.lock;
            cargoBuildFlags = [
              "--bin"
              "micro_blossom"
              "--bin"
              "generate_nix_d3_fixture"
            ];
            MICROBLOSSOM_SKIP_CBINDGEN = "1";
            doCheck = false;

            meta = {
              description = "Native MicroBlossom primal decoder and deterministic graph tools";
              license = lib.licenses.mit;
              platforms = systems;
              mainProgram = "micro_blossom";
            };
          };

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
          microblossom-d3-graph = d3Fixture;
          microblossom-d3-rtl = d3Rtl;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          fixture = self.packages.${system}.microblossom-d3-graph;
          scala = self.packages.${system}.microblossom-scala;
          rtl = self.packages.${system}.microblossom-d3-rtl;
        in
        {
          formatting = (treefmtEval system).config.build.check self;

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

          rtl-contract =
            pkgs.runCommand "microblossom-d3-rtl-contract"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.jq
                  pkgs.verilator
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
            ];
          };
        }
      );

      formatter = forAllSystems (system: (treefmtEval system).config.build.wrapper);
    };
}
