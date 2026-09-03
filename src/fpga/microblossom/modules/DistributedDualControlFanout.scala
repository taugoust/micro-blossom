package microblossom.modules

import spinal.core._
import spinal.core.sim._
import microblossom._
import microblossom.types._
import org.scalatest.funsuite.AnyFunSuite

private[modules] case class ControlFanoutTopology(consumerCount: Int) {
  require(consumerCount > 0)

  val maxFanout: Int = DualConfig.DistributedControlMaxFanout

  val levelWidths: IndexedSeq[Int] = {
    if (consumerCount <= maxFanout) {
      IndexedSeq.empty
    } else {
      val widthsFromLeaves = collection.mutable.ArrayBuffer[Int]()
      var width = (consumerCount + maxFanout - 1) / maxFanout
      widthsFromLeaves.append(width)
      while (width > maxFanout) {
        width = (width + maxFanout - 1) / maxFanout
        widthsFromLeaves.append(width)
      }
      widthsFromLeaves.reverse.toIndexedSeq
    }
  }

  val depth: Int = levelWidths.length
  val leafCount: Int = levelWidths.lastOption.getOrElse(1)

  def leafForConsumer(consumerIndex: Int): Int = {
    require(consumerIndex >= 0 && consumerIndex < consumerCount)
    consumerIndex / maxFanout
  }
}

private[modules] case class DistributedDualControlFanout(config: DualConfig, consumerCount: Int) extends Component {
  private val topology = ControlFanoutTopology(consumerCount)

  val io = new Bundle {
    val message = in(BroadcastMessage(config))
    val leafMessages = out(Vec.fill(topology.leafCount)(BroadcastMessage(config)))
    val leafResets = out(Bits(topology.leafCount bits))
  }

  private case class ControlNode(message: BroadcastMessage, reset: Bool)

  private val sourceClockDomain = ClockDomain.current
  private val sourceReset = sourceClockDomain.isResetActive
  private val pipelineClockDomain = sourceClockDomain.withoutReset()
  private var previousLevel = IndexedSeq(ControlNode(io.message, sourceReset))

  for ((levelWidth, level) <- topology.levelWidths.zipWithIndex) {
    val parentLevel = previousLevel
    previousLevel = IndexedSeq.tabulate(levelWidth) { nodeIndex =>
      val parent = parentLevel(nodeIndex / topology.maxFanout)
      val messageStage = new ClockingArea(pipelineClockDomain) {
        val message = RegNext(parent.message)
        message.setName(s"message_l${level}_n${nodeIndex}")
        message.addAttribute("keep", "true")
        message.addAttribute("dont_touch", "true")
        message.addAttribute("max_fanout", topology.maxFanout)
      }

      // Each reset register asynchronously asserts from its parent and only
      // releases on a clock edge. Cascading these registers preserves direct
      // assertion while matching the message pipeline's equal-depth release.
      val resetClockDomain = sourceClockDomain.copy(
        reset = parent.reset,
        config = sourceClockDomain.config.copy(resetKind = ASYNC, resetActiveLevel = HIGH)
      )
      val resetStage = new ClockingArea(resetClockDomain) {
        val reset = Reg(Bool()) init (True)
        reset := False
        reset.setName(s"reset_l${level}_n${nodeIndex}")
        reset.addAttribute("keep", "true")
        reset.addAttribute("dont_touch", "true")
        reset.addAttribute("max_fanout", topology.maxFanout)
      }
      ControlNode(messageStage.message, resetStage.reset)
    }
  }

  for (leafIndex <- 0 until topology.leafCount) {
    io.leafMessages(leafIndex) := previousLevel(leafIndex).message
    io.leafResets(leafIndex) := previousLevel(leafIndex).reset
  }
}

// sbt 'testOnly microblossom.modules.DistributedDualControlFanoutTest'
class DistributedDualControlFanoutTest extends AnyFunSuite {
  private case class MessageSample(valid: Boolean, instruction: Long, isReset: Boolean, contextId: Int)

  private def graphConfig(environmentVariable: String): DualConfig = {
    DualConfig(filename = sys.env.getOrElse(environmentVariable, fail(s"$environmentVariable must name a graph")))
  }

  private def assertMinimalBoundedTopology(config: DualConfig, expectedVertices: Int, expectedEdges: Int): Unit = {
    assert(config.vertexNum == expectedVertices)
    assert(config.edgeNum == expectedEdges)
    assert(config.offloaderNum == 0)

    val topology = ControlFanoutTopology(config.distributedControlConsumerCount)
    val widths = IndexedSeq(1) ++ topology.levelWidths ++ IndexedSeq(topology.consumerCount)
    for (pair <- widths.sliding(2)) {
      val parentWidth = pair.head
      val childWidth = pair.last
      val minimumParentWidth = (childWidth + topology.maxFanout - 1) / topology.maxFanout
      assert(parentWidth == minimumParentWidth)
      assert(childWidth <= parentWidth * topology.maxFanout)
    }

    val leafLoads = Array.fill(topology.leafCount)(0)
    for (consumerIndex <- 0 until topology.consumerCount) {
      leafLoads(topology.leafForConsumer(consumerIndex)) += 1
    }
    assert(leafLoads.forall(load => load > 0 && load <= topology.maxFanout))
    assert(topology.depth == config.distributedControlLatency)
    assert(config.broadcastLatency == config.broadcastDelay + topology.depth)
    assert(config.readLatency == config.broadcastLatency + config.convergecastDelay + config.executeLatency)
  }

  test("circuit d3 and d9 use minimal equal-depth bounded control trees") {
    assertMinimalBoundedTopology(graphConfig("MICROBLOSSOM_CIRCUIT_D3_GRAPH"), 19, 39)
    assertMinimalBoundedTopology(graphConfig("MICROBLOSSOM_CIRCUIT_D9_GRAPH"), 433, 1737)
  }

  private def checkBehavior(name: String, sourceConfig: DualConfig): Unit = {
    sourceConfig.contextDepth = 4
    val topology = ControlFanoutTopology(sourceConfig.distributedControlConsumerCount)
    val compiled = SimConfig
      .withConfig(Config.spinal())
      .workspaceName(s"control-fanout-$name")
      .allOptimisation
      .compile(DistributedDualControlFanout(sourceConfig, topology.consumerCount))

    compiled.doSim(name) { dut =>
      def drive(sample: MessageSample): Unit = {
        dut.io.message.valid #= sample.valid
        dut.io.message.instruction #= sample.instruction
        dut.io.message.isReset #= sample.isReset
        dut.io.message.contextId #= sample.contextId
      }

      def assertLeafResets(expected: Boolean, phase: String): Unit = {
        val expectedBits = if (expected) { (BigInt(1) << topology.leafCount) - 1 }
        else { BigInt(0) }
        assert(
          dut.io.leafResets.toBigInt == expectedBits,
          s"$name $phase: reset leaves were ${dut.io.leafResets.toBigInt}, expected $expectedBits"
        )
      }

      def assertLeafMessages(expected: MessageSample): Unit = {
        for (leafIndex <- 0 until topology.leafCount) {
          val message = dut.io.leafMessages(leafIndex)
          assert(message.valid.toBoolean == expected.valid)
          assert(message.instruction.toLong == expected.instruction)
          assert(message.isReset.toBoolean == expected.isReset)
          assert(message.contextId.toInt == expected.contextId)
        }
      }

      val instructionMask = (1L << sourceConfig.instructionSpec.numBits) - 1L
      val samples = IndexedSeq(
        MessageSample(valid = true, instruction = 0L, isReset = false, contextId = 0),
        MessageSample(valid = true, instruction = instructionMask, isReset = true, contextId = 1),
        MessageSample(
          valid = false,
          instruction = 0x15555555L & instructionMask,
          isReset = false,
          contextId = 2
        ),
        MessageSample(
          valid = true,
          instruction = sourceConfig.instructionSpec.generateReset(),
          isReset = true,
          contextId = 3
        ),
        MessageSample(
          valid = true,
          instruction = 0x2aaaaaaaL & instructionMask,
          isReset = false,
          contextId = 0
        )
      )

      def clockEdge(): Unit = {
        sleep(4)
        dut.clockDomain.clockSim #= true
        sleep(1)
        dut.clockDomain.clockSim #= false
        sleep(5)
      }

      drive(samples.head)
      dut.clockDomain.clockSim #= false
      dut.clockDomain.assertReset()
      sleep(1)
      assertLeafResets(expected = true, phase = "assertion")
      clockEdge()
      clockEdge()

      dut.clockDomain.deassertReset()
      sleep(1)
      assertLeafResets(expected = true, phase = "before release edge")
      for (releaseEdge <- 1 to topology.depth) {
        clockEdge()
        assertLeafResets(
          expected = releaseEdge < topology.depth,
          phase = s"after release edge $releaseEdge"
        )
      }

      for ((sample, sampleIndex) <- samples.zipWithIndex) {
        drive(sample)
        if (topology.depth == 0) {
          sleep(1)
          assertLeafMessages(sample)
        } else {
          clockEdge()
          if (sampleIndex + 1 >= topology.depth) {
            assertLeafMessages(samples(sampleIndex + 1 - topology.depth))
          }
        }
      }

      dut.clockDomain.assertReset()
      sleep(1)
      assertLeafResets(expected = true, phase = "reassertion")
    }
  }

  test("complete control bundle and reset retain directed cycle semantics") {
    checkBehavior("circuit-d3", graphConfig("MICROBLOSSOM_CIRCUIT_D3_GRAPH"))
    checkBehavior("circuit-d9", graphConfig("MICROBLOSSOM_CIRCUIT_D9_GRAPH"))
  }
}
