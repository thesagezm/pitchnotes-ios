// NoteTrackQuery — read-only lookups over a C-2.3 NoteTrack. V8 guarantees
// notes are sorted by start_s and non-overlapping within a part, so binary
// search is valid. Used by the ribbon (J-101) for the active reference note
// and the visible reference-bar window.

import Foundation
import EngineCore

public enum NoteTrackQuery {

    /// The note active at time `t` (start_s ≤ t < end_s), or nil in a gap/rest.
    /// Binary search over the V8-sorted track.
    public static func currentNote(in track: NoteTrack, at t: Double) -> Note? {
        var lo = 0
        var hi = track.notes.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let note = track.notes[mid]
            if t < note.start_s {
                hi = mid - 1
            } else if t >= note.end_s {
                lo = mid + 1
            } else {
                return note
            }
        }
        return nil
    }

    /// Notes intersecting the window [from, to) — the ribbon's reference-bar
    /// window (UX §3.2: 3 s history, 7 s look-ahead). Linear scan is fine at
    /// NoteTrack scales (hundreds of notes); notes are returned in track order.
    public static func notes(in track: NoteTrack, from: Double, to: Double) -> [Note] {
        track.notes.filter { $0.start_s < to && from < $0.end_s }
    }
}
