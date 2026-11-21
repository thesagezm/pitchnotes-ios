// PitchLogic — pure-Swift logic core shared by the app and CI logic-tests.
// M0 placeholder: Jess populates the real modules in J-004 (cents conversion,
// Part enum round-trip, manifest/NoteTrack/PitchFrame schema validation) and
// later milestones (scoring J-401, UltraStar J-303, theory J-501).
// CONTRACTS.md v0.0 is the schema source of truth.

public enum PitchLogicInfo {
    /// Logic-core version, independent of the app version.
    public static let version = "0.0.1"
    /// CONTRACTS.md version this core validates against.
    public static let contractVersion = "v0.0"
}
