import CoreGraphics

/// Pure, synchronous state for the live annotation transform during scroll capture.
/// Image registration must never write this value; it follows observed wheel movement only.
struct ScrollCaptureLiveOffsetAccumulator: Sendable {
    private(set) var offset: CGFloat = 0

    @discardableResult
    mutating func apply(_ delta: CGFloat) -> CGFloat {
        guard delta.isFinite, abs(delta) > 0.1 else { return offset }
        offset += delta
        return offset
    }

    mutating func reset() {
        offset = 0
    }
}
