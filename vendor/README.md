# vendor/ — third-party intake (L-008)

Vendored permissive C/C++ sources only. This directory is how external C/C++ code
(demucs.cpp, basicpitch.cpp, TinySoundFont, sevagh/pitch-detection, …) enters the
repo. **Intake owner: Leto** (this dir is Leto-owned per AGENTS §12); Paul proposes
intake via a queue task, Leto commits it.

## Hard rules (AGENTS §9 / DECISIONS D-15)

1. **Permissive licenses only:** MIT, Apache-2.0, BSD-2/3, Zlib. GPL/LGPL/AGPL code
   is NEVER vendored or linked (STUDY-ONLY list in D-15). Unknown license = not
   shipped.
2. **No git submodules, no shallow snapshots of ambiguity.** Commit a source drop of
   the exact pinned version.
3. **Every change we make is logged** — downstream engineers must be able to see the
   delta against upstream in one file.
4. Vendored code is compiled into shipped targets ⇒ every intake automatically
   appears on the in-app license screen (J-204 reads this directory).

## Intake checklist (all seven, or it doesn't land)

```
vendor/<name>/
  LICENSE            # upstream license file, VERBATIM
  README.md          # intake record (template below)
  patches.log        # one line per local patch: date | sha-of-our-commit | what/why
  <sources…>         # the pinned upstream source tree
```

`README.md` intake record template (fill every field):

```markdown
# <name> intake
- Upstream:        <url>
- Upstream commit: <40-char sha> (or release tag: <tag>)
- Pinned:          <date of intake>
- License:         <SPDX id> — verified by reading LICENSE at the pinned commit
- Purpose:         <which engine task consumes it: P-201 demucs / P-301 basicpitch / P-501 synth …>
- Local changes:   <initially "none"; keep in sync with patches.log>
- Audit:           <DECISIONS.md entry reference (e.g. D-15) if this was a
                    verify-before-use item>
```

## Reference intakes (expected, not yet present)

| Vendor | License | Consumer task | Notes |
|---|---|---|---|
| `demucs.cpp` (sevagh) | MIT | P-201 (M2) | htdemucs fp16 ggml weights; OpenMP→std::thread/GCD port logged in patches.log |
| `basicpitch.cpp` (sevagh) | MIT | P-301 (M3) | with ort-builder minimal ORT; weights→.c/.h |
| `TinySoundFont` | MIT | P-501 (M5) | soundfont file comes from HF repo, never git (D-6) |
| `pitch-detection` (sevagh) | MIT | P-102 fallback (M1) | MPM/YIN ribbon if NanoPitch license fails (D-7) |

## Update procedure

1. New upstream version → Paul queues an update task with changelog + license diff.
2. Leto re-applies `patches.log` onto the new source (or drops patches upstream-first).
3. License file must be re-verified at every update; a license CHANGE upstream is a
   blocking DECISIONS item, not a routine update.
