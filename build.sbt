ThisBuild / version := "1.0"
ThisBuild / scalaVersion := "2.12.12"
ThisBuild / organization := "org.yecl"

val spinalVersion = "1.9.3"

// The VexRiscv-dependent Blinky demos are unrelated to the generated
// MicroBlossom accelerator and to the V80 hard-CPU integration. Keep their
// sources in-tree, but leave them out of the baseline generator dependency
// closure so sbt does not fetch a mutable RISC-V CPU repository.
val vexRiscvDemoSources = "BlinkyAsm.scala" || "BlinkyPower.scala"

lazy val microblossom = (project in file("."))
  .settings(
    Compile / scalaSource := baseDirectory.value / "src" / "fpga",
    Test / scalaSource := baseDirectory.value / "src" / "fpga",
    Compile / unmanagedSources / excludeFilter := HiddenFileFilter || vexRiscvDemoSources,
    Test / unmanagedSources / excludeFilter := HiddenFileFilter || vexRiscvDemoSources,
    assembly / assemblyJarName := "microblossom.jar",
    assembly / test := {},
    assembly / assemblyMergeStrategy := {
      case PathList("META-INF", _*) => MergeStrategy.discard
      case _                        => MergeStrategy.first
    },
    libraryDependencies ++= Seq(
      "com.github.spinalhdl" % "spinalhdl-core_2.12" % spinalVersion,
      "com.github.spinalhdl" % "spinalhdl-lib_2.12" % spinalVersion,
      compilerPlugin("com.github.spinalhdl" % "spinalhdl-idsl-plugin_2.12" % spinalVersion),
      "org.scalatest" %% "scalatest" % "3.2.5",
      "org.yaml" % "snakeyaml" % "1.8",
      compilerPlugin("org.scalamacros" % "paradise" % "2.1.1" cross CrossVersion.full),
      "io.circe" %% "circe-core" % "0.14.3",
      "io.circe" %% "circe-generic" % "0.14.3",
      "io.circe" %% "circe-parser" % "0.14.3",
      "io.circe" %% "circe-generic-extras" % "0.14.3",
      "org.rogach" %% "scallop" % "5.0.1",
      "org.playframework" %% "play-json" % "3.0.1"
    )
  )

fork := true
javaOptions ++= Seq("-Xmx32G") // java option for the forked process
