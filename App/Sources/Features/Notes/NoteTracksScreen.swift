import SwiftUI
import PitchLogic
import EngineCore

// NoteTracksScreen (J-302) — the per-part note tracks WITH the user's
// corrections.
//
// THIS IS THE CORRECTED-FIRST SCREEN (D-41 §4 / C-14 rule 1): the roll it
// hosts renders the EFFECTIVE tracks (the engine's tracks + the user's
// overlay), never the raw file. The engine's `notes/<PART>.json` is never
// rewritten — the overlay is a separate, reversible layer (CONTRACTS v1.1
// C-11).
//
// WHERE THE OVERLAY LIVES (C-11): `corrections/<PART>.json`, INSIDE the song's
// bundle directory — ONE FILE PER CORRECTED PART, and absence means "no
// corrections", never "unknown". The song's bundle directory therefore has to
// reach this screen (`LibrarySong.bundleDirectory`); the synthetic demo
// tracks have none, so their corrections are not saved and the screen says so
// plainly.
//
// WHERE AN OPERATION GOES (C-11): an operation belongs to the file of the
// part whose ORIGINAL, IMMUTABLE `notes[]` array holds the target note — that
// is `op.fromPart`. A reassign to another part therefore lands in the
// SOURCE part's file, not the destination's.
//
// THE UNDO ORDER (honest, and stated in the UI): C-11 fixes the operation
// order WITHIN a file and says nothing about the order BETWEEN files, so a
// global "undo the last" is not contract-defined. While the user works, the
// undo stack is the order they appended in. After a relaunch there is no
// session order any more, so the undo falls back to a deterministic order
// (parts in C-1 order, each part's operations in order) — and the UI SAYS SO
// instead of pretending the order is obvious.
//
// HONESTY (AGENTS §11 — a product requirement):
//   · the corrections are labelled as the USER'S edits, never as the engine's
//     opinion, and the notes they touched are marked on the roll;
//   · the engine's original tracks are one tap away ("clear all corrections"),
//     so nothing the user does is a one-way door;
//   · a skipped or repaired correction is REPORTED, never swallowed;
//   · the demo tracks say plainly that corrections to them are not saved.

/// The screen's state: the per-part overlays, the calibration, the effective
/// tracks, and persistence.
@MainActor
final class NoteTracksModel: ObservableObject {

    /// The user's note corrections, one overlay per corrected part (C-11).
    @Published private(set) var overlays: [Part: PartCorrectionOverlay]
    /// The user's per-song part names + range overrides (X-216 proposal —
    /// Leto rules). Nil ⇒ no renames and no range overrides (the absence
    /// rule: behave exactly as before).
    @Published private(set) var calibration: SongCalibrationOverlay?
    /// The engine's tracks + the overlays — what everything reads.
    @Published private(set) var effective: EffectiveTracks
    /// Set when the stored corrections could not be read (honest, not silent).
    @Published private(set) var loadMessage: String?
    /// Set when a save failed (the corrections stay in memory and the user
    /// is told they were NOT saved).
    @Published private(set) var saveError: String?

    private let rawTracks: [Part: NoteTrack]
    private var store: CorrectionStore?
    /// The parts in the order the USER appended operations to them. Empty
    /// after a relaunch — then the undo uses the deterministic fallback.
    private var undoStack: [Part] = []
    /// The parts whose overlay file was successfully READ. Only those may be
    /// removed by a save; a file we could not read (quarantined) is left
    /// alone until the user deliberately edits that part.
    private var loadedParts: Set<Part> = []
    /// True when `corrections/song.json` was successfully read (so it may be
    /// removed when the calibration becomes empty).
    private var calibrationWasLoaded = false

    /// - Parameters:
    ///   - bundleDirectory: the song's bundle directory (C-11's home for the
    ///     overlay). Nil ⇒ nothing is saved (the demo tracks, or a failed row).
    ///   - rawTracks: the engine's tracks (never mutated).
    init(bundleDirectory: URL?, rawTracks: [Part: NoteTrack]) {
        self.rawTracks = rawTracks
        self.overlays = [:]
        self.calibration = nil
        self.effective = CorrectionResolver.resolve(raw: rawTracks, overlays: [:])

        if let bundleDirectory {
            Task { await load(bundleDirectory: bundleDirectory) }
        }
    }

    // MARK: - Derived state

    /// The parts of the corrected tracks, in C-1 order.
    var parts: [Part] {
        effective.tracks.keys.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// The parts that have corrections, in C-1 order (the list is grouped by
    /// part, and the label says so).
    var partsWithCorrections: [Part] {
        overlays.keys
            .filter { !(overlays[$0]?.operations.isEmpty ?? true) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// How many note corrections are stored.
    var correctionCount: Int {
        overlays.values.reduce(0) { $0 + $1.operations.count }
    }

    /// True while the undo order is the USER's session order. False right
    /// after a relaunch (or before the first correction) — then the undo uses
    /// the deterministic fallback and the UI says so.
    var undoOrderIsSessionOrder: Bool { !undoStack.isEmpty }

    /// The display name of a part (the user's rename, else the contract name).
    func displayName(for part: Part) -> String {
        calibration?.displayName(for: part) ?? part.displayName
    }

    /// The effective per-song ranges (C-6.1 preset + the song's override).
    var ranges: [Part: EffectivePartRange] {
        PartCalibration.effectiveRanges(calibration: calibration, parts: parts)
    }

    /// How many notes of each part fall outside its effective range.
    var notesOutsideRange: [Part: Int] {
        PartCalibration.notesOutsideRange(in: effective.tracks, ranges: ranges)
    }

    /// The range override for a part (nil = the C-6.1 preset).
    func rangeOverride(for part: Part) -> PartRangeOverride? {
        calibration?.rangeOverride(for: part)
    }

    // MARK: - Loading

    private func load(bundleDirectory: URL) async {
        let store = CorrectionStore(bundleDirectory: bundleDirectory)
        self.store = store
        let result = await Task.detached(priority: .userInitiated) {
            store.loadResult()
        }.value

        switch result {
        case let .loaded(stored):
            // An EMPTY overlay is "no corrections" — it is dropped, so the
            // list only ever shows real corrections. The part stays in
            // `loadedParts`, so a later save removes the now-pointless file.
            var loadedOverlays: [Part: PartCorrectionOverlay] = [:]
            for (part, overlay) in stored.partOverlays where !overlay.isEmpty {
                loadedOverlays[part] = overlay
            }
            self.overlays = loadedOverlays
            self.loadedParts = Set(stored.partOverlays.keys)
            if let calibration = stored.calibration, !calibration.isEmpty {
                self.calibration = calibration
                self.calibrationWasLoaded = true
            } else {
                self.calibration = nil
                self.calibrationWasLoaded = stored.calibration != nil
            }
            self.effective = CorrectionResolver.resolve(raw: rawTracks, overlays: loadedOverlays)
            self.undoStack = []
            self.loadMessage = stored.problems.isEmpty
                ? nil
                : stored.problems.joined(separator: "\n")
        case .absent:
            // No corrections directory ⇒ no corrections at all. The roll is
            // EXACTLY the engine's output (C-11's absence rule).
            self.overlays = [:]
            self.calibration = nil
            self.effective = CorrectionResolver.resolve(raw: rawTracks, overlays: [:])
            self.loadMessage = nil
        case let .failed(reason):
            self.loadMessage = reason
                + " The notes below are the engine's own, uncorrected."
        }
    }

    // MARK: - Editing

    /// Applies one note correction (C-11's operation, already contract-shaped).
    ///
    /// The operation lands in the overlay of `op.fromPart` — the part whose
    /// ORIGINAL array holds the target note.
    func apply(_ op: CorrectionOperation) {
        var overlay = overlays[op.fromPart] ?? PartCorrectionOverlay(part: op.fromPart)
        overlay.operations.append(op)
        overlays[op.fromPart] = overlay
        undoStack.append(op.fromPart)
        recompute()
        persist()
    }

    /// Undoes the last correction (an exact reversal).
    ///
    /// While the user works, the last correction is the last one they made.
    /// After a relaunch there is no session order, so the fallback is the
    /// deterministic one (parts in C-1 order, each part's operations in
    /// order) — and the UI says which order it is using.
    func undoLast() {
        guard correctionCount > 0 else { return }
        if let part = undoStack.last {
            undoStack.removeLast()
            removeLastOperation(from: part)
        } else {
            guard let part = partsWithCorrections.last else { return }
            removeLastOperation(from: part)
        }
        recompute()
        persist()
    }

    /// Clears every note correction — the engine's tracks come back exactly.
    /// The part names and ranges are the user's display preferences and are
    /// NOT touched (they have their own reset).
    func clearAllCorrections() {
        overlays = [:]
        undoStack = []
        recompute()
        persist()
    }

    /// Renames a part for this song.
    func rename(part: Part, to name: String) {
        var overlay = calibration ?? SongCalibrationOverlay()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            overlay.partRenames.removeValue(forKey: part.rawValue)
        } else {
            overlay.partRenames[part.rawValue] = trimmed
        }
        calibration = overlay.isEmpty ? nil : overlay
        persist()
    }

    /// Sets (or clears) a part's per-song range.
    func setRange(_ rangeOverride: PartRangeOverride?, for part: Part) {
        var overlay = calibration ?? SongCalibrationOverlay()
        if let rangeOverride {
            overlay.rangeOverrides[part.rawValue] = rangeOverride
        } else {
            overlay.rangeOverrides.removeValue(forKey: part.rawValue)
        }
        calibration = overlay.isEmpty ? nil : overlay
        persist()
    }

    /// Clears the part names and the range overrides (back to the contract's
    /// own names and C-6.1 presets).
    func resetCalibration() {
        calibration = nil
        persist()
    }

    // MARK: - Internals

    private func recompute() {
        effective = CorrectionResolver.resolve(raw: rawTracks, overlays: overlays)
    }

    /// Removes a part's LAST operation; the part's overlay disappears when it
    /// has none left (absence = "no corrections", C-11).
    private func removeLastOperation(from part: Part) {
        guard var overlay = overlays[part], !overlay.operations.isEmpty else { return }
        overlay.operations.removeLast()
        if overlay.operations.isEmpty {
            overlays.removeValue(forKey: part)
        } else {
            overlays[part] = overlay
        }
    }

    // MARK: - Persistence

    private func persist() {
        guard let store else {
            // The demo tracks have no song to save to — the screen says so.
            return
        }
        let overlays = self.overlays
        let calibration = self.calibration
        let loadedParts = self.loadedParts
        let calibrationWasLoaded = self.calibrationWasLoaded

        Task {
            do {
                try await Task.detached(priority: .utility) { () -> Void in
                    // A part the user just emptied loses its file (absence =
                    // "no corrections"). A file we could NOT read is left
                    // alone — the user's bytes are never destroyed by a save
                    // that did not touch that part.
                    for part in loadedParts {
                        let overlay = overlays[part]
                        if overlay == nil || overlay!.operations.isEmpty {
                            try? store.clear(part: part)
                        }
                    }
                    for (part, overlay) in overlays where !overlay.operations.isEmpty {
                        try store.save(overlay)
                    }
                    if let calibration, !calibration.isEmpty {
                        try store.save(calibration: calibration)
                    } else if calibrationWasLoaded {
                        try? store.clearCalibration()
                    }
                }.value
                saveError = nil
            } catch {
                saveError = "Your correction could not be saved (\(error.localizedDescription)). "
                    + "It still applies on this screen, but it will be gone when the app closes."
            }
        }
    }
}

// MARK: - The screen

/// The note-tracks screen: the roll + the user's corrections + the per-song
/// part calibration.
struct NoteTracksScreen: View {

    /// The song's title.
    let songTitle: String
    /// The engine's tracks (never mutated).
    let rawTracks: [Part: NoteTrack]
    /// Song duration (the roll's scroll extent).
    let duration_s: Double
    /// True for the synthetic demo tracks.
    let isMock: Bool
    /// The song's bundle directory — C-11's home for the overlay. Nil ⇒ the
    /// corrections are not saved (and the screen says so).
    let bundleDirectory: URL?

    @StateObject private var model: NoteTracksModel
    @State private var renamingPart: Part?
    @State private var renameText: String = ""
    @State private var editingRangePart: Part?
    @State private var isConfirmingClear = false

    init(songTitle: String, rawTracks: [Part: NoteTrack],
         duration_s: Double, isMock: Bool, bundleDirectory: URL?) {
        self.songTitle = songTitle
        self.rawTracks = rawTracks
        self.duration_s = duration_s
        self.isMock = isMock
        self.bundleDirectory = bundleDirectory
        _model = StateObject(wrappedValue: NoteTracksModel(
            bundleDirectory: bundleDirectory, rawTracks: rawTracks))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Token.Spacing.s3) {
                correctionHeader

                PianoRollView(
                    tracks: model.effective.tracks,
                    duration_s: duration_s,
                    isMock: isMock,
                    correctedNotes: model.effective.correctedNotes,
                    noteOrigins: model.effective.origins,
                    ranges: model.ranges,
                    onCorrection: { op in model.apply(op) },
                    partNames: model.calibration?.partNameMap() ?? [:])

                partsSection
                correctionsSection
            }
            .padding(Token.Spacing.s3)
        }
        .background(Color.pnBackground)
        .navigationTitle("Note tracks")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename part", isPresented: Binding(
            get: { renamingPart != nil },
            set: { if !$0 { renamingPart = nil } })) {
            TextField("Part name", text: $renameText)
            Button("Save") {
                if let part = renamingPart {
                    model.rename(part: part, to: renameText)
                }
                renamingPart = nil
            }
            Button("Cancel", role: .cancel) { renamingPart = nil }
        } message: {
            Text("A name for this voice part in this song. The engine's part names are unchanged.")
        }
        .sheet(isPresented: Binding(
            get: { editingRangePart != nil },
            set: { if !$0 { editingRangePart = nil } })) {
            if let part = editingRangePart {
                PartRangeEditorSheet(part: part,
                                     displayName: model.displayName(for: part),
                                     current: model.rangeOverride(for: part)) { newRange in
                    model.setRange(newRange, for: part)
                }
            }
        }
        .confirmationDialog("Clear every correction?",
                            isPresented: $isConfirmingClear,
                            titleVisibility: .visible) {
            Button("Clear all corrections", role: .destructive) { model.clearAllCorrections() }
            Button("Keep them", role: .cancel) {}
        } message: {
            Text("The engine's own note tracks come back exactly as they were. Nothing is deleted from the song. Your part names and ranges are kept.")
        }
    }

    // MARK: - The correction header

    private var correctionHeader: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s1) {
            Label {
                VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                    Text(correctionCountText)
                        .font(Token.Fonts.caption)
                        .fontWeight(.semibold)
                    Text(correctionExplaination)
                        .font(Token.Fonts.caption)
                        .foregroundStyle(Color.pnTextSecondary)
                }
            } icon: {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(Color.pnAccent)
            }
            .padding(Token.Spacing.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pnAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: Token.Radius.card))

            if let message = model.loadMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.octaveWarn)
                    .padding(Token.Spacing.s2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.octaveWarn.opacity(0.10), in: RoundedRectangle(cornerRadius: Token.Radius.card))
            }
            if let saveError = model.saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.octaveWarn)
                    .padding(Token.Spacing.s2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.octaveWarn.opacity(0.10), in: RoundedRectangle(cornerRadius: Token.Radius.card))
            }
            if !model.effective.warnings.isEmpty {
                VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                    ForEach(model.effective.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.octaveWarn)
                    }
                }
                .padding(Token.Spacing.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.octaveWarn.opacity(0.08), in: RoundedRectangle(cornerRadius: Token.Radius.card))
            }
        }
    }

    private var correctionCountText: String {
        let count = model.correctionCount
        if count == 0 { return "No corrections yet" }
        return count == 1 ? "1 correction" : "\(count) corrections"
    }

    private var correctionExplaination: String {
        if isMock {
            return "These are synthetic demo notes, so corrections to them are not saved. "
                + "Your corrections to a real song are saved with the song and never change the engine's own tracks."
        }
        if bundleDirectory == nil {
            return "This song's bundle folder is not available on this device, so corrections to it are not saved. "
                + "The notes below are the engine's own, uncorrected."
        }
        if model.correctionCount == 0 {
            return "Tap a note to move it to another part, split it, or delete it. "
                + "Your corrections are saved with the song; the engine's own tracks are never rewritten."
        }
        return "These are YOUR corrections — the notes they touched are marked on the roll. "
            + "The engine's own tracks are untouched, so you can undo anything."
    }

    // MARK: - The parts (rename + calibration)

    private var partsSection: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s2) {
            Text("Parts & ranges")
                .font(Token.Fonts.caption)
                .fontWeight(.semibold)

            if model.parts.isEmpty {
                Text("This song has no note tracks yet.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            } else {
                ForEach(model.parts, id: \.self) { part in
                    partRow(part)
                }
                if model.calibration != nil {
                    Button("Reset names & ranges") { model.resetCalibration() }
                        .font(Token.Fonts.caption)
                        .accessibilityHint("Back to the contract's part names and the C-6.1 presets")
                }
            }
        }
        .padding(Token.Spacing.s3)
        .background(Color.pnSurface, in: RoundedRectangle(cornerRadius: Token.Radius.card))
    }

    private func partRow(_ part: Part) -> some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s1) {
            HStack {
                Circle()
                    .fill(PartPalette.color(for: part))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(model.displayName(for: part))
                    .font(Token.Fonts.caption)
                    .fontWeight(.semibold)
                Spacer()
                Text(model.ranges[part]?.label ?? "No C-6.1 range")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
            if let outside = model.notesOutsideRange[part], outside > 0 {
                Text("\(outside) note\(outside == 1 ? "" : "s") sit outside this part's range. "
                     + "They are marked on the roll, not removed — a range is a filter, not a gate.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.octaveWarn)
            }
            HStack(spacing: Token.Spacing.s2) {
                Button("Rename") {
                    renameText = model.displayName(for: part)
                    renamingPart = part
                }
                .font(Token.Fonts.caption)
                Button("Set range") {
                    editingRangePart = part
                }
                .font(Token.Fonts.caption)
            }
        }
        .padding(.vertical, Token.Spacing.s1)
    }

    // MARK: - The corrections list

    /// One group of corrections: a part and the operations in it, in order.
    private struct CorrectionGroup: Identifiable {
        let part: Part
        let operations: [CorrectionOperation]
        var id: Part { part }
    }

    private var correctionGroups: [CorrectionGroup] {
        model.partsWithCorrections.map { part in
            CorrectionGroup(part: part, operations: model.overlays[part]?.operations ?? [])
        }
    }

    private var correctionsSection: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s2) {
            Text("Your corrections")
                .font(Token.Fonts.caption)
                .fontWeight(.semibold)

            if model.correctionCount == 0 {
                Text("Nothing corrected yet. The roll above is exactly what the engine found.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            } else {
                Text("Grouped by the part the correction starts from (contract order); within a part, the order you corrected in.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)

                ForEach(correctionGroups) { group in
                    VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                        Text(model.displayName(for: group.part))
                            .font(Token.Fonts.caption)
                            .fontWeight(.semibold)
                        ForEach(Array(group.operations.enumerated()), id: \.offset) { _, op in
                            HStack {
                                Image(systemName: "pencil.circle")
                                    .foregroundStyle(Color.pnAccent)
                                    .accessibilityHidden(true)
                                Text(op.summary)
                                    .font(Token.Fonts.caption)
                                    .foregroundStyle(Color.pnTextPrimary)
                                Spacer()
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.vertical, Token.Spacing.s1)
                }

                if !model.undoOrderIsSessionOrder {
                    Text("Undo removes the last correction in contract part order (T1, T2, …), because these corrections were loaded from the file — there is no session order to follow.")
                        .font(Token.Fonts.caption)
                        .foregroundStyle(Color.pnTextSecondary)
                }

                HStack(spacing: Token.Spacing.s2) {
                    Button("Undo the last") { model.undoLast() }
                        .font(Token.Fonts.caption)
                    Button("Clear all", role: .destructive) { isConfirmingClear = true }
                        .font(Token.Fonts.caption)
                }
            }
        }
        .padding(Token.Spacing.s3)
        .background(Color.pnSurface, in: RoundedRectangle(cornerRadius: Token.Radius.card))
    }
}

// MARK: - The per-song range editor

/// The per-song range editor (J-302): the C-6.1 preset with an optional
/// nudge, or a custom range for this song.
struct PartRangeEditorSheet: View {

    let part: Part
    let displayName: String
    /// The override being edited (nil = the contract preset).
    let current: PartRangeOverride?
    /// Called with the new override (nil = back to the contract preset).
    let onSave: (PartRangeOverride?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: PartRangeOverride.Mode
    @State private var nudge: Int
    @State private var low: Int
    @State private var high: Int

    init(part: Part, displayName: String, current: PartRangeOverride?,
         onSave: @escaping (PartRangeOverride?) -> Void) {
        self.part = part
        self.displayName = displayName
        self.current = current
        self.onSave = onSave
        let preset = PartRangeOverride.preset(for: part)
        _mode = State(initialValue: current?.mode ?? .preset)
        _nudge = State(initialValue: current?.nudgeSemitones ?? 0)
        _low = State(initialValue: current?.midiLow ?? preset.midiLow)
        _high = State(initialValue: current?.midiHigh ?? preset.midiHigh)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Range", selection: $mode) {
                        Text("Contract preset").tag(PartRangeOverride.Mode.preset)
                        Text("Custom for this song").tag(PartRangeOverride.Mode.custom)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("\(displayName) — range")
                } footer: {
                    Text("C-6.1's preset is the contract's own range for this part. A custom range applies to this song only; the contract table is never changed.")
                }

                if mode == .preset {
                    Section("Contract preset") {
                        LabeledContent("Preset") {
                            Text(presetLabel)
                                .font(Token.Fonts.numeric)
                        }
                        Stepper("Nudge: \(nudge >= 0 ? "+" : "−")\(abs(nudge)) semitone\(abs(nudge) == 1 ? "" : "s")",
                                value: $nudge, in: -2...2)
                        Text("C-6.1 allows −2…+2 semitones. The nudge shifts the band, it never gates a note.")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.pnTextSecondary)
                    }
                } else {
                    Section("Custom range") {
                        Stepper("Lowest MIDI: \(low)", value: $low, in: 24...95)
                        Stepper("Highest MIDI: \(high)", value: $high, in: 25...96)
                        Text("MIDI 60 is C4 (A440 tuning). The range is a filter: notes outside it are marked, never removed.")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.pnTextSecondary)
                    }
                }

                Section {
                    LabeledContent("Range") {
                        Text(effectiveLabel)
                            .font(Token.Fonts.numeric)
                    }
                    LabeledContent("Hz") {
                        Text(hzLabel)
                            .font(Token.Fonts.numeric)
                    }
                } header: {
                    Text("What this means")
                }
            }
            .navigationTitle("Part range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        switch mode {
                        case .preset:
                            onSave(.preset(for: part, nudgeSemitones: nudge))
                        case .custom:
                            onSave(.custom(for: part, midiLow: low, midiHigh: high))
                        }
                        dismiss()
                    }
                }
            }
        }
    }

    private var presetLabel: String {
        PartRangePresets.preset(for: part)?.presetName ?? "—"
    }

    private var effectiveLabel: String {
        let rangeOverride: PartRangeOverride
        switch mode {
        case .preset: rangeOverride = .preset(for: part, nudgeSemitones: nudge)
        case .custom: rangeOverride = .custom(for: part, midiLow: low, midiHigh: high)
        }
        return PartCalibration.effectiveRange(for: part, rangeOverride: rangeOverride)?.label ?? "—"
    }

    private var hzLabel: String {
        let rangeOverride: PartRangeOverride
        switch mode {
        case .preset: rangeOverride = .preset(for: part, nudgeSemitones: nudge)
        case .custom: rangeOverride = .custom(for: part, midiLow: low, midiHigh: high)
        }
        guard let range = PartCalibration.effectiveRange(for: part, rangeOverride: rangeOverride) else {
            return "—"
        }
        return String(format: "%.1f–%.1f Hz", range.fmin, range.fmax)
    }
}
