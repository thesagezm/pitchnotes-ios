import Foundation

// P-205 · Instrumental-presence heuristic (D-9).
//
// D-9: two-stem separation ALWAYS runs; when the source has NO accompaniment
// (a cappella), the instrumental stem is near-silent and the bundle must say
// `hasInstrumental = false` — and then there is NO `stems/INSTRUMENTAL.m4a`
// and NO INSTRUMENTAL entry in `parts[]` (V15).
//
// The decision is measured on the SEPARATOR's staged instrumental stem (the
// PCM WAV) so it stays PORTABLE (Linux-testable): the level of a WAV is a
// header + a sample scan, no AVFoundation involved.
//
// The threshold is deliberately conservative: only a stem that is near-silent
// over its WHOLE length is called "no accompaniment". A quiet passage inside
// a real accompaniment does not trip it (the whole-stem RMS is what counts).

public enum InstrumentalPresenceHeuristic {

    /// RMS level (dBFS) at or below which the instrumental stem counts as
    /// "near-silent" ⇒ acapella ⇒ `hasInstrumental = false`.
    ///
    /// −50 dBFS RMS is ~0.3 % of full scale: below any real accompaniment
    /// (a quiet a cappella recording still leaks room tone and breath noise
    /// above that) and far above the model's numerical noise floor
    /// (≈ −70 dB on the tone fixture).
    public static let nearSilentRMSdB: Double = -50.0

    /// Whole-stem RMS in dBFS. Returns `nil` for an unreadable/empty file.
    /// Uses the channel-preserving float reader when the file is a float32
    /// staging WAV, otherwise the PCM16 reader (mono-folded — the LEVEL is
    /// what matters here, not the stereo image).
    public static func rmsDB(url: URL) -> Double? {
        let samples: [Float]
        if let mix = try? PCMF32Wav.read(url: url) {
            samples = mix.frames
        } else if let pcm = try? PCMWaveReader.read(url: url) {
            samples = pcm.samples
        } else {
            return nil
        }
        guard !samples.isEmpty else { return nil }
        var sum: Double = 0
        for s in samples {
            let v = Double(s)
            sum += v * v
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 0 else { return -120.0 } // digital silence
        return 20.0 * log10(rms)
    }

    /// D-9 decision: `false` when the instrumental stem is missing or
    /// near-silent (acapella); `true` otherwise.
    ///
    /// An UNREADABLE stem is treated as "present" (we do not delete a stem we
    /// failed to measure — the safe direction: the bundle keeps the
    /// accompaniment the user can hear).
    public static func measure(instrumentalStem: URL?) -> Bool {
        guard let instrumentalStem else { return false }
        guard let rms = rmsDB(url: instrumentalStem) else { return true }
        return rms > nearSilentRMSdB
    }

    /// The seam value for `ImportOrchestrator.Config.instrumentalPresence`.
    public static let presence: ImportOrchestrator.InstrumentalPresence = { url in
        measure(instrumentalStem: url)
    }
}
