// PartRangeChips — the UI display layer over the C-6.1 part range presets.
//
// CONTRACT SOURCE OF TRUTH = EngineCore.PartRangePresets (P-105, CONTRACTS v0.1
// C-6.1 verbatim). This file owns NO contract values: every row DERIVES from
// the EngineCore table, adding only the UI conveniences J-101 consumes — chip
// labels ("Bass E2–G3", UX §3.6), C-1 display order for the chip row, and the
// follow-window center in absolute cents (UX §3.3 initial center).
//
// Named …Chips (not …Presets) on purpose: EngineCore already exports
// `EngineCore.PartRangePresets`, and App files import both modules — a same-named type
// here would be ambiguous at every use site.
//
// The verbatim C-6.1 doc-value test (RibbonMappingTests.testC61TableVerbatim
// + testC61HzValuesMatchContractRounding) now pins THE ENGINECORE TABLE through
// this adapter, so drift in Paul's table is still caught by Jess's suite.
//
// Calibration (C-6.1): per-part nudge −2…+2 / mic-profile offset are USER-LOCAL
// (J-405, M4) applied via EngineCore.PartRangePresets.calibratedBand — presets
// here stay fixed contract data. Persistence arrives with J-405.

import Foundation
import EngineCore

/// UI row for one C-6.1 preset: derived from EngineCore's contract table.
public struct PartRange: Equatable, Sendable {
    public let part: Part
    /// Contract preset label, e.g. "E2–G3" (en dash, verbatim C-6.1).
    public let presetName: String
    public let midiLow: Int
    public let midiHigh: Int
    /// Contract Hz bounds (EngineCore rounds to 0.1 per C-6.1).
    public let hzLow: Double
    public let hzHigh: Double

    /// Derives the display row from the EngineCore contract preset.
    public init(from preset: EngineCore.PartRangePreset) {
        self.part = preset.part
        self.presetName = preset.presetName
        self.midiLow = preset.midiLow
        self.midiHigh = preset.midiHigh
        self.hzLow = preset.fmin
        self.hzHigh = preset.fmax
    }

    /// Chip label: "Bass E2–G3" (UX §3.6).
    public var displayName: String { "\(part.displayName) \(presetName)" }

    /// Center of the range in absolute cents — initial follow-window center
    /// when no reference note is active (UX §3.3).
    public var centerCents: Double {
        (Double(midiLow) + Double(midiHigh)) / 2 * 100
    }
}

public enum PartRangeChips {

    // MARK: Per-part rows (derived — EngineCore.PartRangePresets is the source)

    public static var bass:      PartRange { PartRange(from: EngineCore.PartRangePresets.all[.bass]!) }
    public static var baritone:  PartRange { PartRange(from: EngineCore.PartRangePresets.all[.baritone]!) }
    public static var baritenor: PartRange { PartRange(from: EngineCore.PartRangePresets.all[.baritenor]!) }
    public static var t2:        PartRange { PartRange(from: EngineCore.PartRangePresets.all[.t2]!) }
    public static var t1:        PartRange { PartRange(from: EngineCore.PartRangePresets.all[.t1]!) }
    public static var soprano:   PartRange { PartRange(from: EngineCore.PartRangePresets.all[.soprano]!) }
    public static var alto:      PartRange { PartRange(from: EngineCore.PartRangePresets.all[.alto]!) }

    /// All ratified presets, C-1 display order (soprano … bass per sortOrder —
    /// UI sorts chips per C-1; SOPRANO/ALTO only surface for female chorales).
    public static let all: [PartRange] = [soprano, alto, t1, t2, baritenor, baritone, bass]

    /// Preset for a part, or nil for structural markers (VP/LEAD/INSTRUMENTAL
    /// have no C-6.1 row — they are not graded singing parts).
    public static func range(for part: Part) -> PartRange? {
        EngineCore.PartRangePresets.preset(for: part).map(PartRange.init(from:))
    }
}
