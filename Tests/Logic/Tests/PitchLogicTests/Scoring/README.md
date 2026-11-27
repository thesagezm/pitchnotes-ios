# Scoring/ — the M4 scoring suite's home (J-401)

**This directory is the CI contract for the M4 scoring gate (L-402).** J-401's
pure-Swift scoring engine tests live HERE — `Scoring*.swift` files in this
directory — so the `logic-tests` job's scoring-suite gate can find them by
path.

- **The gate:** the `logic-tests` workflow step
  (`M4 scoring-suite gate`) asserts `>= 30` `func test` declarations in
  `Scoring/*.swift` (J-401's AC: ≥30 unit tests — silence, octave error,
  vibrato, late onset, breath, the D-22 detuned-recording case, determinism,
  the closer-pitch property test). UNTIL J-401 lands the step is RED BY
  DESIGN and `continue-on-error` keeps the job green (the L-302/L-304
  precedent); it **flips to BLOCKING at the M4 close (L-403)**.
- **Fixtures:** the synthetic session fixtures the scoring tests consume are
  committed at `Tests/Sessions/fixtures/*.json` (11 scenarios; generator +
  integrity gate `Tests/Sessions/gen_session_fixtures.py --check`, ALWAYS
  blocking). Read them from tests via `#filePath`-relative paths (the
  ImportKit fixture pattern) — no Package.swift resource declaration needed.
  The fixtures carry DATA invariants (checked in CI) and contract pins
  (`contractPins`), deliberately NOT expected hit/miss verdicts — computing
  those is what the grader under test does.
- **Contract:** CONTRACTS v1.2 (D-58) — C-18 `SessionResult`, C-19
  `GradingConfig`, C-20 transposition/tempo/latency, C-17's adoption gate;
  the D-54 policy (confidence is REPORTED, never a weight; UNASSIGNED
  excluded VISIBLY; steady/transition reported separately).
- **Ruled:** D-55 (GRDB), D-57 (sequencing), D-54/D-58 (this suite's policy).

Jess owns the test files in this directory (AGENTS §12: Tests/Logic is the
Jess lane); the gate step and the fixtures are Leto's (L-402).
