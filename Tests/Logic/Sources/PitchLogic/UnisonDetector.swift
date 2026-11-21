// UnisonDetector — UX §3.7 bleed-awareness (binding product rule): when ≥ 2
// parts' reference notes overlap in time AND pitch, that passage cannot be
// isolated by pitch separation. Published evidence (Docs/RESEARCH.md §8):
// ACappellaSet fine-tuned HTDemucs NSDR 4.05–10.50 dB, part-aware note F1
// ≈ 0.225. The UI surfaces unison honestly (chip / badge) instead of implying
// isolation — AGENTS §11: "design for bleed, honesty about accuracy is a
// product requirement".
//
// Purity: absolute cents position = midi·100 + cents_ref (C-2.3 semantics —
// cents_ref is the note center's deviation from equal temperament). Two notes
// are unison-risk when their time ranges overlap AND their absolute cents
// positions differ by ≤ 100 (a semitone-adjacent overlap still bleeds; the
// badge is deliberately conservative).
//
// Restored from the deleted M0 StubEngine (X-006) as a tested PitchLogic unit.

import Foundation
import EngineCore

/// One detected unison-risk pair, ordered by C-1 `sortOrder` (UI/display order).
public struct UnisonPair: Equatable, Sendable {
    /// Lower `sortOrder` part (e.g. T1 before T2 in display order).
    public let first: Part
    public let second: Part

    public init(first: Part, second: Part) {
        self.first = first
        self.second = second
    }
}

public enum UnisonDetector {

    /// Absolute cents position of a note (midi·100 + cents_ref, C-2.3).
    static func absoluteCents(_ note: Note) -> Double {
        Double(note.midi) * 100 + Double(note.cents_ref)
    }

    /// Parts whose reference notes overlap in time AND pitch (|Δcents| ≤ 100).
    /// Returns pairs sorted by `first` then `second` sortOrder; no duplicates;
    /// parts without a track (or with empty tracks) are ignored.
    public static func pairs(in tracks: [Part: NoteTrack]) -> [UnisonPair] {
        let singable = tracks
            .filter { $0.key.isSingableVoice && !$0.value.notes.isEmpty }
            .sorted { $0.key.sortOrder < $1.key.sortOrder }

        var out: [UnisonPair] = []
        for i in singable.indices {
            for j in (i + 1)..<singable.count {
                let a = singable[i], b = singable[j]
                let overlaps = a.value.notes.contains { noteA in
                    b.value.notes.contains { noteB in
                        noteA.start_s < noteB.end_s && noteB.start_s < noteA.end_s
                            && abs(absoluteCents(noteA) - absoluteCents(noteB)) <= 100
                    }
                }
                if overlaps {
                    out.append(UnisonPair(first: a.key, second: b.key))
                }
            }
        }
        return out
    }

    /// "T1 ↔ T2" display label (UX §3.7 chip text).
    public static func label(for pair: UnisonPair) -> String {
        "\(pair.first.displayName) ↔ \(pair.second.displayName)"
    }
}
