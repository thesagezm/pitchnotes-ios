import SwiftUI
import Foundation
import UniformTypeIdentifiers
import PitchLogic
import EngineCore

// ScoreReviewView (J-304) — import a MusicXML score, review the alignment
// against the detected notes, accept or reject it, and nudge a note.
//
// WHAT THIS SCREEN IS (and is not):
//   · it is the CONSUMER of the score (C-13) — it writes NO MusicXML parser
//     (D-40: ONE parser, Paul's, in the portable engine core) and it aligns
//     nothing itself (the parser NEVER aligns by itself);
//   · it decides WHICH track the grader reads, in C-14's order: the user's
//     corrections (C-11) → else the score-informed track (when the alignment
//     is confident AND it improved the match) → else the heuristic track;
//   · rejecting the alignment leaves the heuristic track EXACTLY as it was
//     (C-13 rule 3: a score-informed track never replaces the heuristic track
//     on disk).
//
// THE HONEST LIMITS — said in the UI, not hidden:
//   · THE PARSER MAY NOT BE IN THIS BUILD. P-304 has not landed, so the app
//     ships `UnavailableScoreImportService`: the score file is saved with the
//     song, and the screen says plainly that nothing was parsed;
//   · A MANUAL NUDGE IS NOT SAVED YET. C-11's op set is exactly
//     reassign / delete / split — there is no time-shift op, and the overlay
//     addresses the engine's notes, not the score's — so the nudge works in
//     this session (visible, undoable) and is NOT pretended to be persisted;
//   · THE SCORE'S PART MAPPING is not in C-13.2's JSON, so it travels with
//     the alignment result (an X-task asks Leto where the contract should
//     carry it).
//
// THE DEMO ENTRY is clearly synthetic (MockScore) — it exists so the review
// can be seen and tested before the parser lands, and it never claims to be a
// parsed score.

// MARK: - The seam's honest default

/// The score import service for a build that has no parser yet.
///
/// P-304 (Paul) implements the real one: one Foundation `XMLParser` parser in
/// the portable engine core, and the alignment as a SEPARATE step. Until it
/// lands, this service refuses — loudly — instead of pretending.
struct UnavailableScoreImportService: ScoreImportService {

    /// The message the UI shows (honest, specific).
    static let message = "The MusicXML parser (P-304) has not landed in this build — the score file is saved with the song, but nothing was parsed."

    func parseScore(data: Data) throws -> ScoreNoteList {
        throw ScoreImportError.parserUnavailable
    }

    func align(score: ScoreNoteList, detected: [Part: NoteTrack]) throws -> ScoreAlignmentResult {
        throw ScoreImportError.parserUnavailable
    }
}

// MARK: - The model

/// The screen's state: the review, the import, the user's decision.
@MainActor
final class ScoreReviewModel: ObservableObject {

    /// The review (nil ⇒ no score yet — the heuristic track is the reference).
    @Published private(set) var review: ScoreReview?
    /// An honest status line (what happened, in plain words).
    @Published private(set) var status: String?
    /// An honest error line (what went wrong, in plain words).
    @Published private(set) var errorMessage: String?
    /// True while the import is running.
    @Published private(set) var isWorking = false
    /// The picker's state.
    @Published var isPickerPresented = false

    /// The score and the alignment, once there are any.
    @Published private(set) var score: ScoreNoteList?
    @Published private(set) var alignmentResult: ScoreAlignmentResult?
    /// The tracks the score is compared with — the EFFECTIVE (corrected)
    /// tracks when J-302's overlay is present, else the engine's tracks.
    @Published private(set) var detected: [Part: NoteTrack]
    /// True when the loaded overlay has at least one operation (C-14 rule 1).
    ///
    /// HONESTY: this is READ from the overlay the screen loads itself — it is
    /// never a flag guessed by the caller.
    @Published private(set) var hasOverlay = false
    /// An honest line about the corrections. A correction file we could not
    /// read is REPORTED here — the screen never silently pretends the user
    /// has no corrections.
    @Published private(set) var overlayMessage: String?
    /// The song's bundle directory — where `score.musicxml` lives (C-2.1).
    private let bundleDirectory: URL?
    /// The seam. The real implementation arrives with P-304.
    private let service: ScoreImportService
    /// True for the synthetic demo (the UI labels it).
    let isMock: Bool

    /// - Parameters:
    ///   - rawTracks: the engine's note tracks (never mutated).
    ///   - bundleDirectory: the song's bundle directory — where C-11's
    ///     `corrections/` live and where `score.musicxml` is written. Nil ⇒
    ///     the demo (nothing on disk to read or save).
    init(rawTracks: [Part: NoteTrack], bundleDirectory: URL?,
         isMock: Bool = false, service: ScoreImportService = UnavailableScoreImportService()) {
        self.detected = rawTracks
        self.bundleDirectory = bundleDirectory
        self.isMock = isMock
        self.service = service
        if let bundleDirectory {
            Task { await loadCorrections(rawTracks: rawTracks, bundleDirectory: bundleDirectory) }
        } else {
            self.overlayMessage = isMock
                ? "These are the synthetic demo notes — there is no song on disk, so there are no corrections to read."
                : nil
        }
    }

    // MARK: - The corrections (C-14 rule 1 — read, never guessed)

    /// Loads the user's corrections and computes the EFFECTIVE tracks the score
    /// is compared against — exactly what C-14 compares (the overlay, when it
    /// exists, wins).
    ///
    /// A correction file we cannot read is REPORTED (never silently treated as
    /// "no corrections"), and the detected notes are shown with the warning.
    private func loadCorrections(rawTracks: [Part: NoteTrack], bundleDirectory: URL) async {
        let store = CorrectionStore(bundleDirectory: bundleDirectory)
        let result = await Task.detached(priority: .userInitiated) {
            store.loadResult()
        }.value

        switch result {
        case .absent:
            detected = rawTracks
            hasOverlay = false
            overlayMessage = nil
        case let .loaded(loaded):
            let effective = CorrectionResolver.resolve(raw: rawTracks, overlays: loaded.partOverlays)
            detected = effective.tracks
            hasOverlay = loaded.correctionCount > 0
            var messages = loaded.problems
            if effective.skippedOpCount > 0 {
                messages.append("\(effective.skippedOpCount) correction(s) could not be applied: "
                                + effective.warnings.joined(separator: " "))
            }
            overlayMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
        case let .failed(reason):
            detected = rawTracks
            hasOverlay = false
            overlayMessage = reason
                + " The detected notes are shown, but the score comparison is not authoritative."
        }
        rebuildReview()
    }

    /// Rebuilds the review after the tracks, the overlay state or the score
    /// changed — keeping the user's decision and their nudges.
    private func rebuildReview() {
        guard let score, let alignmentResult else { return }
        let previous = review
        review = ScoreReview(score: score,
                             alignmentResult: alignmentResult,
                             detected: detected,
                             hasOverlay: hasOverlay,
                             accepted: previous?.accepted ?? false,
                             nudges: previous?.nudges ?? [:])
    }

    // MARK: - The demo

    /// Loads the synthetic DEMO score (the demo entry only).
    func loadDemo() {
        score = MockScore.demoScore(detected: detected)
        alignmentResult = MockScore.demoAlignment(detected: detected)
        rebuildReview()
        status = "This is a synthetic DEMO score built from the demo notes — it is not a parsed MusicXML file and not a real alignment."
        errorMessage = nil
    }

    // MARK: - The import

    /// The picker's result.
    func handlePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = "The score file could not be opened: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            importScore(from: url)
        }
    }

    /// Copies the score into the song's bundle and asks the seam to parse and
    /// align it.
    private func importScore(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        isWorking = true
        errorMessage = nil
        status = nil

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            isWorking = false
            errorMessage = "The score file could not be read: \(error.localizedDescription)"
            return
        }

        // The score lives with the song (C-2.1's optional `score.musicxml`).
        var savedMessage: String?
        if let bundleDirectory {
            do {
                let destination = bundleDirectory.appendingPathComponent("score.musicxml")
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.createDirectory(at: bundleDirectory,
                                                        withIntermediateDirectories: true,
                                                        attributes: nil)
                try data.write(to: destination, options: .atomic)
                savedMessage = "Saved the score with the song as score.musicxml."
            } catch {
                savedMessage = "The score could not be saved with the song: \(error.localizedDescription)"
            }
        } else {
            savedMessage = "This song has no bundle on disk (the demo notes), so the score was not saved."
        }

        let service = self.service
        Task {
            // The EFFECTIVE tracks (the engine's + the user's corrections) are
            // what C-14 compares the score against, so the alignment is done
            // against them too.
            let detected = self.detected
            do {
                let score = try await Task.detached(priority: .userInitiated) {
                    try service.parseScore(data: data)
                }.value
                let alignment = try await Task.detached(priority: .userInitiated) {
                    try service.align(score: score, detected: detected)
                }.value
                self.score = score
                self.alignmentResult = alignment
                self.rebuildReview()
                isWorking = false
                status = savedMessage
            } catch let error as ScoreImportError {
                isWorking = false
                status = savedMessage
                errorMessage = ScoreReviewModel.message(for: error)
            } catch {
                isWorking = false
                status = savedMessage
                errorMessage = "The score could not be parsed: \(error.localizedDescription)"
            }
        }
    }

    /// The honest message for a seam failure.
    static func message(for error: ScoreImportError) -> String {
        switch error {
        case .parserUnavailable:
            return UnavailableScoreImportService.message
        case .malformedScore(let detail):
            return "The file is not a MusicXML score we can read: \(detail)"
        case .alignmentFailed(let detail):
            return "The score was read, but it could not be aligned to the recording: \(detail)"
        }
    }

    // MARK: - The user's actions

    func accept() {
        review?.accept()
    }

    func reject() {
        review?.reject()
    }

    func nudge(scoreIndex: Int, by seconds: Double) {
        review?.nudge(scoreIndex: scoreIndex, by: seconds)
    }

    func resetNudges() {
        review?.resetNudges()
    }

    // MARK: - Derived

    /// One part's score notes (the comparison's rows).
    struct PartScoreNotes: Identifiable {
        let part: Part
        let notes: [ScoreAlignedNote]
        var id: Part { part }
    }

    /// The score notes, grouped by the C-1 part they were mapped to (the
    /// unmapped ones are listed separately).
    var notesByPart: [PartScoreNotes] {
        guard let review else { return [] }
        var grouped: [Part: [ScoreAlignedNote]] = [:]
        for note in review.alignedNotes {
            guard let part = note.part else { continue }
            grouped[part, default: []].append(note)
        }
        return grouped.keys.sorted { $0.sortOrder < $1.sortOrder }.map { part in
            PartScoreNotes(part: part, notes: grouped[part] ?? [])
        }
    }

    /// The score notes the alignment could not put into a part.
    var unmappedNotes: [ScoreAlignedNote] {
        review?.unmappedScoreNotes ?? []
    }

    /// The detected notes per part (the "what the engine heard" column).
    var detectedCount(for part: Part) -> Int {
        model.detected[part]?.notes.count ?? 0
    }
}

// MARK: - The screen

/// The score import + alignment review screen.
struct ScoreReviewView: View {

    /// The song's title.
    let songTitle: String
    /// The engine's note tracks (the raw ones). The screen loads the user's
    /// corrections ITSELF, so it never guesses whether an overlay exists.
    let rawTracks: [Part: NoteTrack]
    /// The song's bundle directory (where `score.musicxml` goes, and where
    /// C-11's `corrections/` live). Nil ⇒ the demo (nothing is saved).
    let bundleDirectory: URL?
    /// True for the synthetic demo.
    let isMock: Bool

    @StateObject private var model: ScoreReviewModel
    @State private var selectedScoreIndex: Int?

    init(songTitle: String, rawTracks: [Part: NoteTrack], bundleDirectory: URL?,
         isMock: Bool = false) {
        self.songTitle = songTitle
        self.rawTracks = rawTracks
        self.bundleDirectory = bundleDirectory
        self.isMock = isMock
        _model = StateObject(wrappedValue: ScoreReviewModel(
            rawTracks: rawTracks, bundleDirectory: bundleDirectory, isMock: isMock))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Token.Spacing.s3) {
                correctionsSection
                referenceHeader
                if let review = model.review {
                    alignmentSection(review)
                    conditionsSection(review)
                    decisionSection(review)
                    comparisonSection(review)
                    nudgeSection(review)
                } else {
                    noScoreSection
                }
                importSection
            }
            .padding(Token.Spacing.s3)
        }
        .background(Color.pnBackground)
        .navigationTitle("Score & alignment")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $model.isPickerPresented,
                      allowedContentTypes: ScoreReviewView.supportedTypes,
                      allowsMultipleSelection: false) { model.handlePickerResult($0) }
        .onAppear {
            if isMock { model.loadDemo() }
        }
    }

    /// MusicXML files are XML documents. The dedicated UTI declaration is
    /// X-216-PENDING (Leto owns `project.yml`), so the picker accepts XML
    /// documents and the open-in-place path stays out until it lands.
    static let supportedTypes: [UTType] = [UTType("com.recordare.musicxml") ?? .xml, .xml]

    // MARK: - The corrections (C-14 rule 1)

    /// What the grader will actually read, and whether the user's corrections
    /// are in play. The corrections are READ from disk here (the screen loads
    /// them itself) — the flag is never a guess.
    private var correctionsSection: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s1) {
            Text("Your corrections")
                .font(Token.Fonts.heading)
            if model.hasOverlay {
                Text("Your corrections are in play — they win (C-14). The score is shown for comparison only.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            } else if model.overlayMessage != nil {
                Text("Your corrections could not be read — the detected notes are shown, but the score comparison is not authoritative.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.octaveWarn)
            } else {
                Text("No corrections for this song — the detected notes are what the grader reads.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
            if let message = model.overlayMessage {
                Text(message)
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.octaveWarn)
            }
        }
    }

    // MARK: - The reference header

    private var referenceHeader: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s1) {
            Label {
                VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                    Text("Grading reference: \(referenceName)")
                        .font(Token.Fonts.caption)
                        .fontWeight(.semibold)
                    Text(referenceExplanation)
                        .font(Token.Fonts.caption)
                        .foregroundStyle(Color.pnTextSecondary)
                }
            } icon: {
                Image(systemName: "target")
                    .foregroundStyle(Color.pnAccent)
            }
        }
    }

    private var referenceName: String {
        guard let review = model.review else { return "the detected notes" }
        return review.reference.label
    }

    private var referenceExplanation: String {
        guard let review = model.review else {
            return "No score has been imported, so the assignment is heuristic — the detected notes are what the grader reads."
        }
        switch review.reference {
        case .overlay:
            return "Your corrections win (C-14). The score is shown for comparison only — it does not change what is graded."
        case .scoreInformed:
            let percent = Int((review.alignmentResult.alignment.confidence * 100).rounded())
            return "The score is aligned to the recording (confidence \(percent)%) and it improved the match, so the grader reads the score-informed notes."
        case .heuristic:
            return "This assignment is heuristic — the grader reads the detected notes, not the score. \(bandSummaryText(review))"
        }
    }

    private func bandSummaryText(_ review: ScoreReview) -> String {
        let summary = review.bandSummary
        let confirmed = summary[.confirmed] ?? 0
        let provisional = summary[.provisional] ?? 0
        let unassigned = summary[.unassigned] ?? 0
        return "Confirmed \(confirmed), provisional \(provisional), unassigned \(unassigned) — unassigned notes are not graded until you assign them."
    }

    // MARK: - The no-score path

    private var noScoreSection: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s1) {
            Text("No score imported")
                .font(Token.Fonts.heading)
            Text("A score is optional. Without one, the app stays on the detected notes, the import never fails, and the roll keeps its 4-second phrases.")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
        }
    }

    // MARK: - The alignment

    private func alignmentSection(_ review: ScoreReview) -> some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s1) {
            Text("Alignment")
                .font(Token.Fonts.heading)
            Text("Confidence \(percentText(review.alignmentResult.alignment.confidence)) · method \(review.alignmentResult.alignment.methodName)")
                .font(Token.Fonts.caption)
            Text("Match before \(percentText(review.agreementBefore.ratio)) → after \(percentText(review.agreementAfter.ratio))")
                .font(Token.Fonts.numeric)
            if !review.alignmentResult.alignment.used {
                Text("The aligner did not apply this alignment — accepting it is your decision.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
            if !review.unplacedScoreNotes.isEmpty {
                Text("\(review.unplacedScoreNotes.count) score note(s) are in measures the bar map does not cover — they are not used.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
            if !model.unmappedNotes.isEmpty {
                Text("\(model.unmappedNotes.count) score note(s) have no voice-part mapping — they are not put into any part.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
        }
    }

    // MARK: - C-14's conditions

    private func conditionsSection(_ review: ScoreReview) -> some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s1) {
            Text("What has to be true for the score to be used")
                .font(Token.Fonts.heading)
            conditionRow("Your corrections do not override it", ok: !review.hasOverlay)
            conditionRow("You accepted the alignment", ok: review.accepted)
            conditionRow("Confidence is at least \(percentText(ScoreReview.confidenceThreshold))",
                         ok: review.confidenceSufficient)
            conditionRow("The alignment improved the match", ok: review.agreementImproved)
        }
    }

    private func conditionRow(_ text: String, ok: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Token.Spacing.s1) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.inTune : Color.pnTextSecondary)
                .accessibilityHidden(true)
            Text(text)
                .font(Token.Fonts.caption)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(text): \(ok ? "yes" : "no")")
    }

    // MARK: - Accept / reject

    private func decisionSection(_ review: ScoreReview) -> some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s1) {
            Text("Your decision")
                .font(Token.Fonts.heading)
            HStack(spacing: Token.Spacing.s2) {
                Button("Accept the alignment") { model.accept() }
                    .buttonStyle(.borderedProminent)
                    .disabled(review.accepted)
                Button("Reject it") { model.reject() }
                    .buttonStyle(.bordered)
                    .disabled(!review.accepted)
            }
            Text("Rejecting leaves the detected notes exactly as they are — the score never overwrites them.")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
        }
    }

    // MARK: - The comparison

    private func comparisonSection(_ review: ScoreReview) -> some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s2) {
            Text("Score against the detected notes")
                .font(Token.Fonts.heading)
            ForEach(model.notesByPart) { group in
                VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                    Text("\(group.part.displayName): \(group.notes.count) score note(s), \(model.detectedCount(for: group.part)) detected note(s)")
                        .font(Token.Fonts.caption)
                        .fontWeight(.semibold)
                    ForEach(group.notes) { note in
                        Button {
                            selectedScoreIndex = note.scoreIndex
                        } label: {
                            HStack {
                                Text(PitchMath.noteName(forMidi: note.midi))
                                    .font(Token.Fonts.numeric)
                                Text("\(timeText(note.alignedStart_s))–\(timeText(note.alignedEnd_s))")
                                    .font(Token.Fonts.numeric)
                                    .foregroundStyle(Color.pnTextSecondary)
                                let nudge = review.nudge(for: note.scoreIndex)
                                if nudge != 0 {
                                    Text("nudged \(msText(nudge))")
                                        .font(Token.Fonts.caption)
                                        .foregroundStyle(Color.pnAccent)
                                }
                                Spacer(minLength: 0)
                                if selectedScoreIndex == note.scoreIndex {
                                    Image(systemName: "checkmark").accessibilityHidden(true)
                                }
                            }
                            .font(Token.Fonts.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - The nudge

    private func nudgeSection(_ review: ScoreReview) -> some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s1) {
            Text("Manual nudge")
                .font(Token.Fonts.heading)
            if let index = selectedScoreIndex,
               let note = review.alignedNotes.first(where: { $0.scoreIndex == index }) {
                Text("Note \(index + 1) (\(PitchMath.noteName(forMidi: note.midi))) at \(timeText(note.alignedStart_s))")
                    .font(Token.Fonts.caption)
                Text("Nudged by \(msText(review.nudge(for: index)))")
                    .font(Token.Fonts.numeric)
                HStack(spacing: Token.Spacing.s2) {
                    Button("−10 ms") { model.nudge(scoreIndex: index, by: -0.010) }
                        .buttonStyle(.bordered)
                    Button("+10 ms") { model.nudge(scoreIndex: index, by: 0.010) }
                        .buttonStyle(.bordered)
                    Button("Undo all nudges") { model.resetNudges() }
                        .buttonStyle(.bordered)
                        .disabled(review.nudges.isEmpty)
                }
            } else {
                Text("Pick a score note above to nudge it.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
            Text("A nudge moves the score note in this session. It is NOT saved yet: the correction overlay has no time-shift operation yet (an X-task asks for one), so the nudge is gone when the app closes.")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
        }
    }

    // MARK: - The import

    private var importSection: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s1) {
            Text("Import a score")
                .font(Token.Fonts.heading)
            Button {
                model.isPickerPresented = true
            } label: {
                Label("Import MusicXML…", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(model.isWorking)

            if model.isWorking {
                ProgressView("Reading the score…")
                    .font(Token.Fonts.caption)
            }
            if let status = model.status {
                Text(status)
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.octaveWarn)
            }
            Text("MusicXML is optional. Without it, nothing about the import changes.")
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
        }
    }

    // MARK: - Formatting

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func timeText(_ seconds: Double) -> String {
        let total = max(seconds, 0)
        let minutes = Int(total) / 60
        let rest = total - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, rest)
    }

    private func msText(_ seconds: Double) -> String {
        "\(Int((seconds * 1000).rounded())) ms"
    }
}
