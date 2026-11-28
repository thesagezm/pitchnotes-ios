import Foundation

// P-304 · The score aligner — the DTW alignment + the C-13.2 metadata + the
// score-informed tracks.
//
// WHAT THIS IS: the second half of the score path (D-40 §5 — the parser NEVER
// aligns by itself). Input: a PARSED score (`MusicXMLScoreParser`, C-13.1), the
// model's per-frame salience candidates (the SAME candidate set the voice
// assignment consumes, P-302/P-303), the heuristic detected tracks and the
// audio's duration. Output: the C-13.2 alignment (the confidence, the bar map,
// the part mapping, the used decision), the aligned score notes and the
// DERIVED score-informed tracks.
//
// THE METHOD (settled by the numeric prototype `p304_alignment_measurements.py`,
// kept outside the repo so it can be re-run — the Swift numbers below MUST
// equal its numbers):
//
//   · The AUDIO side's chroma is the MODEL'S PER-FRAME SALIENCE CANDIDATES —
//     the same candidate set P-303 assigns (12-bin pitch-class mass,
//     L2-normalised). NOT a spectrogram: no FFT in the portable core, and the
//     aligner stays consistent with the assignment path by construction.
//   · The DTW uses the notes' PITCH PRESENCE ONLY. The salience is NOT a
//     weight in the DTW (C-12: it is the model's posterior strength, never a
//     calibrated probability — weighting the alignment with it would smuggle
//     an uncalibrated filter into a decision path).
//   · A BANDED DTW (Sakoe-Chiba-style proportional band ≈ 0.15 around the
//     diagonal) over cost = 1 − cosine similarity; steps (1,1)/(1,0)/(0,1);
//     rolling DP rows + a UInt8 backpointer matrix; the global path from
//     (0,0) to (N−1, M−1).
//   · The alignment's `confidence` is THE MEAN SIMILARITY ALONG THE PATH,
//     clipped to [0, 1] — the ALIGNMENT's confidence. Never the salience,
//     never a per-note probability (C-12/D-41 §1: the two are never mixed).
//   · THE BAR MAP WARP IS ANCHORED TO BOTH DURATIONS. A bar boundary read
//     straight off the DTW path was MEASURED to fail the ≤ 50 ms AC (58 ms —
//     the path is a staircase and its chord changeover runs ~3 frames EARLY,
//     because basic-pitch's analysis window looks FORWARD). A plain global
//     least-squares time-scale measured 23 ms. The CHOSEN warp is a single
//     time-scale whose least-squares fit is anchored to the duration
//     correspondence (S ↔ A carrying the weight of the whole path):
//
//         scale = (Σ_path x_i·y_i + N·S·A) / (Σ_path x_i² + N·S²)
//         warp(t) = scale · t
//
//     with x_i = the score frame's time, y_i = the path's audio frame's time,
//     S = the score's duration, A = the audio's duration, N = the number of
//     path anchors. MEASURED on the committed satb5_prog demonstration:
//     max bar error 7.0 ms (the AC is ≤ 50 ms), alignment confidence
//     0.990145, and the score-informed track is 688/688 frames correct where
//     the heuristic track is 672/688 — the score fixes EXACTLY the 16
//     transition frames. The duration anchor is not knife-edge: weight N/4
//     still gives 688/688 at 16.5 ms.
//   · HONEST LIMITATION (also true of the prototype): the warp is a SINGLE
//     TIME-SCALE. A recording whose tempo CHANGES across the score is not
//     modelled by the bar map (the alignment's confidence still reflects the
//     path, and a tempo-drifting score simply may not be adopted — the used
//     decision below is a measurement, never an assumption).
//
// THE USED DECISION IS CONTRACTS v1.2's C-17 GATE (D-58 — P-404; it supersedes
// D-47 §9's v1.1.1 rule-4 consequence BY REFERENCE, D-47 stays on file):
//
//     used = (confidence ≥ 0.70) AND (after ≥ before) AND
//            (after > before OR after ≥ 0.90)
//
// where `before` is the RAW score's agreement with the detected notes and
// `after` is the ALIGNED score's (the pinned `Agreement` metric — same MIDI
// integer, NO octave fold, ±0.25 s both-extended overlap, one-to-one,
// two-sided Dice; 0 when either side is empty). TWO adoption branches:
//   · IMPROVEMENT (after > before) — D-47 §9's rule, unchanged and still
//     sufficient alone ("the alignment fixed something measurable").
//   · CORROBORATION (after ≥ 0.90) — the score already matches the engine's
//     hearing near-unanimously at the pinned metric; refusing it would discard
//     its real grading value (exact times, partMapping, the bar map) exactly
//     when it is MOST trustworthy. 0.90 is a ruling, not a derivation —
//     lowering it is a future ruling with evidence (C-17).
// `after ≥ before` (never degrades) applies to BOTH branches, and the
// ZERO-AGREEMENT refusal is preserved (after = 0 passes neither branch —
// D-47 §9's degenerate case stays refused). On refusal `reason` states which
// contractual reason applies: confidence short of the gate, degraded
// agreement, or no improvement AND corroboration short of 0.90.
//
// THE PLACEMENT RULE MIRRORS JESS'S `ScoreReview.align` EXACTLY (the consumer
// in Tests/Logic/Sources/PitchLogic/ScoreReview.swift): a score note in
// measure M is anchored to the bar-map entry for M; a measure with two or
// more notes is scaled onto the bar's audio span; a measure with a single
// note keeps its own duration (scale = 1); a note whose measure the bar map
// does not cover is skipped; its part is the mapping's value (nil when
// unmapped — never guessed into a part, D-47 §8). The engine does NOT apply
// the user's score nudges (C-16 is Jess's overlay, applied on top of these
// pre-nudge times).
//
// THE SCORE-INFORMED TRACKS ARE DERIVED, NEVER WRITTEN OVER THE HEURISTIC
// ONES (C-13 rule 3): the engine's `notes/<PART>.json` stays exactly what the
// engine heard. Each score-informed note carries the ALIGNMENT's confidence —
// the score has no per-note confidence, and inventing one would be a lie.
//
// THE NO-SCORE PATH (C-13 rule 1): a nil score (or a score with no note
// events, or too little audio to align) ⇒ `alignment == nil`, the import
// still succeeds, and `reason` states why the grading stays heuristic-only.

// MARK: - The options

/// The aligner's knobs. The defaults are the MEASURED configuration (the
/// prototype's) — the benchmark report names the exact configuration that
/// produced a number (P-306's honesty gate).
public struct ScoreAlignerOptions: Equatable, Sendable {

    /// The proportional DTW band width around the diagonal (Sakoe-Chiba style:
    /// the band is `centre · (1 ± bandFraction)`).
    public var bandFraction: Double

    /// The analysis grid is bounded to at most this many frames PER SIDE by
    /// binning (a 4-minute song at the model's 11.61 ms hop would be ~20 000
    /// audio frames). 2000 keeps the DP matrix at ~4 MB of backpointers.
    public var maxFrames: Int

    /// D-41 §4's adoption threshold: the score-informed track is used ONLY IF
    /// the alignment's confidence is at least this AND the C-17 gate's
    /// agreement branch holds (CONTRACTS v1.2).
    public var adoptionConfidenceThreshold: Double

    /// C-17's CORROBORATION gate: an alignment whose agreement did not
    /// strictly improve is still adopted when the ALIGNED score's agreement
    /// with the detected notes reaches this level (near-unanimous
    /// corroboration of the engine's own hearing). **0.90 is a RULING, not a
    /// derivation** (C-17) — lowering it is a future ruling with evidence,
    /// never a quiet tune.
    public var corroborationAgreementThreshold: Double

    /// An EXPLICIT score `part_id` → C-1 part mapping. It WINS over the label
    /// resolver (the aligner never second-guesses an explicit instruction).
    /// Absent/empty ⇒ the labels are resolved against the alias table, and an
    /// unresolved label stays UNMAPPED — never guessed (D-47 §8).
    public var explicitPartMapping: [String: Part]?

    public init(bandFraction: Double = 0.15,
                maxFrames: Int = 2000,
                adoptionConfidenceThreshold: Double = 0.70,
                corroborationAgreementThreshold: Double = 0.90,
                explicitPartMapping: [String: Part]? = nil) {
        self.bandFraction = bandFraction
        self.maxFrames = maxFrames
        self.adoptionConfidenceThreshold = adoptionConfidenceThreshold
        self.corroborationAgreementThreshold = corroborationAgreementThreshold
        self.explicitPartMapping = explicitPartMapping
    }

    /// The measured defaults (the prototype's configuration).
    public static let `default` = ScoreAlignerOptions()
}

// MARK: - The v1.2 adoption gate (C-17)

/// WHY the v1.2 adoption gate decided as it did (CONTRACTS v1.2 C-17, D-58 —
/// P-404). The three refusal kinds are CONTRACTUAL: C-17 requires the UI to
/// state the reason — "confidence short of the gate, degraded agreement, or
/// no improvement AND corroboration short of 0.90".
public enum AdoptionDecision: Equatable, Sendable {

    /// The IMPROVEMENT branch (`after > before`) — D-47 §9's rule, unchanged
    /// and still sufficient alone: the alignment fixed something measurable.
    case improvement

    /// The CORROBORATION branch (`after ≥ 0.90` with `after ≥ before`) — the
    /// aligned score corroborates the engine's own hearing near-unanimously
    /// at the pinned Agreement metric. 0.90 is a ruling, not a derivation.
    case corroboration

    /// REFUSED: the alignment's confidence is below the 0.70 gate (D-41 §4).
    case lowConfidence

    /// REFUSED: the aligned score's agreement is WORSE than the raw score's
    /// (`after < before`) — an alignment that degrades agreement is never
    /// adopted at any absolute level (C-17's both-branches rule).
    case degraded

    /// REFUSED: no improvement AND corroboration short of 0.90. The
    /// ZERO-AGREEMENT case (`before = after = 0`) lands here — D-47 §9's
    /// degenerate refusal, preserved by C-17.
    case insufficient
}

// MARK: - The outcome

/// What one alignment produced. The C-13.2 file is written from `alignment`
/// (nil ⇒ NO alignment file exists — the honest no-score state, C-13 rule 1).
public struct ScoreAlignerOutcome: Equatable, Sendable {

    /// The C-13.2 alignment metadata. NIL ⇒ no score was aligned (no score
    /// supplied, an empty score, or too little audio) — the heuristic-only
    /// path, and `reason` says why.
    public var alignment: ScoreContract.Alignment?

    /// The score `part_id` → C-1 part mapping THE ALIGNMENT CARRIES (empty
    /// when there is no score or nothing resolved). This is the same mapping
    /// `alignment?.partMapping` carries — duplicated here so a consumer does
    /// not have to unwrap the optional to read it (D-47 §8: absent ⇒ no score
    /// note enters any part).
    public var partMapping: [String: Part]

    /// Every score note placed on the audio timeline (pre-nudge; the unmapped
    /// ones carry `part == nil` and are placed IN TIME but enter NO part's
    /// track).
    public var alignedNotes: [ScoreContract.AlignedNote]

    /// The DERIVED score-informed tracks, per mapped part. NEVER a replacement
    /// for the heuristic tracks on disk (C-13 rule 3).
    public var scoreInformedTracks: [Part: NoteTrack]

    /// The RAW score's agreement with the detected notes (before).
    public var agreementBefore: ScoreContract.Agreement?

    /// The ALIGNED score's agreement with the detected notes (after).
    public var agreementAfter: ScoreContract.Agreement?

    /// The honest reason for the used decision (or for heuristic-only). This
    /// is what the UI says — it is a measurement report, never a claim.
    public var reason: String

    /// The score's own duration (seconds at the score's tempo); 0 with no score.
    public var scoreDuration: Double

    /// The audio duration the alignment was anchored to; 0 with no score.
    public var audioDuration: Double
}

// MARK: - The aligner

/// The score aligner (P-304). See the file header for the method and its
/// measured provenance.
public enum ScoreAligner {

    /// The engine version stamped into the derived score-informed tracks.
    public static let version = "score-aligner-0.1.0"
    /// The `method` string written into the C-13.2 JSON.
    public static let method = "DTW"

    /// The analysis grid: the model's own hop (256 / 22050 s ≈ 11.61 ms).
    static let analysisGrid = Double(BasicPitchFrameClock.frameHop) / BasicPitchFrameClock.sampleRate

    /// THE v1.2 ADOPTION GATE (CONTRACTS v1.2 C-17, D-58 — P-404):
    ///
    ///     used = (confidence ≥ 0.70) AND (after ≥ before) AND
    ///            (after > before OR after ≥ 0.90)
    ///
    /// The metric is the PINNED `Agreement` (same MIDI integer, no octave
    /// fold, ±0.25 s both-extended overlap, one-to-one, two-sided Dice; 0 when
    /// either side is empty). `before` = the RAW score's agreement with the
    /// detected notes; `after` = the ALIGNED score's. The returned decision
    /// names WHICH branch or refusal fired, so `reason` states the
    /// contractual refusal kind (C-17) instead of a vague "no".
    ///
    /// Jess reads `used` (and MAY read this decision); she MUST NOT re-derive
    /// the gate (C-17's ack duty).
    public static func decideAdoption(confidence: Double,
                                      agreementBefore: Double,
                                      agreementAfter: Double,
                                      options: ScoreAlignerOptions = .default) -> AdoptionDecision {
        guard confidence >= options.adoptionConfidenceThreshold else {
            return .lowConfidence
        }
        guard agreementAfter >= agreementBefore else {
            return .degraded
        }
        if agreementAfter > agreementBefore {
            return .improvement
        }
        if agreementAfter >= options.corroborationAgreementThreshold {
            return .corroboration
        }
        return .insufficient
    }

    /// Resolve the score against the audio: align, decide `used`, and derive
    /// the score-informed tracks.
    ///
    /// - Parameters:
    ///   - score: the PARSED score (C-13.1), or nil for the no-score path
    ///     (which SUCCEEDS — C-13 rule 1 — and states the reason).
    ///   - candidates: the model's per-frame salience candidates (the same
    ///     set the voice assignment consumes). One array per frame.
    ///   - detectedTracks: the heuristic note tracks (the agreement's
    ///     comparator and the origin of the bundle's own tracks).
    ///   - audioDuration: the audio's duration in seconds (the decoded
    ///     audio's length — the S ↔ A anchor's A).
    ///   - options: the aligner's knobs (the defaults are the measured ones).
    public static func resolve(score: ParsedMusicXMLScore?,
                               candidates: [[SalienceCandidate]],
                               detectedTracks: [Part: NoteTrack],
                               audioDuration: Double,
                               options: ScoreAlignerOptions = .default) -> ScoreAlignerOutcome {

        // THE NO-SCORE PATH (C-13 rule 1): everything here is OPTIONAL; the
        // import still succeeds and the reason is stated.
        guard let score, !score.noteList.scoreNotes.isEmpty else {
            return ScoreAlignerOutcome(
                alignment: nil,
                partMapping: [:],
                alignedNotes: [],
                scoreInformedTracks: [:],
                agreementBefore: nil,
                agreementAfter: nil,
                reason: score == nil
                    ? "No score supplied — the grading reference stays the heuristic track (C-13 rule 1)."
                    : "The score parsed but carried no note events — the grading reference stays the heuristic track (C-13 rule 1).",
                scoreDuration: score?.noteList.duration ?? 0,
                audioDuration: audioDuration)
        }

        guard candidates.count >= 2, audioDuration > 0 else {
            return ScoreAlignerOutcome(
                alignment: nil,
                partMapping: [:],
                alignedNotes: [],
                scoreInformedTracks: [:],
                agreementBefore: nil,
                agreementAfter: nil,
                reason: "Too little audio to align (need ≥ 2 frames and a positive duration) — the grading reference stays the heuristic track.",
                scoreDuration: score.noteList.duration,
                audioDuration: audioDuration)
        }

        // 1. The audio side: the candidates' 12-bin chroma (L2-normalised),
        //    on the model's own chunk-aware frame clock, binned to ≤ maxFrames.
        let audio = AudioSide(candidates: candidates, maxFrames: options.maxFrames)

        // 2. The score side: a 12-bin chroma on the analysis grid, itself
        //    bounded to ≤ maxFrames for a long score.
        let scoreSide = ScoreSide(score: score, maxFrames: options.maxFrames)

        // 3. The banded DTW over cost = 1 − cosine similarity.
        let dtw = BandedDTW(scoreChroma: scoreSide.chroma,
                            audioChroma: audio.chroma,
                            bandFraction: options.bandFraction)
        let path = dtw.path
        guard path.count >= 2 else {
            return ScoreAlignerOutcome(
                alignment: nil,
                partMapping: [:],
                alignedNotes: [],
                scoreInformedTracks: [:],
                agreementBefore: nil,
                agreementAfter: nil,
                reason: "The DTW produced no usable path — the grading reference stays the heuristic track.",
                scoreDuration: score.noteList.duration,
                audioDuration: audioDuration)
        }

        // 4. The alignment's confidence: the MEAN SIMILARITY ALONG THE PATH,
        //    clipped to [0, 1]. Never the salience, never a per-note
        //    probability (C-12/D-41 §1).
        var similaritySum = 0.0
        for (i, j) in path {
            similaritySum += cosine(scoreSide.chroma[i], audio.chroma[j])
        }
        let confidence = min(1.0, max(0.0, similaritySum / Double(path.count)))

        // 5. THE WARP — the single time-scale anchored to both durations
        //    (the file header has the derivation and the measured numbers).
        let scoreDuration = score.noteList.duration
        var sxy = 0.0
        var sxx = 0.0
        for (i, j) in path {
            let x = scoreSide.times[i]
            let y = audio.times[j]
            sxy += x * y
            sxx += x * x
        }
        let anchors = Double(path.count)
        let denominator = sxx + anchors * scoreDuration * scoreDuration
        let scale = denominator > 0
            ? (sxy + anchors * scoreDuration * audioDuration) / denominator
            : audioDuration / scoreDuration

        func warp(_ scoreTime: Double) -> Double { scale * scoreTime }

        // 6. THE BAR MAP (C-13.2): per measure, the score's own span → the
        //    audio's span via the warp. The LAST measure's end is clamped to
        //    the audio's duration, and the entries stay monotone.
        let barMap = barMap(score: score, warp: warp, audioDuration: audioDuration)

        // 7. THE PART MAPPING: explicit wins; labels resolve through the alias
        //    table; an unresolved label stays UNMAPPED (D-47 §8).
        let mapping = partMapping(score: score, options: options)

        // 8. THE PLACEMENT — Jess's `ScoreReview.align` rule, mirrored exactly
        //    (the file header). The unmapped notes are placed IN TIME but
        //    enter NO part's track.
        let aligned = alignedNotes(score: score, barMap: barMap, mapping: mapping)

        // 9. THE AGREEMENT, before (the RAW score) and after (the ALIGNED
        //    score) — the v1.2 gate's two inputs (C-17's pinned metric).
        let agreementBefore = ScoreContract.Agreement.between(
            score: score.noteList.scoreNotes, detected: detectedTracks)
        let alignedScoreNotes = aligned.enumerated().map { index, note in
            ScoreContract.Note(midi: note.midi,
                               start_s: note.alignedStart_s,
                               end_s: note.alignedEnd_s,
                               measure: note.measure,
                               part_id: note.scorePartID,
                               voice: note.voice)
        }
        let agreementAfter = ScoreContract.Agreement.between(
            score: alignedScoreNotes, detected: detectedTracks)

        // 10. THE USED DECISION — the v1.2 gate (C-17, D-58; see
        //     `decideAdoption`): confidence ≥ 0.70 AND after ≥ before AND
        //     (after > before OR after ≥ 0.90). The decision names WHICH
        //     branch or refusal fired, and `reason` states it in the
        //     contractual vocabulary (C-17's three refusal kinds).
        let decision = Self.decideAdoption(confidence: confidence,
                                           agreementBefore: agreementBefore.ratio,
                                           agreementAfter: agreementAfter.ratio,
                                           options: options)
        let adopted = decision == .improvement || decision == .corroboration
        let reason: String
        switch decision {
        case .improvement:
            reason = String(format: "Adopted: the alignment's confidence %.6f ≥ %.2f and it improved note agreement (before %.4f → after %.4f) — C-17's improvement branch.",
                            confidence, options.adoptionConfidenceThreshold,
                            agreementBefore.ratio, agreementAfter.ratio)
        case .corroboration:
            reason = String(format: "Adopted: the alignment's confidence %.6f ≥ %.2f and the aligned score corroborates the engine's own hearing near-unanimously (after %.4f ≥ %.2f, before %.4f, not degraded) — C-17's corroboration branch.",
                            confidence, options.adoptionConfidenceThreshold,
                            agreementAfter.ratio, options.corroborationAgreementThreshold,
                            agreementBefore.ratio)
        case .lowConfidence:
            reason = String(format: "NOT adopted: the alignment's confidence %.6f is below the %.2f threshold (D-41 §4) — the grading reference stays the heuristic track.",
                            confidence, options.adoptionConfidenceThreshold)
        case .degraded:
            reason = String(format: "NOT adopted: the aligned score's agreement (%.4f) is WORSE than the raw score's (%.4f) — an alignment that degrades agreement is never adopted, at any absolute level (C-17). The grading reference stays the heuristic track, and the UI must say so.",
                            agreementAfter.ratio, agreementBefore.ratio)
        case .insufficient:
            reason = String(format: "NOT adopted: the aligned score's agreement (%.4f) did not strictly improve on the raw score's (%.4f) and its corroboration is short of the %.2f gate — C-17. The grading reference stays the heuristic track, and the UI must say so.",
                            agreementAfter.ratio, agreementBefore.ratio,
                            options.corroborationAgreementThreshold)
        }

        // 11. THE DERIVED SCORE-INFORMED TRACKS (C-13 rule 3: never a
        //     replacement on disk). Each note carries the ALIGNMENT's
        //     confidence — the score has no per-note confidence.
        var tracks: [Part: NoteTrack] = [:]
        for note in aligned {
            guard let part = note.part else { continue } // unmapped ⇒ no track
            tracks[part, default: NoteTrack(contractVersion: NoteTrack.contractVersionV11,
                                            part: part,
                                            notes: [],
                                            engineVersion: version)].notes.append(
                EngineCore.Note(start_s: note.alignedStart_s,
                                end_s: note.alignedEnd_s,
                                midi: note.midi,
                                cents_ref: 0,
                                confidence: confidence))
        }
        // C-2.3 V8: sorted by start_s, never overlapping within a part (the
        // same repair the correction applier uses — the onsets stay exact).
        let repaired = tracks.mapValues { track in
            NoteTrack(contractVersion: NoteTrack.contractVersionV11,
                      part: track.part,
                      notes: ScoreContract.CorrectionApplier.repairOverlaps(track.notes),
                      engineVersion: version)
        }
        tracks = repaired

        let alignment = ScoreContract.Alignment(confidence: confidence,
                                                used: adopted,
                                                barMap: barMap,
                                                method: Self.method,
                                                partMapping: mapping.isEmpty ? nil : mapping)

        return ScoreAlignerOutcome(
            alignment: alignment,
            partMapping: mapping,
            alignedNotes: aligned,
            scoreInformedTracks: tracks,
            agreementBefore: agreementBefore,
            agreementAfter: agreementAfter,
            reason: reason,
            scoreDuration: scoreDuration,
            audioDuration: audioDuration)
    }

    // MARK: The audio side

    /// The audio side of the DTW: the candidates' 12-bin chroma on the
    /// model's own frame clock.
    ///
    /// THE CHROMA IS THE MODEL'S OWN OUTPUT (the per-frame salience
    /// candidates, P-302) — the same candidate set the voice assignment
    /// consumes. NOT a spectrogram: no FFT in the portable core, and the
    /// aligner stays consistent with the assignment path by construction.
    struct AudioSide {
        /// One chroma vector per DTW frame (≤ maxFrames).
        var chroma: [[Double]]
        /// One time per DTW frame (seconds; the chunk-aware clock, or the
        /// bin's first frame's time when binned).
        var times: [Double]

        init(candidates: [[SalienceCandidate]], maxFrames: Int) {
            let raw = candidates.map { frame -> [Double] in
                var chroma = [Double](repeating: 0, count: 12)
                for candidate in frame {
                    chroma[((candidate.midi % 12) + 12) % 12] += candidate.salience
                }
                return Self.normalize(chroma)
            }
            let rawTimes = candidates.indices.map { BasicPitchFrameClock.seconds(forFrame: $0) }
            let (binnedChroma, binnedTimes) = Self.binned(raw, times: rawTimes, maxFrames: maxFrames)
            self.chroma = binnedChroma
            self.times = binnedTimes
        }

        /// Bin consecutive frames when a long song would exceed `maxFrames`:
        /// each bin sums its members' chroma and is re-normalised; its time is
        /// the bin's FIRST frame's time (the model's own clock, no invention).
        static func binned(_ chroma: [[Double]], times: [Double],
                           maxFrames: Int) -> ([[Double]], [Double]) {
            guard chroma.count > maxFrames, maxFrames > 0 else { return (chroma, times) }
            let binSize = Int(ceil(Double(chroma.count) / Double(maxFrames)))
            var outChroma: [[Double]] = []
            var outTimes: [Double] = []
            var index = 0
            while index < chroma.count {
                let end = min(index + binSize, chroma.count)
                var summed = [Double](repeating: 0, count: 12)
                for k in index..<end {
                    for bin in 0..<12 { summed[bin] += chroma[k][bin] }
                }
                outChroma.append(normalize(summed))
                outTimes.append(times[index])
                index = end
            }
            return (outChroma, outTimes)
        }

        /// L2-normalise (a zero vector stays zero — silence stays silent).
        static func normalize(_ vector: [Double]) -> [Double] {
            var sum = 0.0
            for value in vector { sum += value * value }
            let norm = sum.squareRoot()
            guard norm > 0 else { return vector }
            return vector.map { $0 / norm }
        }
    }

    // MARK: The score side

    /// The score side of the DTW: the parsed notes' 12-bin chroma on the
    /// analysis grid (the model's hop), bounded to ≤ maxFrames.
    struct ScoreSide {
        var times: [Double]
        var chroma: [[Double]]

        init(score: ParsedMusicXMLScore, maxFrames: Int) {
            let duration = score.noteList.duration
            // A long score widens its grid instead of dropping frames: the
            // chroma stays a faithful (coarser) picture of the score.
            let grid = duration > 0
                ? max(ScoreAligner.analysisGrid, duration / Double(max(maxFrames, 1)))
                : ScoreAligner.analysisGrid
            var times: [Double] = []
            var time = 0.0
            while time < duration - 1e-9 {
                times.append(time)
                time += grid
            }
            self.times = times
            self.chroma = times.map { Self.chroma(at: $0, notes: score.noteList.scoreNotes) }
        }

        /// The notes sounding in `[t, t + grid)` — pitch presence only, +1
        /// per sounding note, then L2-normalised. THE SALIENCE IS NOT A
        /// WEIGHT HERE (C-12): the DTW uses the notes' pitch presence only.
        static func chroma(at time: Double, notes: [ScoreContract.Note]) -> [Double] {
            var chroma = [Double](repeating: 0, count: 12)
            for note in notes where note.start_s <= time && time < note.end_s {
                chroma[((note.midi % 12) + 12) % 12] += 1.0
            }
            return AudioSide.normalize(chroma)
        }
    }

    // MARK: The banded DTW

    /// The banded DTW: cost = 1 − cosine; steps (1,1)/(1,0)/(0,1); a
    /// proportional band around the diagonal; rolling rows + a UInt8
    /// backpointer matrix (N×M bytes — a 4-minute song at ≤ 2000 frames a
    /// side stays ~4 MB, AGENTS §8's memory posture).
    ///
    /// The path is the GLOBAL path from (0, 0) to (N−1, M−1).
    struct BandedDTW {
        var path: [(Int, Int)]

        init(scoreChroma: [[Double]], audioChroma: [[Double]],
             bandFraction: Double) {
            let n = scoreChroma.count
            let m = audioChroma.count
            guard n >= 2, m >= 2 else {
                self.path = []
                return
            }

            let infinity = Double.infinity
            var previous = [Double](repeating: infinity, count: m)
            previous[0] = 1.0 - Self.cosine(scoreChroma[0], audioChroma[0])
            var back = [UInt8](repeating: 0, count: n * m)

            for i in 1..<n {
                // The proportional band's centre follows the diagonal — and
                // pins the path's start and end (the band of row i always
                // contains the diagonal cell, so (0,0) and (N−1,M−1) are
                // both reachable).
                let centre = Double(i) * Double(m - 1) / Double(max(1, n - 1))
                let low = max(0, Int((centre * (1.0 - bandFraction)).rounded(.down)))
                let high = min(m - 1, Int((centre * (1.0 + bandFraction)).rounded(.up)))
                var current = [Double](repeating: infinity, count: m)
                let cost = audioChroma[low...high].map { 1.0 - Self.cosine(scoreChroma[i], $0) }
                for j in low...high {
                    var best = infinity
                    var step: UInt8 = 1
                    if j >= 1, previous[j - 1] < best { best = previous[j - 1]; step = 1 }
                    if previous[j] < best { best = previous[j]; step = 2 }
                    if j >= 1, current[j - 1] < best { best = current[j - 1]; step = 3 }
                    current[j] = best + cost[j - low]
                    back[i * m + j] = step
                }
                previous = current
            }

            // The global path, backtracked from the far corner.
            var walked: [(Int, Int)] = []
            var i = n - 1
            var j = m - 1
            while true {
                walked.append((i, j))
                if i == 0 && j == 0 { break }
                let step = back[i * m + j]
                if step == 1 {
                    i -= 1; j -= 1
                } else if step == 2 {
                    i -= 1
                } else {
                    j -= 1
                }
                if i < 0 || j < 0 { break } // defensive; cannot happen on a computed path
            }
            self.path = walked.reversed()
        }

        /// The cosine of two L2-normalised vectors is their dot product.
        static func cosine(_ a: [Double], _ b: [Double]) -> Double {
            var sum = 0.0
            for k in 0..<min(a.count, b.count) { sum += a[k] * b[k] }
            return sum
        }
    }

    /// The cosine helper the confidence and the DP share.
    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        BandedDTW.cosine(a, b)
    }

    // MARK: The bar map

    /// The C-13.2 bar map: per measure, the score's own span → the audio's
    /// span through the warp.
    ///
    /// The score's own measure spans come from the measures' own notes (the
    /// parser does not read `<time>` — it is outside D-40 §2's scope), CHAINED:
    /// a measure ends where the next one begins, and the last measure ends at
    /// the score's own duration. The last AUDIO end is clamped to the audio's
    /// duration. The entries stay monotone (the warp is a positive scale).
    static func barMap(score: ParsedMusicXMLScore,
                       warp: (Double) -> Double,
                       audioDuration: Double) -> [ScoreContract.BarMapEntry] {
        let notes = score.noteList.scoreNotes
        guard !notes.isEmpty else { return [] }
        let measures = score.noteList.measures
        var spans: [Int: (start: Double, end: Double)] = [:]
        for note in notes {
            let existing = spans[note.measure]
            spans[note.measure] = (min(existing?.start ?? note.start_s, note.start_s),
                                   max(existing?.end ?? note.end_s, note.end_s))
        }
        var entries: [ScoreContract.BarMapEntry] = []
        for (index, measure) in measures.enumerated() {
            let start = spans[measure]?.start ?? 0
            let end: Double
            if index + 1 < measures.count {
                end = spans[measures[index + 1]]?.start ?? spans[measure]!.end
            } else {
                end = max(score.noteList.duration, spans[measure]!.end)
            }
            let audioStart = warp(start)
            let audioEnd = min(warp(end), audioDuration)
            // Monotone and non-degenerate: a bar never starts before the
            // previous one ends.
            let clampedStart = entries.last.map { max(audioStart, $0.end_s) } ?? max(0, audioStart)
            let clampedEnd = max(clampedStart, audioEnd)
            entries.append(ScoreContract.BarMapEntry(measure: measure,
                                                     start_s: clampedStart,
                                                     end_s: clampedEnd))
        }
        return entries
    }

    // MARK: The part mapping

    /// The score `part_id` → C-1 part mapping. An explicit mapping WINS; the
    /// label resolver runs otherwise; an unresolved label stays OUT of the
    /// map — never guessed (D-47 §8).
    static func partMapping(score: ParsedMusicXMLScore,
                            options: ScoreAlignerOptions) -> [String: Part] {
        if let explicit = options.explicitPartMapping, !explicit.isEmpty {
            return explicit
        }
        var mapping: [String: Part] = [:]
        for (partID, label) in score.partLabels {
            if let part = Self.part(forLabel: label) {
                mapping[partID] = part
            }
        }
        return mapping
    }

    /// The LABEL ALIAS TABLE: a normalised `<part-name>` → the C-1 part.
    ///
    /// Normalisation: lowercase, drop every non-alphanumeric character (so
    /// "Tenor 1", "tenor-1" and "TenorI"… all resolve). A label that is NOT
    /// in the table returns nil — the caller leaves that score part UNMAPPED.
    /// **"tenor" alone is deliberately absent**: in an SDA score it could be
    /// T1 or T2, and guessing a part is exactly what D-47 §8 forbids.
    public static func part(forLabel label: String) -> Part? {
        let normalised = label.lowercased().filter { $0.isLetter || $0.isNumber }
        switch normalised {
        case "bass", "basses":
            return .bass
        case "baritone", "baritones":
            return .baritone
        case "baritenor", "baritenors":
            return .baritenor
        case "tenor1", "tenori", "tenorus1", "firsttenor", "firsttenors", "t1":
            return .t1
        case "tenor2", "tenorii", "tenorus2", "secondtenor", "secondtenors", "t2":
            return .t2
        case "soprano", "sopranos":
            return .soprano
        case "alto", "altos":
            return .alto
        case "vocalpercussion", "vp":
            return .vp
        case "lead":
            return .lead
        case "instrumental":
            return .instrumental
        case "vocals":
            return .vocals
        default:
            return nil
        }
    }

    // MARK: The placement (Jess's `ScoreReview.align` rule, mirrored)

    /// Place the score's notes on the AUDIO timeline (pre-nudge).
    ///
    /// THE RULE (mirrors `ScoreReview.align` exactly — the engine and the
    /// consumer must place identically):
    ///   · a measure with two or more notes is scaled onto the bar's audio
    ///     span (`scale = audioSpan / scoreSpan`);
    ///   · a measure with a single note keeps its own duration (scale = 1);
    ///   · `alignedStart = bar.start_s + (note.start_s − measureStart)·scale`,
    ///     `alignedEnd = alignedStart + (note.end_s − note.start_s)·scale`;
    ///   · a note whose measure the bar map does not cover is SKIPPED;
    ///   · the part is the mapping's value — NIL when the score's part is
    ///     unmapped (the note is never guessed into a part, D-47 §8).
    static func alignedNotes(score: ParsedMusicXMLScore,
                             barMap: [ScoreContract.BarMapEntry],
                             mapping: [String: Part]) -> [ScoreContract.AlignedNote] {
        let scoreNotes = score.noteList.scoreNotes
        var measureSpans: [Int: (start: Double, end: Double, count: Int)] = [:]
        for note in scoreNotes {
            var span = measureSpans[note.measure] ?? (note.start_s, note.end_s, 0)
            span.start = min(span.start, note.start_s)
            span.end = max(span.end, note.end_s)
            span.count += 1
            measureSpans[note.measure] = span
        }
        let bars = Dictionary(barMap.map { ($0.measure, $0) },
                              uniquingKeysWith: { first, _ in first })

        var result: [ScoreContract.AlignedNote] = []
        result.reserveCapacity(scoreNotes.count)
        for (index, note) in scoreNotes.enumerated() {
            guard let bar = bars[note.measure], let span = measureSpans[note.measure] else {
                continue // the bar map does not cover this measure
            }
            let scoreSpan = max(span.end - span.start, 0)
            let audioSpan = max(bar.end_s - bar.start_s, 0)
            let scale: Double = (span.count > 1 && scoreSpan > 0) ? audioSpan / scoreSpan : 1
            let offset = (note.start_s - span.start) * scale
            let length = (note.end_s - note.start_s) * scale
            result.append(ScoreContract.AlignedNote(
                scoreIndex: index,
                part: mapping[note.part_id],
                midi: note.midi,
                scoreStart_s: note.start_s,
                scoreEnd_s: note.end_s,
                alignedStart_s: bar.start_s + offset,
                alignedEnd_s: bar.start_s + offset + length,
                measure: note.measure,
                scorePartID: note.part_id,
                voice: note.voice))
        }
        return result
    }
}
