import Foundation

// P-201 (M2): mapping of the vendored demucs.cpp 4-source output onto the
// CONTRACTS C-1 two-stem pair (D-9: always two-stem). Portable + pure —
// unit-tested on Linux; the shim/DemucsEngine (Apple-wired via project.yml)
// feed it the raw buffers.
//
// Source layout (intake README "Build notes for P-201", upstream CLI naming):
//   target_0 = drums, target_1 = bass, target_2 = other, target_3 = vocals.
// The stem buffer is source-major INTERLEAVED stereo — per source block of
// 2*N floats: [L0, R0, L1, R1, …] (same layout as DemucsShim output and the
// spike runner's .f32 dumps).
//
// Two-stem composition (M2 policy, recorded in ENGINE.md §M2):
//   vocals        = target_3                                  (mono per D-8)
//   instrumental  = drums + bass + other (residual sum)      (stereo per D-8)
// The 4-source run exists BECAUSE the residual sum yields a cleaner
// instrumental than mix − vocals; D-9's near-silence flag (hasInstrumental)
// is P-205 and consumes instrumental.rms from the manifest (not here).
public enum DemucsOutputMapper {

    public enum MapperError: Error, Sendable {
        /// Buffer size ≠ 4 sources × 2 channels × N samples.
        case sizeMismatch(expected: Int, actual: Int)
        /// Non-finite sample (the shim already filters; defense in depth).
        case nonFinite(offset: Int)
    }

    /// Interleaved stereo (L,R) per sample.
    public struct StereoBuffer: Sendable {
        public let samples: [Float] // 2*N, interleaved
        public let sampleRate: Int

        public init(samples: [Float], sampleRate: Int) {
            self.samples = samples
            self.sampleRate = sampleRate
        }

        /// Channel-mean mono (voice-stem D-8 policy).
        public func mono() -> [Float] {
            var out = [Float](repeating: 0, count: samples.count / 2)
            for i in out.indices {
                out[i] = 0.5 * (samples[2 * i] + samples[2 * i + 1])
            }
            return out
        }
    }

    public static let sourceCount = 4
    public static let sampleRate = 44100 // SUPPORTED_SAMPLE_RATE (D-8)

    /// Source index of the vocals target in the 4-source output.
    static let vocalsIndex = 3

    /// Raw demucs buffer (n_sources*2*N source-major interleaved) → the C-1
    /// two-stem pair. `nSources` allows the 6-source model later (M3 mapping)
    /// while pinning M2 behavior to 4.
    public static func map(rawStems: [Float], nSamples: Int,
                           nSources: Int = sourceCount,
                           sampleRate: Int = DemucsOutputMapper.sampleRate) throws
        -> (vocals: StereoBuffer, instrumental: StereoBuffer)
    {
        let expected = nSources * 2 * nSamples
        guard rawStems.count == expected else {
            throw MapperError.sizeMismatch(expected: expected, actual: rawStems.count)
        }
        // Finite scan (offset reported relative to the whole buffer).
        for (i, v) in rawStems.enumerated() where !v.isFinite {
            throw MapperError.nonFinite(offset: i)
        }
        let block = 2 * nSamples

        // Vocals: direct from target_3 (stereo kept; mono taken at write time).
        var vocals = [Float](repeating: 0, count: 2 * nSamples)
        let vBase = vocalsIndex * block
        for i in 0..<nSamples {
            vocals[2 * i] = rawStems[vBase + 2 * i]
            vocals[2 * i + 1] = rawStems[vBase + 2 * i + 1]
        }

        // Instrumental: residual sum drums+bass+other (D-9 two-stem policy).
        var instrumental = [Float](repeating: 0, count: 2 * nSamples)
        for src in 0..<min(3, nSources) {
            let base = src * block
            for i in 0..<nSamples {
                instrumental[2 * i] += rawStems[base + 2 * i]
                instrumental[2 * i + 1] += rawStems[base + 2 * i + 1]
            }
        }

        return (StereoBuffer(samples: vocals, sampleRate: sampleRate),
                StereoBuffer(samples: instrumental, sampleRate: sampleRate))
    }
}
