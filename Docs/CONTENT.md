# Docs/CONTENT.md — PitchNotes content schemas & licensing policy (Jess)

> **Owner:** Jess. **Version:** v0 stub (M0, J-003). These sketches become
> **CONTRACTS v1.3** in M5 (Leto ratifies) and are implemented by J-501/J-504/J-505.
> Licensing rules are binding NOW (AGENTS §9, D-11); schemas are sketches until M5.
> Companion: `Docs/UX.md` §5.6/§5.7 (where this content appears), `Docs/RESEARCH.md` §8.

---

## 1. Purpose

In-app learning content has three families:

1. **Glossary** — music-theory glyphs & terms (M5, J-502 clickable glyph cards).
2. **Exercises** — theory drills + ear-training specs (M5, J-501/J-504), optionally
   derived from the user's imported song (generated on device, not shipped data).
3. **Song metadata** — SDA hymn metadata (title, number, key, meter, tune name,
   lyrics where PD) to enrich import and exercises.

Content ships as versioned JSON in `Resources/Content/**` (Jess's lane), validated
by `logic-tests`. No copyrighted scans, recordings, or arrangements — ever.

## 2. GlossaryEntry — schema sketch (final in CONTRACTS v1.3)

```json
{
  "id": "glyph.treble-clef",
  "kind": "glyph",                  // glyph | term | symbol
  "name": "Treble clef (G clef)",
  "glyph": "𝄞",                    // unicode text glyph (no image assets in v1)
  "summary": "Fixes G4 on the second staff line.",
  "detail_md": "One short paragraph max; offline text only.",
  "seeAlso": ["glyph.bass-clef", "term.staff"],
  "masteryExercises": ["exercise.clef-identify"]
}
```

- M5 glyph set (UX §5.6): treble (G clef), bass (F clef), key signature, time
  signature, accidentals (♯ ♭ ♮), ties, dots, dynamics (pp p mp mf f ff).
- Every entry: `id` stable forever (additive-only changes), `kind`, `name`,
  `summary`; text authored in-house (PD/CC-BY sources only, attribution log §4).

## 3. ExerciseSpec — schema sketch (final in CONTRACTS v1.3)

```json
{
  "id": "ear.chordcompletion.T1",
  "family": "earTraining",          // earTraining | theory
  "skill": "chordCompletion",       // chordCompletion | scaleDegree | interval | keyFinding
  "prompt": "Sing the missing voice (T1).",
  "source": { "type": "songPhrase", "ref": "{songId}/{phraseIndex}" },
  "voicing": { "playedParts": ["BASS","BARITONE","BARITENOR","T2"], "targetPart": "T1" },
  "variants": {
    "octave": "up|down|none",       // sing an octave up/down (UX §5.7)
    "keys": [0, 2, -3],             // semitone transposes (re-synthesized, not shifted)
    "tuning": "ET|JI"               // JI: maj3 −14¢, 5th +2¢, dom7 −31¢
  },
  "grading": { "toleranceCents": 50, "onsetGraceMs": 100 },
  "audioSource": "stems|synth"      // stems (real) or TinySoundFont re-synth (D-6)
}
```

- Generated exercises reference the user's OWN bundle (`source.type: songPhrase`);
  shipped seeds use bundled demo content only.
- Schema validated by J-004 logic tests when ratified (v1.3).

## 4. Content licensing policy (binding NOW)

| Source class | Verdict | Rule |
|---|---|---|
| In-house authored text | ship | preferred; tracked in this file |
| Public Domain (pre-1929 US; PD-marked hymnals) | ship | no scans of copyrighted *editions* — text/facts only |
| CC-BY / CC-BY-SA | ship w/ attribution | attribution log below; SA → derived content stays CC-BY-SA |
| CC-BY-NC / ND / GTSinger / M4Singer | **BANNED** | never ships, never trains weights (AGENTS §9) |
| BarbershopTags.com | **LINK-OUT only** (D-11) | deep-link out of app until Leto verifies license; no redistribution of audio/sheets in-app |
| Copyrighted hymnal scans / commercial recordings | **BANNED** | never in git, never bundled |

**Attribution log (append on first use; audit at every merge, Leto):**
_(none yet — populate at M5 content authoring)_

## 5. SDA hymn metadata sources (verify-before-use flags)

Metadata candidates for import enrichment & theory context. **All flags must be
resolved by a Leto ruling (DECISIONS) before any bytes enter `Resources/Content/`.**

| Source | Use candidate | License status | Flag |
|---|---|---|---|
| sdahymnals.com | hymn text/metadata, page scans | unclear — verify terms | ⚠ VERIFY |
| sdahymnal.org / sdahymnal.net | hymn numbers, titles, lyrics | unclear — verify terms | ⚠ VERIFY |
| transposedhymns.com | transposed SATB leadsheets | unclear — verify terms | ⚠ VERIFY |
| Hymnary.org (Calvin Univ.) | comprehensive metadata, PD texts | site terms + per-item rights vary | ⚠ VERIFY per-item |
| Cyber Hymnal (HymnTime) | PD hymn texts, tune metadata | CC BY-NC 4.0 for site compilation | ⚠ VERIFY — NC likely restricts bundling |
| User-entered metadata | in-app editing | in-house | ✓ safe path |

Working assumption: **facts** (title/number/composer dates) are unencumbered;
**compilation & text formatting** may not be — so we store facts + PD texts with
per-field provenance, and never mirror a site's full database. If a source fails
verification, metadata falls back to user-entered + PD originals.

## 6. Demo seed content (M5)

- 1–3 PD hymns (text + facts + synthesized SATB from hymn MIDI) shipped as seed
  bundles for ear-training without an import — generated by in-house scripts only.
- No third-party audio in `Resources/Content/` ever; audio seeds are synthesized
  in-house from PD scores (license-clean by construction).
