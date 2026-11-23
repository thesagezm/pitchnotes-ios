# Tests/Spikes/Fixtures — synthetic fixtures (P-001, PAUL lane)

All fixtures are **synthetic, seeded, ≤ 1 MB** (PLAN M0 fixture policy, AGENTS §4).
No copyrighted audio; real SDA songs stay local and are never committed.
`.gitignore` blocks `*.wav` repo-wide — fixtures are force-added once
(`git add -f Tests/Spikes/Fixtures/*.wav`); after that git tracks their bytes.

## Regenerate (byte-identical)

```bash
python3 scripts/fixtures/gen.py          # regenerate into this directory
python3 scripts/fixtures/gen.py --check  # verify bytes vs fixtures.sha256 (CI-safe)
```

Byte-identity policy: fixed seeds, numpy `Generator(PCG64)` (stable streams),
stdlib `wave` headers, IEEE-754 doubles. Committed bytes are canonical —
`--check` is the CI gate for drift. See `scripts/fixtures/gen.py` docstring.

**Encoded formats (mp3/flac/m4a)** are ffmpeg encodes of `mix44k_short.wav`
committed once from the dev box; runners never need ffmpeg. ffmpeg encoders are
NOT byte-deterministic across platforms/versions, so `gen.py` regenerate mode
only encodes when the file is MISSING (committed encodes are never re-encoded),
and `--check` validates structure (ID3/frame-sync, `fLaC`, `ftyp`) + the
recorded sha — never re-encode-and-compare. A deliberate re-encode updates
`fixtures.sha256` (gen.py does it automatically).

## Manifest (SHA256, committed as fixtures.sha256 too)

| Fixture | Bytes | SHA256 | Purpose |
|---|---|---|---|
| sweep_46_2100Hz_16k.wav | 256044 | `a552be29b76fbe04220fca976a239a79a1be96c52ad355da9ee1821a3c90140f` | full contract V11 pitch band (46.9–2093.75 Hz), 16k mono — pitch-spike truth input |
| synthetic_voice_16k.wav | 160044 | `a03d20a8feb90ec9687aa7c022c13c3a79912506d35788bff875488a17bac0d2` | P-101 voice-like melody C3-D3-E3-D3-C3, ±15 c vibrato @5.5 Hz, 0.5 s silence tail — SwiftF0 ±20c accuracy truth (`gen.synthetic_voice_f0`) |
| satb_mixture_16k.wav | 256044 | `f05a6d33f53f2142387cffe3fb2515138654b3cd2a6794c75349e9298ae5c712` | 4-voice C–F–G–C progression (C3/E3/G3/C4 voicings) — polyphonic/assignment spikes |
| click_track_16k.wav | 256044 | `0382447c5d9db2ad6dde0b69eaadbf4760e974a09c1af20f20ff873cc87ea828` | 120 BPM clicks — onset/latency spikes |
| silence_16k.wav | 64044 | `20eaebffe1816e0ffa6f7f854f5ef4ea80d5349faaf0ce1fec1b713e7fde58fa` | digital silence — VAD gating / unvoiced assertions |
| noise_burst_16k.wav | 32044 | `83656bc513a38e9a1b81797f81ded5ccb231a13fa20294de69d9890e7e36512b` | 0.25 s noise burst in silence — VAD/edge tests |
| mix44k_short.wav | 220544 | `bbe91a6cd6e8cd4cbf3cc3e549306df8cde47f2c5d7167d670e40d173c036211` | 2.5 s 44.1k melody+chord — M2 separation / M3 transcription spikes |

Verify locally: `sha256sum -c fixtures.sha256` (from this directory) or
`python3 scripts/fixtures/gen.py --check` (repo root, path-independent).
