import SwiftUI
import PitchLogic
import EngineCore

// NoteTracksScreen (J-302) — the per-part note tracks WITH the user's
// corrections.
//
// THIS IS THE CORRECTED-FIRST SCREEN (D-41 §4): the roll it hosts renders the
// EFFECTIVE tracks (the engine's tracks + the user's overlay), never the raw
// file. The engine's `notes/<PART>.json` is never rewritten — the overlay is
// a separate, reversible layer (PitchLogic's CorrectionOverlay).
//
// HONESTY (AGENTS §11 — a product requirement):
//   · the corrections are labelled as the USER'S edits, never as the engine's
//     opinion, and the notes they touched are marked on the roll;
//   · the engine's original tracks are one tap away ("clear all corrections"),
//     so nothing the user does is a one-way door;
//   · a skipped or repaired correction is REPORTED, never swallowed;
//   · the demo tracks say plainly that corrections to them are not saved.
//
// WHY A SEPARATE SCREEN AND NOT THE INSPECTOR: the corrections need room to
// be honest — a list of what was changed, what was skipped, and what the
// per-song ranges are. The inspector stays the read-only verdict view.

/// The screen's state: the overlay, the effective tracks, and persistence.
@MainActor
final class NoteTracksModel: ObservableObject {

    /// The user's corrections for this song.
    @Published private(set) var overlay: CorrectionOverlay
    /// The engine's tracks + the overlay — what everything reads.
    @Published private(set) var effective: EffectiveTracks
    /// Set when the stored corrections could not be read (honest, not silent).
    @Published private(set) var loadMessage: String?
    /// Set when a save failed (the corrections stay in memory and the user
    /// is told they were NOT saved).
    @Published private(set) var saveError: String?

    private let rawTracks: [Part: NoteTrack]
    private var store: CorrectionStore?

    /// - Parameters:
    ///   - bundleID: the song's manifest id (nil for the demo tracks).
    ///   - rawTracks: the engine's tracks (never mutated).
    ///   - persist: false for the demo tracks (there is no song to save to).
    init(bundleID: String?, rawTracks: [Part: NoteTrack], persist: Bool) {
        self.rawTracks = rawTracks
        let empty = CorrectionOverlay.empty(bundleID: bundleID ?? "demo")
        self.overlay = empty
        self.effective = CorrectionResolver.resolve(raw: rawTracks, overlay: empty)

        if persist, let bundleID {
            Task { await load(bundleID: bundleID) }
        }
    }

    /// The parts of the corrected tracks, in C-1 order.
    var parts: [Part] {
        effective.tracks.keys.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// The display name of a part (the user's rename, else the contract name).
    func displayName(for part: Part) -> String { overlay.displayName(for: part) }

    /// The effective per-song ranges (C-6.1 preset + the song's override).
    var ranges: [Part: EffectivePartRange] {
        PartCalibration.effectiveRanges(overlay: overlay, parts: parts)
    }

    /// How many notes of each part fall outside its effective range.
    var notesOutsideRange: [Part: Int] {
        PartCalibration.notesOutsideRange(in: effective.tracks, ranges: ranges)
    }

    // MARK: - Loading

    private enum LoadOutcome: Sendable {
        case loaded(CorrectionStore, CorrectionLoadResult)
        case failed(String)
    }

    private func load(bundleID: String) async {
        let outcome = await Task.detached(priority: .userInitiated) { () -> LoadOutcome in
            guard let store = try? CorrectionStore.makeDefault() else {
                return .failed("Corrections could not be opened on this device.")
            }
            return .loaded(store, store.loadResult(forBundleID: bundleID))
        }.value

        switch outcome {
        case let .loaded(store, .loaded(stored)):
            self.store = store
            self.overlay = stored
            self.effective = CorrectionResolver.resolve(raw: rawTracks, overlay: stored)
            self.loadMessage = nil
        case let .loaded(store, .corrupted(reason)):
            self.store = store
            self.loadMessage = "Your corrections for this song could not be read: \(reason) "
                + "A copy was kept, and the notes below are the engine's own, uncorrected."
        case let .loaded(store, .absent):
            self.store = store
            self.loadMessage = nil
        case let .failed(message):
            self.loadMessage = message
        }
    }

    // MARK: - Editing

    /// Applies one note correction.
    func apply(_ op: CorrectionOp) {
        overlay.append(op)
        effective = CorrectionResolver.resolve(raw: rawTracks, overlay: overlay)
        persist()
    }

    /// Undoes the last correction (an exact reversal).
    func undoLast() {
        overlay.undoLast()
        effective = CorrectionResolver.resolve(raw: rawTracks, overlay: overlay)
        persist()
    }

    /// Clears every correction — the engine's tracks come back exactly.
    func clearAll() {
        overlay.resetAll()
        effective = CorrectionResolver.resolve(raw: rawTracks, overlay: overlay)
        persist()
    }

    /// Renames a part for this song.
    func rename(part: Part, to name: String) {
        overlay.rename(part: part, to: name)
        persist()
    }

    /// Sets (or clears) a part's per-song range.
    func setRange(_ rangeOverride: PartRangeOverride?, for part: Part) {
        overlay.setRange(rangeOverride, for: part)
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        guard let store else {
            // The demo tracks have no song to save to — the screen says so.
            return
        }
        let overlay = self.overlay
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try store.save(overlay)
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

    /// The song's manifest id (nil for the demo tracks).
    let bundleID: String?
    /// The song's title.
    let songTitle: String
    /// The engine's tracks (never mutated).
    let rawTracks: [Part: NoteTrack]
    /// Song duration (the roll's scroll extent).
    let duration_s: Double
    /// True for the synthetic demo tracks.
    let isMock: Bool

    @StateObject private var model: NoteTracksModel
    @State private var renamingPart: Part?
    @State private var renameText: String = ""
    @State private var editingRangePart: Part?
    @State private var isConfirmingClear = false

    init(bundleID: String?, songTitle: String, rawTracks: [Part: NoteTrack],
         duration_s: Double, isMock: Bool) {
        self.bundleID = bundleID
        self.songTitle = songTitle
        self.rawTracks = rawTracks
        self.duration_s = duration_s
        self.isMock = isMock
        _model = StateObject(wrappedValue: NoteTracksModel(
            bundleID: bundleID, rawTracks: rawTracks, persist: !isMock))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Token.Spacing.s3) {
                correctionHeader

                PianoRollView(
                    tracks: model.effective.tracks,
                    duration_s: duration_s,
                    isMock: isMock,
                    correctedIdentities: model.effective.correctedIdentities,
                    ranges: model.ranges,
                    onCorrection: { op in model.apply(op) },
                    partNames: model.overlay.partNameMap())

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
                                     current: model.overlay.rangeOverride(for: part)) { newRange in
                    model.setRange(newRange, for: part)
                }
            }
        }
        .confirmationDialog("Clear every correction?",
                            isPresented: $isConfirmingClear,
                            titleVisibility: .visible) {
            Button("Clear all corrections", role: .destructive) { model.clearAll() }
            Button("Keep them", role: .cancel) {}
        } message: {
            Text("The engine's own note tracks come back exactly as they were. Nothing is deleted from the song.")
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
        let count = model.overlay.correctionCount
        if count == 0 { return "No corrections yet" }
        return count == 1 ? "1 correction" : "\(count) corrections"
    }

    private var correctionExplaination: String {
        if isMock {
            return "These are synthetic demo notes, so corrections to them are not saved. "
                + "Your corrections to a real song are saved with the song and never change the engine's own tracks."
        }
        if model.overlay.correctionCount == 0 {
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

    private var correctionsSection: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s2) {
            Text("Your corrections")
                .font(Token.Fonts.caption)
                .fontWeight(.semibold)

            if model.overlay.ops.isEmpty {
                Text("Nothing corrected yet. The roll above is exactly what the engine found.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            } else {
                ForEach(Array(model.overlay.ops.enumerated()), id: \.offset) { _, op in
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
                            onSave(.custom(midiLow: low, midiHigh: high))
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
        case .custom: rangeOverride = .custom(midiLow: low, midiHigh: high)
        }
        return PartCalibration.effectiveRange(for: part, rangeOverride: rangeOverride)?.label ?? "—"
    }

    private var hzLabel: String {
        let rangeOverride: PartRangeOverride
        switch mode {
        case .preset: rangeOverride = .preset(for: part, nudgeSemitones: nudge)
        case .custom: rangeOverride = .custom(midiLow: low, midiHigh: high)
        }
        guard let range = PartCalibration.effectiveRange(for: part, rangeOverride: rangeOverride) else {
            return "—"
        }
        return String(format: "%.1f–%.1f Hz", range.fmin, range.fmax)
    }
}
