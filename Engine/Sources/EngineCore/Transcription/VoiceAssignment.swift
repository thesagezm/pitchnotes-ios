import Foundation

// P-303 · Voice assignment — per-frame pitch candidates → per-part note events
// (PAUL lane).
//
// WHAT THIS IS: the engine that decides WHICH PART sings each candidate pitch.
// P-302 gives the per-frame multi-f0 posterior (the candidates + their
// salience); this file turns those candidates into one note track per part,
// with an honest per-note assignment confidence.
//
// THE MODEL (one frame at a time):
//
//   score(part, pitch) = salienceWeight · salience(pitch)
//                      + rangePrior(part, pitch)
//   frameScore(assignment) = Σ parts score + Σ adjacent parts harmonicTerm
//
//   · RANGE PRIOR — C-6.1's part range presets, as a SOFT prior. A pitch
//     outside the part's preset costs `rangePenaltyPerSemitone` per semitone.
//     It is NEVER a hard gate (D-12: the presets constrain FILTERING, they do
//     not decide what is true), and a pitch can still be assigned outside the
//     preset when that is the best explanation of the audio.
//   · SALIENCE — the model's posterior strength, used here as a MONOTONE
//     PREFERENCE ("the model believes this pitch more strongly"). It is NOT a
//     calibrated probability and it is NEVER rescaled into a confidence
//     (C-12): the `confidence` this file produces is the ASSIGNMENT posterior
//     (D-41 §1), a different quantity, and the two never mix.
//   · HARMONIC TERM — the adjacent interval class (a consonant stack of
//     thirds/fifths/sixths scores above a stack of seconds/tritones). It is a
//     SMALL tie-breaker, never an override: the model's own posterior leads.
//   · ORDERING — the parts are ordered by pitch (BASS < BARITONE < BARITENOR
//     < T2 < T1) and the assigned pitches must strictly increase along that
//     order: the NO-CROSSING rule. A part may be absent in a frame (subset
//     handling — a resting part, a song with fewer voices than parts).
//   · UNISON — two parts may share one pitch when `allowUnisons` is on; the
//     unison costs `unisonPenalty` and SPLITS the posterior mass, so a unison
//     note is automatically LOW confidence (D-41 §3). A unison is only
//     CONSIDERED for a part that has no candidate of its own inside its C-6.1
//     range above the last assigned pitch — otherwise the unison would
//     STEAL that part's own note (and the model would happily pile every
//     part onto the strongest pitch, because a unison is worth one more
//     salience reward). In practice: a unison fills a gap, it never
//     cannibalises a part that has a note of its own.
//
// ACROSS FRAMES: a beam Viterbi over the frames adds the melodic smoothness
// term (a pitch change costs, capped at `smoothnessCapCents` = 240 c/frame —
// a big leap is not infinitely worse than a small one) and the onset/offset
// costs (a voice that keeps singing is cheaper than one that flickers).
//
// THE CONFIDENCE (D-41 §1): the normalized posterior of the assigned part over
// the CANDIDATE PART SET. For every frame and every assigned pitch, the
// engine asks "how good is the best assignment in which part P sings THIS
// pitch?" for every part P, and normalizes those scores. The posterior is the
// frame-level model's belief; the temporal term selects the PATH, it does not
// enter the marginal. The value is NOT a calibrated probability of being right
// — D-41 §5 asks for a measured reliability table (band → precision), and
// P-306 publishes it in Docs/BENCHMARKS.md §5.3.
//
// HONESTY (AGENTS §11): the engine reports what it decided and how sure it
// is. It never drops a candidate silently (P-302 owns the candidate set), it
// never claims a certainty it does not have, and the limitations are stated
// in the code comments and in Docs/ENGINE.md §1.7.
//
// PORTABILITY: Foundation-only, no ONNX / C++ / AVFoundation. The sibling
// ports (Android/Linux) reuse this file unchanged (AGENTS §0).

// MARK: - The options

/// Every knob of the assignment, named.
///
/// Each one is a named constant so the benchmark report can name the exact
/// configuration that produced a number (P-306's honesty gate) and so a
/// future tuning round is a visible change, never a silent one.
public struct VoiceAssignmentOptions: Equatable, Sendable {

    /// The weight of the salience reward (the model's posterior strength).
    public var salienceWeight: Double
    /// The cost of ONE SEMITONE outside the part's C-6.1 range preset.
    public var rangePenaltyPerSemitone: Double
    /// The cap on the range penalty (in semitones) — a pitch 40 semitones out
    /// of range is not 40× worse than one 1 semitone out.
    public var rangePenaltyCapSemitones: Int
    /// The weight of the adjacent-interval harmonic term.
    public var harmonicWeight: Double
    /// The cost of two parts sharing one pitch (a unison).
    public var unisonPenalty: Double
    /// The cost of a part that STARTS singing between two frames.
    public var onsetPenalty: Double
    /// The cost of a part that STOPS singing between two frames.
    public var offsetPenalty: Double
    /// The cost of ONE CENT of pitch change between two frames.
    public var smoothnessWeight: Double
    /// The cap on the pitch-change cost, in cents (the AC's "≤ ~240 c/frame"):
    /// a leap bigger than this is not penalised beyond the cap.
    public var smoothnessCapCents: Double
    /// The temperature of the posterior softmax (lower ⇒ sharper).
    public var posteriorTemperature: Double
    /// How many per-frame assignments the beam keeps (by cumulative score).
    public var beamWidth: Int
    /// How many per-frame assignments enter the beam at all (by frame score).
    public var frameStateLimit: Int
    /// Whether two parts may share one pitch (a unison).
    public var allowUnisons: Bool
    /// The shortest note kept, in seconds (below this a run is a blip).
    public var minimumNoteDurationSeconds: Double

    public init(salienceWeight: Double = 1.0,
                rangePenaltyPerSemitone: Double = 0.35,
                rangePenaltyCapSemitones: Int = 24,
                harmonicWeight: Double = 0.05,
                unisonPenalty: Double = 0.25,
                onsetPenalty: Double = 0.15,
                offsetPenalty: Double = 0.15,
                smoothnessWeight: Double = 0.001,
                smoothnessCapCents: Double = 240.0,
                posteriorTemperature: Double = 0.25,
                beamWidth: Int = 48,
                frameStateLimit: Int = 64,
                allowUnisons: Bool = true,
                minimumNoteDurationSeconds: Double = 0.050) {
        self.salienceWeight = salienceWeight
        self.rangePenaltyPerSemitone = rangePenaltyPerSemitone
        self.rangePenaltyCapSemitones = rangePenaltyCapSemitones
        self.harmonicWeight = harmonicWeight
        self.unisonPenalty = unisonPenalty
        self.onsetPenalty = onsetPenalty
        self.offsetPenalty = offsetPenalty
        self.smoothnessWeight = smoothnessWeight
        self.smoothnessCapCents = smoothnessCapCents
        self.posteriorTemperature = posteriorTemperature
        self.beamWidth = beamWidth
        self.frameStateLimit = frameStateLimit
        self.allowUnisons = allowUnisons
        self.minimumNoteDurationSeconds = minimumNoteDurationSeconds
    }

    /// The M3 default configuration.
    public static let `default` = VoiceAssignmentOptions()
}

// MARK: - The output

/// One frame's assignment: which part sings which pitch, and how sure the
/// engine is about each of them.
public struct AssignedFrame: Equatable, Sendable {
    /// The frame index in the salience grid.
    public var frameIndex: Int
    /// The frame's time in seconds (the chunk-aware clock).
    public var time: Double
    /// The assigned pitch per part (nil ⇒ the part is silent in this frame).
    public var pitches: [Part: Int]
    /// The assignment confidence per part, [0,1] (D-41 §1).
    public var confidences: [Part: Double]
    /// The model's posterior strength for the assigned pitch, per part.
    /// NOT a calibrated probability and NEVER rescaled (C-12).
    public var saliences: [Part: Double]

    public init(frameIndex: Int, time: Double,
                pitches: [Part: Int], confidences: [Part: Double], saliences: [Part: Double]) {
        self.frameIndex = frameIndex
        self.time = time
        self.pitches = pitches
        self.confidences = confidences
        self.saliences = saliences
    }
}

/// The assignment's whole output.
public struct VoiceAssignmentResult: Equatable, Sendable {
    /// The per-frame assignments (one entry per salience frame).
    public var frames: [AssignedFrame]
    /// The per-part note events (the assignment's per-note output).
    public var notesByPart: [Part: [AssignedNote]]
    /// The engine version (C-10.2's per-track `engineVersion`).
    public var engineVersion: String
    /// The configuration that produced this result (the report names it).
    public var options: VoiceAssignmentOptions

    public init(frames: [AssignedFrame], notesByPart: [Part: [AssignedNote]],
                engineVersion: String, options: VoiceAssignmentOptions) {
        self.frames = frames
        self.notesByPart = notesByPart
        self.engineVersion = engineVersion
        self.options = options
    }

    /// The mean confidence of a part's notes (the manifest's `noteConfidence`).
    public func meanConfidence(for part: Part) -> Double {
        let notes = notesByPart[part] ?? []
        guard !notes.isEmpty else { return 0 }
        return notes.reduce(0.0) { $0 + $1.confidence } / Double(notes.count)
    }
}

// MARK: - The engine

/// The voice assignment engine (P-303).
public enum VoiceAssignmentEngine {

    /// The engine version this file writes into the tracks (C-10.2).
    public static let version = "voice-assignment-0.1.0"

    /// Assign the candidates of a salience table to parts.
    ///
    /// The convenience entry point: it picks the candidates with P-302's peak
    /// picker and then assigns them.
    public static func assign(table: PitchSalienceTable,
                               parts: [Part],
                               options: VoiceAssignmentOptions = .default,
                               peakOptions: SaliencePeakOptions = .default,
                               engineVersion: String = VoiceAssignmentEngine.version) -> VoiceAssignmentResult {
        let candidates = MultiFOSalience.candidates(in: table, options: peakOptions)
        return assign(candidates: candidates, parts: parts,
                      options: options, engineVersion: engineVersion)
    }

    /// Assign the per-frame candidates to parts.
    ///
    /// - Parameters:
    ///   - candidates: the per-frame candidates (P-302's `MultiFOSalience.candidates`).
    ///   - parts: the parts to assign. ANY subset (subset handling): a
    ///     four-voice song passes four parts; the engine never invents a part
    ///     that was not asked for, and never assigns a part it was not given.
    ///   - options: the configuration (see `VoiceAssignmentOptions`).
    /// - Returns: the per-frame assignments and the per-part note events.
    public static func assign(candidates: [[SalienceCandidate]],
                               parts: [Part],
                               options: VoiceAssignmentOptions = .default,
                               engineVersion: String = VoiceAssignmentEngine.version) -> VoiceAssignmentResult {
        let ordered = orderedParts(parts)
        guard !ordered.isEmpty else {
            return VoiceAssignmentResult(frames: [], notesByPart: [:],
                                         engineVersion: engineVersion, options: options)
        }

        // 1. The per-frame candidate assignments (the enumeration the beam
        //    searches over).
        var frameStates: [[FrameState]] = []
        frameStates.reserveCapacity(candidates.count)
        for frame in candidates {
            let states = enumerateStates(frame: frame, parts: ordered, options: options)
                .sorted { lhs, rhs in
                    lhs.score == rhs.score
                        ? lexLess(lhs.pitches, rhs.pitches)
                        : lhs.score > rhs.score
                }
            frameStates.append(Array(states.prefix(max(1, options.frameStateLimit))))
        }

        // 2. The temporal beam Viterbi over the frames.
        let path = viterbi(frameStates: frameStates, parts: ordered, options: options)

        // 3. The per-frame confidences (the frame model's posterior over the
        //    candidate part set).
        var frames: [AssignedFrame] = []
        frames.reserveCapacity(candidates.count)
        for (frameIndex, frameCandidates) in candidates.enumerated() {
            let pitches = frameIndex < path.count ? path[frameIndex] : [Int](repeating: -1, count: ordered.count)
            var framePitches: [Part: Int] = [:]
            var frameConfidences: [Part: Double] = [:]
            var frameSaliences: [Part: Double] = [:]
            var posteriors = posteriorByPitch(frame: frameCandidates, parts: ordered,
                                               options: options)
            for (partIndex, part) in ordered.enumerated() {
                let pitch = pitches[partIndex]
                guard pitch >= 0 else { continue }
                framePitches[part] = pitch
                frameConfidences[part] = posteriors[pitch]?[part] ?? 0
                frameSaliences[part] = salience(of: pitch, in: frameCandidates)
            }
            frames.append(AssignedFrame(frameIndex: frameIndex,
                                        time: BasicPitchFrameClock.seconds(forFrame: frameIndex),
                                        pitches: framePitches,
                                        confidences: frameConfidences,
                                        saliences: frameSaliences))
        }

        // 4. The per-part note events.
        let notesByPart = buildNotes(frames: frames, candidates: candidates,
                                     parts: ordered, options: options)

        return VoiceAssignmentResult(frames: frames, notesByPart: notesByPart,
                                     engineVersion: engineVersion, options: options)
    }

    /// Build the contract v1.1 tracks from an assignment.
    ///
    /// The entry point P-305's writer expects: the assignment's per-part notes
    /// go in, the contract tracks (with the bands, the presence and the unison
    /// flags) come out. `spans` is the phrase grid — the fixed 4.0 s grid, or
    /// P-304's bar-aligned spans when a score is present.
    public static func buildTracks(from result: VoiceAssignmentResult,
                                   spans: [PhraseSpan]) -> [Part: NoteTrack] {
        NoteTrackV11Builder.buildTracks(parts: result.notesByPart,
                                        spans: spans,
                                        engineVersion: result.engineVersion)
    }

    // MARK: - The parts order

    /// The parts in PITCH order, LOW → HIGH: BASS < BARITONE < BARITENOR <
    /// T2 < T1 (and SOPRANO/ALTO above T1 for a female chorale).
    ///
    /// `Part.sortOrder` is the contractual DISPLAY order (SOPRANO first),
    /// which is also the high → low order — so the pitch order is its reverse.
    public static func orderedParts(_ parts: [Part]) -> [Part] {
        var seen = Set<Part>()
        var unique: [Part] = []
        for part in parts where !seen.contains(part) {
            seen.insert(part)
            unique.append(part)
        }
        return unique.sorted { $0.sortOrder > $1.sortOrder }
    }

    // MARK: - The scoring

    /// The per-(part, pitch) score: the salience reward + the range prior.
    public static func baseScore(part: Part, midi: Int, salience: Double,
                                 options: VoiceAssignmentOptions) -> Double {
        options.salienceWeight * salience + rangePrior(part: part, midi: midi, options: options)
    }

    /// C-6.1's range prior — a SOFT cost, never a gate (D-12).
    public static func rangePrior(part: Part, midi: Int,
                                  options: VoiceAssignmentOptions) -> Double {
        guard let preset = PartRangePresets.preset(for: part) else { return 0 }
        let outside: Int
        if midi < preset.midiLow {
            outside = preset.midiLow - midi
        } else if midi > preset.midiHigh {
            outside = midi - preset.midiHigh
        } else {
            return 0
        }
        let capped = min(outside, max(0, options.rangePenaltyCapSemitones))
        return -options.rangePenaltyPerSemitone * Double(capped)
    }

    /// The harmonic term of one adjacent interval: +1 consonant, −1 dissonant,
    /// 0 neutral (a fourth is neither — it is the interval between a bass and
    /// the root above it in most hymn voicings).
    public static func harmonicScore(lowerMidi: Int, higherMidi: Int) -> Double {
        let interval = abs(higherMidi - lowerMidi) % 12
        switch interval {
        case 0, 3, 4, 7, 8, 9: return 1.0
        case 1, 2, 6, 10, 11: return -1.0
        default: return 0.0
        }
    }

    // MARK: - The frame enumeration

    /// One candidate assignment of a frame.
    struct FrameState {
        /// The assigned pitch per ordered part (−1 ⇒ the part is silent).
        var pitches: [Int]
        /// The frame score of the assignment.
        var score: Double
    }

    /// Enumerate every assignment of one frame that satisfies the ordering
    /// rule, with its frame score.
    ///
    /// The parts are walked from LOW to HIGH; each may take a candidate pitch
    /// strictly above the last one (the no-crossing rule), take the SAME pitch
    /// (a unison, when allowed), or stay silent.
    static func enumerateStates(frame: [SalienceCandidate], parts: [Part],
                                 options: VoiceAssignmentOptions) -> [FrameState] {
        let candidates = frame.sorted { $0.midi < $1.midi }
        var results: [FrameState] = []
        var pitches = [Int](repeating: -1, count: parts.count)

        func recurse(_ partIndex: Int, _ lastCandidateIndex: Int, _ lastMidi: Int, _ score: Double) {
            if partIndex == parts.count {
                results.append(FrameState(pitches: pitches, score: score))
                return
            }
            let part = parts[partIndex]
            // (a) the part is silent in this frame.
            recurse(partIndex + 1, lastCandidateIndex, lastMidi, score)
            // (b) the part takes a candidate.
            // A unison (the same pitch as the part below) is only CONSIDERED
            // when the part has no in-range candidate of its own above the
            // last assigned pitch — otherwise it would steal that note.
            let hasOwnCandidate = candidates.indices.contains { index in
                index > lastCandidateIndex
                    && rangePrior(part: part, midi: candidates[index].midi, options: options) == 0
            }
            for (candidateIndex, candidate) in candidates.enumerated() {
                if candidateIndex < lastCandidateIndex { continue }
                if candidateIndex == lastCandidateIndex {
                    // A unison: the same pitch as the part below.
                    guard options.allowUnisons, lastMidi == candidate.midi,
                          !hasOwnCandidate else { continue }
                    let unisonScore = score + baseScore(part: part, midi: candidate.midi,
                                                         salience: candidate.salience,
                                                         options: options)
                        - options.unisonPenalty
                    pitches[partIndex] = candidate.midi
                    recurse(partIndex + 1, candidateIndex, candidate.midi, unisonScore)
                    pitches[partIndex] = -1
                } else {
                    var assigned = score + baseScore(part: part, midi: candidate.midi,
                                                     salience: candidate.salience,
                                                     options: options)
                    if lastMidi >= 0 {
                        assigned += options.harmonicWeight
                            * harmonicScore(lowerMidi: lastMidi, higherMidi: candidate.midi)
                    }
                    pitches[partIndex] = candidate.midi
                    recurse(partIndex + 1, candidateIndex, candidate.midi, assigned)
                    pitches[partIndex] = -1
                }
            }
        }

        recurse(0, -1, -1, 0)
        return results
    }

    /// The best frame score with an optional constraint ("part P must sing
    /// this pitch"). `nil` when the constraint is unsatisfiable.
    ///
    /// This is the DP formulation of the enumeration above — the same model,
    /// computed in O(parts × states × candidates) so the posterior can ask it
    /// once per (part, pitch) pair.
    static func bestFrameScore(frame: [SalienceCandidate], parts: [Part],
                               options: VoiceAssignmentOptions,
                               constrainedPart: Part? = nil,
                               constrainedMidi: Int? = nil) -> Double? {
        let candidates = frame.sorted { $0.midi < $1.midi }
        let stateCount = candidates.count + 1
        // State 0 = "no pitch assigned yet"; state i+1 = candidate i is the
        // last assigned pitch.
        var dp = [Double](repeating: -Double.infinity, count: stateCount)
        dp[0] = 0
        for part in parts {
            var next = [Double](repeating: -Double.infinity, count: stateCount)
            let isConstrained = (constrainedPart == part)
            for state in 0..<stateCount where dp[state] > -Double.infinity {
                let lastCandidateIndex = state - 1
                let lastMidi = lastCandidateIndex >= 0 ? candidates[lastCandidateIndex].midi : -1
                if !isConstrained {
                    next[state] = max(next[state], dp[state])
                }
                for (candidateIndex, candidate) in candidates.enumerated() {
                    if isConstrained {
                        guard constrainedMidi == candidate.midi else { continue }
                    }
                    if candidateIndex < lastCandidateIndex { continue }
                    if candidateIndex == lastCandidateIndex {
                        // A unison: only when the part has no in-range
                        // candidate of its own above the last assigned pitch.
                        let hasOwnCandidate = candidates.indices.contains { index in
                            index > lastCandidateIndex
                                && rangePrior(part: part, midi: candidates[index].midi,
                                              options: options) == 0
                        }
                        guard options.allowUnisons, lastMidi == candidate.midi,
                              !hasOwnCandidate else { continue }
                        let value = dp[state]
                            + baseScore(part: part, midi: candidate.midi,
                                        salience: candidate.salience, options: options)
                            - options.unisonPenalty
                        next[candidateIndex + 1] = max(next[candidateIndex + 1], value)
                    } else {
                        var value = dp[state]
                            + baseScore(part: part, midi: candidate.midi,
                                        salience: candidate.salience, options: options)
                        if lastMidi >= 0 {
                            value += options.harmonicWeight
                                * harmonicScore(lowerMidi: lastMidi, higherMidi: candidate.midi)
                        }
                        next[candidateIndex + 1] = max(next[candidateIndex + 1], value)
                    }
                }
            }
            dp = next
        }
        let best = dp.max() ?? -Double.infinity
        return best == -Double.infinity ? nil : best
    }

    // MARK: - The posterior

    /// The per-pitch posterior over the parts: for every candidate pitch, the
    /// normalized belief of each part (D-41 §1's "the normalized posterior of
    /// the assigned part over the candidate part set").
    static func posteriorByPitch(frame: [SalienceCandidate], parts: [Part],
                                  options: VoiceAssignmentOptions) -> [Int: [Part: Double]] {
        var result: [Int: [Part: Double]] = [:]
        let pitches = Array(Set(frame.map { $0.midi })).sorted()
        for pitch in pitches {
            var scores: [(part: Part, score: Double)] = []
            for part in parts {
                if let score = bestFrameScore(frame: frame, parts: parts, options: options,
                                              constrainedPart: part, constrainedMidi: pitch) {
                    scores.append((part, score))
                }
            }
            guard !scores.isEmpty else { continue }
            let temperature = max(1e-6, options.posteriorTemperature)
            let maximum = scores.map { $0.score }.max() ?? 0
            var weights: [Part: Double] = [:]
            var total = 0.0
            for entry in scores {
                let weight = exp((entry.score - maximum) / temperature)
                weights[entry.part] = weight
                total += weight
            }
            guard total > 0 else { continue }
            var posterior: [Part: Double] = [:]
            for (part, weight) in weights {
                posterior[part] = weight / total
            }
            result[pitch] = posterior
        }
        return result
    }

    // MARK: - The temporal beam

    /// One beam entry.
    struct BeamEntry {
        var pitches: [Int]
        var score: Double
        var back: Int
    }

    /// The temporal beam Viterbi: the per-frame path of assignments.
    ///
    /// The transition cost is the melodic smoothness (capped at
    /// `smoothnessCapCents`) plus the onset/offset costs. The beam keeps
    /// `beamWidth` paths by cumulative score and each frame contributes at
    /// most `frameStateLimit` candidate assignments (by frame score) — both
    /// are named options, so the approximation is visible in the report.
    static func viterbi(frameStates: [[FrameState]], parts: [Part],
                        options: VoiceAssignmentOptions) -> [[Int]] {
        var beam: [BeamEntry] = []
        var history: [[BeamEntry]] = []
        history.reserveCapacity(frameStates.count)

        for states in frameStates {
            var next: [BeamEntry] = []
            next.reserveCapacity(states.count)
            if beam.isEmpty {
                for state in states {
                    next.append(BeamEntry(pitches: state.pitches, score: state.score, back: -1))
                }
            } else {
                for state in states {
                    var best = -Double.infinity
                    var bestIndex = -1
                    for (index, entry) in beam.enumerated() {
                        let value = entry.score - transitionCost(old: entry.pitches,
                                                                 new: state.pitches,
                                                                 options: options)
                        if value > best {
                            best = value
                            bestIndex = index
                        }
                    }
                    next.append(BeamEntry(pitches: state.pitches,
                                          score: best + state.score,
                                          back: bestIndex))
                }
            }
            next.sort { lhs, rhs in
                lhs.score == rhs.score ? lexLess(lhs.pitches, rhs.pitches) : lhs.score > rhs.score
            }
            beam = Array(next.prefix(max(1, options.beamWidth)))
            history.append(beam)
        }

        // Backtrack the best path.
        guard let last = history.last, !last.isEmpty else {
            return frameStates.map { _ in [Int](repeating: -1, count: parts.count) }
        }
        var path: [[Int]] = Array(repeating: [], count: history.count)
        var cursor = 0
        var back = last[0].back
        for frameIndex in stride(from: history.count - 1, through: 0, by: -1) {
            let entries = history[frameIndex]
            let index = min(max(0, cursor), entries.count - 1)
            path[frameIndex] = entries[index].pitches
            cursor = back
            back = index >= 0 && index < entries.count ? entries[index].back : -1
        }
        return path
    }

    /// The transition cost between two frames' assignments.
    static func transitionCost(old: [Int], new: [Int],
                               options: VoiceAssignmentOptions) -> Double {
        var cost = 0.0
        let count = min(old.count, new.count)
        for index in 0..<count {
            let before = old[index]
            let after = new[index]
            if before == after { continue }
            if before < 0 {
                cost += options.onsetPenalty
            } else if after < 0 {
                cost += options.offsetPenalty
            } else {
                let cents = abs(Double(after - before) * 100.0)
                cost += options.smoothnessWeight * min(cents, options.smoothnessCapCents)
            }
        }
        return cost
    }

    // MARK: - The note events

    /// The per-part note events from the per-frame assignments.
    ///
    /// A run of consecutive frames with the same pitch for a part is one note.
    /// The note's salience is the MEAN of the model's posterior strength over
    /// the run (carried verbatim, never rescaled — C-12) and its confidence is
    /// the MEAN of the per-frame assignment posteriors (D-41 §1).
    static func buildNotes(frames: [AssignedFrame], candidates: [[SalienceCandidate]],
                            parts: [Part], options: VoiceAssignmentOptions) -> [Part: [AssignedNote]] {
        var result: [Part: [AssignedNote]] = [:]
        for part in parts {
            var notes: [AssignedNote] = []
            var runStart: Double?
            var runEnd: Double = 0
            var runSaliences: [Double] = []
            var runConfidences: [Double] = []
            var runPitch = -1

            func closeRun() {
                guard let start = runStart, runPitch >= 0 else { return }
                let duration = runEnd - start
                if duration >= options.minimumNoteDurationSeconds {
                    let salience = runSaliences.reduce(0, +) / Double(max(1, runSaliences.count))
                    let confidence = runConfidences.reduce(0, +) / Double(max(1, runConfidences.count))
                    notes.append(AssignedNote(start_s: start, end_s: runEnd, midi: runPitch,
                                              confidence: confidence, salience: salience))
                }
                runStart = nil
                runSaliences.removeAll(keepingCapacity: true)
                runConfidences.removeAll(keepingCapacity: true)
                runPitch = -1
            }

            for (frameIndex, frame) in frames.enumerated() {
                let pitch = frame.pitches[part] ?? -1
                let frameEnd = frameIndex + 1 < frames.count
                    ? frames[frameIndex + 1].time
                    : BasicPitchFrameClock.seconds(forFrame: frameIndex + 1)
                if pitch == runPitch, runStart != nil {
                    runEnd = frameEnd
                    runSaliences.append(frame.saliences[part] ?? 0)
                    runConfidences.append(frame.confidences[part] ?? 0)
                    continue
                }
                closeRun()
                guard pitch >= 0 else { continue }
                runPitch = pitch
                runStart = frame.time
                runEnd = frameEnd
                runSaliences = [frame.saliences[part] ?? 0]
                runConfidences = [frame.confidences[part] ?? 0]
            }
            closeRun()

            notes = repairOverlaps(notes)
            result[part] = notes
        }
        return result
    }

    /// C-2.3 V8: within one part the notes are sorted and never overlap.
    ///
    /// The same rule as `NoteTrackBuilder.repairOverlaps`: the earlier note's
    /// sustain is truncated at the later note's onset (the ONSETS are the
    /// engine's measurement and they stay exact).
    static func repairOverlaps(_ notes: [AssignedNote]) -> [AssignedNote] {
        var sorted = notes.sorted { lhs, rhs in
            lhs.start_s == rhs.start_s ? lhs.midi < rhs.midi : lhs.start_s < rhs.start_s
        }
        var result: [AssignedNote] = []
        for note in sorted {
            if let last = result.last, note.start_s < last.end_s {
                let truncated = AssignedNote(start_s: last.start_s, end_s: note.start_s,
                                             midi: last.midi, cents_ref: last.cents_ref,
                                             confidence: last.confidence, salience: last.salience)
                if truncated.duration > 0 {
                    result[result.count - 1] = truncated
                } else {
                    result.removeLast()
                }
            }
            result.append(note)
        }
        return result
    }

    // MARK: - Helpers

    /// The salience of a pitch in a frame (0 when it is not a candidate).
    static func salience(of midi: Int, in frame: [SalienceCandidate]) -> Double {
        for candidate in frame where candidate.midi == midi {
            return candidate.salience
        }
        return 0
    }

    /// A deterministic lexicographic comparison (Swift's `sort` is not
    /// guaranteed stable, so every tie-break is explicit).
    static func lexLess(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for index in 0..<min(lhs.count, rhs.count) where lhs[index] != rhs[index] {
            return lhs[index] < rhs[index]
        }
        return lhs.count < rhs.count
    }
}

// MARK: - The metrics

/// The assignment's measured quality against a truth (P-303's AC).
///
/// The truth is per frame: which pitch each part sings. The metrics are
/// reported, never used to tune silently (D-41 §5 asks for the reliability
/// table, which P-306 publishes).
public struct VoiceAssignmentMetrics: Equatable, Sendable {
    /// The number of frames compared.
    public var frameCount: Int
    /// The frames in which EVERY part's pitch matched the truth.
    public var framesAllPartsCorrect: Int
    /// The frames in which at least one part's pitch matched.
    public var framesAnyPartCorrect: Int
    /// The per-part frame accuracy.
    public var perPartAccuracy: [Part: Double]
    /// The macro average of the per-part frame accuracies.
    public var macroPartAccuracy: Double
    /// The number of (part, frame) slots in the truth.
    public var partFrameSlots: Int
    /// The number of (part, frame) slots assigned CORRECTLY.
    public var partFrameHits: Int

    /// The strict frame accuracy: the fraction of frames in which every part
    /// carries the right pitch. This is the number P-303's AC quotes.
    public var frameAccuracy: Double {
        frameCount > 0 ? Double(framesAllPartsCorrect) / Double(frameCount) : 0
    }

    /// The macro part accuracy: the mean over the parts of the per-part frame
    /// accuracy. It is the PART-AWARE number (the macro F1's accuracy
    /// sibling) and it is reported SEPARATELY from the strict frame accuracy.
    public var macroAccuracy: Double { macroPartAccuracy }
}

/// Evaluates an assignment against a per-frame truth.
public enum VoiceAssignmentEvaluator {

    /// Compare an assignment with the truth.
    ///
    /// - Parameters:
    ///   - frames: the assignment's per-frame assignments.
    ///   - truth: the per-frame truth (frame → part → the pitch it sings).
    ///     A part missing from a frame's truth is ABSENT there (the engine may
    ///     or may not have assigned it — an absent truth slot is not counted
    ///     as a hit).
    public static func evaluate(frames: [AssignedFrame], truth: [[Part: Int]]) -> VoiceAssignmentMetrics {
        var framesAllCorrect = 0
        var framesAnyCorrect = 0
        var perPartHits: [Part: Int] = [:]
        var perPartSlots: [Part: Int] = [:]
        var totalSlots = 0
        var totalHits = 0

        for (index, frame) in frames.enumerated() {
            guard index < truth.count else { break }
            let frameTruth = truth[index]
            var allCorrect = !frameTruth.isEmpty
            var anyCorrect = false
            for (part, pitch) in frameTruth {
                perPartSlots[part, default: 0] += 1
                totalSlots += 1
                if frame.pitches[part] == pitch {
                    perPartHits[part, default: 0] += 1
                    totalHits += 1
                    anyCorrect = true
                } else {
                    allCorrect = false
                }
            }
            if allCorrect { framesAllCorrect += 1 }
            if anyCorrect { framesAnyCorrect += 1 }
        }

        var perPartAccuracy: [Part: Double] = [:]
        var macro = 0.0
        var partsCounted = 0
        for (part, slots) in perPartSlots where slots > 0 {
            let accuracy = Double(perPartHits[part] ?? 0) / Double(slots)
            perPartAccuracy[part] = accuracy
            macro += accuracy
            partsCounted += 1
        }
        macro = partsCounted > 0 ? macro / Double(partsCounted) : 0

        return VoiceAssignmentMetrics(frameCount: min(frames.count, truth.count),
                                       framesAllPartsCorrect: framesAllCorrect,
                                       framesAnyPartCorrect: framesAnyCorrect,
                                       perPartAccuracy: perPartAccuracy,
                                       macroPartAccuracy: macro,
                                       partFrameSlots: totalSlots,
                                       partFrameHits: totalHits)
    }
}

// MARK: - AssignedNote's duration helper

extension AssignedNote {
    /// The note's duration in seconds.
    public var duration: Double { max(0, end_s - start_s) }
}
