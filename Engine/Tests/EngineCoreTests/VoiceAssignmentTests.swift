import XCTest
@testable import EngineCore

// P-303 · The voice-assignment tests.
//
// TWO KINDS OF TEST, and both matter:
//
// (1) THE CROSS-IMPLEMENTATION GATE. The artifact
//     (`Tests/Spikes/Fixtures/assignment_satb5.json`) is produced by
//     `Tests/Spikes/assignment_dump.py` from the REAL basic-pitch model, and
//     its `expected` block is computed by the PYTHON mirror of
//     `VoiceAssignmentEngine`. This file recomputes the same numbers with the
//     SWIFT implementation over the SAME committed candidates. If the two
//     implementations ever drift apart, this test goes RED instead of the two
//     sides quietly publishing different assignment numbers.
//
// (2) THE BEHAVIOUR TESTS. The model's RULES, each on a small hand-built
//     candidate frame, so a rule cannot be broken by a tuning change: the
//     no-crossing order, the subset handling, the unison rule (the gap-filling
//     rule AND the low confidence a unison produces), the range prior as a
//     SOFT prior (D-12), the confidence's range and the D-41 bands, and the
//     determinism.
//
// THE MEASURED NUMBERS ARE PINNED at the bottom: a change in what the engine
// MEASURES must be a visible, deliberate change.

final class VoiceAssignmentTests: XCTestCase {

    // MARK: - The artifact

    private struct Artifact: Decodable {
        /// A `[index, value]` pair (the artifact's part-indexed entries).
        struct IndexValue: Decodable {
            var index: Int
            var value: Double
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                self.index = try container.decode(Int.self)
                self.value = try container.decode(Double.self)
            }
        }
        struct Options: Decodable {
            var salience_weight: Double
            var range_penalty_per_semitone: Double
            var range_penalty_cap_semitones: Int
            var harmonic_weight: Double
            var unison_penalty: Double
            var onset_penalty: Double
            var offset_penalty: Double
            var smoothness_weight: Double
            var smoothness_cap_cents: Double
            var posterior_temperature: Double
            var beam_width: Int
            var frame_state_limit: Int
            var allow_unisons: Bool
            var minimum_note_duration_seconds: Double
        }
        struct PeakOptions: Decodable {
            var minimum_salience: Double
            var local_max_window_semitones: Int
            var minimum_peak_spacing_frames: Int
        }
        struct Config: Decodable {
            var options: Options
            var peak_options: PeakOptions
            var part_ranges_midi: [String: [Int]]
            var sort_order: [String: Int]
        }
        struct Expected: Decodable {
            var frame_count: Int
            var frames_all_parts_correct: Int
            var frames_any_part_correct: Int
            var frame_accuracy: Double
            var frames_any_accuracy: Double
            var per_part_accuracy: [String: Double]
            var macro_part_accuracy: Double
            var part_frame_slots: Int
            var part_frame_hits: Int
        }
        struct AssignmentFrame: Decodable {
            var frame_index: Int
            var time: Double
            var pitches: [IndexValue]
            var confidences: [IndexValue]
        }
        struct Note: Decodable {
            var start_s: Double
            var end_s: Double
            var midi: Int
            var confidence: Double
            var salience: Double
        }
        struct TruthChord: Decodable {
            var start_s: Double
            var end_s: Double
            var pitches: [String: Int]
        }
        /// The accuracy split at the chord transitions (the honest reading of
        /// where the engine's errors live).
        struct BoundaryAnalysis: Decodable {
            var window_frames: Int
            var window_ms: Double
            var boundary_frames: [Int]
            var transition_frames: Int
            var transition_frames_all_correct: Int
            var transition_accuracy: Double
            var steady_frames: Int
            var steady_frames_all_correct: Int
            var steady_accuracy: Double
        }
        struct Case: Decodable {
            var name: String
            var fixture: String
            var truth_sidecar: String
            var parts_low_to_high: [String]
            var frame_count: Int
            var candidates: [[[Double]]]
            var truth_chords: [TruthChord]
            var truth_frames: [[[Int]]]
            var assignment: [AssignmentFrame]
            var notes: [String: [Note]]
            var expected: Expected
            var boundary_analysis: BoundaryAnalysis
        }
        var config: Config
        var cases: [Case]
    }

    private func loadArtifact() throws -> Artifact {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // EngineCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Engine
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Tests/Spikes/Fixtures/assignment_satb5.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Artifact.self, from: data)
    }

    /// The parts of a case, in the artifact's LOW → HIGH order.
    private func parts(of testCase: Artifact.Case) throws -> [Part] {
        try testCase.parts_low_to_high.map { raw in
            guard let part = Part(rawValue: raw) else {
                throw XCTSkip("unknown part \(raw) in the artifact")
            }
            return part
        }
    }

    /// Rebuild the per-frame candidates from the artifact.
    private func candidates(of testCase: Artifact.Case) -> [[SalienceCandidate]] {
        testCase.candidates.enumerated().map { frameIndex, frame in
            frame.map { pair in
                SalienceCandidate(frameIndex: frameIndex,
                                  time: BasicPitchFrameClock.seconds(forFrame: frameIndex),
                                  midi: Int(pair[0]),
                                  salience: pair[1])
            }
        }
    }

    /// The per-frame truth from the artifact (`[partIndex, midi]` pairs).
    private func truth(of testCase: Artifact.Case, parts: [Part]) -> [[Part: Int]] {
        testCase.truth_frames.map { frame in
            var truthFrame: [Part: Int] = [:]
            for pair in frame {
                truthFrame[parts[pair[0]]] = pair[1]
            }
            return truthFrame
        }
    }

    // MARK: - (1) The cross-implementation gate

    /// The Swift implementation and the Python mirror MUST agree.
    ///
    /// The metrics are compared NUMBER FOR NUMBER (they are discrete counts and
    /// ratios); the per-frame confidences are compared within a tight
    /// tolerance, because the artifact stores the salience rounded to nine
    /// decimals and the posterior is a function of it.
    func testTheSwiftImplementationAgreesWithThePythonMirror() throws {
        let artifact = try loadArtifact()
        XCTAssertEqual(artifact.cases.count, 2, "the artifact carries the static and the moving case")

        for testCase in artifact.cases {
            let parts = try parts(of: testCase)
            let candidates = candidates(of: testCase)
            let result = VoiceAssignmentEngine.assign(candidates: candidates, parts: parts)

            // 1. The frame count.
            XCTAssertEqual(result.frames.count, testCase.frame_count, testCase.name)
            XCTAssertEqual(testCase.assignment.count, testCase.frame_count, testCase.name)

            // 2. The per-frame assignment and its confidences.
            for (index, expectedFrame) in testCase.assignment.enumerated() {
                guard index < result.frames.count else { break }
                let frame = result.frames[index]
                XCTAssertEqual(frame.frameIndex, expectedFrame.frame_index, testCase.name)
                XCTAssertEqual(frame.time, expectedFrame.time, accuracy: 1e-9, testCase.name)

                var expectedPitches: [Part: Int] = [:]
                for pair in expectedFrame.pitches {
                    expectedPitches[parts[pair.index]] = Int(pair.value)
                }
                XCTAssertEqual(frame.pitches, expectedPitches,
                               "\(testCase.name) frame \(index): the assigned pitches differ")

                var expectedConfidences: [Part: Double] = [:]
                for pair in expectedFrame.confidences {
                    expectedConfidences[parts[pair.index]] = pair.value
                }
                XCTAssertEqual(frame.confidences.count, expectedConfidences.count,
                               "\(testCase.name) frame \(index): a different number of parts")
                for (part, expected) in expectedConfidences {
                    let actual = frame.confidences[part] ?? -1
                    XCTAssertEqual(actual, expected, accuracy: 1e-6,
                                   "\(testCase.name) frame \(index) \(part.rawValue): the confidence differs")
                }
            }

            // 3. The per-part note events.
            for part in parts {
                let expectedNotes = testCase.notes[part.rawValue] ?? []
                let actualNotes = result.notesByPart[part] ?? []
                XCTAssertEqual(actualNotes.count, expectedNotes.count,
                               "\(testCase.name) \(part.rawValue): a different number of notes")
                for (index, expected) in expectedNotes.enumerated() where index < actualNotes.count {
                    let actual = actualNotes[index]
                    XCTAssertEqual(actual.midi, expected.midi,
                                   "\(testCase.name) \(part.rawValue) note \(index): the MIDI differs")
                    XCTAssertEqual(actual.start_s, expected.start_s, accuracy: 1e-9,
                                   "\(testCase.name) \(part.rawValue) note \(index): the onset differs")
                    XCTAssertEqual(actual.end_s, expected.end_s, accuracy: 1e-9,
                                   "\(testCase.name) \(part.rawValue) note \(index): the offset differs")
                    XCTAssertEqual(actual.confidence, expected.confidence, accuracy: 1e-6,
                                   "\(testCase.name) \(part.rawValue) note \(index): the confidence differs")
                    XCTAssertEqual(actual.salience ?? 0, expected.salience, accuracy: 1e-6,
                                   "\(testCase.name) \(part.rawValue) note \(index): the salience differs")
                }
            }

            // 4. The metrics — number for number.
            let metrics = VoiceAssignmentEvaluator.evaluate(frames: result.frames,
                                                             truth: truth(of: testCase, parts: parts))
            let expected = testCase.expected
            XCTAssertEqual(metrics.frameCount, expected.frame_count, testCase.name)
            XCTAssertEqual(metrics.framesAllPartsCorrect, expected.frames_all_parts_correct, testCase.name)
            XCTAssertEqual(metrics.framesAnyPartCorrect, expected.frames_any_part_correct, testCase.name)
            XCTAssertEqual(metrics.partFrameSlots, expected.part_frame_slots, testCase.name)
            XCTAssertEqual(metrics.partFrameHits, expected.part_frame_hits, testCase.name)
            XCTAssertEqual(metrics.frameAccuracy, expected.frame_accuracy, accuracy: 1e-12, testCase.name)
            XCTAssertEqual(metrics.macroPartAccuracy, expected.macro_part_accuracy, accuracy: 1e-12, testCase.name)
            XCTAssertEqual(metrics.perPartAccuracy.count, expected.per_part_accuracy.count, testCase.name)
            for (part, accuracy) in metrics.perPartAccuracy {
                XCTAssertEqual(accuracy, expected.per_part_accuracy[part.rawValue] ?? -1,
                               accuracy: 1e-12, "\(testCase.name) \(part.rawValue)")
            }
        }
    }

    /// The CONFIGURATION must be the same on both sides.
    ///
    /// The artifact names the exact configuration that produced its numbers.
    /// If the Swift defaults change, this test goes RED — a tuning change must
    /// be a visible, deliberate change, never a silently different number.
    func testTheConfigurationMatchesTheArtifact() throws {
        let artifact = try loadArtifact()
        let options = artifact.config.options
        let expected = VoiceAssignmentOptions.default

        XCTAssertEqual(expected.salienceWeight, options.salience_weight, accuracy: 1e-12)
        XCTAssertEqual(expected.rangePenaltyPerSemitone, options.range_penalty_per_semitone, accuracy: 1e-12)
        XCTAssertEqual(expected.rangePenaltyCapSemitones, options.range_penalty_cap_semitones)
        XCTAssertEqual(expected.harmonicWeight, options.harmonic_weight, accuracy: 1e-12)
        XCTAssertEqual(expected.unisonPenalty, options.unison_penalty, accuracy: 1e-12)
        XCTAssertEqual(expected.onsetPenalty, options.onset_penalty, accuracy: 1e-12)
        XCTAssertEqual(expected.offsetPenalty, options.offset_penalty, accuracy: 1e-12)
        XCTAssertEqual(expected.smoothnessWeight, options.smoothness_weight, accuracy: 1e-12)
        XCTAssertEqual(expected.smoothnessCapCents, options.smoothness_cap_cents, accuracy: 1e-12)
        XCTAssertEqual(expected.posteriorTemperature, options.posterior_temperature, accuracy: 1e-12)
        XCTAssertEqual(expected.beamWidth, options.beam_width)
        XCTAssertEqual(expected.frameStateLimit, options.frame_state_limit)
        XCTAssertEqual(expected.allowUnisons, options.allow_unisons)
        XCTAssertEqual(expected.minimumNoteDurationSeconds, options.minimum_note_duration_seconds, accuracy: 1e-12)

        let peaks = artifact.config.peak_options
        XCTAssertEqual(SaliencePeakOptions.default.minimumSalience, peaks.minimum_salience, accuracy: 1e-12)
        XCTAssertEqual(SaliencePeakOptions.default.localMaxWindowSemitones, peaks.local_max_window_semitones)
        XCTAssertEqual(SaliencePeakOptions.default.minimumPeakSpacingFrames, peaks.minimum_peak_spacing_frames)

        // The C-6.1 range table — the soft prior's source.
        for (raw, bounds) in artifact.config.part_ranges_midi {
            guard let part = Part(rawValue: raw),
                  let preset = PartRangePresets.preset(for: part) else { continue }
            XCTAssertEqual(preset.midiLow, bounds[0], raw)
            XCTAssertEqual(preset.midiHigh, bounds[1], raw)
        }

        // The contractual display order — the pitch order is its reverse.
        for (raw, sortOrder) in artifact.config.sort_order {
            guard let part = Part(rawValue: raw) else { continue }
            XCTAssertEqual(part.sortOrder, sortOrder, raw)
        }
    }

    // MARK: - (2) The model's rules

    /// The no-crossing rule: the parts are walked LOW → HIGH and the assigned
    /// pitches strictly increase.
    func testTheNoCrossingOrderHolds() {
        let candidates = [[
            SalienceCandidate(frameIndex: 0, time: 0.0, midi: 48, salience: 0.50),
            SalienceCandidate(frameIndex: 0, time: 0.0, midi: 52, salience: 0.55),
            SalienceCandidate(frameIndex: 0, time: 0.0, midi: 57, salience: 0.60),
            SalienceCandidate(frameIndex: 0, time: 0.0, midi: 62, salience: 0.65),
            SalienceCandidate(frameIndex: 0, time: 0.0, midi: 69, salience: 0.70),
        ]]
        let parts: [Part] = [.bass, .baritone, .baritenor, .t2, .t1]
        let result = VoiceAssignmentEngine.assign(candidates: candidates, parts: parts)
        let frame = try? XCTUnwrap(result.frames.first)

        XCTAssertEqual(frame?.pitches[.bass], 48)
        XCTAssertEqual(frame?.pitches[.baritone], 52)
        XCTAssertEqual(frame?.pitches[.baritenor], 57)
        XCTAssertEqual(frame?.pitches[.t2], 62)
        XCTAssertEqual(frame?.pitches[.t1], 69)

        // The property itself: the pitches strictly increase along the parts.
        let ordered = VoiceAssignmentEngine.orderedParts(parts)
        let assigned = ordered.compactMap { frame?.pitches[$0] }
        XCTAssertEqual(assigned, assigned.sorted())
        for index in 1..<max(1, assigned.count) {
            XCTAssertLessThan(assigned[index - 1], assigned[index],
                              "the assigned pitches must strictly increase")
        }
    }

    /// The subset handling: a part with no candidate of its own stays SILENT.
    ///
    /// The pitch that the silent part could have shared (40) is below its
    /// C-6.1 floor, so the unison costs more than it gains — the part stays
    /// out rather than stealing a note outside its range.
    func testAPartWithNoCandidateStaysSilent() {
        let candidates = [[
            SalienceCandidate(frameIndex: 0, time: 0.0, midi: 40, salience: 0.95),
            SalienceCandidate(frameIndex: 0, time: 0.0, midi: 76, salience: 0.40),
        ]]
        let parts: [Part] = [.bass, .baritone, .t1]
        let result = VoiceAssignmentEngine.assign(candidates: candidates, parts: parts)
        let frame = try? XCTUnwrap(result.frames.first)

        XCTAssertEqual(frame?.pitches[.bass], 40)
        XCTAssertEqual(frame?.pitches[.baritone], nil, "a part with no candidate of its own stays silent")
        XCTAssertEqual(frame?.pitches[.t1], 76)
        XCTAssertEqual(result.notesByPart[.baritone]?.count, 0)
    }

    /// The subset handling, take two: the engine never invents a part it was
    /// not asked for, and never assigns a part it was not given.
    func testOnlyTheGivenPartsAreAssigned() {
        let candidates = [[
            SalienceCandidate(frameIndex: 0, time: 0.0, midi: 48, salience: 0.9),
            SalienceCandidate(frameIndex: 0, time: 0.0, midi: 67, salience: 0.8),
        ]]
        let result = VoiceAssignmentEngine.assign(candidates: candidates, parts: [.bass, .t1])
        let frame = try? XCTUnwrap(result.frames.first)

        XCTAssertEqual(Set((frame?.pitches ?? [:]).keys), Set([Part.bass, .t1]))
        XCTAssertEqual(Set(result.notesByPart.keys), Set([Part.bass, .t1]))
    }

    /// The unison rule, take one: a unison NEVER CANNIBALISES a part's own
    /// note.
    ///
    /// The baritone has its own in-range candidate above the bass's note, so
    /// the unison is not even offered: the baritone takes its own note.
    func testAUnisonNeverStealsAPartsOwnNote() {
        let candidates = [[
            SalienceCandidate(frameIndex: 0, time: 0.0, midi: 55, salience: 0.90),
            SalienceCandidate(frameIndex: 0, time: 0.0, midi: 60, salience: 0.30),
        ]]
        let result = VoiceAssignmentEngine.assign(candidates: candidates, parts: [.bass, .baritone])
        let frame = try? XCTUnwrap(result.frames.first)

        XCTAssertEqual(frame?.pitches[.bass], 55)
        XCTAssertEqual(frame?.pitches[.baritone], 60, "the baritone takes its OWN note, not a unison")
    }

    /// The unison rule, take two: a unison FILLS A GAP.
    ///
    /// The baritone has no candidate of its own inside its C-6.1 range, so the
    /// unison is offered — and it is taken, because it is worth more than the
    /// silence. Its CONFIDENCE is low (D-41 §3): the posterior over the
    /// candidate parts splits between the two parts that could sing that pitch.
    func testAUnisonFillsAGapAndIsLowConfidence() {
        let candidates = [[
            SalienceCandidate(frameIndex: 0, time: 0.0, midi: 55, salience: 0.90),
            SalienceCandidate(frameIndex: 0, time: 0.0, midi: 67, salience: 0.80),
        ]]
        let result = VoiceAssignmentEngine.assign(candidates: candidates,
                                                  parts: [.bass, .baritone, .t1])
        let frame = try? XCTUnwrap(result.frames.first)

        XCTAssertEqual(frame?.pitches[.bass], 55)
        XCTAssertEqual(frame?.pitches[.baritone], 55, "the baritone fills the gap in a unison")
        XCTAssertEqual(frame?.pitches[.t1], 67)

        let unisonConfidence = frame?.confidences[.baritone] ?? 1
        let realConfidence = frame?.confidences[.t1] ?? 0
        XCTAssertLessThan(unisonConfidence, realConfidence,
                          "a unison must be less certain than the part that owns the note")
        XCTAssertLessThan(unisonConfidence, AssignmentBand.confirmedThreshold,
                          "a unison note is never CONFIRMED")
        XCTAssertEqual(AssignmentBand.band(forConfidence: unisonConfidence), .unassigned,
                       "the unison note lands in the UNASSIGNED band")
        XCTAssertEqual(AssignmentBand.band(forConfidence: realConfidence), .confirmed,
                       "the real note lands in the CONFIRMED band")
    }

    /// The unison PENALTY is SUBTRACTED.
    ///
    /// This is the regression test for the bug the measurement exposed: with
    /// the penalty ADDED, a unison was worth one MORE salience reward, and the
    /// engine piled every part onto the strongest pitch (92.2% frame accuracy
    /// instead of 100%). Here the only candidate is WEAK (0.20) and the
    /// penalty is 0.25, so a correct engine lets ONE part sing it while a
    /// sign-flipped engine would put BOTH parts on it (0.20 + 0.20 + 0.25).
    func testTheUnisonPenaltyIsSubtractedNotAdded() {
        let candidates = [[
            SalienceCandidate(frameIndex: 0, time: 0.0, midi: 55, salience: 0.20),
        ]]
        let result = VoiceAssignmentEngine.assign(candidates: candidates, parts: [.bass, .baritone])
        let frame = try? XCTUnwrap(result.frames.first)

        let singing = [Part.bass, .baritone].filter { frame?.pitches[$0] == 55 }
        XCTAssertEqual(singing.count, 1,
                       "a unison worth less than its penalty must not be taken — "
                       + "the engine must not pile both parts onto one pitch")
        XCTAssertNotEqual(frame?.pitches[.bass], frame?.pitches[.baritone],
                          "the two parts must not share the pitch")
    }

    /// The range prior is a SOFT prior (D-12): a pitch outside the C-6.1
    /// preset is still assignable — it costs, it does not gate.
    func testTheRangePriorIsASoftPrior() {
        // 39 is ONE semitone below the bass's floor (40): the prior costs
        // 0.35, which the salience (0.90) more than pays for.
        let oneSemitoneOut = [[
            SalienceCandidate(frameIndex: 0, time: 0.0, midi: 39, salience: 0.90),
        ]]
        let close = VoiceAssignmentEngine.assign(candidates: oneSemitoneOut, parts: [.bass])
        XCTAssertEqual(close.frames.first?.pitches[.bass], 39,
                       "a pitch one semitone out of range is still assignable")

        // 36 is FOUR semitones out: the prior costs 1.40, more than the
        // salience (0.95) is worth, so the engine leaves the part silent
        // rather than assign a note far outside the preset.
        let fourSemitonesOut = [[
            SalienceCandidate(frameIndex: 0, time: 0.0, midi: 36, salience: 0.95),
        ]]
        let far = VoiceAssignmentEngine.assign(candidates: fourSemitonesOut, parts: [.bass])
        XCTAssertEqual(far.frames.first?.pitches[.bass], nil)

        // The prior itself is a NEGATIVE cost that grows with the distance
        // and is CAPPED — never a gate.
        XCTAssertLessThan(VoiceAssignmentEngine.rangePrior(part: .bass, midi: 39,
                                                           options: .default), 0)
        XCTAssertGreaterThan(VoiceAssignmentEngine.rangePrior(part: .bass, midi: 39,
                                                              options: .default),
                             VoiceAssignmentEngine.rangePrior(part: .bass, midi: 36,
                                                              options: .default),
                             "the further out of range, the higher the cost")
        XCTAssertEqual(VoiceAssignmentEngine.rangePrior(part: .bass, midi: 48,
                                                        options: .default), 0,
                       "a pitch inside the preset costs nothing")
    }

    /// The confidence is in [0,1] and the D-41 bands follow the thresholds.
    func testTheConfidenceIsInRangeAndTheBandsFollowD41() throws {
        let artifact = try loadArtifact()
        for testCase in artifact.cases {
            let parts = try parts(of: testCase)
            let result = VoiceAssignmentEngine.assign(candidates: candidates(of: testCase),
                                                      parts: parts)
            XCTAssertFalse(result.frames.isEmpty, testCase.name)
            for frame in result.frames {
                for (part, confidence) in frame.confidences {
                    XCTAssertGreaterThanOrEqual(confidence, 0, testCase.name)
                    XCTAssertLessThanOrEqual(confidence, 1, testCase.name)
                    // The confidence is the ASSIGNMENT posterior — it is never
                    // the salience (C-12): the two are different quantities.
                    let salience = frame.saliences[part] ?? 0
                    XCTAssertNotEqual(confidence, salience, accuracy: 1e-12,
                                      "\(testCase.name): the confidence must not be the salience")
                }
            }
            // The notes carry a confidence in range too.
            for part in parts {
                for note in result.notesByPart[part] ?? [] {
                    XCTAssertGreaterThanOrEqual(note.confidence, 0)
                    XCTAssertLessThanOrEqual(note.confidence, 1)
                }
            }
        }

        // D-41 §1's band thresholds.
        XCTAssertEqual(AssignmentBand.band(forConfidence: 0.80), .confirmed)
        XCTAssertEqual(AssignmentBand.band(forConfidence: 0.99), .confirmed)
        XCTAssertEqual(AssignmentBand.band(forConfidence: 0.79), .provisional)
        XCTAssertEqual(AssignmentBand.band(forConfidence: 0.50), .provisional)
        XCTAssertEqual(AssignmentBand.band(forConfidence: 0.49), .unassigned)
        XCTAssertEqual(AssignmentBand.band(forConfidence: 0.0), .unassigned)
    }

    /// The assignment is DETERMINISTIC: the same input gives the same output.
    func testTheAssignmentIsDeterministic() throws {
        let artifact = try loadArtifact()
        for testCase in artifact.cases {
            let parts = try parts(of: testCase)
            let candidates = candidates(of: testCase)
            let first = VoiceAssignmentEngine.assign(candidates: candidates, parts: parts)
            let second = VoiceAssignmentEngine.assign(candidates: candidates, parts: parts)
            XCTAssertEqual(first.frames, second.frames, testCase.name)
            XCTAssertEqual(first.notesByPart, second.notesByPart, testCase.name)
        }
    }

    /// The ordering of the parts: LOW → HIGH is the REVERSE of the
    /// contractual display order.
    func testThePartsAreWalkedLowToHigh() {
        let ordered = VoiceAssignmentEngine.orderedParts([.t1, .bass, .t2, .baritone, .baritenor])
        XCTAssertEqual(ordered, [.bass, .baritone, .baritenor, .t2, .t1])
    }

    // MARK: - The pinned measurements

    /// The MEASURED numbers, pinned.
    ///
    /// These are the numbers logged in BENCHMARKS.md (P-306). A change here is
    /// a change in what the engine MEASURES, and it must be a deliberate,
    /// documented one — not a drift.
    func testTheMeasuredNumbersArePinned() throws {
        let artifact = try loadArtifact()
        let byName = Dictionary(uniqueKeysWithValues: artifact.cases.map { ($0.name, $0.expected) })

        // (a) FIVE VOICES, ONE SUSTAINED CHORD: every frame is assigned
        //     correctly. This is the AC fixture.
        let staticCase = try XCTUnwrap(byName["satb5"])
        XCTAssertEqual(staticCase.frame_count, 344)
        XCTAssertEqual(staticCase.frames_all_parts_correct, 344)
        XCTAssertEqual(staticCase.frame_accuracy, 1.0, accuracy: 1e-12)
        XCTAssertEqual(staticCase.macro_part_accuracy, 1.0, accuracy: 1e-12)
        XCTAssertEqual(staticCase.part_frame_slots, 1720)
        XCTAssertEqual(staticCase.part_frame_hits, 1720)
        for part in ["BASS", "BARITONE", "BARITENOR", "T2", "T1"] {
            XCTAssertEqual(staticCase.per_part_accuracy[part] ?? 0, 1.0, accuracy: 1e-12, part)
        }

        // (b) FIVE VOICES THAT MOVE (the C-F-G-F progression): the engine
        //     still gets 97.7% of the frames exactly right and 98.9% of the
        //     (part, frame) slots. The part-aware number is NOT measured on
        //     one frozen chord.
        let movingCase = try XCTUnwrap(byName["satb5_prog"])
        XCTAssertEqual(movingCase.frame_count, 688)
        XCTAssertEqual(movingCase.frames_all_parts_correct, 672)
        XCTAssertEqual(movingCase.frame_accuracy, 672.0 / 688.0, accuracy: 1e-12)
        XCTAssertEqual(movingCase.macro_part_accuracy, 0.989, accuracy: 5e-4)
        XCTAssertEqual(movingCase.part_frame_slots, 3440)
        XCTAssertEqual(movingCase.part_frame_hits, 3402)
        for part in ["BASS", "BARITONE", "BARITENOR", "T2", "T1"] {
            let accuracy = movingCase.per_part_accuracy[part] ?? 0
            XCTAssertGreaterThan(accuracy, 0.98, part)
            XCTAssertLessThan(accuracy, 1.0, part)
        }
    }

    /// The AC: at least 70% of the frames correctly assigned on the clean
    /// synthetic five-voice fixture.
    func testTheAcceptanceCriterionIsMet() throws {
        let artifact = try loadArtifact()
        for testCase in artifact.cases {
            XCTAssertGreaterThanOrEqual(testCase.expected.frame_accuracy, 0.70,
                                        "\(testCase.name): the AC is >=70% of the frames")
        }
    }

    /// WHERE the errors live: the steady state is perfect and the errors sit
    /// at the chord transitions.
    ///
    /// At a chord change the audio physically carries BOTH chords, so a frame
    /// near the boundary legitimately sees both sets of pitches. The split is
    /// the honest reading — it says the engine's weakness is at the
    /// transitions, which is exactly what P-304's score-informed alignment
    /// (snapping the notes onto the score's grid) is there to fix.
    func testTheErrorsLiveAtTheChordTransitions() throws {
        let artifact = try loadArtifact()
        let byName = Dictionary(uniqueKeysWithValues: artifact.cases.map { ($0.name, $0) })

        // The static chord has no transitions at all — every frame is steady.
        let staticCase = try XCTUnwrap(byName["satb5"])
        XCTAssertEqual(staticCase.boundary_analysis.transition_frames, 0)
        XCTAssertEqual(staticCase.boundary_analysis.steady_accuracy, 1.0, accuracy: 1e-12)

        // The moving progression: 661 steady frames, ALL of them correct.
        let movingCase = try XCTUnwrap(byName["satb5_prog"])
        let analysis = movingCase.boundary_analysis
        XCTAssertEqual(analysis.window_frames, 4)
        XCTAssertEqual(analysis.window_ms, 46.44, accuracy: 1e-3)
        XCTAssertEqual(analysis.boundary_frames.count, 3, "three chord changes")
        XCTAssertEqual(analysis.steady_frames, 661)
        XCTAssertEqual(analysis.steady_frames_all_correct, 661)
        XCTAssertEqual(analysis.steady_accuracy, 1.0, accuracy: 1e-12,
                       "away from a chord change, every frame is assigned correctly")
        XCTAssertEqual(analysis.transition_frames, 27)
        XCTAssertEqual(analysis.transition_frames_all_correct, 11)
        XCTAssertEqual(analysis.transition_accuracy, 11.0 / 27.0, accuracy: 1e-12,
                       "the transitions are where the engine is weak — stated, not hidden")
    }
}
