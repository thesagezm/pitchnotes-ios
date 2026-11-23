import Foundation

// P-202 L2 · Separation channel adaptation (portable, Linux-tested).
//
// The separation path has THREE channel layouts and they must not be confused:
//
//   1. DECODED MIX (D-8): 1 or 2 channels, channel-interleaved — what the
//      import pipeline stages (PCMF32Wav).
//   2. PROCESSING (vendor/shim contract): ALWAYS stereo, interleaved. The
//      demucs.cpp shim takes a 2 x N matrix; a mono mix is upmixed (mono
//      duplicated to L/R) — this is what the pre-P-202 whole-song path did
//      too, so the change is behaviour-preserving.
//   3. STEMS (D-8): voice MONO, instrumental STEREO. Applied at staging time
//      (PCMWavWriter / P-204 ALAC), NOT inside the chunked driver — the
//      driver blends in the processing layout and must not fold channels
//      mid-blend (folding twice is not idempotent with the blend math).
//
// These helpers are the ONLY place the layouts are converted, so the portable
// core can be unit-tested without the vendor (the Apple-only DemucsEngine
// calls them; it cannot run on Linux).

public enum SeparationChannels {

    public enum ChannelError: Error, Sendable, Equatable {
        /// Channel count outside the D-8 mix policy {1, 2}.
        case unsupportedChannelCount(Int)
        /// Sample count is not a whole number of frames for the given layout.
        case notFrameAligned(samples: Int, channels: Int)
    }

    /// Mix layout (1 or 2 channels, interleaved) → processing layout
    /// (always stereo, interleaved). Mono is duplicated to L/R.
    public static func upmixToStereo(frames: [Float], channels: Int) throws -> [Float] {
        guard channels == 1 || channels == 2 else {
            throw ChannelError.unsupportedChannelCount(channels)
        }
        guard frames.count % channels == 0 else {
            throw ChannelError.notFrameAligned(samples: frames.count, channels: channels)
        }
        let frameCount = frames.count / channels
        var out = [Float](repeating: 0, count: frameCount * 2)
        if channels == 2 {
            out = frames
        } else {
            for f in 0..<frameCount {
                let v = frames[f]
                out[f * 2] = v
                out[f * 2 + 1] = v
            }
        }
        return out
    }

    /// Processing layout (stereo, interleaved) → mono (channel mean).
    /// D-8's voice-stem policy; also the 1-channel processing fallback.
    public static func toMono(stereo: [Float]) throws -> [Float] {
        guard stereo.count % 2 == 0 else {
            throw ChannelError.notFrameAligned(samples: stereo.count, channels: 2)
        }
        var out = [Float](repeating: 0, count: stereo.count / 2)
        for i in out.indices {
            out[i] = 0.5 * (stereo[2 * i] + stereo[2 * i + 1])
        }
        return out
    }

    /// Processing layout (stereo) → the requested output layout
    /// (1 = mono fold, 2 = passthrough). Used by the SegmentEngine conformer
    /// so the driver's length contract (frames × channels) always holds.
    public static func fromStereo(stereo: [Float], channels: Int) throws -> [Float] {
        switch channels {
        case 2:
            guard stereo.count % 2 == 0 else {
                throw ChannelError.notFrameAligned(samples: stereo.count, channels: 2)
            }
            return stereo
        case 1:
            return try toMono(stereo: stereo)
        default:
            throw ChannelError.unsupportedChannelCount(channels)
        }
    }
}
