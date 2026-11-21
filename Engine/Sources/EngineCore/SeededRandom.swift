import Foundation

/// Deterministic, platform-stable PRNG (splitmix64). Pure integer math — identical
/// streams on iOS/macOS/Linux/Android, which the MockEngine determinism AC and the
/// byte-identical fixture policy (PLAN M0 fixture policy) depend on.
///
/// Floats are derived by fixed-point scaling of integer bits (no libm), so values
/// are bit-identical everywhere.
public struct SeededRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        // Any seed (including 0) produces a full-period, well-distributed stream
        // after the splitmix64 scramble.
        self.state = seed
    }

    public mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform [0, 1) via 53 fixed-point bits.
    public mutating func nextDouble() -> Double {
        Double(nextUInt64() >> 11) / 9007199254740992.0
    }

    /// Uniform [min, max).
    public mutating func nextDouble(in range: Range<Double>) -> Double {
        range.lowerBound + nextDouble() * (range.upperBound - range.lowerBound)
    }

    /// Uniform [min, max) over a ClosedRange argument (floating-point "closed"
    /// upper bound is not representable; upper is effectively exclusive).
    public mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + nextDouble() * (range.upperBound - range.lowerBound)
    }

    /// Uniform [min, max].
    public mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(nextUInt64() % width)
    }
}
