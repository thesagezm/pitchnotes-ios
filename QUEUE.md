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

- Status: **OPEN** (opened 2026-11-20 UTC by Leto). **Leto lane: L-001…L-008 DONE —
  awaiting Paul (P-002/P-003; P-001 DONE) and Jess (J-001…J-004 REVIEW), then L-009
  merges M0. CI BRING-UP: leto→main merged early per D-16 (NOT the M0 gate) — build.yml
  now on default branch; agents rebase onto main to get CI on their pushes.**
- Gate (PLAN.md M0): L-001…L-009, P-001…P-003, J-001…J-004 DONE; `logic-tests` green;
  `build-ipa` green (IPA artifact, no `@rpath`); CONTRACTS v0.0 ratified; queue live;
  `m0` tagged; license baseline recorded.
- Device Demo M0: install IPA via LiveContainer → boots to 5 tabs → debug inspector
  shows mock bundle → airplane mode ON, app still boots. Human logs results here.
- CI this milestone: `logic-tests`, `build-ipa`; spike stubs `allow-failure` until
  models land (P-002 wires them).

## Paul (Paul edits ONLY this section)

- [P-003] TODO | Docs/ENGINE.md v0: model table (SwiftF0, NanoPitch, demucs.cpp, basicpitch.cpp, silero-vad) w/ versions/licenses/export plan/RTF targets; read ACappellaSet, PawCT, windowed-roformer, SwiftF0 papers; list open questions | branch:paul | dep:L-007 | ac:ENGINE.md committed; export plan per model; benchmark plan matches PLAN §0 targets | note:no code deps — claim FIRST (PLAN suggested order P-003→P-001→P-002); sources in Docs/RESEARCH.md
- [P-001] TODO | Engine/ skeleton: EngineAPI protocol + MockEngine (contract-valid fake PitchFrames/NoteTrack/bundle); scripts/fixtures/gen.py (seeded synthetic fixtures ≤1 MB: sweep, SATB mixture, click, silence, noise) | branch:paul | dep:L-006 | ac:fixtures regenerate byte-identically; MockEngine passes schema tests; J-002/J-101 consume immediately | note:implement EXACTLY CONTRACTS.md v0.0 (Part enum, SongBundle, EngineAPI); fixtures gitignored >1 MB — synthetic only
- [P-002] TODO | Tests/Spikes/ harness: assertion helpers (pitch 46.9–2093.75 Hz, confidence [0,1], finite, non-silence, shape); wire 5 CI spike stubs to harness with mock model | branch:paul | dep:L-004,P-001 | ac:spike harness runs on CI and passes with mock; ready for real models | note:stub jobs are allow-failure until P-002 lands; then Leto un-allow-failures at M1 (L-101)

## Jess (Jess edits ONLY this section)

- [J-003] DOING | Docs/UX.md v0 + learner ribbon wireframe spec: cents scale, tolerance band, note name, octave toggle, sharp/flat colors, voiced state; focus-mix + grading + theory/ear flow storyboards; content schema stub | branch:jess | dep:L-006 | ac:UX.md committed; ribbon spec complete enough for J-101 | note:no code deps — claim FIRST (PLAN suggested order J-003→J-001→J-002→J-004)
- [J-001] TODO | App/ shell v0: SwiftUI TabView (Learn, Library, Theory, Ear, Settings) placeholders, navigation, design tokens, dark mode, accessibility labels | branch:jess | dep:L-003 | ac:app boots to tabs in CI build; no crashes; VoiceOver labels present | note:Leto committed MINIMAL bootstrap source in App/Sources/PitchNotesApp.swift (one-file Text placeholder) purely so CI can produce an IPA — replace freely; target is `PitchNotesIOS` (PRODUCT_NAME `PitchNotes`), bundle id com.thesagezm.pitchnotes — keep or update project.yml
- [J-002] TODO | MockEngine integration + Library stub + debug bundle inspector: consume EngineAPI mock, fake song list, render parts/stems/notes placeholders | branch:jess | dep:P-001,L-006 | ac:mock bundle renders; contract mismatch fails logic test; UI never blocked on real engine | note:consume EngineAPI from CONTRACTS v0.0; MockEngine arrives with P-001
- [J-004] TODO | Tests/Logic/ harness: cents conversion, Part enum round-trip, manifest/NoteTrack/PitchFrame schema validation tests (red→green with P-001) | branch:jess | dep:P-001,L-006 | ac:logic-tests runs real tests (not placeholder); all green | note:Leto committed placeholder Tests/Logic/SmokeTests.swift for CI — replace it; job name is `logic-tests`

## Leto (Leto edits ONLY this section)

- [L-001] DONE | Repo init: private repo, branches main/paul/jess/leto, .gitignore, commit AGENTS.md + Docs/RESEARCH.md + README stub | branch:main | dep:— | ac:4 branches exist; AGENTS+RESEARCH committed; first push green | note:@cb653cd; visibility=private per human; branch protection BLOCKED(human) (GitHub Pro needed for private repos) — see BLOCKED
- [L-002] DONE | Seed coordination: PLAN.md verbatim @c043fc0; QUEUE.md seeded (all M0 rows); DECISIONS.md D1–D12 ruled + D-13 ORT pin + D-14 bootstrap exception | branch:main | dep:L-001 | ac:queue live; all M0 rows have owner/ac/deps; LOG seeded | note:M0 OPEN — Paul claim P-003, Jess claim J-003 immediately; work on your OWN branch (rebase onto origin/main first)
- [L-003] DONE | project.yml v0 (XcodeGen): app target PitchNotesIOS, iOS 16.0, SPM ORT mirror tag 1.24.2 (D-13), static-link flags, NSMicrophoneUsageDescription, no network entitlement, bundle id per D-3 | branch:leto | dep:L-001 | build:https://github.com/thesagezm/pitchnotes-ios/actions/runs/44840402693@f06860f | ac:xcodegen generate succeeds on CI; ORT resolves; no dynamic framework refs | ac-met 2× green runs. @ba3182a. HANDOFF: project.yml + bootstrap App/Sources/PitchNotesApp.swift + Tests/Logic SPM package (PitchLogic placeholder) + Scripts/package-ipa.sh; Jess replaces app source in J-001 and Tests/Logic tests in J-004; target name PitchNotesIOS, PRODUCT_NAME PitchNotes, bundle id com.thesagezm.pitchnotes
- [L-004] DONE | .github/workflows/build.yml v0: triggers push main + paul/jess/leto (path-filtered) + workflow_dispatch; jobs logic-tests, build-ipa (static patch, unsigned, no-@rpath check, dist/PitchNotesIOS.ipa), 5 spike stubs allow-failure | branch:leto | dep:L-003 | build:https://github.com/thesagezm/pitchnotes-ios/actions/runs/44840402693@f06860f | ac:dispatch on leto yields IPA artifact; @rpath check passes; artifact downloadable | ac-met: all 7 jobs green; PitchNotesIOS IPA artifact 7.19 MB downloadable (run 44840402693); dispatch run 44840966586 confirms dispatch path. @e8b325e+fixes 024f355/f06860f (YAML colon-in-scalar; private-repo raw 404 → file:// + http-probe). HANDOFF: P-002 wires the 5 named stub jobs to Tests/Spikes; spike names are FROZEN for merge gates
- [L-005] DONE | Models/manifest.json schema {name,version,url,sha256,size,license,runtime,io} + scripts/models/download.py (SHA256 verify + cache); CI downloads+verifies committed 1 KB test blob (D-2 placeholder until HF repo exists) | branch:leto | dep:L-001 | build:https://github.com/thesagezm/pitchnotes-ios/actions/runs/44840402693@f06860f | ac:schema ratified; CI downloads+verifies test blob; manifest validated | ac-met: CI validated manifest + verified test-blob (file://) AND http-probe (real HTTP+SHA256 over network). @b5504ad/f06860f. HANDOFF: P-101+ add real model entries to Models/manifest.json (url → HF repo once D-2 unblocks); download.py prints cached path, exit codes 1-4 documented in docstring
- [L-006] DONE | CONTRACTS.md v0.0: Part enum exact raw values; SongBundle + song.json/NoteTrack/PitchFrame JSON schemas; EngineAPI protocol; MockEngine requirement; UltraStar semantics; contractVersion | branch:leto | dep:L-002 | ac:v0.0 ratified; Paul+Jess ack in LOG; schema unit tests land via J-004 | ac-met: v0.0 ratified @66cf24c. ARBITER RULING: ratification is complete; the "Paul+Jess ack" is an OBLIGATION ON PAUL/JESS — first queue LOG line of your first session must ack CONTRACTS v0.0. HANDOFF: P-001 implements C-1/C-2/C-3 exactly; J-004 tests the V1–V13 rules; C-5 formulas deferred to v1.2 (L-401)
- [L-007] DONE | License audit baseline in DECISIONS.md: ship-safe vs study-only lists (AGENTS §9); verify-before-use tasks pinned (NanoPitch→P-102, soundfont→L-501, RMVPE→X-601) | branch:leto | dep:L-001 | ac:baseline recorded; zero unknown-license deps in project.yml/vendor | ac-met: D-15 committed @3637583; project.yml deps = ORT mirror (MIT) + PitchLogic (in-house); vendor/ empty. HANDOFF: P-003 UNBLOCKED; new deps enter only via queue task + Leto ruling (D-15 procedure)
- [L-008] DONE | vendor/README.md intake process: permissive C/C++ only, license file + version pin + patches log; reference demucs.cpp/basicpitch.cpp/TinySoundFont intake | branch:leto | dep:L-007 | ac:process committed; P-201/P-301/P-501 reference it | ac-met: vendor/README.md committed @3637583 (intake checklist, 7-field record template, update procedure, reference-intake table). HANDOFF: P-201/P-301/P-501 queue rows MUST reference vendor/README.md when Leto seeds M2/M3/M5
- [L-009] TODO | M0 merge dry-run + real: review gate, merge leto/paul/jess→main, tag m0, LOG MERGED, open M1, seed M1 queue | branch:leto | dep:all M0 | ac:m0 tag exists; all agents rebase per AGENTS §3; M1 queue live | note:DO NOT START — waits for Paul P-001..P-003 and Jess J-001..J-004 DONE

## BLOCKED / DECISIONS PENDING (anyone appends; Leto resolves)

- **BLOCKED(human)** — `main` branch protection: GitHub requires GitHub Pro (or public repo) for protected branches on private repos; API returned 403. Options for the human: (a) upgrade GitHub Pro, (b) make repo public, (c) accept procedural rails (AGENTS §3/§11) for M0. Leto proceeded with (c). [L-001 residue, 2026-11-20]
- **BLOCKED(human)** — create Hugging Face repo `thesagezm/pitchnotes-models` (public) per D-2. Unblocks real model URLs in `Models/manifest.json` + M1 model uploads. CI meanwhile uses the committed 1 KB test blob (L-005). [D-2, 2026-11-20]

## LOG (append-only, everyone; newest at TOP)

- 2026-11-21T02:20Z leto: **D-16 RULED + CI BRING-UP MERGE leto→main** (not the M0 gate — L-009 unchanged). Fix for the CI reachability gap Jess flagged (J-001/J-002/J-004 build:NOT-TRIGGERED): build.yml now on default branch. **PAUL + JESS: `git fetch && git rebase origin main` NOW** — then your pushes trigger CI and `gh workflow run build.yml --ref <your-branch>` works. X-rulings: **X-002 STRUCK** (satisfied by P-001 MockScenario — exact proposed set, no frozen surface touched); **X-001 ROUTED → L-102** (contract v0.1 additive; UX.md §3.6 table is interim source of truth, J-101 may build against it now); **X-003 ACCEPTED, executes at L-009 by Leto** (project.yml `EngineCore: {path: Engine}` + app dep + `cd Engine && swift test` in logic-tests; Jess's Tests/Logic edit + swap sequence runs on HER branch post-merge). **SmokeTests.swift re-routed: Jess deletes it on her branch post-rebase** (Tests/Logic is her lane; file will exist in her tree after rebase — deletion by leto first would break CI with zero test sources). Paul: P-001 ack noted — L-006 ack obligation satisfied by both lanes (Jess's deep C-1/V-rules usage in LOG counts). Gate remaining: P-002 (DOING), P-003 (TODO), Jess REVIEW→DONE at my gate review, device demo.

- 2026-11-21T00:20Z jess: claimed J-003 (bootstrapped: rebase jess→origin/main ddb859e done; read AGENTS/PLAN/QUEUE/CONTRACTS v0.0 from origin/leto @cec3789 + project.yml + RESEARCH). Working in dedicated clone /home/sagestation/code/pitchnotes-jess to avoid disturbing paul's checkout. Will ack CONTRACTS v0.0 when implementing against it (J-002/J-004).
- 2026-11-21T00:05Z leto: dispatch run 44840966586 SUCCESS (50s) — **PitchNotesIOS.ipa artifact downloadable via workflow_dispatch**, @rpath gate green. L-004 AC fully met on both trigger paths. Leto M0 session ends here; next Leto session = L-009 (M0 merge) once Paul P-001…P-003 and Jess J-001…J-004 are DONE.
- 2026-11-21T00:02Z leto: **L-003…L-008 DONE** — Leto M0 lane complete. Run 44840402693 ALL GREEN (7 jobs): logic-tests (manifest validate + http-probe HTTP/SHA256 + PitchLogic), build-ipa (IPA artifact **7.19 MB**, no @rpath), 5 spike stubs. Dispatch run 44840966586 fired to confirm the workflow_dispatch path. **READY FOR PAUL: P-003 → P-001 → P-002. READY FOR JESS: J-003 → J-001 → (J-002/J-004 after P-001 lands).** Both agents: rebase onto origin/main FIRST (`git fetch && git rebase origin main` on your branch), then claim via DOING + LOG + tiny queue commit. First LOG line = ack CONTRACTS v0.0 (L-006 obligation).
- 2026-11-20T23:57Z leto: CI triage on leto: run 44840060323 → **build-ipa GREEN** (xcodegen+ORT resolve+unsigned archive+no-@rpath) + 5 spike stubs GREEN; logic-tests red (test-blob raw.githubusercontent 404s on PRIVATE repos) → fixed @f06860f (file:// blob + public http-probe manifest entry), run 44840402693 pending. Also: paul/jess/leto branches were cut BEFORE the governance seed — rebased leto onto origin/main (force-with-lease). PAUL/JESS: `git fetch && git rebase origin/main` on your branch before claiming, or you won't have PLAN/QUEUE/DECISIONS.
- 2026-11-20T23:55Z leto: claimed L-006 (CONTRACTS v0.0). L-003/L-004/L-005 pushed on leto → CI runs recorded on rows, BUILD_PENDING. First run 44839742341 failed 0s (YAML: colon inside stub echo plain scalar) — fixed, re-pushed. Fire-and-continue per §5.
- 2026-11-20T23:44Z leto: opened M0 — seeded QUEUE (L-002 DONE); ruled D1–D12 + D-13 (ORT pin 1.24.2) + D-14 (bootstrap-to-main exception) in DECISIONS.md; PLAN.md committed verbatim @c043fc0. PAUL: claim P-003 first. JESS: claim J-003 first. Work on your own branch, rebase onto origin/main first.
- 2026-11-20T23:42Z leto: L-001 DONE — repo created (private per human), branches main/paul/jess/leto pushed, AGENTS.md + Docs/RESEARCH.md + README + .gitignore @cb653cd. Branch protection BLOCKED(human) (403: GitHub Pro required for private repos).
