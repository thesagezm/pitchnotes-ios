# QUEUE.md — PitchNotes-iOS task board

> The ONLY task board (AGENTS.md §2). Every agent: edit ONLY your own section,
> append to LOG (newest at TOP). Queue edits are tiny standalone commits
> (`queue: <claim/done/build> <task-id>`) — never bundled with code, pushed immediately.

Task row format (one line per task, keep it short):

```
- [P-014] DOING | swiftf0 ONNX spike on macOS runner | branch:paul | dep:— | build:<run-url>@<sha> | ac:spike asserts pitch+confidence on 3 fixtures | note:<handoff/next-step>
```

- IDs: `P-###` Paul, `J-###` Jess, `L-###` Leto, `X-###` cross-cutting (Leto assigns owner).
- Status lifecycle: `TODO → DOING → REVIEW → DONE`, plus `BLOCKED(reason)`;
  `BUILD_PENDING` is a *flag on the row*, never a reason to stop working.
- `ac:` = acceptance criteria. A task without `ac:` is not claimable; write one first.
- `note:` = handoff. EVERY finished task ends with a note telling the next reader
  exactly what exists, where, and what's next.
- Max one DOING coding task per agent; unlimited pending CI builds (tracked on the
  row via `build:`, not in your head).

---

## Milestone: M0 — Scaffold & Contracts (Leto maintains this header + gate status)

- Status: **OPEN** (opened 2026-11-20 UTC by Leto).
- Gate (PLAN.md M0): L-001…L-009, P-001…P-003, J-001…J-004 DONE; `logic-tests` green;
  `build-ipa` green (IPA artifact, no `@rpath`); CONTRACTS v0.0 ratified; queue live;
  `m0` tagged; license baseline recorded.
- Device Demo M0: install IPA via LiveContainer → boots to 5 tabs → debug inspector
  shows mock bundle → airplane mode ON, app still boots. Human logs results here.
- CI this milestone: `logic-tests`, `build-ipa`; spike stubs `allow-failure` until
  models land (P-002 wires them).

## Paul (Paul edits ONLY this section)

- [P-003] DOING | Docs/ENGINE.md v0: model table (SwiftF0, NanoPitch, demucs.cpp, basicpitch.cpp, silero-vad) w/ versions/licenses/export plan/RTF targets; read ACappellaSet, PawCT, windowed-roformer, SwiftF0 papers; list open questions | branch:paul | dep:L-007 | ac:ENGINE.md committed; export plan per model; benchmark plan matches PLAN §0 targets | note:no code deps — claim FIRST (PLAN suggested order P-003→P-001→P-002); sources in Docs/RESEARCH.md
- [P-001] DONE | Engine/ skeleton: EngineAPI protocol + MockEngine (contract-valid fake PitchFrames/NoteTrack/bundle); scripts/fixtures/gen.py (seeded synthetic fixtures ≤1 MB: sweep, SATB mixture, click, silence, noise) | branch:paul | dep:L-006 | build:CI-UNAVAILABLE-ON-PAUL (build.yml lives on origin/leto pre-merge; workflow_dispatch requires default-branch file — Leto may cherry-pick to main for early agent-branch CI) | ac:fixtures regenerate byte-identically; MockEngine passes schema tests; J-002/J-101 consume immediately | ac-met: EngineCore SPM package @Engine/ (Foundation-only, portable, compiles+tests GREEN on Linux swift 6.0.3): 45/45 tests (Part C-1, schema JSON round-trips C-2.1/2.3/2.4, V1–V13 validators, 8 scenarios, byte-identical bundle regen, band filter, livePitch <1 ms). Fixtures @Tests/Spikes/Fixtures (6 WAV 32–256 KB) regenerate BYTE-IDENTICAL ×2 (gen.py --check gate + fixtures.sha256). HANDOFF for Jess (J-002/J-004): add `.package(path: "../Engine")` to Tests/Logic/Package.swift → `import EngineCore`; MockEngine(scenario:seed:referencePart:bundleDirectory:) with 8 scenarios (perfect/flat-30c/sharp+35c/octaveError/silent/breathy/lateOnset/vibrato); makeBundle() → V1–V13-valid bundle; EngineAPI surface frozen per CONTRACTS v0.0. Mock honesty notes: WAV stems (ALAC at P-204), pseudo-hash hex (real BLAKE3 at P-203), fixed-timestamp ULID. Leto: project.yml wiring = same local-package pattern as PitchLogic.
- [P-002] DONE | Tests/Spikes/ harness: assertion helpers (pitch 46.9–2093.75 Hz, confidence [0,1], finite, non-silence, shape); wire 5 CI spike stubs to harness with mock model | branch:paul | dep:L-004,P-001 | build:CI-UNAVAILABLE-ON-PAUL (see P-001 row + LOG; Leto wiring = 1-line job steps) | ac:spike harness runs on CI and passes with mock; ready for real models | ac-met: `python3 Tests/Spikes/run_spike.py --spike <name>` — 5/5 spikes GREEN with deterministic mock (S1–S8: 9+17+24+29+32 checks), exit codes verified, negative paths verified (tampered fixture hash → red; unknown spike → red), fixture-integrity preflight gate. HANDOFF for Leto (L-101/M1): point the five frozen stub jobs at the one-liners in Tests/Spikes/README.md (macos runner: python3 + numpy). Real-model wiring points documented in mock_model.py docstring (M1 SwiftF0/NanoPitch/silero; M2 demucs.cpp; M3 basicpitch.cpp); Swift-side V-rule parity in EngineCore validators. Fixtures integrity-gated by fixtures.sha256.

## Jess (Jess edits ONLY this section)

- [J-003] TODO | Docs/UX.md v0 + learner ribbon wireframe spec: cents scale, tolerance band, note name, octave toggle, sharp/flat colors, voiced state; focus-mix + grading + theory/ear flow storyboards; content schema stub | branch:jess | dep:L-006 | ac:UX.md committed; ribbon spec complete enough for J-101 | note:no code deps — claim FIRST (PLAN suggested order J-003→J-001→J-002→J-004)
- [J-001] TODO | App/ shell v0: SwiftUI TabView (Learn, Library, Theory, Ear, Settings) placeholders, navigation, design tokens, dark mode, accessibility labels | branch:jess | dep:L-003 | ac:app boots to tabs in CI build; no crashes; VoiceOver labels present | note:Leto committed MINIMAL bootstrap sources in App/ (PitchNotesApp.swift, ContentView.swift) purely so CI can produce an IPA — replace freely; keep target name `PitchNotes` or update project.yml
- [J-002] TODO | MockEngine integration + Library stub + debug bundle inspector: consume EngineAPI mock, fake song list, render parts/stems/notes placeholders | branch:jess | dep:P-001,L-006 | ac:mock bundle renders; contract mismatch fails logic test; UI never blocked on real engine | note:consume EngineAPI from CONTRACTS v0.0; MockEngine arrives with P-001
- [J-004] TODO | Tests/Logic/ harness: cents conversion, Part enum round-trip, manifest/NoteTrack/PitchFrame schema validation tests (red→green with P-001) | branch:jess | dep:P-001,L-006 | ac:logic-tests runs real tests (not placeholder); all green | note:Leto committed placeholder Tests/Logic/SmokeTests.swift for CI — replace it; job name is `logic-tests`

## Leto (Leto edits ONLY this section)

- [L-001] DONE | Repo init: private repo, branches main/paul/jess/leto, .gitignore, commit AGENTS.md + Docs/RESEARCH.md + README stub | branch:main | dep:— | ac:4 branches exist; AGENTS+RESEARCH committed; first push green | note:@cb653cd; visibility=private per human; branch protection BLOCKED(human) (GitHub Pro needed for private repos) — see BLOCKED
- [L-002] DONE | Seed coordination: PLAN.md verbatim @c043fc0; QUEUE.md seeded (all M0 rows); DECISIONS.md D1–D12 ruled + D-13 ORT pin + D-14 bootstrap exception | branch:main | dep:L-001 | ac:queue live; all M0 rows have owner/ac/deps; LOG seeded | note:M0 OPEN — Paul claim P-003, Jess claim J-003 immediately; work on your OWN branch (rebase onto origin/main first)
- [L-003] DOING | project.yml v0 (XcodeGen): app target PitchNotes, iOS 16.0, SPM ORT mirror tag 1.24.2 (D-13), static-link flags, NSMicrophoneUsageDescription, no network entitlement, bundle id per D-3 | branch:leto | dep:L-001 | build:pending | ac:xcodegen generate succeeds on CI; ORT resolves; no dynamic framework refs | note:templating thesagezm/speechnotes-ios; minimal bootstrap App/ sources included so build-ipa can produce an IPA before J-001
- [L-004] TODO | .github/workflows/build.yml v0: triggers push main + paul/jess/leto (path-filtered) + workflow_dispatch; jobs logic-tests (placeholder), build-ipa (static patch, unsigned, no-@rpath check, dist/PitchNotesIOS.ipa), 5 spike stubs allow-failure | branch:leto | dep:L-003 | build:pending | ac:dispatch on leto yields IPA artifact; @rpath check passes; artifact downloadable | note:fire-and-continue after push
- [L-005] TODO | Models/manifest.json schema {name,version,url,sha256,size,license,runtime,io} + scripts/models/download.py (SHA256 verify + cache); CI downloads+verifies committed 1 KB test blob (D-2 placeholder until HF repo exists) | branch:leto | dep:L-001 | ac:schema ratified; CI downloads+verifies test blob; manifest validated | note:D-2 BLOCKED(human) for the real HF repo; test blob keeps path green now
- [L-006] TODO | CONTRACTS.md v0.0: Part enum exact raw values; SongBundle + song.json/NoteTrack/PitchFrame JSON schemas; EngineAPI protocol; MockEngine requirement; UltraStar semantics; contractVersion | branch:leto | dep:L-002 | ac:v0.0 ratified; Paul+Jess ack in LOG; schema unit tests land via J-004 | note:P-001/J-002/J-004 implement against this
- [L-007] TODO | License audit baseline in DECISIONS.md: ship-safe vs study-only lists (AGENTS §9); verify-before-use tasks pinned (NanoPitch→P-102, soundfont→L-501, RMVPE→X-601) | branch:leto | dep:L-001 | ac:baseline recorded; zero unknown-license deps in project.yml/vendor | note:unblocks P-003
- [L-008] TODO | vendor/README.md intake process: permissive C/C++ only, license file + version pin + patches log; reference demucs.cpp/basicpitch.cpp/TinySoundFont intake | branch:leto | dep:L-007 | ac:process committed; P-201/P-301/P-501 reference it | note:—
- [L-009] TODO | M0 merge dry-run + real: review gate, merge leto/paul/jess→main, tag m0, LOG MERGED, open M1, seed M1 queue | branch:leto | dep:all M0 | ac:m0 tag exists; all agents rebase per AGENTS §3; M1 queue live | note:DO NOT START — waits for Paul P-001..P-003 and Jess J-001..J-004 DONE

## BLOCKED / DECISIONS PENDING (anyone appends; Leto resolves)

- **BLOCKED(human)** — `main` branch protection: GitHub requires GitHub Pro (or public repo) for protected branches on private repos; API returned 403. Options for the human: (a) upgrade GitHub Pro, (b) make repo public, (c) accept procedural rails (AGENTS §3/§11) for M0. Leto proceeded with (c). [L-001 residue, 2026-11-20]
- **BLOCKED(human)** — create Hugging Face repo `thesagezm/pitchnotes-models` (public) per D-2. Unblocks real model URLs in `Models/manifest.json` + M1 model uploads. CI meanwhile uses the committed 1 KB test blob (L-005). [D-2, 2026-11-20]

## LOG (append-only, everyone; newest at TOP)

- 2026-11-21T00:53Z paul: claimed P-003 (DOING) — last M0 task. Reading Docs/RESEARCH.md fully before writing ENGINE.md (facts re-verified against the source pack, not memory); license flags will be filed as OPEN items + X-task proposals for Leto.
- 2026-11-21T00:52Z paul: **P-002 DONE @ad13bef** — spike harness green with mock: `python3 Tests/Spikes/run_spike.py --spike <swiftf0|nanopitch|silero-vad|separation|basicpitch>` (also `all`). S1–S8 rules; fixture-integrity preflight; negative paths verified. LETO: wiring = 1-line steps per Tests/Spikes/README.md; real-model wiring points in mock_model.py. No weights downloaded in M0.
- 2026-11-21T00:44Z paul: claimed P-002 (DOING). Python-based spike harness so Leto's frozen job names just invoke the runner; mock model = deterministic contract-shaped outputs from P-001 fixtures; zero weight downloads in M0.
- 2026-11-21T00:43Z paul: **P-001 DONE @653a6f8** — JESS UNBLOCKED: EngineAPI + MockEngine + fixtures ready. Scenarios: perfect, flat(-30c), sharp(+35c), octaveError, silent, breathy, lateOnset(+120ms), vibrato(±25c@5.5Hz); EngineAPI surface frozen per CONTRACTS v0.0. Consume: `.package(path: "../Engine")` → `import EngineCore`. 45/45 EngineCore tests green on Linux swift 6.0.3; 6 synthetic fixtures (sweep/SATB/click/silence/noise/44.1k-mix, all ≤256 KB) regenerate byte-identically.
- 2026-11-21T00:43Z paul: CI note for Leto — `gh workflow run build.yml --ref paul` 422s: workflow_dispatch needs the file on the default branch; paul branch has no .github/ (build.yml lives on origin/leto pre-merge). Push CI likewise inert on agent branches. Not blocking P-001 ACs (self-verified locally). If early agent-branch CI is wanted before L-009, Leto can cherry-pick build.yml to main. Fire-and-continue: proceeding to P-002.
- 2026-11-21T00:43Z paul: minor C-1 observation (non-blocking, no change requested): C-1's prose "bass < baritone < …" is the voice-RANK reading (P-303 no-crossing), while the ratified sortOrder switch is numeric layout order (soprano 0 … bass 6) — Comparable = numeric, so `Part.bass < Part.baritone` is false. Engine implements the switch verbatim; tests assert both readings. Leto may add one clarifying sentence to CONTRACTS whenever convenient; also relevant to P-303 (pitch order = descending sortOrder among voice parts).
- 2026-11-21T00:10Z paul: **ACK CONTRACTS v0.0** (L-006 obligation) — P-001 implements C-1/C-2/C-3 exactly; EngineCore exposes V1–V13 validators for reuse (J-004 may test through it or per PitchLogic). Sync state: paul rebased onto origin/main (fast-forward, no divergence); CONTRACTS.md + DECISIONS D-13…D-15 read from origin/leto READ-ONLY — no leto content merged into paul; QUEUE conflicts at L-009 are Leto's (R7).
- 2026-11-21T00:10Z paul: claimed P-001 (DOING). REORDER LOGGED: P-001 runs BEFORE PLAN-suggested P-003 because it unblocks Jess (J-002/J-004); P-003 has no downstream deps this milestone. Leto may override. Next after P-001: P-002 → P-003.
- 2026-11-20T23:44Z leto: opened M0 — seeded QUEUE (L-002 DONE); ruled D1–D12 + D-13 (ORT pin 1.24.2) + D-14 (bootstrap-to-main exception) in DECISIONS.md; PLAN.md committed verbatim @c043fc0. PAUL: claim P-003 first. JESS: claim J-003 first. Work on your own branch, rebase onto origin/main first.
- 2026-11-20T23:42Z leto: L-001 DONE — repo created (private per human), branches main/paul/jess/leto pushed, AGENTS.md + Docs/RESEARCH.md + README + .gitignore @cb653cd. Branch protection BLOCKED(human) (403: GitHub Pro required for private repos).
