package microblossom.regression

import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Paths}
import java.security.MessageDigest
import scala.collection.mutable.ArrayBuffer
import scala.util.Random

import microblossom._
import microblossom.modules.DistributedDual
import spinal.core.sim._

object CircuitD9StagePipelineRegression extends App {
  private val InjectedRegisters = Seq("offload3", "execute2", "update")
  private val ExpectedGraphSha256 = "9582b1c0539c72a7ea76e1a7ca7290df36ff89f8e84f53f65f77d86899bba41a"
  private val ExpectedVertexCount = 433
  private val ExpectedEdgeCount = 1737
  private val ExpectedOffloaderCount = 1737
  private val DirectedOffloaderIndex = 0
  private val RandomSeed = 0x5eedd009L

  private case class Stimulus(valid: Boolean, instruction: Long, label: String)
  private case class Result(
      maxGrowable: Int,
      conflictValid: Boolean,
      node1: Int,
      node2: Int,
      touch1: Int,
      touch2: Int,
      vertex1: Int,
      vertex2: Int
  )
  private case class Observation(
      result: Result,
      activeOffloaders: Set[Int],
      vertexOffload3Valid: Boolean,
      vertexExecute2Valid: Boolean,
      vertexUpdateValid: Boolean,
      edgeOffload3Valid: Boolean,
      edgeExecute2Valid: Boolean,
      edgeUpdateValid: Boolean
  )
  private case class Run(config: DualConfig, observations: Vector[Observation])

  private val graphPath = sys.env.getOrElse(
    "MICROBLOSSOM_CIRCUIT_D9_GRAPH",
    throw new IllegalArgumentException("MICROBLOSSOM_CIRCUIT_D9_GRAPH must name the frozen circuit-d9 graph")
  )
  private val workspace = sys.env.getOrElse(
    "MICROBLOSSOM_STAGE_PIPELINE_WORKSPACE",
    "simWorkspace/circuit-d9-stage-pipeline"
  )

  private def sha256(path: String): String = {
    MessageDigest
      .getInstance("SHA-256")
      .digest(Files.readAllBytes(Paths.get(path)))
      .iterator
      .map(byte => f"${byte.toInt & 0xff}%02x")
      .mkString
  }

  private def makeConfig(injectedRegisters: Seq[String]): DualConfig = {
    val config = DualConfig(
      filename = graphPath,
      supportOffloading = true,
      injectRegisters = injectedRegisters
    )
    config.sanityCheck()
    assert(config.vertexNum == ExpectedVertexCount)
    assert(config.edgeNum == ExpectedEdgeCount)
    assert(config.graph.offloading.length == ExpectedOffloaderCount)
    assert(config.offloaderNum == ExpectedOffloaderCount)
    config
  }

  assert(sha256(graphPath) == ExpectedGraphSha256)
  val graphConfig = makeConfig(InjectedRegisters)
  assert(graphConfig.executeLatency == 3)
  assert(graphConfig.readLatency == 4)
  assert(graphConfig.activeOffloading(DirectedOffloaderIndex).dm.exists(_.e.toInt == 1))

  private val instructionSpec = DualConfig().instructionSpec
  private val stimuli = ArrayBuffer[Stimulus]()
  private val acceptedCycles = ArrayBuffer[(Int, String)]()

  private def append(valid: Boolean, instruction: Long, label: String): Unit = {
    if (valid) acceptedCycles.append((stimuli.length, label))
    stimuli.append(Stimulus(valid, instruction, label))
  }

  private def appendSpaced(instruction: Long, label: String): Unit = {
    append(valid = true, instruction, label)
    for (_ <- 1 until graphConfig.readLatency) append(valid = false, 0L, s"$label/drain")
  }

  private def addDefectPair(offloaderIndex: Int, prefix: String): Unit = {
    val edgeIndex = graphConfig.offloaderEdgeIndex(offloaderIndex)
    val (left, right) = graphConfig.incidentVerticesOf(edgeIndex)
    val weight = graphConfig.graph.weighted_edges(edgeIndex).w.toInt
    assert(weight > 0 && weight % 2 == 0)
    assert(!graphConfig.isVirtual(left) && !graphConfig.isVirtual(right))
    appendSpaced(instructionSpec.generateReset(), s"$prefix/reset")
    appendSpaced(instructionSpec.generateAddDefect(left, 0), s"$prefix/add-left-$left")
    appendSpaced(instructionSpec.generateAddDefect(right, 1), s"$prefix/add-right-$right")
    appendSpaced(instructionSpec.generateGrow(weight / 2), s"$prefix/grow-${weight / 2}")
    appendSpaced(instructionSpec.generateFindObstacle(), s"$prefix/find")
  }

  addDefectPair(DirectedOffloaderIndex, "directed")

  val defectMatchIndices = graphConfig.activeOffloading.indices.filter(index =>
    graphConfig.activeOffloading(index).dm.nonEmpty
  ).toIndexedSeq
  val random = new Random(RandomSeed)
  val randomOffloaderIndices = IndexedSeq.fill(12)(defectMatchIndices(random.nextInt(defectMatchIndices.length)))
  randomOffloaderIndices.zipWithIndex.foreach { case (offloaderIndex, index) =>
    addDefectPair(offloaderIndex, s"random-$index-offloader-$offloaderIndex")
  }

  appendSpaced(instructionSpec.generateReset(), "throughput/reset")
  val burstStart = stimuli.length
  val burstLength = 32
  for (index <- 0 until burstLength) {
    append(valid = true, instructionSpec.generateFindObstacle(), s"throughput/find-$index")
  }
  for (_ <- 0 until graphConfig.readLatency + 2) append(valid = false, 0L, "throughput/drain")

  private val observedOffloaderIndices =
    (DirectedOffloaderIndex +: randomOffloaderIndices).distinct.sorted

  private def run(name: String, injectedRegisters: Seq[String]): Run = {
    val config = makeConfig(injectedRegisters)
    val ioConfig = DualConfig()
    var observations = Vector.empty[Observation]

    val compiled = SimConfig
      .withConfig(Config.spinal())
      .workspacePath(workspace)
      .workspaceName(name)
      .allOptimisation
      .compile({
        val dut = DistributedDual(config, ioConfig)
        observedOffloaderIndices.foreach(index => dut.offloaders(index).io.condition.simPublic())
        dut.vertices.head.stages.offloadGet3.message.valid.simPublic()
        dut.vertices.head.stages.executeGet2.compact.valid.simPublic()
        dut.vertices.head.stages.updateGet.compact.valid.simPublic()
        dut.edges.head.stages.offloadGet3.compact.valid.simPublic()
        dut.edges.head.stages.executeGet2.compact.valid.simPublic()
        dut.edges.head.stages.updateGet.compact.valid.simPublic()
        dut
      })

    compiled.doSim(name) { dut =>
      dut.io.message.valid #= false
      dut.io.message.instruction #= 0
      dut.clockDomain.forkStimulus(period = 10)
      for (_ <- 0 until 12) dut.clockDomain.waitSampling()

      val trace = ArrayBuffer[Observation]()
      stimuli.foreach { stimulus =>
        dut.io.message.valid #= stimulus.valid
        dut.io.message.instruction #= stimulus.instruction
        dut.clockDomain.waitSampling()
        sleep(1)
        val conflict = dut.io.conflict
        trace.append(
          Observation(
            result = Result(
              maxGrowable = dut.io.maxGrowable.length.toInt,
              conflictValid = conflict.valid.toBoolean,
              node1 = conflict.node1.toInt,
              node2 = conflict.node2.toInt,
              touch1 = conflict.touch1.toInt,
              touch2 = conflict.touch2.toInt,
              vertex1 = conflict.vertex1.toInt,
              vertex2 = conflict.vertex2.toInt
            ),
            activeOffloaders = observedOffloaderIndices.iterator
              .filter(index => dut.offloaders(index).io.condition.toBoolean)
              .toSet,
            vertexOffload3Valid = dut.vertices.head.stages.offloadGet3.message.valid.toBoolean,
            vertexExecute2Valid = dut.vertices.head.stages.executeGet2.compact.valid.toBoolean,
            vertexUpdateValid = dut.vertices.head.stages.updateGet.compact.valid.toBoolean,
            edgeOffload3Valid = dut.edges.head.stages.offloadGet3.compact.valid.toBoolean,
            edgeExecute2Valid = dut.edges.head.stages.executeGet2.compact.valid.toBoolean,
            edgeUpdateValid = dut.edges.head.stages.updateGet.compact.valid.toBoolean
          )
        )
      }
      observations = trace.toVector
    }

    Run(config, observations)
  }

  private val reference = run("reference", Seq.empty)
  System.gc()
  private val pipelined = run("pipelined", InjectedRegisters)

  assert(reference.config.executeLatency == 0)
  assert(reference.config.readLatency == 1)
  assert(pipelined.config.executeLatency == 3)
  assert(pipelined.config.readLatency == 4)
  assert(reference.observations.length == stimuli.length)
  assert(pipelined.observations.length == stimuli.length)

  acceptedCycles.foreach { case (acceptedCycle, label) =>
    val referenceCycle = acceptedCycle + reference.config.readLatency - 1
    val pipelinedCycle = acceptedCycle + pipelined.config.readLatency - 1
    assert(
      pipelined.observations(pipelinedCycle).result == reference.observations(referenceCycle).result,
      s"result mismatch for $label: reference cycle $referenceCycle, pipelined cycle $pipelinedCycle"
    )
  }

  def assertSingleCyclePulse(values: Vector[Boolean], cycle: Int, label: String): Unit = {
    assert(values(cycle), s"$label missing at cycle $cycle")
    if (cycle > 0) assert(!values(cycle - 1), s"$label arrived before cycle $cycle")
    if (cycle + 1 < values.length) assert(!values(cycle + 1), s"$label remained after cycle $cycle")
  }

  val isolatedPulseCycle = acceptedCycles.head._1
  assertSingleCyclePulse(
    pipelined.observations.map(_.vertexOffload3Valid),
    isolatedPulseCycle,
    "vertex offload3 register"
  )
  assertSingleCyclePulse(
    pipelined.observations.map(_.vertexExecute2Valid),
    isolatedPulseCycle + 1,
    "vertex execute2 register"
  )
  assertSingleCyclePulse(
    pipelined.observations.map(_.vertexUpdateValid),
    isolatedPulseCycle + 2,
    "vertex update register"
  )
  assertSingleCyclePulse(
    pipelined.observations.map(_.edgeOffload3Valid),
    isolatedPulseCycle,
    "edge offload3 register"
  )
  assertSingleCyclePulse(
    pipelined.observations.map(_.edgeExecute2Valid),
    isolatedPulseCycle + 1,
    "edge execute2 register"
  )
  assertSingleCyclePulse(
    pipelined.observations.map(_.edgeUpdateValid),
    isolatedPulseCycle + 2,
    "edge update register"
  )

  val directedOffloaderWasActive = pipelined.observations.exists(
    _.activeOffloaders.contains(DirectedOffloaderIndex)
  )
  assert(directedOffloaderWasActive, "directed circuit-d9 defect match did not activate its offloader")

  val burstUpdateStart = burstStart + 2
  assert(
    pipelined.observations
      .slice(burstUpdateStart, burstUpdateStart + burstLength)
      .forall(_.vertexUpdateValid),
    "the circuit-d9 pipeline did not carry one command per cycle through update"
  )
  assert(
    pipelined.observations
      .slice(burstUpdateStart, burstUpdateStart + burstLength)
      .forall(_.edgeUpdateValid),
    "the circuit-d9 edge pipeline did not carry one command per cycle through update"
  )

  println(
    s"CIRCUIT_D9_STAGE_PIPELINE_OK directed=1 random=${randomOffloaderIndices.length} " +
      s"offloaders=${graphConfig.offloaderNum} burst=$burstLength executeLatency=${pipelined.config.executeLatency} " +
      s"readLatency=${pipelined.config.readLatency} graphSha256=$ExpectedGraphSha256"
  )
}
