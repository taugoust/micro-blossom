package microblossom.modules

import io.circe._
import io.circe.generic.extras._
import io.circe.generic.semiauto._
import spinal.core._
import spinal.lib._
import spinal.core.sim._
import microblossom._
import microblossom.util._
import microblossom.types._
import microblossom.util.Vivado
import org.scalatest.funsuite.AnyFunSuite
import scala.util.control.Breaks._
import scala.collection.mutable.ArrayBuffer
import scala.collection.mutable.Map

object DistributedDual {
  private[modules] def maxGrowableLeafIndicesInOrder(tree: BinaryTree): IndexedSeq[Int] = {
    require(tree.nodes.nonEmpty)
    val leaves = ArrayBuffer[Int]()

    def visit(nodeIndex: Int): Unit = {
      val node = tree.nodes(nodeIndex)
      (node.l, node.r) match {
        case (None, None) => leaves.append(nodeIndex)
        case (Some(left), Some(right)) =>
          visit(left.toInt)
          visit(right.toInt)
        case _ => throw new IllegalArgumentException("binary tree node must have either zero or two children")
      }
    }

    visit(tree.nodes.length - 1)
    leaves.toIndexedSeq
  }

  private[modules] val MaxGrowablePipelineFanIn = 16

  private[modules] def reduceMaxGrowable[T <: Data](candidates: Seq[T])(lengthOf: T => UInt): T = {
    require(candidates.nonEmpty)
    candidates.reduceBalancedTree { (left, right) =>
      Mux(lengthOf(left) < lengthOf(right), left, right)
    }
  }

  private[modules] def contiguousGroups[T](values: IndexedSeq[T], groupCount: Int): IndexedSeq[IndexedSeq[T]] = {
    require(values.nonEmpty)
    require(groupCount > 0 && groupCount <= values.length)
    (0 until groupCount).map { index =>
      val from = index * values.length / groupCount
      val until = (index + 1) * values.length / groupCount
      values.slice(from, until)
    }
  }

  private[modules] def reduceMaxGrowablePipelined[T <: Data](
      candidates: IndexedSeq[T],
      pipelineLatency: Int
  )(lengthOf: T => UInt): T = {
    require(candidates.nonEmpty)
    require(pipelineLatency >= 0)
    if (pipelineLatency == 0) {
      reduceMaxGrowable(candidates)(lengthOf)
    } else {
      val firstBoundaryCapacity = (0 until pipelineLatency).foldLeft(1) { (capacity, _) =>
        Math.multiplyExact(capacity, MaxGrowablePipelineFanIn)
      }
      val totalCapacity = Math.multiplyExact(firstBoundaryCapacity, MaxGrowablePipelineFanIn)
      require(
        candidates.length <= totalCapacity,
        s"${candidates.length} max-growable candidates exceed the $totalCapacity-candidate pipeline capacity"
      )

      var level = contiguousGroups(candidates, Math.min(candidates.length, firstBoundaryCapacity))
        .map(group => reduceMaxGrowable(group)(lengthOf))
      for (stage <- 0 until pipelineLatency) {
        if (stage > 0) {
          level = level
            .grouped(MaxGrowablePipelineFanIn)
            .map(group => reduceMaxGrowable(group.toIndexedSeq)(lengthOf))
            .toIndexedSeq
        }
        level = level.zipWithIndex.map { case (candidate, index) =>
          val registered = RegNext(candidate)
          registered.setName(s"maxGrowablePipeline_${stage}_$index")
          registered
        }
      }
      reduceMaxGrowable(level)(lengthOf)
    }
  }

  private[modules] def conflictLeafIndicesInOrder(tree: BinaryTree): IndexedSeq[Int] = {
    maxGrowableLeafIndicesInOrder(tree)
  }

  private[modules] def reduceConflict[T <: Data](candidates: Seq[T])(validOf: T => Bool): T = {
    require(candidates.nonEmpty)
    candidates.reduceBalancedTree { (left, right) =>
      Mux(validOf(left), left, right)
    }
  }

  private[modules] def conflictBoundaryGroupCount(candidateCount: Int): Int = {
    require(candidateCount > 0)
    1 << (log2Up(candidateCount) / 2)
  }

  private[modules] def reduceConflictPipelined[T <: Data](
      candidates: IndexedSeq[T],
      pipelineLatency: Int
  )(validOf: T => Bool): T = {
    require(candidates.nonEmpty)
    require(pipelineLatency == 0 || pipelineLatency == 1)
    if (pipelineLatency == 0) {
      reduceConflict(candidates)(validOf)
    } else {
      val groups = contiguousGroups(candidates, conflictBoundaryGroupCount(candidates.length))
      val registeredWinners = groups.zipWithIndex.map { case (group, index) =>
        val registered = RegNext(reduceConflict(group)(validOf))
        registered.setName(s"conflictPipeline_$index")
        registered
      }
      reduceConflict(registeredWinners)(validOf)
    }
  }
}

case class DistributedDual(config: DualConfig, ioConfig: DualConfig) extends Component {
  ioConfig.contextDepth = config.contextDepth

  val io = new Bundle {
    val message = in(BroadcastMessage(ioConfig, explicitReset = false))

    val maxGrowable = out(ConvergecastMaxGrowable(ioConfig.weightBits))
    val conflict = out(ConvergecastConflict(ioConfig.vertexBits))
    val parityReports = out(Bits(config.parityReportersNum bits))
  }

  // width conversion
  val broadcastMessage = BroadcastMessage(config)
  broadcastMessage.instruction.resizedFrom(io.message.instruction)
  broadcastMessage.valid := io.message.valid
  if (config.contextBits > 0) { broadcastMessage.contextId := io.message.contextId }
  broadcastMessage.isReset := io.message.instruction.isReset

  // Apply the configured delay before graph-sized distribution. The complete
  // message stays on its minimal tree; reset uses finer leaves at equal depth.
  val broadcastSource = Delay(broadcastMessage, config.broadcastDelay)
  val messageTopology = ControlFanoutTopology(config.distributedControlConsumerCount)
  val resetTopology = ResetFanoutTopology(
    config.distributedControlConsumerCount,
    messageTopology.depth,
    config.resetLeafMaxConsumers
  )
  val controlFanout = DistributedDualControlFanout(config, messageTopology.consumerCount)
  controlFanout.io.message := broadcastSource

  val sourceClockDomain = ClockDomain.current
  val consumerClockDomains = (0 until resetTopology.leafCount).map { leafIndex =>
    sourceClockDomain.copy(
      reset = controlFanout.io.leafResets(leafIndex),
      config = sourceClockDomain.config.copy(resetActiveLevel = HIGH)
    )
  }
  def messageLeaf(consumerIndex: Int): Int = messageTopology.leafForConsumer(consumerIndex)
  def resetLeaf(consumerIndex: Int): Int = resetTopology.leafForConsumer(consumerIndex)

  // Instantiate each contiguous graph group under its hierarchy-local reset.
  // All local domains retain the source clock and reset semantics.
  val vertices = Seq.range(0, config.vertexNum).map { vertexIndex =>
    consumerClockDomains(resetLeaf(vertexIndex)) {
      new Vertex(config, vertexIndex)
    }
  }
  val edges = Seq.range(0, config.edgeNum).map { edgeIndex =>
    consumerClockDomains(resetLeaf(config.vertexNum + edgeIndex)) {
      new Edge(config, edgeIndex)
    }
  }
  val offloaders = Seq.range(0, config.offloaderNum).map { offloaderIndex =>
    consumerClockDomains(resetLeaf(config.vertexNum + config.edgeNum + offloaderIndex)) {
      new Offloader(config, offloaderIndex)
    }
  }

  // connect vertex I/O
  for ((vertex, vertexIndex) <- vertices.zipWithIndex) {
    vertex.io.message := controlFanout.io.leafMessages(messageLeaf(vertexIndex))
    for ((edgeIndex, localIndex) <- config.incidentEdgesOf(vertexIndex).zipWithIndex) {
      vertex.io.edgeInputs(localIndex) := edges(edgeIndex).io.stageOutputs
    }
    for ((offloaderIndex, localIndex) <- config.incidentOffloaderOf(vertexIndex).zipWithIndex) {
      vertex.io.offloaderInputs(localIndex) := offloaders(offloaderIndex).io.stageOutputs
    }
    for ((edgeIndex, localIndex) <- config.incidentEdgesOf(vertexIndex).zipWithIndex) {
      vertex.io.peerVertexInputsExecute3(localIndex) := vertices(
        config.peerVertexOfEdge(edgeIndex, vertexIndex)
      ).io.stageOutputs.executeGet3
    }
  }

  // connect edge I/O
  for ((edge, edgeIndex) <- edges.zipWithIndex) {
    edge.io.message := controlFanout.io.leafMessages(messageLeaf(config.vertexNum + edgeIndex))
    val (leftVertex, rightVertex) = config.incidentVerticesOf(edgeIndex)
    edge.io.leftVertexInput := vertices(leftVertex).io.stageOutputs
    edge.io.rightVertexInput := vertices(rightVertex).io.stageOutputs
  }

  // connect offloader I/O
  for ((offloader, offloaderIndex) <- offloaders.zipWithIndex) {
    for ((vertexIndex, localIndex) <- config.offloaderNeighborVertexIndices(offloaderIndex).zipWithIndex) {
      offloader.io.vertexInputsOffloadGet3(localIndex) := vertices(vertexIndex).io.stageOutputs.offloadGet3
    }
    for ((edgeIndex, localIndex) <- config.offloaderNeighborEdgeIndices(offloaderIndex).zipWithIndex) {
      offloader.io.neighborEdgeInputsOffloadGet3(localIndex) := edges(edgeIndex).io.stageOutputs.offloadGet3
    }
    val edgeIndex = config.offloaderEdgeIndex(offloaderIndex)
    offloader.io.edgeInputOffloadGet3 := edges(edgeIndex).io.stageOutputs.offloadGet3
  }

  // Preserve the graph tree's leaf order while balancing the max-growable reduction.
  val maxGrowableCandidates = vertices.map(_.io.maxGrowable) ++ edges.map(_.io.maxGrowable)
  val maxGrowableInOrder = DistributedDual
    .maxGrowableLeafIndicesInOrder(config.graph.vertex_edge_binary_tree)
    .map(index => maxGrowableCandidates(index))
  val selectedMaxGrowable = Delay(
    DistributedDual.reduceMaxGrowablePipelined(
      maxGrowableInOrder,
      config.maxGrowablePipelineLatency
    )(_.length),
    config.convergecastDelay
  )
  io.maxGrowable.resizedFrom(selectedMaxGrowable)

  // Preserve the graph tree's leaf order while balancing the conflict reduction.
  val conflictCandidates = edges.map(_.io.conflict)
  val conflictInOrder = DistributedDual
    .conflictLeafIndicesInOrder(config.graph.edge_binary_tree)
    .map(index => conflictCandidates(index))
  val conflictPipelineLatency = Math.min(config.maxGrowablePipelineLatency, 1)
  val selectedConflict = DistributedDual.reduceConflictPipelined(
    conflictInOrder,
    conflictPipelineLatency
  )(_.valid)
  val conflictTailLatency =
    config.maxGrowablePipelineLatency + config.convergecastDelay - conflictPipelineLatency
  val convergecastedConflict = Delay(selectedConflict, conflictTailLatency)
  io.conflict.resizedFrom(convergecastedConflict)

  // build convergecast tree of parity reporter
  for ((parityReporter, index) <- config.parityReporters.zipWithIndex) {
    val parities = Vec.fill(parityReporter.length)(Bool)
    for ((offloaderIndex, reportIndex) <- parityReporter.zipWithIndex) {
      if (offloaderIndex < offloaders.length) {
        parities(reportIndex) := offloaders(offloaderIndex.toInt).io.condition
      } else {
        parities(reportIndex) := False
      }
    }
    val parityReport = parities.reduceBalancedTree(_ ^ _) // XOR
    io.parityReports(index) := Delay(
      parityReport,
      config.maxGrowablePipelineLatency + config.convergecastDelay
    )
  }

  def simExecute(instruction: Long): (DataMaxGrowable, DataConflictRaw) = {
    io.message.valid #= true
    io.message.instruction #= instruction
    clockDomain.waitSampling()
    io.message.valid #= false
    for (idx <- 0 until config.readLatency - 1) { clockDomain.waitSampling() }
    sleep(1)
    (
      DataMaxGrowable(io.maxGrowable.length.toInt),
      // the distributed dual does not do node reordering, so leave the original index here
      DataConflictRaw(
        io.conflict.valid.toBoolean,
        io.conflict.node1.toInt,
        io.conflict.node2.toInt,
        io.conflict.touch1.toInt,
        io.conflict.touch2.toInt,
        io.conflict.vertex1.toInt,
        io.conflict.vertex2.toInt
      )
    )
  }

  // before compiling the simulator, mark the fields as public to enable snapshot
  def simMakePublicSnapshot() = {
    vertices.foreach(vertex => {
      vertex.register.simPublic()
      vertex.io.simPublic()
    })
    edges.foreach(edge => {
      if (!config.hardCodeWeights) {
        edge.register.simPublic()
      }
      edge.io.simPublic()
    })
    offloaders.foreach(offloader => {
      offloader.io.simPublic()
    })
  }

  // a temporary solution without primal offloading
  def simFindObstacle(maxGrowth: Long): (DataMaxGrowable, DataConflictRaw, Long) = {
    var (maxGrowable, conflict) = simExecute(ioConfig.instructionSpec.generateFindObstacle())
    var grown = 0.toLong
    breakable {
      while (maxGrowable.length > 0 && !conflict.valid) {
        var length = maxGrowable.length.toLong
        if (length == ioConfig.LengthNone) {
          break
        }
        if (length + grown > maxGrowth) {
          length = maxGrowth - grown
        }
        if (length == 0) {
          break
        }
        grown += length
        simExecute(ioConfig.instructionSpec.generateGrow(length))
        val update = simExecute(ioConfig.instructionSpec.generateFindObstacle())
        maxGrowable = update._1
        conflict = update._2
      }
    }
    (maxGrowable, conflict, grown)
  }

  // take a snapshot of the dual module, in the format of fusion blossom visualization
  def simSnapshot(abbrev: Boolean = true): Json = {
    // https://circe.github.io/circe/api/io/circe/JsonObject.html
    var jsonVertices = ArrayBuffer[Json]()
    vertices.foreach(vertex => {
      val register = vertex.register
      val vertexMap = Map(
        (if (abbrev) { "v" }
         else { "is_virtual" }) -> Json.fromBoolean(register.isVirtual.toBoolean),
        (if (abbrev) { "s" }
         else { "is_defect" }) -> Json.fromBoolean(register.isDefect.toBoolean)
      )
      val node = register.node.toLong
      if (node != config.IndexNone) {
        vertexMap += ((
          if (abbrev) { "p" }
          else { "propagated_dual_node" },
          Json.fromLong(node)
        ))
      }
      val root = register.root.toLong
      if (root != config.IndexNone) {
        vertexMap += ((
          if (abbrev) { "pg" }
          else { "propagated_grandson_dual_node" },
          Json.fromLong(root)
        ))
      }
      jsonVertices.append(Json.fromFields(vertexMap))
    })
    var jsonEdges = ArrayBuffer[Json]()
    edges.foreach(edge => {
      val register = edge.register
      val weight = if (config.hardCodeWeights) { config.graph.weighted_edges(edge.edgeIndex).w.toLong }
      else { register.weight.toLong }
      val (leftIndex, rightIndex) = config.incidentVerticesOf(edge.edgeIndex)
      val leftReg = vertices(leftIndex).register
      val rightReg = vertices(rightIndex).register
      val edgeMap = Map(
        (if (abbrev) { "w" }
         else { "weight" }) -> Json.fromLong(weight),
        (if (abbrev) { "l" }
         else { "left" }) -> Json.fromLong(leftIndex),
        (if (abbrev) { "r" }
         else { "right" }) -> Json.fromLong(rightIndex),
        (if (abbrev) { "lg" }
         else { "left_growth" }) -> Json.fromLong(leftReg.grown.toLong),
        (if (abbrev) { "rg" }
         else { "right_growth" }) -> Json.fromLong(rightReg.grown.toLong)
      )
      val leftNode = leftReg.node.toLong
      if (leftNode != config.IndexNone) {
        edgeMap += ((
          if (abbrev) { "ld" }
          else { "left_dual_node" },
          Json.fromLong(leftNode)
        ))
      }
      val leftRoot = leftReg.root.toLong
      if (leftRoot != config.IndexNone) {
        edgeMap += ((
          if (abbrev) { "lgd" }
          else { "left_grandson_dual_node" },
          Json.fromLong(leftRoot)
        ))
      }
      val rightNode = rightReg.node.toLong
      if (rightNode != config.IndexNone) {
        edgeMap += ((
          if (abbrev) { "rd" }
          else { "right_dual_node" },
          Json.fromLong(rightNode)
        ))
      }
      val rightRoot = rightReg.root.toLong
      if (rightRoot != config.IndexNone) {
        edgeMap += ((
          if (abbrev) { "rgd" }
          else { "right_grandson_dual_node" },
          Json.fromLong(rightRoot)
        ))
      }
      jsonEdges.append(Json.fromFields(edgeMap))
    })
    Json.fromFields(
      Map(
        "vertices" -> Json.fromValues(jsonVertices),
        "edges" -> Json.fromValues(jsonEdges)
      )
    )
  }

  def simMakePublicPreMatching() = {
    vertices.foreach(vertex => {
      vertex.register.node.simPublic()
      vertex.register.root.simPublic()
    })
    offloaders.foreach(offloader => {
      offloader.io.stageOutputs.offloadGet4.condition.simPublic()
    })
  }

  def simPreMatchings(): Seq[DataPreMatching] = {
    var preMatchings = ArrayBuffer[DataPreMatching]()
    for ((offloader, offloaderIndex) <- offloaders.zipWithIndex) {
      val edgeIndex = config.offloaderEdgeIndex(offloaderIndex)
      if (offloader.io.stageOutputs.offloadGet4.condition.toBoolean) {
        var pairIndex = config.incidentVerticesOf(edgeIndex)
        var pair = (vertices(pairIndex._1).register, vertices(pairIndex._2).register)
        if (pair._1.node.toLong == config.IndexNone) {
          pair = pair.swap
          pairIndex = pairIndex.swap
        }
        val node1 = pair._1.node.toInt
        val node2 = pair._2.node.toInt
        val touch1 = pair._1.root.toInt
        val touch2 = pair._2.root.toInt
        var vertex1 = pairIndex._1
        var vertex2 = pairIndex._2
        assert(node1 != config.IndexNone)
        assert(touch1 != config.IndexNone)
        assert(vertex1 != config.IndexNone)
        assert(vertex2 != config.IndexNone)
        val option_node2: Option[Int] = if (node2 == config.IndexNone) { None }
        else { Some(node2) }
        val option_touch2: Option[Int] = if (touch2 == config.IndexNone) { None }
        else { Some(touch2) }
        preMatchings.append(
          DataPreMatching(edgeIndex, node1, option_node2, touch1, option_touch2, vertex1, vertex2)
        )
      }
    }
    preMatchings
  }
}

private[modules] case class TaggedMaxGrowable(weightBits: Int, sourceBits: Int) extends Bundle {
  val length = UInt(weightBits bits)
  val source = UInt(sourceBits bits)
}

private[modules] case class MaxGrowableReductionHarness(
    candidateCount: Int,
    weightBits: Int,
    pipelineLatency: Int
) extends Component {
  private val sourceBits = log2Up(candidateCount)

  val io = new Bundle {
    val lengths = in(Vec.fill(candidateCount)(UInt(weightBits bits)))
    val selectedLength = out(UInt(weightBits bits))
    val selectedSource = out(UInt(sourceBits bits))
  }

  val candidates = io.lengths.zipWithIndex.map { case (length, index) =>
    val candidate = TaggedMaxGrowable(weightBits, sourceBits)
    candidate.length := length
    candidate.source := U(index, sourceBits bits)
    candidate
  }
  val selected = DistributedDual.reduceMaxGrowablePipelined(
    candidates.toIndexedSeq,
    pipelineLatency
  )(_.length)
  io.selectedLength := selected.length
  io.selectedSource := selected.source
}

class MaxGrowableReductionTest extends AnyFunSuite {
  private case class ModelCandidate(length: Int, source: Int)

  private val weightBits = 5

  private def graphConfig(environmentName: String): DualConfig = {
    val graphPath = sys.env.getOrElse(
      environmentName,
      fail(s"$environmentName must name a circuit-level graph")
    )
    DualConfig(filename = graphPath)
  }

  private lazy val circuitD3 = graphConfig("MICROBLOSSOM_CIRCUIT_D3_GRAPH")
  private lazy val circuitD9 = graphConfig("MICROBLOSSOM_CIRCUIT_D9_GRAPH")

  private lazy val compiledD3 = SimConfig
    .withConfig(Config.spinal())
    .workspaceName("max-growable-circuit-d3")
    .allOptimisation
    .compile(MaxGrowableReductionHarness(circuitD3.vertexNum + circuitD3.edgeNum, weightBits, 0))

  private lazy val compiledD9 = SimConfig
    .withConfig(Config.spinal())
    .workspaceName("max-growable-circuit-d9-pipelined")
    .allOptimisation
    .compile(MaxGrowableReductionHarness(circuitD9.vertexNum + circuitD9.edgeNum, weightBits, 2))

  private def select(left: ModelCandidate, right: ModelCandidate): ModelCandidate = {
    if (left.length < right.length) left else right
  }

  private def expected(values: IndexedSeq[Int]): ModelCandidate = {
    values.indices
      .map(index => ModelCandidate(values(index), index))
      .reduceLeft(select)
  }

  private def legacyTreeReduce(tree: BinaryTree, values: IndexedSeq[Int], nodeIndex: Int): ModelCandidate = {
    val node = tree.nodes(nodeIndex)
    (node.l, node.r) match {
      case (None, None) => ModelCandidate(values(nodeIndex), nodeIndex)
      case (Some(left), Some(right)) =>
        select(
          legacyTreeReduce(tree, values, left.toInt),
          legacyTreeReduce(tree, values, right.toInt)
        )
      case _ => fail("binary tree node must have either zero or two children")
    }
  }

  private def checkGraphOrdering(config: DualConfig, expectedLeafCount: Int, seed: Long): Unit = {
    val tree = config.graph.vertex_edge_binary_tree
    val inOrder = DistributedDual.maxGrowableLeafIndicesInOrder(tree)
    assert(config.vertexNum + config.edgeNum == expectedLeafCount)
    assert(inOrder.length == expectedLeafCount)
    assert(inOrder.distinct.length == expectedLeafCount)
    assert(inOrder.sorted.sameElements(0 until expectedLeafCount))

    val allEqual = IndexedSeq.fill(expectedLeafCount)(3)
    assert(legacyTreeReduce(tree, allEqual, tree.nodes.length - 1).source == inOrder.last)

    val random = new scala.util.Random(seed)
    for (_ <- 0 until 128) {
      val values = IndexedSeq.fill(expectedLeafCount)(random.nextInt(1 << weightBits))
      val legacy = legacyTreeReduce(tree, values, tree.nodes.length - 1)
      val balanced = inOrder.iterator.map(index => ModelCandidate(values(index), index)).reduceLeft(select)
      assert(balanced == legacy)
    }
  }

  private def drive(dut: MaxGrowableReductionHarness, values: IndexedSeq[Int]): Unit = {
    values.zipWithIndex.foreach { case (value, index) => dut.io.lengths(index) #= value }
  }

  private def checkOutput(
      dut: MaxGrowableReductionHarness,
      reference: ModelCandidate
  ): Unit = {
    assert(dut.io.selectedLength.toInt == reference.length)
    assert(dut.io.selectedSource.toInt == reference.source)
  }

  test("circuit d3 keeps ordered right-biased random and tie results at zero reduction latency") {
    assert(circuitD3.vertexNum + circuitD3.edgeNum == 58)
    assert(circuitD3.distributedControlLatency == 1)
    assert(circuitD3.broadcastLatency == 1)
    assert(circuitD3.executeLatency == 0)
    assert(circuitD3.maxGrowablePipelineLatency == 0)
    assert(circuitD3.convergecastDelay == 1)
    assert(circuitD3.readLatency == 2)
    assert(circuitD3.initiationInterval == 1)
    checkGraphOrdering(circuitD3, 58, 0x0d3c0deL)

    compiledD3.doSim("ties-and-random") { dut =>
      val directed = Seq(
        IndexedSeq.fill(58)(7),
        IndexedSeq.tabulate(58)(index => if (Set(0, 16, 57).contains(index)) 1 else 9),
        IndexedSeq.tabulate(58)(index => if (index == 0) 0 else 11)
      )
      val random = new scala.util.Random(0x3eedc0deL)
      val vectors = directed ++ Seq.fill(256)(IndexedSeq.fill(58)(random.nextInt(1 << weightBits)))
      vectors.foreach { values =>
        drive(dut, values)
        sleep(1)
        checkOutput(dut, expected(values))
      }
    }
  }

  test("circuit d9 keeps ordered right-biased random and tie results at two-cycle reduction latency") {
    val candidateCount = circuitD9.vertexNum + circuitD9.edgeNum
    assert(candidateCount == 2170)
    circuitD9.injectRegisters = Seq("execute2", "update")
    circuitD9.maxGrowablePipelineLatency = 2
    assert(circuitD9.distributedControlLatency == 2)
    assert(circuitD9.broadcastLatency == 2)
    assert(circuitD9.executeLatency == 2)
    assert(circuitD9.maxGrowablePipelineLatency == 2)
    assert(circuitD9.convergecastDelay == 1)
    assert(circuitD9.readLatency == 7)
    assert(circuitD9.initiationInterval == 1)
    checkGraphOrdering(circuitD9, candidateCount, 0x0d9c0deL)

    val firstBoundary = DistributedDual.contiguousGroups(
      (0 until candidateCount).toIndexedSeq,
      16 * 16
    )
    assert(firstBoundary.length == 256)
    assert(firstBoundary.forall(group => group.length == 8 || group.length == 9))
    assert(firstBoundary.flatten.sameElements(0 until candidateCount))
    assert(firstBoundary.grouped(16).length == 16)

    compiledD9.doSim("ties-random-and-latency") { dut =>
      dut.clockDomain.forkStimulus(period = 10)
      val idle = IndexedSeq.fill(candidateCount)((1 << weightBits) - 1)
      drive(dut, idle)
      for (_ <- 0 until 3) { dut.clockDomain.waitSampling() }

      val directed = Seq(
        IndexedSeq.fill(candidateCount)(7),
        IndexedSeq.tabulate(candidateCount)(index => if (Set(0, 255, 256, 2169).contains(index)) 1 else 9),
        IndexedSeq.tabulate(candidateCount)(index => if (Set(15, 16, 1023, 2048).contains(index)) 2 else 10),
        IndexedSeq.tabulate(candidateCount)(index => if (index == 0) 0 else 11)
      )
      val random = new scala.util.Random(0x9eedc0deL)
      val vectors = directed ++ Seq.fill(32)(
        IndexedSeq.fill(candidateCount)(random.nextInt(1 << weightBits))
      )
      val pending = scala.collection.mutable.Queue[ModelCandidate]()

      vectors.foreach { values =>
        drive(dut, values)
        pending.enqueue(expected(values))
        dut.clockDomain.waitSampling()
        sleep(1)
        if (pending.length >= 2) {
          checkOutput(dut, pending.dequeue())
        }
      }
      while (pending.nonEmpty) {
        drive(dut, idle)
        dut.clockDomain.waitSampling()
        sleep(1)
        checkOutput(dut, pending.dequeue())
      }
    }
  }
}

private[modules] case class TaggedConflict(payloadBits: Int, sourceBits: Int) extends Bundle {
  val valid = Bool()
  val payload = UInt(payloadBits bits)
  val source = UInt(sourceBits bits)
}

private[modules] case class ConflictReductionHarness(
    tree: BinaryTree,
    candidateCount: Int,
    payloadBits: Int,
    pipelineLatency: Int,
    tailLatency: Int
) extends Component {
  private val sourceBits = log2Up(candidateCount)

  val io = new Bundle {
    val valids = in(Vec.fill(candidateCount)(Bool))
    val payloads = in(Vec.fill(candidateCount)(UInt(payloadBits bits)))
    val selectedValid = out(Bool)
    val selectedPayload = out(UInt(payloadBits bits))
    val selectedSource = out(UInt(sourceBits bits))
  }

  val candidates = io.valids.zip(io.payloads).zipWithIndex.map { case ((valid, payload), index) =>
    val candidate = TaggedConflict(payloadBits, sourceBits)
    candidate.valid := valid
    candidate.payload := payload
    candidate.source := U(index, sourceBits bits)
    candidate
  }
  val inOrder = DistributedDual
    .conflictLeafIndicesInOrder(tree)
    .map(index => candidates(index))
  val selected = Delay(
    DistributedDual.reduceConflictPipelined(inOrder, pipelineLatency)(_.valid),
    tailLatency
  )
  io.selectedValid := selected.valid
  io.selectedPayload := selected.payload
  io.selectedSource := selected.source
}

class ConflictReductionTest extends AnyFunSuite {
  private case class InputCandidate(valid: Boolean, payload: Int)
  private case class ModelCandidate(valid: Boolean, payload: Int, source: Int)

  private val payloadBits = 8

  private def graphConfig(environmentName: String): DualConfig = {
    val graphPath = sys.env.getOrElse(
      environmentName,
      fail(s"$environmentName must name a circuit-level graph")
    )
    DualConfig(filename = graphPath)
  }

  private lazy val circuitD3 = graphConfig("MICROBLOSSOM_CIRCUIT_D3_GRAPH")
  private lazy val circuitD9 = {
    val config = graphConfig("MICROBLOSSOM_CIRCUIT_D9_GRAPH")
    config.injectRegisters = Seq("execute2", "update")
    config.maxGrowablePipelineLatency = 2
    config
  }

  private def pipelineLatency(config: DualConfig): Int = {
    Math.min(config.maxGrowablePipelineLatency, 1)
  }

  private def tailLatency(config: DualConfig): Int = {
    config.maxGrowablePipelineLatency + config.convergecastDelay - pipelineLatency(config)
  }

  private def totalLatency(config: DualConfig): Int = {
    pipelineLatency(config) + tailLatency(config)
  }

  private lazy val compiledD3 = SimConfig
    .withConfig(Config.spinal())
    .workspaceName("conflict-circuit-d3")
    .allOptimisation
    .compile(
      ConflictReductionHarness(
        circuitD3.graph.edge_binary_tree,
        circuitD3.edgeNum,
        payloadBits,
        pipelineLatency(circuitD3),
        tailLatency(circuitD3)
      )
    )

  private lazy val compiledD9 = SimConfig
    .withConfig(Config.spinal())
    .workspaceName("conflict-circuit-d9-pipelined")
    .allOptimisation
    .compile(
      ConflictReductionHarness(
        circuitD9.graph.edge_binary_tree,
        circuitD9.edgeNum,
        payloadBits,
        pipelineLatency(circuitD9),
        tailLatency(circuitD9)
      )
    )

  private def select(left: ModelCandidate, right: ModelCandidate): ModelCandidate = {
    if (left.valid) left else right
  }

  private def legacyTreeReduce(
      tree: BinaryTree,
      values: IndexedSeq[InputCandidate],
      nodeIndex: Int
  ): ModelCandidate = {
    val node = tree.nodes(nodeIndex)
    (node.l, node.r) match {
      case (None, None) =>
        val value = values(nodeIndex)
        ModelCandidate(value.valid, value.payload, nodeIndex)
      case (Some(left), Some(right)) =>
        select(
          legacyTreeReduce(tree, values, left.toInt),
          legacyTreeReduce(tree, values, right.toInt)
        )
      case _ => fail("binary tree node must have either zero or two children")
    }
  }

  private def expected(config: DualConfig, values: IndexedSeq[InputCandidate]): ModelCandidate = {
    val tree = config.graph.edge_binary_tree
    legacyTreeReduce(tree, values, tree.nodes.length - 1)
  }

  private def orderedExpected(config: DualConfig, values: IndexedSeq[InputCandidate]): ModelCandidate = {
    DistributedDual
      .conflictLeafIndicesInOrder(config.graph.edge_binary_tree)
      .map { index =>
        val value = values(index)
        ModelCandidate(value.valid, value.payload, index)
      }
      .reduceLeft(select)
  }

  private def directedVectors(config: DualConfig): Seq[IndexedSeq[InputCandidate]] = {
    val order = DistributedDual.conflictLeafIndicesInOrder(config.graph.edge_binary_tree)
    val groups = DistributedDual.contiguousGroups(
      order,
      DistributedDual.conflictBoundaryGroupCount(order.length)
    )
    val acrossBoundary = Set(groups.head.last, groups(1).head, groups.last.last)
    Seq(
      IndexedSeq.fill(config.edgeNum)(InputCandidate(valid = true, payload = 7)),
      IndexedSeq.tabulate(config.edgeNum)(index => InputCandidate(valid = false, payload = index & 0xff)),
      IndexedSeq.tabulate(config.edgeNum) { index =>
        InputCandidate(valid = acrossBoundary.contains(index), payload = 11)
      },
      IndexedSeq.tabulate(config.edgeNum) { index =>
        InputCandidate(valid = index == order.last, payload = 13)
      }
    )
  }

  private def randomVectors(
      config: DualConfig,
      count: Int,
      seed: Long
  ): Seq[IndexedSeq[InputCandidate]] = {
    val random = new scala.util.Random(seed)
    Seq.fill(count)(
      IndexedSeq.fill(config.edgeNum)(
        InputCandidate(random.nextInt(4) == 0, random.nextInt(1 << payloadBits))
      )
    )
  }

  private def drive(dut: ConflictReductionHarness, values: IndexedSeq[InputCandidate]): Unit = {
    values.zipWithIndex.foreach { case (value, index) =>
      dut.io.valids(index) #= value.valid
      dut.io.payloads(index) #= value.payload
    }
  }

  private def checkOutput(dut: ConflictReductionHarness, reference: ModelCandidate): Unit = {
    assert(dut.io.selectedValid.toBoolean == reference.valid)
    assert(dut.io.selectedPayload.toInt == reference.payload)
    assert(dut.io.selectedSource.toInt == reference.source)
  }

  private def runVectors(
      dut: ConflictReductionHarness,
      config: DualConfig,
      vectors: Seq[IndexedSeq[InputCandidate]]
  ): Unit = {
    val idle = IndexedSeq.fill(config.edgeNum)(InputCandidate(valid = false, payload = 0))
    val latency = totalLatency(config)
    val pending = scala.collection.mutable.Queue[ModelCandidate]()

    drive(dut, idle)
    for (_ <- 0 to latency) { dut.clockDomain.waitSampling() }

    vectors.foreach { values =>
      val reference = expected(config, values)
      assert(orderedExpected(config, values) == reference)
      drive(dut, values)
      pending.enqueue(reference)
      dut.clockDomain.waitSampling()
      sleep(1)
      if (pending.length >= latency) {
        checkOutput(dut, pending.dequeue())
      }
    }
    while (pending.nonEmpty) {
      drive(dut, idle)
      dut.clockDomain.waitSampling()
      sleep(1)
      checkOutput(dut, pending.dequeue())
    }
  }

  test("circuit d3 preserves conflict priority and one-cycle alignment") {
    assert(circuitD3.edgeNum == 39)
    assert(circuitD3.distributedControlLatency == 1)
    assert(circuitD3.broadcastLatency == 1)
    assert(circuitD3.executeLatency == 0)
    assert(circuitD3.maxGrowablePipelineLatency == 0)
    assert(circuitD3.convergecastDelay == 1)
    assert(pipelineLatency(circuitD3) == 0)
    assert(tailLatency(circuitD3) == 1)
    assert(circuitD3.readLatency == 2)
    assert(circuitD3.initiationInterval == 1)

    compiledD3.doSim("equal-valid-priority-random-latency") { dut =>
      dut.clockDomain.forkStimulus(period = 10)
      runVectors(
        dut,
        circuitD3,
        directedVectors(circuitD3) ++ randomVectors(circuitD3, 256, 0x3c0ff1c7L)
      )
    }
  }

  test("circuit d9 moves one conflict cycle into an ordered internal boundary") {
    val order = DistributedDual.conflictLeafIndicesInOrder(circuitD9.graph.edge_binary_tree)
    assert(circuitD9.edgeNum == 1737)
    assert(order.length == circuitD9.edgeNum)
    assert(order.distinct.length == circuitD9.edgeNum)
    assert(order.sorted.sameElements(0 until circuitD9.edgeNum))
    assert(DistributedDual.conflictBoundaryGroupCount(circuitD9.edgeNum) == 32)
    val groups = DistributedDual.contiguousGroups(order, 32)
    assert(groups.forall(group => group.length == 54 || group.length == 55))
    assert(groups.flatten == order)
    assert(circuitD9.distributedControlLatency == 2)
    assert(circuitD9.broadcastLatency == 2)
    assert(circuitD9.executeLatency == 2)
    assert(circuitD9.maxGrowablePipelineLatency == 2)
    assert(circuitD9.convergecastDelay == 1)
    assert(pipelineLatency(circuitD9) == 1)
    assert(tailLatency(circuitD9) == 2)
    assert(circuitD9.readLatency == 7)
    assert(circuitD9.initiationInterval == 1)

    compiledD9.doSim("equal-valid-priority-random-latency") { dut =>
      dut.clockDomain.forkStimulus(period = 10)
      runVectors(
        dut,
        circuitD9,
        directedVectors(circuitD9) ++ randomVectors(circuitD9, 32, 0x9c0ff1c7L)
      )
    }
  }
}

// sbt 'testOnly microblossom.modules.DistributedDualTest'
class DistributedDualTest extends AnyFunSuite {

  test("construct a DistributedDual") {
    val config = DualConfig(filename = "./resources/graphs/example_code_capacity_d3.json")
    val ioConfig = DualConfig()
    // config.contextDepth = 1024 // fit in a single Block RAM of 36 kbits in 36-bit mode
    config.contextDepth = 1 // no context switch
    config.sanityCheck()
    Config.spinal().generateVerilog(DistributedDual(config, ioConfig))
  }

  test("test pipeline registers") {
    // gtkwave simWorkspace/DistributedDual/testA.fst
    val config = DualConfig(filename = "./resources/graphs/example_code_capacity_d3.json", minimizeBits = false)
    val ioConfig = DualConfig()
    config.graph.offloading = Seq() // remove all offloaders
    config.fitGraph(minimizeBits = false)
    config.sanityCheck()
    Config.sim
      .compile({
        val dut = DistributedDual(config, ioConfig)
        dut.simMakePublicSnapshot()
        dut
      })
      .doSim("testA") { dut =>
        dut.io.message.valid #= false
        dut.clockDomain.forkStimulus(period = 10)

        for (idx <- 0 to 10) { dut.clockDomain.waitSampling() }

        dut.simExecute(ioConfig.instructionSpec.generateReset())
        dut.simExecute(ioConfig.instructionSpec.generateAddDefect(0, 0))
        var (maxGrowable, conflict) = dut.simExecute(ioConfig.instructionSpec.generateFindObstacle())

        assert(maxGrowable.length == 2) // at most grow 2
        assert(conflict.valid == false)

        dut.simExecute(ioConfig.instructionSpec.generateGrow(1))
        var (maxGrowable2, conflict2) = dut.simExecute(ioConfig.instructionSpec.generateFindObstacle())
        assert(maxGrowable2.length == 1)
        assert(conflict2.valid == false)

        val (_, conflict3, grown3) = dut.simFindObstacle(1)
        assert(grown3 == 1)
        assert(conflict3.valid == true)
        assert(conflict3.node1 == 0)
        assert(conflict3.node2 == ioConfig.IndexNone)
        assert(conflict3.touch1 == 0)
        assert(conflict3.touch2 == ioConfig.IndexNone)
        assert(conflict3.vertex1 == 0)
        assert(conflict3.vertex2 == 3)

        println(dut.simSnapshot().noSpacesSortKeys)

        for (idx <- 0 to 10) { dut.clockDomain.waitSampling() }

      }
  }

}

// sbt "runMain microblossom.modules.DistributedDualTestDebug1"
object DistributedDualTestDebug1 extends App {
  // gtkwave simWorkspace/DistributedDualTest/testB.fst
  val config = DualConfig(filename = "./resources/graphs/example_code_capacity_planar_d3.json", minimizeBits = false)
  val ioConfig = DualConfig()
  config.graph.offloading = Seq() // remove all offloaders
  config.fitGraph(minimizeBits = false)
  config.sanityCheck()
  Config.sim
    .compile({
      val dut = DistributedDual(config, ioConfig)
      dut.simMakePublicSnapshot()
      dut
    })
    .doSim("testB") { dut =>
      dut.io.message.valid #= false
      dut.clockDomain.forkStimulus(period = 10)

      for (idx <- 0 to 10) { dut.clockDomain.waitSampling() }

      dut.simExecute(ioConfig.instructionSpec.generateReset())
      dut.simExecute(ioConfig.instructionSpec.generateAddDefect(0, 0))
      dut.simExecute(ioConfig.instructionSpec.generateAddDefect(4, 1))
      dut.simExecute(ioConfig.instructionSpec.generateAddDefect(8, 2))

      val (_, conflict, grown) = dut.simFindObstacle(1000)
      assert(grown == 1)
      assert(conflict.valid == true)
      println(conflict.node1, conflict.node2, conflict.touch1, conflict.touch2)

      println(dut.simSnapshot().noSpacesSortKeys)

      dut.simExecute(ioConfig.instructionSpec.generateSetBlossom(0, 3000))
      dut.simExecute(ioConfig.instructionSpec.generateSetBlossom(1, 3000))
      dut.simExecute(ioConfig.instructionSpec.generateSetBlossom(2, 3000))
      dut.simExecute(ioConfig.instructionSpec.generateSetSpeed(3, Speed.Shrink))

      for (idx <- 0 to 10) { dut.clockDomain.waitSampling() }

    }
}

object Local {

  def dualConfig(name: String, removeWeight: Boolean = false): DualConfig = {
    val config = DualConfig(filename = s"./resources/graphs/example_$name.json")
    if (removeWeight) {
      for (edgeIndex <- 0 until config.edgeNum) {
        config.graph.weighted_edges(edgeIndex).w = 2
      }
      config.fitGraph()
      require(config.weightBits == 2)
    }
    config
  }
}

// sbt 'runMain microblossom.modules.DistributedDualEstimation'
object DistributedDualEstimation extends App {
  val configurations = List(
    // synth: 387, impl: 310 Slice LUTs (0.14% on ZCU106), or 407 CLB LUTs (0.05% on VMK180)
    (Local.dualConfig("code_capacity_d5"), "code capacity repetition d=5"),
    // synth: 1589, impl: 1309 Slice LUTs (0.6% on ZCU106), or 1719 CLB LUTs (0.19% on VMK180)
    (Local.dualConfig("code_capacity_rotated_d5"), "code capacity rotated d=5"),
    // synth: 15470, impl: 13186 Slice LUTs (6.03% on ZCU106)
    (Local.dualConfig("phenomenological_rotated_d5"), "phenomenological d=5"),
    // synth: 31637, impl: 25798 Slice LUTs (11.80% on ZCU106)
    (Local.dualConfig("circuit_level_d5", true), "circuit-level d=5 (unweighted)"),
    // synth: 41523, impl: 34045 Slice LUTs (15.57% on ZCU106)
    (Local.dualConfig("circuit_level_d5"), "circuit-level d=5"),
    // synth: 299282, impl:
    (Local.dualConfig("circuit_level_d9"), "circuit-level d=9")
  )
  for ((config, name) <- configurations) {
    // val reports = Vivado.report(DistributedDual(config, config))
    val reports = Vivado.report(DistributedDual(config, config), useImpl = true)
    println(s"$name:")
    // reports.resource.primitivesTable.print()
    reports.resource.netlistLogicTable.print()
  }
}

// sbt 'runMain microblossom.modules.DistributedDualPhenomenologicalEstimation'
object DistributedDualPhenomenologicalEstimation extends App {
  // post-implementation estimations on VMK180
  // d=3: 3873 LUTs (0.43%), 670 Registers (0.04%)
  // d=5: 17293 LUTs (1.92%), 2474 Registers (0.14%)
  // d=7: 48709 LUTs (5.41%), 6233 Registers (0.35%)
  // d=9: 106133 LUTs (11.79%), 13170 Registers (0.73%)
  // d=11: 205457 LUTs (22.83%), 24621 Registers (1.37%)
  // d=13: 354066 LUTs (39.35%), 41790 Registers (2.32%)
  // d=15: 529711 LUTs (58.87%), 62267 Registers (3.46%)
  // d=17: 799536 LUTs (88.85%), 94875 Registers (5.27%)
  for (d <- List(3, 5, 7, 9, 11, 13, 15, 17)) {
    val config = Local.dualConfig(s"phenomenological_rotated_d$d")
    val reports = Vivado.report(DistributedDual(config, config), useImpl = true)
    println(s"phenomenological d = $d:")
    reports.resource.netlistLogicTable.print()
  }
}

// sbt 'runMain microblossom.modules.DistributedDualCircuitLevelUnweightedEstimation'
object DistributedDualCircuitLevelUnweightedEstimation extends App {
  // post-implementation estimations on VMK180
  // d=3: 6540 LUTs (0.73%), 1064 Registers (0.06%)
  // d=5: 39848 LUTs (4.43%), 4558 Registers (0.25%)
  // d=7: 128923 LUTs (14.33%), 12387 Registers (0.69%)
  // d=9: 307017 LUTs (34.12%), 26856 Registers (1.49%)
  // d=11: 609352 LUTs (67.72%), 50385 Registers (2.80%)
  for (d <- List(3, 5, 7, 9, 11)) {
    val config = Local.dualConfig(s"circuit_level_d$d", removeWeight = true)
    val reports = Vivado.report(DistributedDual(config, config), useImpl = true)
    println(s"circuit-level unweighted d = $d:")
    reports.resource.netlistLogicTable.print()
  }
}

// sbt 'runMain microblossom.modules.DistributedDualCircuitLevelEstimation'
object DistributedDualCircuitLevelEstimation extends App {
  // post-implementation estimations on VMK180
  // d=3: 7575 LUTs (0.84%), 1110 Registers (0.06%)
  // d=5: 46483 LUTs (5.17%), 4684 Registers (0.26%)
  // d=7: 146994 LUTs (16.34%), 12576 Registers (0.70%)
  // d=9: 342254 LUTs (38.03%), 27151 Registers (1.51%)
  // d=11: 679519 LUTs (75.52%), 50907 Registers (2.83%)
  for (d <- List(3, 5, 7, 9, 11)) {
    val config = Local.dualConfig(s"circuit_level_d$d")
    val reports = Vivado.report(DistributedDual(config, config), useImpl = true)
    println(s"circuit-level d = $d:")
    reports.resource.netlistLogicTable.print()
  }
}

// sbt 'runMain microblossom.modules.DistributedDualContextDepthEstimation'
object DistributedDualContextDepthEstimation extends App {
  // post-implementation estimations on VMK180
  // depth=1: 342254 LUTs (38.03%), 27151 Registers (1.51%)
  // depth=2: 429404 LUTs (47.72%), 52555 Registers (2.92%)
  // depth=4: 433277 LUTs (48.15%), 56941 Registers (3.16%)
  // depth=8: 436583 LUTs (48.52%), 61789 Registers (3.43%)
  // depth=16: 435172 LUTs (48.36%), 66428 Registers (3.69%)
  // depth=32: 436308 LUTs (48.49%), 71110 Registers (3.95%)
  // depth=64: 457438 LUTs (50.84%), 75760 Registers (4.21%)
  // depth=1024: seg fault, potentially due to insufficient memory
  val d = 9
  for (contextDepth <- List(1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048)) {
    val config = Local.dualConfig(s"circuit_level_d$d")
    config.contextDepth = contextDepth
    val reports = Vivado.report(DistributedDual(config, config), useImpl = true)
    println(s"contextDepth = $contextDepth:")
    reports.resource.netlistLogicTable.print()
  }
}

// sbt "runMain microblossom.modules.DistributedDualExamples"
object DistributedDualExamples extends App {
  for (d <- Seq(3, 5, 7)) {
    val config =
      DualConfig(filename = "./resources/graphs/example_code_capacity_planar_d%d.json".format(d), minimizeBits = true)
    Config.spinal("gen/example_code_capacity_planar_d%d".format(d)).generateVerilog(DistributedDual(config, config))
  }
  for (d <- Seq(3, 5, 7)) {
    val config =
      DualConfig(filename = "./resources/graphs/example_code_capacity_rotated_d%d.json".format(d), minimizeBits = true)
    Config.spinal("gen/example_code_capacity_rotated_d%d".format(d)).generateVerilog(DistributedDual(config, config))
  }
  for (d <- Seq(3, 5, 7, 9, 11)) {
    val config =
      DualConfig(
        filename = "./resources/graphs/example_phenomenological_rotated_d%d.json".format(d),
        minimizeBits = true
      )
    config.broadcastDelay = 2
    config.convergecastDelay = 4
    Config.spinal("gen/example_phenomenological_rotated_d%d".format(d)).generateVerilog(DistributedDual(config, config))
  }
}

// Note: to further increase the memory limit to instantiate even larger instances, see `javaOptions` in `build.sbt`
// sbt "runMain microblossom.modules.DistributedDualLargeInstance"
object DistributedDualLargeInstance extends App {
  val config = Local.dualConfig(s"circuit_level_d13")
  Config.spinal().generateVerilog(DistributedDual(config, config))
}
