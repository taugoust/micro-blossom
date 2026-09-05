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

private[modules] case class ResetFanoutTopology(
    consumerCount: Int,
    depth: Int,
    maxConsumersPerLeaf: Int
) {
  require(consumerCount > 0)
  require(depth >= 0)
  require(maxConsumersPerLeaf > 0)

  val maxFanout: Int = DualConfig.DistributedControlMaxFanout
  val leafCount: Int = (consumerCount + maxConsumersPerLeaf - 1) / maxConsumersPerLeaf

  private val maximumLeafCount = Iterator.fill(depth)(BigInt(maxFanout)).foldLeft(BigInt(1))(_ * _)
  require(
    BigInt(leafCount) <= maximumLeafCount,
    s"$leafCount reset leaves cannot fit in $depth levels with fanout $maxFanout"
  )

  val levelWidths: IndexedSeq[Int] = {
    if (depth == 0) {
      IndexedSeq.empty
    } else {
      val widths = Array.fill(depth)(1)
      widths(depth - 1) = leafCount
      var level = depth - 2
      while (level >= 0) {
        widths(level) = (widths(level + 1) + maxFanout - 1) / maxFanout
        level -= 1
      }
      require(widths.head <= maxFanout)
      widths.toIndexedSeq
    }
  }

  def leafForConsumer(consumerIndex: Int): Int = {
    require(consumerIndex >= 0 && consumerIndex < consumerCount)
    consumerIndex / maxConsumersPerLeaf
  }
}

private[modules] case class DistributedDualControlFanout(config: DualConfig, consumerCount: Int) extends Component {
  private val messageTopology = ControlFanoutTopology(consumerCount)
  private val resetTopology = ResetFanoutTopology(
    consumerCount,
    messageTopology.depth,
    config.resetLeafMaxConsumers
  )

  val io = new Bundle {
    val message = in(BroadcastMessage(config))
    val leafMessages = out(Vec.fill(messageTopology.leafCount)(BroadcastMessage(config)))
    val leafResets = out(Bits(resetTopology.leafCount bits))
  }

  private val sourceClockDomain = ClockDomain.current
  private val sourceReset = sourceClockDomain.isResetActive
  private val pipelineClockDomain = sourceClockDomain.withoutReset()

  // Keep the complete wide message bundle on its existing minimal tree.
  private var previousMessageLevel = IndexedSeq(io.message)
  for ((levelWidth, level) <- messageTopology.levelWidths.zipWithIndex) {
    val parentLevel = previousMessageLevel
    previousMessageLevel = IndexedSeq.tabulate(levelWidth) { nodeIndex =>
      val parent = parentLevel(nodeIndex / messageTopology.maxFanout)
      val messageStage = new ClockingArea(pipelineClockDomain) {
        val message = RegNext(parent)
        message.setName(s"message_l${level}_n${nodeIndex}")
        message.addAttribute("keep", "true")
        message.addAttribute("dont_touch", "true")
        message.addAttribute("max_fanout", messageTopology.maxFanout)
      }
      messageStage.message
    }
  }

  // Reset has the same number of stages as the message path but independent,
  // finer leaves. Each register asynchronously asserts from its parent and
  // synchronously releases on one edge, preserving equal-depth release.
  private var previousResetLevel = IndexedSeq(sourceReset)
  for ((levelWidth, level) <- resetTopology.levelWidths.zipWithIndex) {
    val parentLevel = previousResetLevel
    previousResetLevel = IndexedSeq.tabulate(levelWidth) { nodeIndex =>
      val parent = parentLevel(nodeIndex / resetTopology.maxFanout)
      val resetClockDomain = sourceClockDomain.copy(
        reset = parent,
        config = sourceClockDomain.config.copy(resetKind = ASYNC, resetActiveLevel = HIGH)
      )
      val resetStage = new ClockingArea(resetClockDomain) {
        val reset = Reg(Bool()) init (True)
        reset := False
        reset.setName(s"reset_l${level}_n${nodeIndex}")
        reset.addAttribute("keep", "true")
        reset.addAttribute("dont_touch", "true")
        reset.addAttribute("max_fanout", resetTopology.maxFanout)
      }
      resetStage.reset
    }
  }

  for (leafIndex <- 0 until messageTopology.leafCount) {
    io.leafMessages(leafIndex) := previousMessageLevel(leafIndex)
  }
  for (leafIndex <- 0 until resetTopology.leafCount) {
    io.leafResets(leafIndex) := previousResetLevel(leafIndex)
  }
}

// sbt 'testOnly microblossom.modules.DistributedDualControlFanoutTest'
class DistributedDualControlFanoutTest extends AnyFunSuite {
  private case class MessageSample(valid: Boolean, instruction: Long, isReset: Boolean, contextId: Int)

  private def graphConfig(environmentVariable: String): DualConfig = {
    val config =
      DualConfig(filename = sys.env.getOrElse(environmentVariable, fail(s"$environmentVariable must name a graph")))
    config.resetLeafMaxConsumers = DualConfig.minimumResetLeafMaxConsumers(
      config.distributedControlConsumerCount,
      config.distributedControlLatency
    )
    config
  }

  private def assertMinimalBoundedTopology(config: DualConfig, expectedVertices: Int, expectedEdges: Int): Unit = {
    assert(config.vertexNum == expectedVertices)
    assert(config.edgeNum == expectedEdges)
    assert(config.offloaderNum == 0)

    val messageTopology = ControlFanoutTopology(config.distributedControlConsumerCount)
    val messageWidths = IndexedSeq(1) ++ messageTopology.levelWidths ++ IndexedSeq(messageTopology.consumerCount)
    for (pair <- messageWidths.sliding(2)) {
      val parentWidth = pair.head
      val childWidth = pair.last
      val minimumParentWidth = (childWidth + messageTopology.maxFanout - 1) / messageTopology.maxFanout
      assert(parentWidth == minimumParentWidth)
      assert(childWidth <= parentWidth * messageTopology.maxFanout)
    }

    val messageLeafLoads = Array.fill(messageTopology.leafCount)(0)
    for (consumerIndex <- 0 until messageTopology.consumerCount) {
      messageLeafLoads(messageTopology.leafForConsumer(consumerIndex)) += 1
    }
    assert(messageLeafLoads.forall(load => load > 0 && load <= messageTopology.maxFanout))

    val resetTopology = ResetFanoutTopology(
      config.distributedControlConsumerCount,
      messageTopology.depth,
      config.resetLeafMaxConsumers
    )
    assert(resetTopology.depth == messageTopology.depth)
    val resetWidths = IndexedSeq(1) ++ resetTopology.levelWidths
    for (pair <- resetWidths.sliding(2)) {
      val parentWidth = pair.head
      val childWidth = pair.last
      val minimumParentWidth = (childWidth + resetTopology.maxFanout - 1) / resetTopology.maxFanout
      assert(parentWidth == minimumParentWidth)
      assert(childWidth <= parentWidth * resetTopology.maxFanout)
    }

    val resetLeafLoads = Array.fill(resetTopology.leafCount)(0)
    for (consumerIndex <- 0 until resetTopology.consumerCount) {
      resetLeafLoads(resetTopology.leafForConsumer(consumerIndex)) += 1
    }
    assert(resetLeafLoads.forall(load => load > 0 && load <= config.resetLeafMaxConsumers))
    assert(resetTopology.leafCount > messageTopology.leafCount)

    assert(messageTopology.depth == config.distributedControlLatency)
    assert(config.broadcastLatency == config.broadcastDelay + messageTopology.depth)
    assert(
      config.readLatency ==
        config.broadcastLatency + config.executeLatency + config.maxGrowablePipelineLatency + config.convergecastDelay
    )
  }

  test("circuit d3 and d9 use bounded same-depth reset and message trees") {
    assertMinimalBoundedTopology(graphConfig("MICROBLOSSOM_CIRCUIT_D3_GRAPH"), 19, 39)
    assertMinimalBoundedTopology(graphConfig("MICROBLOSSOM_CIRCUIT_D9_GRAPH"), 433, 1737)
  }

  test("reset grouping is configurable without changing message topology or latency") {
    for (config <- Seq(
        graphConfig("MICROBLOSSOM_CIRCUIT_D3_GRAPH"),
        graphConfig("MICROBLOSSOM_CIRCUIT_D9_GRAPH")
      )) {
      val messageTopology = ControlFanoutTopology(config.distributedControlConsumerCount)
      val fineReset = ResetFanoutTopology(
        config.distributedControlConsumerCount,
        messageTopology.depth,
        config.resetLeafMaxConsumers
      )
      val coarseReset = ResetFanoutTopology(
        config.distributedControlConsumerCount,
        messageTopology.depth,
        config.resetLeafMaxConsumers * 2
      )
      assert(fineReset.depth == messageTopology.depth)
      assert(coarseReset.depth == messageTopology.depth)
      assert(fineReset.leafCount > coarseReset.leafCount)
      assert(messageTopology.depth == config.distributedControlLatency)
    }
  }

  private def checkBehavior(name: String, sourceConfig: DualConfig): Unit = {
    sourceConfig.contextDepth = 4
    val messageTopology = ControlFanoutTopology(sourceConfig.distributedControlConsumerCount)
    val resetTopology = ResetFanoutTopology(
      sourceConfig.distributedControlConsumerCount,
      messageTopology.depth,
      sourceConfig.resetLeafMaxConsumers
    )
    val compiled = SimConfig
      .withConfig(Config.spinal())
      .workspaceName(s"control-fanout-$name")
      .allOptimisation
      .compile(DistributedDualControlFanout(sourceConfig, messageTopology.consumerCount))

    compiled.doSim(name) { dut =>
      def drive(sample: MessageSample): Unit = {
        dut.io.message.valid #= sample.valid
        dut.io.message.instruction #= sample.instruction
        dut.io.message.isReset #= sample.isReset
        dut.io.message.contextId #= sample.contextId
      }

      def assertLeafResets(expected: Boolean, phase: String): Unit = {
        val expectedBits = if (expected) { (BigInt(1) << resetTopology.leafCount) - 1 }
        else { BigInt(0) }
        assert(
          dut.io.leafResets.toBigInt == expectedBits,
          s"$name $phase: reset leaves were ${dut.io.leafResets.toBigInt}, expected $expectedBits"
        )
      }

      def assertLeafMessages(expected: MessageSample): Unit = {
        for (leafIndex <- 0 until messageTopology.leafCount) {
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
      for (releaseEdge <- 1 to resetTopology.depth) {
        clockEdge()
        assertLeafResets(
          expected = releaseEdge < resetTopology.depth,
          phase = s"after release edge $releaseEdge"
        )
      }

      for ((sample, sampleIndex) <- samples.zipWithIndex) {
        drive(sample)
        if (messageTopology.depth == 0) {
          sleep(1)
          assertLeafMessages(sample)
        } else {
          clockEdge()
          if (sampleIndex + 1 >= messageTopology.depth) {
            assertLeafMessages(samples(sampleIndex + 1 - messageTopology.depth))
          }
        }
      }

      dut.clockDomain.assertReset()
      sleep(1)
      assertLeafResets(expected = true, phase = "reassertion")
    }
  }

  test("complete control bundle and localized reset retain directed cycle semantics") {
    checkBehavior("circuit-d3", graphConfig("MICROBLOSSOM_CIRCUIT_D3_GRAPH"))
    checkBehavior("circuit-d9", graphConfig("MICROBLOSSOM_CIRCUIT_D9_GRAPH"))
  }
}
