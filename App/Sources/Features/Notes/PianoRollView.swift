import SwiftUI
import PitchLogic
import EngineCore

// PianoRollView — J-301's headline screen: the per-part piano roll.
//
// INTERACTION PATTERNS (Muskey's notes window, REIMPLEMENTED AGPL-safe per
// D-26 — no code copied, no dependency, our own drawing):
//   · a moving play line over a STATIC page of engraved notes (the roll does
//     not scroll under the playhead like a ticker; the user pans the page),
//   · tap a note → seek to that note's time + open its detail,
//   · drag ACROSS notes → a region (A/B) loop for the transport,
//   · ↑/↓ transpose the DISPLAYED reference only — the audio is never
//     touched (UX §A.2.4) and the display stays inside each part's C-6.1
//     singable range.
//
// HONESTY (AGENTS §11 — a product requirement, not a nicety):
//   · confidence shading follows D-41's bands (≥0.80 solid, 0.50–0.80
//     shaded, <0.50 faint) — a soft signal never renders as a hard fact;
//   · a part that looks ABSENT in a phrase is DIMMED, never hidden (D-41 §2);
//   · unison notes carry a badge — "this passage cannot be isolated by pitch";
//   · a MOCK track says so, in the UI, in plain words.
//
// SWAP SEAM: the view takes `[Part: NoteTrack]`. The mock source and Paul's
// real per-part tracks (P-305) are the SAME type, so the mock→real swap
// changes nothing in this file (J-301 AC: zero UI changes).

/// Time zoom levels. The middle one is the UX §3.2 token default (90 px/s).
enum PianoRollZoom: Double, CaseIterable, Identifiable {
    case wide = 45
    case standard = 90
    case close = 180
    case detail = 360

    var pixelsPerSecond: Double { rawValue }
    var id: Double { rawValue }

    var label: String {
        switch self {
        case .wide: return "Wide"
        case .standard: return "Normal"
        case .close: return "Close"
        case .detail: return "Detail"
        }
    }

    /// Seconds visible across a ~390 pt-wide phone at this zoom.
    /// (A `func`, not a computed property: Swift computed properties cannot
    /// take parameters — that was the J-301 build-ipa compile red.)
    func visibleSeconds(phoneWidth: Double) -> Double {
        phoneWidth / rawValue
    }
}

struct PianoRollView: View {
    /// The tracks to render — mock today, Paul's real tracks after P-305.
    let tracks: [Part: NoteTrack]
    /// Song duration (scroll extent).
    let duration_s: Double
    /// Optional bar map from a score alignment (P-304) — makes the phrases
    /// bar-aligned (D-41 §2). Absent ⇒ 4.0 s phrases, heuristic-only.
    var barStarts: [Double]? = nil
    /// True when the tracks are the synthetic MOCK (the UI says so).
    var isMock: Bool = false
    /// Called when the user taps a note (seek the transport to that note).
    var onSeek: ((Double) -> Void)? = nil
    /// Called when the user drags a region across notes (A/B loop).
    var onLoopRegion: ((Double, Double) -> Void)? = nil
    /// Optional live playhead position (seconds).
    var currentTime: Double? = nil
    /// J-302: the notes the USER corrected — they are marked on the roll so
    /// a user's opinion never looks like the engine's output.
    var correctedNotes: Set<NoteKey> = []
    /// J-302: where each displayed note came from (the engine's original
    /// part + index). C-11 addresses notes by that index, so the roll needs
    /// it to turn a tapped note into a contract-shaped operation.
    var noteOrigins: [NoteKey: NoteOrigin] = [:]
    /// J-302: the effective per-song ranges (C-6.1 preset + the song's
    /// override). A note outside its part's band is MARKED, never hidden
    /// (D-12: a range is a filter, not a gate).
    var ranges: [Part: EffectivePartRange] = [:]
    /// J-302: called when the user corrects a note (move / split / delete).
    /// The roll itself never changes the tracks — the owner does, through
    /// the correction overlay.
    var onCorrection: ((CorrectionOperation) -> Void)? = nil
    /// The USER's per-song part names (J-302). Empty = the C-1 names.
    var partNames: [Part: String] = [:]

    @State private var model: PianoRollModel
    @State private var zoom: PianoRollZoom = .standard
    @State private var scrollSeconds: Double = 0
    @State private var selectedNote: PianoRollNote?
    @State private var loopRegion: PianoRollModel.LoopRegion?
    @State private var dragStartX: CGFloat?
    @State private var dragStartTime: Double?

    init(tracks: [Part: NoteTrack], duration_s: Double,
         barStarts: [Double]? = nil, isMock: Bool = false,
         onSeek: ((Double) -> Void)? = nil,
         onLoopRegion: ((Double, Double) -> Void)? = nil,
         currentTime: Double? = nil,
         correctedNotes: Set<NoteKey> = [],
         noteOrigins: [NoteKey: NoteOrigin] = [:],
         ranges: [Part: EffectivePartRange] = [:],
         onCorrection: ((CorrectionOperation) -> Void)? = nil,
         partNames: [Part: String] = [:]) {
        self.tracks = tracks
        self.duration_s = duration_s
        self.barStarts = barStarts
        self.isMock = isMock
        self.onSeek = onSeek
        self.onLoopRegion = onLoopRegion
        self.currentTime = currentTime
        self.correctedNotes = correctedNotes
        self.noteOrigins = noteOrigins
        self.ranges = ranges
        self.onCorrection = onCorrection
        self.partNames = partNames
        var initialModel = PianoRollModel(tracks: tracks, duration_s: duration_s,
                                          barStarts: barStarts)
        initialModel.partNames = partNames
        _model = State(initialValue: initialModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Token.Spacing.s3) {
                if isMock {
                    mockNotice
                }
                partToggles
                roll
                transportControls
                detailsList
            }
            .padding(Token.Spacing.s3)
        }
        .background(Color.pnBackground)
        .navigationTitle("Note tracks")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: partNames) { newValue in model.partNames = newValue }
        .onChange(of: tracks) { newTracks in
            // J-302: the corrected tracks arrive as NEW tracks — the model's
            // notes are immutable, so the roll is rebuilt while the user's
            // display state (hidden parts, transpose) is kept.
            var rebuilt = PianoRollModel(tracks: newTracks, duration_s: duration_s,
                                         barStarts: barStarts)
            rebuilt.hiddenParts = model.hiddenParts
            rebuilt.transposeSemitones = model.transposeSemitones
            rebuilt.partNames = model.partNames
            model = rebuilt
        }
        .sheet(item: $selectedNote) { note in
            NoteDetailSheet(note: note, model: model,
                            isCorrected: correctedNotes.contains(NoteKey(part: note.part, note: note.note)),
                            onMove: moveHandler(for: note),
                            onSplit: splitHandler(for: note),
                            onDelete: deleteHandler(for: note))
        }
    }

    // MARK: - Correction handlers (J-302)
    //
    // C-11 addresses a note by its index in the ENGINE'S ORIGINAL, IMMUTABLE
    // `notes[]` array for `fromPart`. The roll is showing the CORRECTED
    // track, so every operation needs the note's origin — the resolver hands
    // it over in `noteOrigins`. A note with no origin cannot be corrected by
    // index, and the roll says so rather than guessing.

    /// Move the note to another part (nil when the roll is read-only).
    private func moveHandler(for note: PianoRollNote) -> ((Part) -> Void)? {
        guard let onCorrection else { return nil }
        return { target in
            let key = NoteKey(part: note.part, note: note.note)
            guard let origin = noteOrigins[key] else {
                selectedNote = nil
                return
            }
            selectedNote = nil
            onCorrection(.reassign(fromPart: origin.part,
                                    noteIndex: origin.index,
                                    toPart: target))
        }
    }

    /// Split the note in two at its midpoint. The second part is the user's
    /// choice (C-11's `toParts` names TWO parts; the first half goes to the
    /// first one).
    private func splitHandler(for note: PianoRollNote) -> ((Part) -> Void)? {
        guard let onCorrection else { return nil }
        return { secondPart in
            let key = NoteKey(part: note.part, note: note.note)
            guard let origin = noteOrigins[key] else {
                selectedNote = nil
                return
            }
            selectedNote = nil
            let middle = (note.note.start_s + note.note.end_s) / 2
            onCorrection(.split(fromPart: origin.part,
                                noteIndex: origin.index,
                                splitAt_s: middle,
                                toParts: [note.part, secondPart]))
        }
    }

    /// Delete the note.
    private func deleteHandler(for note: PianoRollNote) -> (() -> Void)? {
        guard let onCorrection else { return nil }
        return {
            let key = NoteKey(part: note.part, note: note.note)
            guard let origin = noteOrigins[key] else {
                selectedNote = nil
                return
            }
            selectedNote = nil
            onCorrection(.delete(fromPart: origin.part, noteIndex: origin.index))
        }
    }

    // MARK: - Honesty banner

    private var mockNotice: some View {
        Label {
            VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                Text("Demo track — synthetic, not a real song")
                    .font(Token.Fonts.caption)
                    .fontWeight(.semibold)
                Text("These notes are generated to show how the roll works. Real note tracks arrive with the engine's note tracker.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            }
        } icon: {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Color.octaveWarn)
        }
        .padding(Token.Spacing.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.octaveWarn.opacity(0.10), in: RoundedRectangle(cornerRadius: Token.Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Demo track. Synthetic notes for demonstration, not a real song.")
    }

    // MARK: - Part toggles

    private var partToggles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Token.Spacing.s2) {
                ForEach(model.parts, id: \.self) { part in
                    partChip(part)
                }
            }
            .padding(.vertical, Token.Spacing.s1)
        }
        .accessibilityLabel("Parts")
    }

    private func partChip(_ part: Part) -> some View {
        let visible = !model.hiddenParts.contains(part)
        return Button {
            if visible {
                model.hiddenParts.insert(part)
            } else {
                model.hiddenParts.remove(part)
            }
        } label: {
            HStack(spacing: Token.Spacing.s1) {
                Circle()
                    .fill(visible ? PartPalette.color(for: part) : PartPalette.color(for: part).opacity(0.3))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(model.partName(for: part))
                    .font(Token.Fonts.caption)
                    .fontWeight(.semibold)
                Image(systemName: visible ? "eye" : "eye.slash")
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Token.Spacing.s2)
            .padding(.vertical, Token.Spacing.s1)
            .background(visible ? Color.pnSurface : Color.pnSurfaceElevated,
                        in: Capsule())
            .foregroundStyle(Color.pnTextPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.partName(for: part)), \(visible ? "shown" : "hidden")")
        .accessibilityHint("Double tap to \(visible ? "hide" : "show") the \(model.partName(for: part)) lane")
    }

    // MARK: - The roll itself

    private var roll: some View {
        GeometryReader { proxy in
            let rollLayout = layout(for: proxy.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawRoll(context: &context, size: size, layout: rollLayout)
                }
                .background(Color.pnSurface)
                .clipShape(RoundedRectangle(cornerRadius: Token.Radius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: Token.Radius.card)
                        .stroke(Color.pnTrack, lineWidth: 1)
                )
                .contentShape(Rectangle())
                .gesture(dragGesture(layout: rollLayout))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Piano roll")
                .accessibilityValue(accessibilitySummary(layout: rollLayout))
                .accessibilityHint("Tap a note for its details. Drag across notes for a region loop. Drag empty space to move through the song.")

                if let region = loopRegion {
                    let startX = CGFloat(rollLayout.x(forTime: region.start_s))
                    let endX = CGFloat(rollLayout.x(forTime: region.end_s))
                    Rectangle()
                        .fill(Color.pnAccent.opacity(0.18))
                        .frame(width: max(endX - startX, 2), height: proxy.size.height)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.pnAccent).frame(width: 2)
                        }
                        .offset(x: startX)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: 360)
    }

    /// The geometry for the current viewport: time from `scrollSeconds`, pitch
    /// auto-fitted to the visible parts (no vertical scroll needed; the roll
    /// stays readable on a phone).
    private func layout(for size: CGSize) -> PianoRollLayout {
        let range = model.contentCentsRange()
        let semitoneSpan = max((range.upperBound - range.lowerBound) / 100, 6)
        let fitted = Double(size.height) / semitoneSpan
        let pixelsPerSemitone = min(max(fitted, 6), 22)
        return PianoRollLayout(
            pixelsPerSecond: zoom.pixelsPerSecond,
            pixelsPerSemitone: pixelsPerSemitone,
            scrollSeconds: scrollSeconds,
            topCents: range.upperBound,
            viewportWidth: Double(size.width),
            viewportHeight: Double(size.height))
    }

    private func drawRoll(context: inout GraphicsContext, size: CGSize, layout: PianoRollLayout) {
        // Second gridlines.
        let visible = layout.visibleTimeRange
        let firstSecond = Int(floor(visible.lowerBound))
        let lastSecond = Int(ceil(visible.upperBound))
        var path = Path()
        for second in firstSecond...max(firstSecond, lastSecond) {
            let x = CGFloat(layout.x(forTime: Double(second)))
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(path, with: .color(Color.pnTrack.opacity(0.5)), lineWidth: 0.5)

        // The play line (Muskey's moving line — vertical, never reflows).
        if let currentTime = currentTime {
            let x = layout.x(forTime: currentTime)
            if x >= 0 && x <= Double(size.width) {
                var line = Path()
                line.move(to: CGPoint(x: CGFloat(x), y: 0))
                line.addLine(to: CGPoint(x: CGFloat(x), y: size.height))
                context.stroke(line, with: .color(Color.pnTextSecondary), lineWidth: 1.5)
            }
        }

        // Notes — only the visible window (a 4-minute song never draws 1000
        // rectangles per frame).
        for note in model.notes(inTimeRange: visible) {
            let rect = model.rect(for: note, layout: layout)
            guard rect.x < Double(size.width) && rect.x + rect.width > 0 else { continue }
            // PitchLogic's geometry is portable Double; CoreGraphics wants
            // CGFloat — convert at the drawing boundary (the green ribbon code
            // does the same: `func y(_ cents: Double) -> CGFloat`).
            let cgRect = CGRect(x: CGFloat(rect.x), y: CGFloat(rect.y),
                                width: CGFloat(rect.width), height: CGFloat(rect.height))
            let present = model.isPresent(part: note.part, phraseIndex: note.phraseIndex)
            var fill = PartPalette.color(for: note.part)
            // D-41 §1 — band shading. CONFIRMED solid, PROVISIONAL shaded,
            // UNASSIGNED faint. D-41 §2 — an absent part is dimmed.
            switch note.band {
            case .confirmed: fill = fill.opacity(1.0)
            case .provisional: fill = fill.opacity(0.55)
            case .unassigned: fill = fill.opacity(0.25)
            }
            if !present { fill = fill.opacity(0.3) }
            let shape = Path(roundedRect: cgRect, cornerRadius: 2)
            context.fill(shape, with: .color(fill))
            if note.band != .confirmed {
                // Dashed outline for a soft assignment (UX §3.2/§3.7: a soft
                // signal never renders as a hard-edged fact).
                context.stroke(shape, with: .color(PartPalette.color(for: note.part)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            if note.isUnison {
                // Unison badge (D-41 §3) — a small ring at the note's corner.
                let badgeCenter = CGPoint(x: cgRect.minX + 4, y: cgRect.minY + 4)
                let badge = Path(ellipseIn: CGRect(x: badgeCenter.x - 3, y: badgeCenter.y - 3,
                                                  width: 6, height: 6))
                context.fill(badge, with: .color(Color.pnTextPrimary))
                context.stroke(badge, with: .color(Color.pnSurface), lineWidth: 1)
            }
            // J-302: a note the USER corrected is marked, so a user's opinion
            // never looks like the engine's output (honesty, AGENTS §11).
            if correctedNotes.contains(NoteKey(part: note.part, note: note.note)) {
                let markCenter = CGPoint(x: cgRect.maxX - 4, y: cgRect.minY + 4)
                let mark = Path(ellipseIn: CGRect(x: markCenter.x - 2.5, y: markCenter.y - 2.5,
                                                 width: 5, height: 5))
                context.fill(mark, with: .color(Color.pnTextPrimary))
            }
            // J-302: a note outside its part's per-song range is marked, never
            // hidden (D-12: a range is a filter, not a gate).
            if let range = ranges[note.part], !range.contains(midi: note.note.midi) {
                context.stroke(shape, with: .color(Color.octaveWarn), lineWidth: 1.5)
            }
        }
    }

    // MARK: - Gestures

    private func dragGesture(layout: PianoRollLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartX == nil {
                    dragStartX = value.startLocation.x
                    dragStartTime = model.hitTest(x: Double(value.startLocation.x),
                                                  y: Double(value.startLocation.y),
                                                  layout: layout)?.note.start_s
                }
            }
            .onEnded { value in
                let startX = dragStartX ?? value.startLocation.x
                let moved = abs(value.translation.width)
                defer {
                    dragStartX = nil
                    dragStartTime = nil
                }
                if moved < 8 {
                    // TAP: hit-test the note under the finger.
                    if let note = model.hitTest(x: Double(value.location.x),
                                                y: Double(value.location.y),
                                                layout: layout) {
                        selectedNote = note
                        onSeek?(note.note.start_s)
                    }
                } else if dragStartTime != nil {
                    // DRAG ACROSS NOTES → region loop (Muskey pattern).
                    let region = model.loopRegion(fromX: Double(startX),
                                                  toX: Double(value.location.x),
                                                  layout: layout)
                    guard !region.isEmpty else { return }
                    loopRegion = region
                    onLoopRegion?(region.start_s, region.end_s)
                } else {
                    // DRAG ON EMPTY SPACE → pan the page.
                    let deltaSeconds = -Double(value.translation.width) / layout.pixelsPerSecond
                    let span = layout.visibleTimeRange.upperBound - layout.visibleTimeRange.lowerBound
                    let maxScroll = max(duration_s - span, 0)
                    scrollSeconds = min(max(scrollSeconds + deltaSeconds, 0), maxScroll)
                }
            }
    }

    // MARK: - Transport-ish controls

    private var transportControls: some View {
        VStack(alignment: .leading, spacing: Token.Spacing.s2) {
            HStack {
                Text("Zoom")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
                Picker("Zoom", selection: $zoom) {
                    ForEach(PianoRollZoom.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Time zoom")
            }

            HStack {
                Button {
                    model.transposeSemitones = max(model.transposeSemitones - 1, -12)
                } label: {
                    Label("Down", systemImage: "arrow.down")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Transpose down one semitone")

                Text(transposeCaption)
                    .font(Token.Fonts.numeric)
                    .foregroundStyle(Color.pnTextSecondary)

                Button {
                    model.transposeSemitones = min(model.transposeSemitones + 1, 12)
                } label: {
                    Label("Up", systemImage: "arrow.up")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Transpose up one semitone")
            }

            VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                Text("Position")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
                Slider(value: Binding(
                    get: { scrollSeconds },
                    set: { scrollSeconds = min(max($0, 0), max(duration_s - 1, 0)) }
                ), in: 0...max(duration_s - 1, 1))
                .accessibilityLabel("Position in the song")
                .accessibilityValue(String(format: "%.1f of %.1f seconds", scrollSeconds, duration_s))
            }

            if let region = loopRegion {
                HStack {
                    Label(String(format: "Loop %.1f–%.1f s", region.start_s, region.end_s),
                          systemImage: "repeat")
                        .font(Token.Fonts.caption)
                    Spacer()
                    Button("Clear") {
                        loopRegion = nil
                        onLoopRegion?(0, 0)
                    }
                    .font(Token.Fonts.caption)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(Token.Spacing.s3)
        .background(Color.pnSurface, in: RoundedRectangle(cornerRadius: Token.Radius.card))
    }

    private var transposeCaption: String {
        let value = model.transposeSemitones
        if value == 0 { return "Reference as detected" }
        return "Display \(value > 0 ? "+" : "−")\(abs(value)) semitone\(abs(value) == 1 ? "" : "s") — audio unchanged"
    }

    // MARK: - Accessibility list (a Canvas is invisible to VoiceOver)

    private var detailsList: some View {
        let visible = model.visibleNotes
        return DisclosureGroup {
            if visible.isEmpty {
                Text("No notes in the visible parts.")
                    .font(Token.Fonts.caption)
                    .foregroundStyle(Color.pnTextSecondary)
            } else {
                VStack(alignment: .leading, spacing: Token.Spacing.s1) {
                    ForEach(visible) { note in
                        Button {
                            selectedNote = note
                            onSeek?(note.note.start_s)
                        } label: {
                            Text(model.accessibilityDescription(for: note))
                                .font(Token.Fonts.caption)
                                .foregroundStyle(Color.pnTextPrimary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } label: {
            Text("All notes (\(visible.count))")
                .font(Token.Fonts.caption)
                .fontWeight(.semibold)
        }
        .padding(Token.Spacing.s3)
        .background(Color.pnSurface, in: RoundedRectangle(cornerRadius: Token.Radius.card))
    }

    /// One-line summary of what is on screen (the canvas's VoiceOver value).
    private func accessibilitySummary(layout: PianoRollLayout) -> String {
        let visible = model.notes(inTimeRange: layout.visibleTimeRange)
        let parts = Set(visible.map(\.part)).sorted { $0.sortOrder < $1.sortOrder }
        let confirmed = visible.filter { $0.band == .confirmed }.count
        let unassigned = visible.filter { $0.band == .unassigned }.count
        let unison = visible.filter(\.isUnison).count
        var text = "\(visible.count) notes on screen from \(parts.map(\.displayName).joined(separator: ", "))."
        text += " \(confirmed) confirmed, \(unassigned) unassigned."
        if unison > 0 { text += " \(unison) in unison." }
        return text
    }
}

// MARK: - Note detail

/// The tap-note detail sheet (J-301 AC: midi, cents, confidence, time).
///
/// J-302 adds the CORRECTION actions: move the note to another part, split
/// it in two, or delete it. They record a correction in the user's overlay —
/// the engine's own track is never rewritten, and every correction can be
/// undone.
struct NoteDetailSheet: View {
    let note: PianoRollNote
    let model: PianoRollModel
    /// J-302: the user has already corrected this note.
    var isCorrected: Bool = false
    /// J-302: move the note to another part.
    var onMove: ((Part) -> Void)? = nil
    /// J-302: split the note in two at its midpoint. The argument is the
    /// SECOND part (C-11's `toParts` names two parts; the first half goes to
    /// the note's own part). Passing the note's own part splits it in place.
    var onSplit: ((Part) -> Void)? = nil
    /// J-302: delete the note.
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    /// The parts a note can be moved to (the singable ones, in C-1 order).
    private var moveTargets: [Part] {
        Part.allCases
            .filter { $0 != note.part }
            .filter { PartRangeChips.range(for: $0) != nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Pitch") {
                    field("Note", note.pitchLabel)
                    field("MIDI", "\(note.note.midi)")
                    field("Cents", note.note.cents_ref == 0
                          ? "0 (equal temperament)"
                          : "\(note.note.cents_ref) (+ = sharper)")
                }
                Section("Timing") {
                    field("Start", String(format: "%.3f s", note.note.start_s))
                    field("End", String(format: "%.3f s", note.note.end_s))
                    field("Length", String(format: "%.3f s", note.duration_s))
                    field("Phrase", "#\(note.phraseIndex)")
                }
                Section("Assignment") {
                    field("Part", model.partName(for: note.part))
                    field("Confidence", PianoRollModel.percentText(note.note.confidence))
                    field("Band", note.band.label)
                    Text(note.band.explanation)
                        .font(Token.Fonts.caption)
                        .foregroundStyle(Color.pnTextSecondary)
                    if isCorrected {
                        Label("You corrected this note.", systemImage: "checkmark.seal")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.pnAccent)
                    }
                }
                if onMove != nil || onSplit != nil || onDelete != nil {
                    Section {
                        if let onMove {
                            Menu {
                                ForEach(moveTargets, id: \.self) { target in
                                    Button(target.displayName) { onMove(target) }
                                }
                            } label: {
                                Label("Move to another part", systemImage: "arrow.left.arrow.right")
                            }
                        }
                        if let onSplit {
                            Menu {
                                Button {
                                    onSplit(note.part)
                                } label: {
                                    Label("Both halves in \(model.partName(for: note.part))",
                                          systemImage: "scissors")
                                }
                                if !moveTargets.isEmpty {
                                    Divider()
                                    ForEach(moveTargets, id: \.self) { target in
                                        Button {
                                            onSplit(target)
                                        } label: {
                                            Label("First half in \(model.partName(for: note.part)), second in \(target.displayName)",
                                                  systemImage: "scissors")
                                        }
                                    }
                                }
                            } label: {
                                Label("Split in two", systemImage: "scissors")
                            }
                            .accessibilityHint("Cuts the note in half. The first half stays in this part; choose where the second half goes.")
                        }
                        if let onDelete {
                            Button(role: .destructive) {
                                onDelete()
                            } label: {
                                Label("Delete this note", systemImage: "trash")
                            }
                        }
                    } header: {
                        Text("Correct it")
                    } footer: {
                        Text("Your corrections are saved with the song. The engine's own note tracks are never changed, so anything you do here can be undone.")
                    }
                }
                if note.isUnison {
                    Section {
                        Text("Another part sings this same pitch here. A unison passage cannot be isolated by pitch separation — the assignment below may be a guess.")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.pnTextSecondary)
                    } header: {
                        Label("Unison", systemImage: "waveform.badge.exclamationmark")
                            .foregroundStyle(Color.flat)
                    }
                }
                if !model.isPresent(part: note.part, phraseIndex: note.phraseIndex) {
                    Section {
                        Text("This part looks absent in this phrase (mean confidence \(PianoRollModel.percentText(model.presence(part: note.part, phraseIndex: note.phraseIndex)?.meanConfidence ?? 0))). It is dimmed, not hidden — check the assignment.")
                            .font(Token.Fonts.caption)
                            .foregroundStyle(Color.pnTextSecondary)
                    } header: {
                        Label("Part looks absent", systemImage: "eye.slash")
                            .foregroundStyle(Color.octaveWarn)
                    }
                }
            }
            .navigationTitle(model.partName(for: note.part))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func field(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
                .font(Token.Fonts.caption)
                .foregroundStyle(Color.pnTextSecondary)
            Spacer()
            Text(value)
                .font(Token.Fonts.numeric)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(value)")
    }
}
