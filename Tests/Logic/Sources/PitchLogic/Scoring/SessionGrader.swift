import Foundation
import EngineCore

// J-401 — the scoring engine. Pure Swift, no UI, no engine audio (AGENTS §1:
// scoring/grading logic belongs to Jess; deterministic; unit-testable).
//
// WHAT IT CONSUMES (all contract-mandated):
//   · the COMPOSED grading reference (C-14: correction overlay → else
//     score-informed → else heuristic). The CALLER composes it (J-402 wires
//     CorrectionResolver + ScoreReview); the grader records WHICH reference
//     graded (C-18 `gradingReference.source`) and never re-derives the choice.
//   · `tuning_cents` (D-22): the reference pitch is `100·midi' + cents_ref +
//     tuningCents` — a faithful singer of a detuned recording is never marked
//     flat or sharp (the D-22 detuned fixtures pin ≈ 0 deviation).
//   · the C-20 environment: the view transform (transposition + tempo) and
//     the latency offset (`live t` compared against `reference t − latency`).
//   · the C-19 config (clamped-for-grading, embedded by value in the result).
//
// THE D-54 POLICY (binding on this engine):
//   · confidence is REPORTED (`confidenceBand`), NEVER a scoring weight —
//     PROVISIONAL notes grade at full weight (D-54 §2);
//   · UNASSIGNED notes are excluded VISIBLY (`notAssessable` reason
//     "unassigned") — a grade from a subset never looks like a grade of the
//     whole (D-54 §1);
//   · unison grades per-part; the flag is reported, the math is unchanged
//     (D-54 §3);
//   · steady vs transition accuracy reported separately (D-54 §4's 50 ms
//     note-boundary window); both numbers always, or an explicit null;
//   · every accuracy number this engine produces is SYNTHETIC-labelled
//     wherever it is published (D-54 §5) — no real fixture exists in the repo.
//
// DETERMINISM (C-18): same inputs + config + environment ⇒ byte-identical
// result. No clock reads, no randomness — `sessionId`/`createdAt` are
// caller-supplied; dictionaries are never iterated for scoring decisions.
//
// THE MODEL, IN ONE PARAGRAPH: each reference note (in the C-20 view
// transform) collects the live frames whose LATENCY-CORRECTED time falls in
// its span. Frames below `breathGate_db` are unvoiced (a breath is silence).
// Voiced frames inside the `onsetGrace_ms` window are sung but not scored
// against pitch (the boundary glide is physiology). The scored frames' cents
// deviations (octave-folded when `octaveEquivalence`) have a MEAN — the
// note's center. The center inside `toleranceCents` makes the note a hit
// (with enough coverage); frames within `vibratoExtentCents` of the center
// count as in tune for the sustain run (vibrato is mean-centered — the swing
// is not an error). The note's score is the weighted pitch/timing/sustain
// combination (C-19's weights), golden notes carrying the bonus.

public enum SessionGrader {

    // MARK: Constants (pinned by the Scoring suite)

    /// The engine version recorded in every `SessionResult` (C-18).
    public static let engineVersion = "grading-0.1.0"
    /// The live stream's fixed grid (C-2.4: `hopMs == 16`).
    public static let hop_s = 0.016
    public static let hop_ms = 16
    /// V13's grid tolerance (frames within 1 ms of the uniform grid).
    public static let gridTolerance_s = 0.001
    /// D-54 §4's transition window (note-level, same part): a note starting
    /// within 50 ms after the previous note's end is TRANSITION-class.
    public static let transitionWindow_s = 0.050
    /// A note is a HIT only if at least this share of it was sung (voiced,
    /// post breath gate). Pin: half the note, sung.
    public static let minCoverageForHit = 0.5
    /// Phrase gap for a reference WITHOUT C-10 `partPresence` spans: notes
    /// separated by ≥ 1.0 s start a new phrase. (With spans, the spans ARE
    /// the phrases — D-41 §2.)
    public static let derivedPhraseGap_s = 1.0

    // MARK: Errors

    public enum GraderError: Error, Equatable {
        /// Nothing to grade — a part with an empty reference track.
        case emptyReference
        /// C-20 §5: the environment is outside the contractual ranges —
        /// refused, never clamped into silent wrongness.
        case environmentOutOfRange(String)
    }

    // MARK: The pure scoring components (public so the suite pins each one)

    /// The pitch component: 1.0 dead-on the (mean-centered) center, linear to
    /// 0 at the tolerance edge, 0 beyond it. Closer pitch ⇒ higher score —
    /// the standing invariant (C-18).
    public static func pitchScore(centerCents: Double, toleranceCents: Double) -> Double {
        guard toleranceCents > 0 else { return 0 }
        return max(0, 1 - abs(centerCents) / toleranceCents)
    }

    /// The timing component: a full 1.0 when the first voiced frame lands
    /// within the onset grace; beyond the grace the lateness is measured
    /// against the note's own duration. `onsetLatency_s` is the gap between
    /// the note's (transformed) start and its first voiced frame.
    public static func timingScore(onsetLatency_s: Double, grace_s: Double,
                                   noteDuration_s: Double) -> Double {
        guard noteDuration_s > 0 else { return 0 }
        let unexcusedLateness = max(0, onsetLatency_s - grace_s)
        return min(1, max(0, 1 - unexcusedLateness / noteDuration_s))
    }

    /// The sustain component: the longest continuous in-tune run as a share
    /// of the note's duration.
    public static func sustainScore(sustain_ms: Int, noteDuration_ms: Double) -> Double {
        guard noteDuration_ms > 0 else { return 0 }
        return min(1, max(0, Double(sustain_ms) / noteDuration_ms))
    }

    /// The A–F band over the session score (C-18: the letter is the UI band).
    public static func grade(forScore score: Double) -> GradeBand {
        GradeBand.band(forScore: score)
    }

    // MARK: The entry point

    /// Grades one part's session and returns the C-18 `SessionResult`.
    ///
    /// - Parameters:
    ///   - reference: the COMPOSED grading reference for ONE part (C-14's
    ///     pipeline output — overlay wins, else score-informed, else
    ///     heuristic). Never mutated: the C-20 transform is a view.
    ///   - live: the session's live pitch frames (C-2.4, the grading-grade
    ///     stream — `engine_id == SWIFTF0` per C-6.0). Sorted internally.
    ///   - config: the C-19 configuration. CLAMPED FOR GRADING first (the
    ///     clamped config is what the math uses and what the result records).
    ///   - environment: the C-20 environment (validated — refused outside the
    ///     ranges, never clamped).
    ///   - gradingReference: which composed reference this IS (C-14 order).
    ///   - goldenNoteIndices: indices into `reference.notes` that are golden
    ///     notes (C-4's UltraStar `*`); out-of-range indices are ignored.
    ///   - sessionId / bundleId / createdAt: caller-supplied identity (the
    ///     grader never reads the clock — determinism).
    ///   - sessionStart_s: the session's start in reference time (0 = the
    ///     song start; the C-20 times scale about it).
    ///   - duration_s: the session's duration; default = the transformed
    ///     reference's span.
    public static func grade(reference: NoteTrack,
                             live: [PitchFrame],
                             config: GradingConfig,
                             environment: SessionEnvironment,
                             gradingReference: GradingReferenceInfo,
                             goldenNoteIndices: Set<Int> = [],
                             sessionId: String,
                             bundleId: String,
                             createdAt: String,
                             sessionStart_s: Double = 0,
                             duration_s: Double? = nil) throws -> SessionResult {
        guard !reference.notes.isEmpty else { throw GraderError.emptyReference }
        try environment.validatedForGrading()
        let (gradedConfig, _) = try config.clampedForGrading()

        // The C-20 view: every time below is a TRANSFORMED time, every pitch
        // a TRANSFORMED reference pitch. The input track is never written to.
        let notes = reference.notes
            .enumerated()
            .map { (index: $0.offset, note: $0.element) }
            .sorted { $0.note.start_s < $1.note.start_s } // V8 already sorts; defensive

        // The live stream, latency-corrected ONCE (C-20 §4): a frame captured
        // at t corresponds to reference time t − latencyOffset.
        let frames = live.sorted { $0.t < $1.t }
        let refTimes = frames.map { environment.referenceTime(forLiveT: $0.t) }

        var verdicts: [Verdict] = []
        verdicts.reserveCapacity(notes.count)
        var frameCursor = 0

        for (position, entry) in notes.enumerated() {
            let span = environment.transformedSpan(start_s: entry.note.start_s,
                                                   end_s: entry.note.end_s,
                                                   sessionStart_s: sessionStart_s)
            let duration = max(span.end - span.start, 0)

            // The band: the C-10 `assignmentBand` when the track carries one,
            // else derived from the confidence (V16's rule — the SAME
            // thresholds). Reported, never a weight (D-54 §2).
            let band = entry.note.assignmentBand.flatMap(AssignmentBand.init(rawValue:))
                ?? AssignmentBand.band(forConfidence: entry.note.confidence)

            // D-54 §1 / C-14: UNASSIGNED notes are excluded from grading BY
            // DEFAULT, and the exclusion is VISIBLE. Checked FIRST — a note
            // the policy excludes is excluded no matter what the stream did.
            if band == .unassigned {
                verdicts.append(Verdict(
                    index: entry.index, band: band, unison: entry.note.unison ?? false,
                    transitional: transitionalClass(position: position, notes: notes,
                                                    environment: environment,
                                                    sessionStart_s: sessionStart_s),
                    notAssessableReason: PerNoteResult.reasonUnassigned,
                    spanStart_s: span.start,
                    spanDuration_s: duration))
                continue
            }

            // The frames of this note's span (half-open, the fixture's
            // 1e-9 convention). Both sides are sorted, so a cursor walk is
            // enough.
            while frameCursor < frames.count && refTimes[frameCursor] < span.start - 1e-9 {
                frameCursor += 1
            }
            var windowEnd = frameCursor
            while windowEnd < frames.count && refTimes[windowEnd] < span.end - 1e-9 {
                windowEnd += 1
            }
            let window = frameCursor..<max(windowEnd, frameCursor)

            // C-18's `notAssessableReason: "noLiveFrames"`: the note's span
            // contains NO frames at all (an uncovered span — the weak-phrase
            // loop reality). Frames exist but all silent ⇒ a graded MISS, not
            // an exclusion (the singer was there and sang nothing).
            if window.isEmpty {
                verdicts.append(Verdict(
                    index: entry.index, band: band, unison: entry.note.unison ?? false,
                    transitional: transitionalClass(position: position, notes: notes,
                                                    environment: environment,
                                                    sessionStart_s: sessionStart_s),
                    notAssessableReason: PerNoteResult.reasonNoLiveFrames,
                    spanStart_s: span.start,
                    spanDuration_s: duration))
                continue
            }

            // Breath gate (C-19): frames below `breathGate_db` (or with no
            // pitch at all) are UNVOICED for grading.
            let voicedInSpan = window.filter {
                frames[$0].hz > 0 && frames[$0].loudness_db >= gradedConfig.breathGate_db
            }
            let coverage = min(1, Double(voicedInSpan.count) * hop_s / max(duration, 1e-9))

            // The onset: the first voiced frame's lateness (in latency-
            // corrected time — a systematic live delay is the DEVICE's, not
            // the singer's, so the grace measures the singer against the
            // corrected timeline).
            let onsetLatency_s: Double
            if let first = voicedInSpan.first {
                onsetLatency_s = max(0, refTimes[first] - span.start)
            } else {
                onsetLatency_s = duration // nothing was sung
            }

            // The scored frames: voiced AND past the onset grace (C-19: the
            // glide through a note boundary is not scored against pitch).
            let graceEnd = span.start + Double(gradedConfig.onsetGrace_ms) / 1000.0
            let scored = voicedInSpan.filter { refTimes[$0] >= graceEnd - 1e-9 }

            // The cents deviations (fold THEN measure, C-19). The CENTER —
            // the note's mean pitch — comes from the SCORED frames only, so
            // an in-grace glide never drags it.
            let refHz = environment.referenceHz(midi: entry.note.midi,
                                                cents_ref: entry.note.cents_ref)
            func deviation(_ frameIndex: Int) -> Double {
                var dev = PitchMath.cents(from: refHz, to: frames[frameIndex].hz)
                if gradedConfig.octaveEquivalence {
                    dev = PitchMath.foldedCents(dev)
                }
                return dev
            }
            let scoredDeviations = scored.map(deviation)
            let center: Double?
            if scoredDeviations.isEmpty {
                center = nil
            } else {
                center = scoredDeviations.reduce(0, +) / Double(scoredDeviations.count)
            }

            // Sustain: the longest continuous run of in-tune VOICED frames in
            // the span. A frame is IN TUNE when the note's center is inside
            // the tolerance AND the frame sits within `vibratoExtentCents` of
            // that center (vibrato is mean-centered — the swing is not an
            // error, C-19). Grace frames ARE sung frames: a sung, in-tune
            // onset counts for sustain (only the glide itself, being off
            // center, breaks a run — which is the physiology the grace
            // exists to excuse). Consecutive = adjacent on the 16 ms grid.
            let tolerance = Double(gradedConfig.toleranceCents)
            let extent = Double(gradedConfig.vibratoExtentCents)
            var sustain_ms = 0
            if let center {
                var run = 0
                var previous: Double?
                for frameIndex in voicedInSpan {
                    let inTune = abs(center) <= tolerance
                        && abs(deviation(frameIndex) - center) <= extent
                    let adjacent = previous.map {
                        abs(refTimes[frameIndex] - $0 - hop_s) <= gridTolerance_s
                    } ?? false
                    if inTune {
                        run = (run > 0 && adjacent) ? run + 1 : 1
                        sustain_ms = max(sustain_ms, run * hop_ms)
                    } else {
                        run = 0
                    }
                    previous = refTimes[frameIndex]
                }
            }

            let pitch = center.map { pitchScore(centerCents: $0, toleranceCents: tolerance) } ?? 0
            let timing = timingScore(onsetLatency_s: onsetLatency_s,
                                     grace_s: Double(gradedConfig.onsetGrace_ms) / 1000.0,
                                     noteDuration_s: duration)
            let sustain = sustainScore(sustain_ms: sustain_ms,
                                       noteDuration_ms: duration * 1000.0)
            var score = gradedConfig.weights.pitch * pitch
                + gradedConfig.weights.timing * timing
                + gradedConfig.weights.sustain * sustain
            if goldenNoteIndices.contains(entry.index) {
                score *= gradedConfig.goldenNoteBonus
            }

            verdicts.append(Verdict(
                index: entry.index, band: band, unison: entry.note.unison ?? false,
                transitional: transitionalClass(position: position, notes: notes,
                                                environment: environment,
                                                sessionStart_s: sessionStart_s),
                notAssessableReason: nil,
                spanStart_s: span.start,
                spanDuration_s: duration,
                centsDeviation: center,
                coverage: coverage,
                sustain_ms: min(sustain_ms, Int((duration * 1000.0).rounded())),
                // A note with frames but NO voiced frames was missed outright —
                // hit FALSE (a miss, not a pitch error; the breath fixture's
                // invariant), while centsDeviation stays nil (no center to
                // report). `center == nil` ⇒ not verified in tune ⇒ not a hit.
                hit: (center.map { abs($0) <= tolerance } ?? false)
                    && coverage >= minCoverageForHit,
                score: score))
        }

        return assemble(verdicts: verdicts,
                        part: reference.part,
                        environment: environment,
                        config: gradedConfig,
                        gradingReference: gradingReference,
                        sessionId: sessionId,
                        bundleId: bundleId,
                        createdAt: createdAt,
                        sessionStart_s: sessionStart_s,
                        duration_s: duration_s,
                        referenceEnd_s: notes.map {
                            environment.transformedTime($0.note.end_s, sessionStart_s: sessionStart_s)
                        }.max() ?? 0,
                        partPresence: reference.partPresence)
    }

    // MARK: - D-54 §4's class (the 50 ms note-boundary window)

    /// TRANSITION when this note starts within 50 ms after the PRECEDING note
    /// of the same part ends; the first note of a part is STEADY. The class
    /// is computed on the TRANSFORMED times (the session grades the
    /// transformed reference).
    static func transitionalClass(position: Int,
                                  notes: [(index: Int, note: Note)],
                                  environment: SessionEnvironment,
                                  sessionStart_s: Double) -> Bool {
        guard position > 0 else { return false }
        let previousEnd = environment.transformedTime(notes[position - 1].note.end_s,
                                                      sessionStart_s: sessionStart_s)
        let start = environment.transformedTime(notes[position].note.start_s,
                                                sessionStart_s: sessionStart_s)
        return start - previousEnd <= transitionWindow_s
    }

    // MARK: - The verdict (the grader's internal per-note fact)

    struct Verdict {
        let index: Int
        let band: AssignmentBand
        let unison: Bool
        let transitional: Bool
        let notAssessableReason: String?
        /// The note's TRANSFORMED span (C-20's view — the times the session
        /// grades against). Carried so the phrase grouping never re-transforms.
        let spanStart_s: Double
        let spanDuration_s: Double
        var centsDeviation: Double?
        var coverage: Double?
        var sustain_ms: Int?
        var hit: Bool?
        var score: Double?
    }

    // MARK: - Aggregation (deterministic; duration-weighted)

    static func assemble(verdicts: [Verdict],
                         part: Part,
                         environment: SessionEnvironment,
                         config: GradingConfig,
                         gradingReference: GradingReferenceInfo,
                         sessionId: String,
                         bundleId: String,
                         createdAt: String,
                         sessionStart_s: Double,
                         duration_s: Double?,
                         referenceEnd_s: Double,
                         partPresence: [EngineCore.PartPresence]?) -> SessionResult {
        let graded = verdicts.filter { $0.notAssessableReason == nil }

        func weightedMean(_ items: [Verdict]) -> Double? {
            guard !items.isEmpty else { return nil }
            let totalDuration = items.reduce(0) { $0 + $1.spanDuration_s }
            guard totalDuration > 0 else { return nil }
            let sum = items.reduce(0) { $0 + ($1.score ?? 0) * $1.spanDuration_s }
            return min(1, max(0, sum / totalDuration))
        }

        let overall = weightedMean(graded)
        let steady = weightedMean(graded.filter { !$0.transitional })
        let transition = weightedMean(graded.filter { $0.transitional })

        // Per-note (C-18), in reference order.
        let perNote = verdicts.map { verdict -> PerNoteResult in
            var result = PerNoteResult(noteIndex: verdict.index)
            if let reason = verdict.notAssessableReason {
                result.notAssessable = true
                result.notAssessableReason = reason
                result.confidenceBand = verdict.band
                result.unison = verdict.unison
                result.transitional = verdict.transitional
                return result
            }
            result.hit = verdict.hit
            result.centsDeviation = verdict.centsDeviation
            result.coverage = verdict.coverage
            result.sustain_ms = verdict.sustain_ms
            result.confidenceBand = verdict.band
            result.unison = verdict.unison
            result.transitional = verdict.transitional
            result.notAssessable = false
            return result
        }

        // Phrases: the C-10 `partPresence` spans when the reference carries
        // them (D-41 §2 — bar-aligned when a score is present), else derived
        // from inter-note gaps. Only GRADED members contribute a score; a
        // phrase with none is OMITTED (its notes are visible in
        // `notAssessable` — a zero here would look like a bad grade).
        let phrases: [(index: Int, members: [Verdict])]
        if let spans = partPresence, !spans.isEmpty {
            phrases = spans.map { span in
                (span.phraseIndex, graded.filter { verdict in verdict.startInSpan(span: span) })
            }
        } else {
            var derived: [(index: Int, members: [Verdict])] = []
            var current: [Verdict] = []
            for verdict in graded {
                if let last = current.last,
                   (verdict.spanStart_s - (last.spanStart_s + last.spanDuration_s))
                    >= derivedPhraseGap_s {
                    derived.append((derived.count, current))
                    current = []
                }
                current.append(verdict)
            }
            if !current.isEmpty { derived.append((derived.count, current)) }
            phrases = derived
        }
        let perPhrase: [PerPhraseResult] = phrases.compactMap { phrase in
            guard let score = weightedMean(phrase.members) else { return nil }
            return PerPhraseResult(phraseIndex: phrase.index, score: score)
        }

        let unassignedCount = verdicts.filter {
            $0.notAssessableReason == PerNoteResult.reasonUnassigned
        }.count
        let noFramesCount = verdicts.filter {
            $0.notAssessableReason == PerNoteResult.reasonNoLiveFrames
        }.count

        return SessionResult(
            sessionId: sessionId,
            bundleId: bundleId,
            part: part,
            createdAt: createdAt,
            duration_s: duration_s ?? referenceEnd_s,
            gradingReference: gradingReference,
            config: config,
            latencyOffset_ms: environment.latencyOffset_ms,
            tuningCents: environment.tuningCents,
            transpositionSemitones: environment.transpositionSemitones,
            tempoScale: environment.tempoScale,
            perNote: perNote,
            perPhrase: perPhrase,
            accuracy: SessionAccuracy(overall: overall, steady: steady, transition: transition),
            notAssessable: NotAssessableSummary(
                total: unassignedCount + noFramesCount,
                byReason: .init(unassigned: unassignedCount, noLiveFrames: noFramesCount)),
            grade: overall.map { grade(forScore: $0) },
            engineVersion: SessionGrader.engineVersion)
    }
}

// MARK: - Span membership helpers (the phrase grouping)

private extension SessionGrader.Verdict {
    func startInSpan(span: EngineCore.PartPresence) -> Bool {
        spanStart_s >= span.start_s - 1e-9 && spanStart_s < span.end_s + 1e-9
    }
}
