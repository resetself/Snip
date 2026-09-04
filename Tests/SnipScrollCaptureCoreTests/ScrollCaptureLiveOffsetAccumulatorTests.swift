import CoreGraphics
import Testing
@testable import SnipScrollCaptureCore

@Test("Live annotation offset accumulates every wheel delta exactly once")
func liveOffsetAccumulatesEveryDelta() {
    var accumulator = ScrollCaptureLiveOffsetAccumulator()

    #expect(accumulator.apply(2.5) == 2.5)
    #expect(accumulator.apply(3.25) == 5.75)
    #expect(accumulator.apply(-1.5) == 4.25)
}

@Test("Live annotation offset reverses immediately without hysteresis")
func liveOffsetReversesImmediately() {
    var accumulator = ScrollCaptureLiveOffsetAccumulator()

    _ = accumulator.apply(12)
    #expect(accumulator.apply(-0.5) == 11.5)
    #expect(accumulator.apply(-3) == 8.5)
}

@Test("Live annotation offset ignores noise and resets between sessions")
func liveOffsetIgnoresNoiseAndResets() {
    var accumulator = ScrollCaptureLiveOffsetAccumulator()

    _ = accumulator.apply(8)
    #expect(accumulator.apply(0.1) == 8)
    #expect(accumulator.apply(.infinity) == 8)

    accumulator.reset()
    #expect(accumulator.offset == 0)
}
