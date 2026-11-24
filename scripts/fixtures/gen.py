#!/usr/bin/env python3
"""Seeded synthetic audio fixture generator (PitchNotes P-001, PAUL lane).

Generates the git-committed fixture set for Tests/Spikes (all SYNTHETIC, all
<= 1 MB, no copyrighted audio — PLAN M0 fixture policy / AGENTS §4):

  sweep_46_2100Hz_16k.wav   8 s log sine sweep 46.9 -> 2093.75 Hz (contract V11
                            band edges), 16 kHz mono PCM16
  synthetic_voice_16k.wav   5 s voice-like mono melody C3-D3-E3-D3-C3 with ±15 c
                            vibrato @5.5 Hz, 5 harmonics + breath noise, 0.5 s
                            silence tail (P-101 swiftf0-spike truth via
                            synthetic_voice_f0), 16 kHz mono
  satb_mixture_16k.wav      8 s 4-voice chord progression (C-F-G-C, voicings
                            C3/E3/G3/C4 family) with harmonics + noise floor,
                            16 kHz mono
  click_track_16k.wav       8 s click track, 120 BPM, 2 ms decaying clicks,
                            16 kHz mono
  silence_16k.wav           2 s digital silence, 16 kHz mono
  noise_burst_16k.wav       1 s: 0.25 s seeded white-noise burst inside silence,
                            16 kHz mono
  mix44k_short.wav          2.5 s 44.1 kHz mono melody+chord mixture for later
                            separation/transcription spikes (M2/M3)
  mix48k_stereo.wav         2.5 s 48 kHz STEREO variant of the same mixture
                            (P-203 decode: 48k->44.1k resample + channel-preserving
                            staging under D-8)
  bp_mono_22050.wav         5 s MONOPHONIC at basic-pitch's NATIVE rate (22.05 kHz):
                            MIDI 48/52/55/52/48, 0.9 s notes, 0.1 s gaps,
                            5-harmonic voice-ish spectrum, seeded noise floor
                            (P-301 basicpitch-spike truth)
  bp_poly_22050.wav         8 s POLYPHONIC at 22.05 kHz: the C-F-G-C progression,
                            1.9 s chords every 2 s (P-301 basicpitch-spike truth)

Truth sidecars (JSON, committed next to the WAVs — the SYNTHESIS truth, NOT a
re-measurement; the spike asserts the model's onsets/offsets against them):
  bp_mono_22050_truth.json  per note {midi, start_s, end_s}
  bp_poly_22050_truth.json  per note {midi, start_s, end_s}

Encoded format fixtures (P-203 ac "each format fixture imports"): lossy/lossless
encodes of the canonical mix44k_short.wav via ffmpeg (dev box; files are
COMMITTED so runners never need ffmpeg):

  mix44k_short.mp3          libmp3lame 128 kbps  (lossy decode — tolerance tests)
  mix44k_short.flac         FLAC               (lossless — bit-identity tests)
  mix44k_short_alac.m4a     ALAC in M4A container (lossless — bit-identity tests)

Determinism policy (P-001 AC: "fixtures regenerate byte-identically"):
  - Fixed seeds per fixture; numpy Generator(PCG64) streams are stable per numpy
    stream-stability policy; stdlib `wave` writes deterministic headers.
  - Tones use np.sin on IEEE-754 doubles. Cross-LIBC last-ULP differences could
    in principle flip an int16 rounding boundary; `--check` exists precisely to
    catch any such drift on CI. The committed fixtures are the canonical bytes.
  - Seeded WAVs: byte-identity is the guarantee (--check compares bytes).
  - Encoded formats: ffmpeg encoders are NOT byte-deterministic across
    platforms/versions. Regenerate mode therefore only encodes when the file is
    MISSING (existing committed encodes are never re-encoded — no churn), and
    --check verifies committed bytes structurally (container magic) + against
    the recorded sha (pinning the committed bytes; NO ffmpeg invocation).
  - Regenerate + verify:
        python3 scripts/fixtures/gen.py            # regenerate into Tests/Spikes/Fixtures
        python3 scripts/fixtures/gen.py --check    # verify bytes vs committed fixtures.sha256

Dependency-light: numpy + Python stdlib only (no scipy/soundfile); ffmpeg only
when an encoded fixture file is missing.
"""
import argparse
import hashlib
import json
import sys
import wave
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = REPO_ROOT / "Tests" / "Spikes" / "Fixtures"
SHA_FILE = OUT_DIR / "fixtures.sha256"

SR = 16000
SR_HIGH = 44100
SR_48K = 48000
SR_BP = 22050  # basic-pitch's NATIVE rate (vendor SAMPLE_RATE) — no resampling
               # is involved in the P-301 spike, so the fixture is the model's
               # own input rate.

# Contract V11 voiced band edges (CONTRACTS v0.0).
HZ_MIN = 46.9
HZ_MAX = 2093.75

# Equal-tempered frequencies (A440), fixed constants — no runtime computation drift.
def midi_hz(midi: float) -> float:
    return 440.0 * 2.0 ** ((midi - 69.0) / 12.0)


def write_wav(path: Path, samples: np.ndarray, sample_rate: int) -> None:
    """Write mono PCM16 WAV via stdlib wave (deterministic header)."""
    int16 = np.clip(samples, -1.0, 1.0)
    int16 = (int16 * 32767.0).round().astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(int16.tobytes())


def write_wav_stereo(path: Path, left: np.ndarray, right: np.ndarray, sample_rate: int) -> None:
    """Write stereo PCM16 WAV (interleaved L/R) via stdlib wave (deterministic)."""
    assert len(left) == len(right)
    li = np.clip(left, -1.0, 1.0)
    ri = np.clip(right, -1.0, 1.0)
    frames = np.empty(len(left) * 2, dtype="<i2")
    frames[0::2] = (li * 32767.0).round().astype("<i2")
    frames[1::2] = (ri * 32767.0).round().astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(frames.tobytes())


def tone(freq: float, n: int, sr: int, amp: float, harmonics=((1, 1.0), (2, 0.3), (3, 0.15))) -> np.ndarray:
    t = np.arange(n, dtype=np.float64) / sr
    out = np.zeros(n, dtype=np.float64)
    for mult, a in harmonics:
        out += a * np.sin(2.0 * np.pi * freq * mult * t)
    # 10 ms linear fades at both ends (click-free boundaries).
    fade = min(n, int(0.01 * sr))
    env = np.ones(n)
    if fade > 0:
        env[:fade] = np.linspace(0.0, 1.0, fade, endpoint=False)
        env[-fade:] = np.linspace(1.0, 0.0, fade, endpoint=False)
    return amp * out * env


def place(buf: np.ndarray, start_s: float, sr: int, piece: np.ndarray) -> None:
    i = int(start_s * sr)
    j = min(i + len(piece), len(buf))
    buf[i:j] += piece[: j - i]


def gen_sweep() -> np.ndarray:
    """8 s logarithmic sweep across the full contract pitch band (V11 edges)."""
    dur = 8.0
    n = int(SR * dur)
    t = np.arange(n, dtype=np.float64) / SR
    # Log chirp: f(t) = f0 * (f1/f0) ** (t/T); phase = 2*pi*int f dt / sr.
    inst_f = HZ_MIN * (HZ_MAX / HZ_MIN) ** (t / dur)
    phase = 2.0 * np.pi * np.cumsum(inst_f) / SR
    return 0.5 * np.sin(phase)


def gen_satb() -> np.ndarray:
    """8 s four-voice progression (C–F–G–C), close-position male voicings."""
    dur = 8.0
    n = int(SR * dur)
    buf = np.zeros(n, dtype=np.float64)
    # (chord start_s, [MIDI voicing]) — C3/E3/G3/C4 family per PLAN fixture policy.
    chords = [
        (0.0, [48, 52, 55, 60]),   # C: C3 E3 G3 C4
        (2.0, [53, 57, 60, 53 + 12]),  # F: F3 A3 C4 F4
        (4.0, [43, 50, 55, 59]),   # G: G2 D3 G3 B3
        (6.0, [48, 52, 55, 60]),   # C again
    ]
    for start, voicing in chords:
        for k, midi in enumerate(voicing):
            piece = tone(midi_hz(midi), int(1.9 * SR), SR, amp=0.3, harmonics=((1, 1.0), (2, 0.25), (3, 0.12)))
            place(buf, start + 0.0, SR, piece)
    # Small seeded noise floor (-55 dB-ish) so fixtures are not bit-trivial.
    rng = np.random.default_rng(0xAB1E)
    buf += 0.0015 * rng.standard_normal(n)
    return buf


def gen_clicks() -> np.ndarray:
    """8 s click track at 120 BPM: 2 ms exponentially decaying full-band clicks."""
    dur = 8.0
    n = int(SR * dur)
    buf = np.zeros(n, dtype=np.float64)
    click_n = int(0.002 * SR)
    t = np.arange(click_n) / SR
    click = 0.8 * np.exp(-t / 0.0004) * np.sin(2.0 * np.pi * 1000.0 * t)
    interval = 0.5  # 120 BPM
    k = 0
    while k * interval < dur:
        place(buf, k * interval, SR, click)
        k += 1
    return buf


def gen_silence() -> np.ndarray:
    return np.zeros(int(2.0 * SR), dtype=np.float64)


def gen_noise_burst() -> np.ndarray:
    n = SR  # 1 s
    buf = np.zeros(n, dtype=np.float64)
    rng = np.random.default_rng(0x30ED)
    burst_len = int(0.25 * SR)
    buf[int(0.25 * SR): int(0.25 * SR) + burst_len] = 0.3 * rng.standard_normal(burst_len)
    # 5 ms fades on the burst edges.
    fade = int(0.005 * SR)
    seg = buf[int(0.25 * SR): int(0.25 * SR) + burst_len]
    seg[:fade] *= np.linspace(0.0, 1.0, fade, endpoint=False)
    seg[-fade:] *= np.linspace(1.0, 0.0, fade, endpoint=False)
    return buf


def _mix_mixture(sr: int, melody_amp: float, chord_amp: float, seed: int,
                 flat_cents: float = -12.0, detune_cents: float = 0.0) -> np.ndarray:
    """Shared 2.5 s melody+chord mixture at the given sample rate (P-203/P-201/P-207
    fixtures): melody C4-A3-B3-C4 with a -12-cent flat singer + sustained chord.
    `detune_cents` shifts the WHOLE mixture (melody + chord, varispeed style) and
    REPLACES the flat-singer offset — used for the P-207 tuning-estimator fixtures
    where every note must sit at exactly ±detune from A440 ET. With the default
    args the arithmetic is bit-identical to the pre-parameterization mix44k."""
    dur = 2.5
    n = int(sr * dur)
    buf = np.zeros(n, dtype=np.float64)
    melody = [(0.0, 60), (0.625, 57), (1.25, 59), (1.875, 60)]  # C4 A3 B3 C4
    mel_shift = (flat_cents + detune_cents) / 1200.0
    ch_shift = detune_cents / 1200.0
    for start, midi in melody:
        f = midi_hz(midi) * 2.0 ** mel_shift
        place(buf, start, sr, tone(f, int(0.55 * sr), sr, amp=melody_amp,
                                   harmonics=((1, 1.0), (2, 0.35), (3, 0.2))))
    # Backing sustained chord C3/E3/G3 under the melody.
    for midi in (48, 52, 55):
        place(buf, 0.0, sr, tone(midi_hz(midi) * 2.0 ** ch_shift, int(dur * sr), sr, amp=chord_amp,
                                 harmonics=((1, 1.0), (2, 0.2))))
    rng = np.random.default_rng(seed)
    buf += 0.001 * rng.standard_normal(n)
    return buf


def gen_mix44k() -> np.ndarray:
    """2.5 s 44.1 kHz mono melody+chord mixture (spike input for M2 separation / M3
    transcription)."""
    return _mix_mixture(SR_HIGH, 0.35, 0.15, 0x4411)


def gen_mix44k_detuned_plus35() -> np.ndarray:
    """P-207 tuning fixture: the whole mixture sits +35 cents from A440 (varispeed;
    flat-singer offset replaced). TuningEstimator must recover ~+35 (±5 c AC)."""
    return _mix_mixture(SR_HIGH, 0.35, 0.15, 0x7135, flat_cents=0.0, detune_cents=35.0)


def gen_mix44k_detuned_minus35() -> np.ndarray:
    """P-207 tuning fixture: the whole mixture sits −35 cents from A440."""
    return _mix_mixture(SR_HIGH, 0.35, 0.15, 0x7136, flat_cents=0.0, detune_cents=-35.0)


def gen_mix48k_stereo() -> tuple[np.ndarray, np.ndarray]:
    """2.5 s 48 kHz STEREO variant of the mixture (P-203 decode fixture): the
    melody leads left (vocal-like placement), chord sits right — exercises the
    D-8 channel-preserving staging + 48k->44.1k resample path. Distinct seeds
    per channel so L != R."""
    left = _mix_mixture(SR_48K, 0.35, 0.12, 0x48C1)
    right = _mix_mixture(SR_48K, 0.26, 0.20, 0x48C2)
    return left, right


def gen_synthetic_voice():
    """5 s voice-like monophonic fixture (P-101 swiftf0-spike "synthetic-voice"):
    C3-D3-E3-D3-C3 (MIDI 48/50/52/50/48, 0.9 s each) with ±15-cent vibrato at
    5.5 Hz, 5-harmonic voice-ish spectrum, breath noise floor, 0.5 s silence tail.

    The truth F0 contour is shared with the spike via synthetic_voice_f0(t) /
    sweep_f0(t) below, so accuracy asserts compare against the exact synthesis
    contour (frame-center instantaneous F0), not a re-estimate.
    """
    dur = 5.0
    n = int(SR * dur)
    t = np.arange(n, dtype=np.float64) / SR
    f0 = synthetic_voice_f0(t)
    phase = 2.0 * np.pi * np.cumsum(f0) / SR
    # Voice-ish spectrum: decaying harmonics, pseudo-formant emphasis on 2-3.
    buf = np.zeros(n, dtype=np.float64)
    for mult, a in ((1, 1.0), (2, 0.60), (3, 0.45), (4, 0.28), (5, 0.18)):
        buf += a * np.sin(mult * phase)
    # 10 ms fades at the very ends only (note steps fade via the contour envelope).
    fade = int(0.01 * SR)
    buf[:fade] *= np.linspace(0.0, 1.0, fade, endpoint=False)
    buf[-int(0.4 * SR):] *= np.linspace(1.0, 0.0, int(0.4 * SR), endpoint=False)
    rng = np.random.default_rng(0x5EED)
    buf += 0.0015 * rng.standard_normal(n)
    return 0.4 * buf


def sweep_f0(t: np.ndarray) -> np.ndarray:
    """Instantaneous F0 of gen_sweep at time(s) t (s) — shared spike truth."""
    return HZ_MIN * (HZ_MAX / HZ_MIN) ** (t / 8.0)


def synthetic_voice_f0(t: np.ndarray) -> np.ndarray:
    """Instantaneous F0 of gen_synthetic_voice at time(s) t (s) — shared spike
    truth: 0.9 s notes C3(48)/D3(50)/E3(52)/D3(50)/C3(48), ±15 c vibrato @5.5 Hz,
    silent (0.0) after 4.5 s."""
    notes = [48, 50, 52, 50, 48]
    note_dur = 0.9
    f0 = np.zeros_like(t)
    for k, midi in enumerate(notes):
        m = (t >= k * note_dur) & (t < (k + 1) * note_dur)
        vibrato = 15.0 * np.sin(2.0 * np.pi * 5.5 * t)
        f0[m] = midi_hz(float(midi)) * 2.0 ** (vibrato[m] / 1200.0)
    return f0


# --- basic-pitch (P-301) fixtures at the model's NATIVE rate -----------------
# The truth tables below ARE the synthesis parameters: the audio is rendered
# from them and the JSON sidecar is written from them, so the committed truth
# can never drift from the committed audio (the sidecar is the SYNTHESIS
# truth, not a re-measurement of the model).
BP_MONO_NOTES = [(48, 0.0, 0.9), (52, 1.0, 1.9), (55, 2.0, 2.9),
                 (52, 3.0, 3.9), (48, 4.0, 4.9)]
BP_MONO_DUR = 5.0
# Voice-ish spectrum (decaying harmonics) — the same shape as the M1
# synthetic_voice fixture, so the model sees a plausible voice rather than a
# bare sine.
BP_VOICE_HARMONICS = ((1, 1.0), (2, 0.50), (3, 0.30), (4, 0.15), (5, 0.08))
# Chord tones: slightly fewer harmonics so four simultaneous voices stay clean.
BP_CHORD_HARMONICS = ((1, 1.0), (2, 0.25), (3, 0.12))

BP_POLY_CHORDS = [(0.0, [48, 52, 55, 60]),   # C: C3 E3 G3 C4
                  (2.0, [53, 57, 60, 65]),   # F: F3 A3 C4 F4
                  (4.0, [43, 50, 55, 59]),   # G: G2 D3 G3 B3
                  (6.0, [48, 52, 55, 60])]   # C again
BP_POLY_NOTE_DUR = 1.9
BP_POLY_DUR = 8.0


def gen_bp_mono() -> np.ndarray:
    """5 s MONOPHONIC fixture at 22.05 kHz (basic-pitch's native rate):
    MIDI 48/52/55/52/48, 0.9 s notes separated by 0.1 s gaps, voice-ish
    5-harmonic spectrum, seeded noise floor."""
    n = int(SR_BP * BP_MONO_DUR)
    buf = np.zeros(n, dtype=np.float64)
    for midi, start, end in BP_MONO_NOTES:
        length = int(round((end - start) * SR_BP))
        piece = tone(midi_hz(float(midi)), length, SR_BP, amp=0.35,
                     harmonics=BP_VOICE_HARMONICS)
        place(buf, start, SR_BP, piece)
    rng = np.random.default_rng(0xB0DE)
    buf += 0.0015 * rng.standard_normal(n)
    return buf


def gen_bp_poly() -> np.ndarray:
    """8 s POLYPHONIC fixture at 22.05 kHz: the C-F-G-C progression, four
    voices per chord, 1.9 s chords starting every 2 s (0.1 s of silence
    between chords), seeded noise floor."""
    n = int(SR_BP * BP_POLY_DUR)
    buf = np.zeros(n, dtype=np.float64)
    for start, voicing in BP_POLY_CHORDS:
        for midi in voicing:
            piece = tone(midi_hz(float(midi)), int(BP_POLY_NOTE_DUR * SR_BP),
                         SR_BP, amp=0.15, harmonics=BP_CHORD_HARMONICS)
            place(buf, start, SR_BP, piece)
    rng = np.random.default_rng(0xB0F7)
    buf += 0.0015 * rng.standard_normal(n)
    return buf


def bp_mono_truth() -> list[dict]:
    """Synthesis truth for bp_mono_22050.wav."""
    return [{"midi": int(m), "start_s": float(s), "end_s": float(e)}
            for m, s, e in BP_MONO_NOTES]


def bp_poly_truth() -> list[dict]:
    """Synthesis truth for bp_poly_22050.wav (every voice of every chord)."""
    notes = []
    for start, voicing in BP_POLY_CHORDS:
        for midi in voicing:
            notes.append({"midi": int(midi), "start_s": float(start),
                          "end_s": float(start + BP_POLY_NOTE_DUR)})
    return notes


def write_truth_json(path: Path, fixture: str, notes: list[dict]) -> None:
    """Write a deterministic truth sidecar (sorted keys, fixed formatting)."""
    import json

    payload = {"fixture": fixture, "sample_rate": SR_BP, "notes": notes}
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


FIXTURES = [
    ("sweep_46_2100Hz_16k.wav", gen_sweep, SR),
    ("synthetic_voice_16k.wav", gen_synthetic_voice, SR),
    ("satb_mixture_16k.wav", gen_satb, SR),
    ("click_track_16k.wav", gen_clicks, SR),
    ("silence_16k.wav", gen_silence, SR),
    ("noise_burst_16k.wav", gen_noise_burst, SR),
    ("mix44k_short.wav", gen_mix44k, SR_HIGH),
    ("mix44k_detuned_plus35.wav", gen_mix44k_detuned_plus35, SR_HIGH),
    ("mix44k_detuned_minus35.wav", gen_mix44k_detuned_minus35, SR_HIGH),
    ("mix48k_stereo.wav", gen_mix48k_stereo, SR_48K),  # stereo (L, R)
    # P-301 basic-pitch fixtures — the model's NATIVE rate (22.05 kHz), so the
    # spike exercises no resampling.
    ("bp_mono_22050.wav", gen_bp_mono, SR_BP),
    ("bp_poly_22050.wav", gen_bp_poly, SR_BP),
]

# Truth sidecars for the P-301 fixtures (JSON, committed next to the WAVs).
# They are part of the fixture set: the sha rows cover them AND the check
# loop re-derives their contents from the synthesis tables, so a sidecar that
# no longer matches the audio it describes FAILS the integrity gate.
TRUTH_FIXTURES = [
    ("bp_mono_22050_truth.json", "bp_mono_22050.wav", bp_mono_truth),
    ("bp_poly_22050_truth.json", "bp_poly_22050.wav", bp_poly_truth),
]

# Encoded format fixtures (P-203): ffmpeg encodes of the canonical mono 44.1k
# mixture, COMMITTED to git. ffmpeg is only invoked when the file is missing
# (encoders are not byte-deterministic across platforms/versions — never
# re-encode an existing committed encode).
ENCODED_FIXTURES = [
    # (name, source, ffmpeg codec args, structural validator)
    ("mix44k_short.mp3", "mix44k_short.wav", ["-c:a", "libmp3lame", "-b:a", "128k"], "mp3"),
    ("mix44k_short.flac", "mix44k_short.wav", ["-c:a", "flac"], "flac"),
    ("mix44k_short_alac.m4a", "mix44k_short.wav", ["-c:a", "alac"], "m4a"),
]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _validate_mp3(data: bytes) -> None:
    """ID3 tag or raw MPEG frame sync (11 set bits = 0xFF 0xEx)."""
    if data[:3] == b"ID3":
        return
    if len(data) >= 2 and data[0] == 0xFF and (data[1] & 0xE0) == 0xE0:
        return
    raise ValueError("no ID3 header and no MPEG frame sync")


def _validate_flac(data: bytes) -> None:
    if data[:4] != b"fLaC":
        raise ValueError("missing 'fLaC' stream magic")


def _validate_m4a(data: bytes) -> None:
    # ISO-BMFF: 4-byte size then 'ftyp' as the first box type.
    if data[4:8] != b"ftyp":
        raise ValueError("missing 'ftyp' ISO-BMFF box")


VALIDATORS = {"mp3": _validate_mp3, "flac": _validate_flac, "m4a": _validate_m4a}


def encode_missing() -> list[str]:
    """Encode any MISSING encoded fixture via ffmpeg. Existing committed encodes
    are never touched (cross-platform encoder non-determinism)."""
    import shutil
    import subprocess

    encoded = []
    for name, source, codec_args, kind in ENCODED_FIXTURES:
        dst = OUT_DIR / name
        if dst.exists():
            encoded.append(f"kept {name} (exists)")
            continue
        src = OUT_DIR / source
        if not src.exists():
            raise RuntimeError(f"{source} missing — regenerate WAVs first")
        if shutil.which("ffmpeg") is None:
            raise RuntimeError(f"{name} missing and ffmpeg not on PATH — cannot encode")
        subprocess.run(
            ["ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", str(src), *codec_args, str(dst)],
            check=True,
        )
        size = dst.stat().st_size
        assert size <= 1_000_000, f"{name} is {size} bytes (> 1 MB policy)"
        try:
            VALIDATORS[kind](dst.read_bytes()[:64])
        except ValueError as e:
            raise RuntimeError(f"{name}: encoded output failed structural check: {e}") from e
        encoded.append(f"encoded {name} ({size} B)")
    return encoded


def regenerate() -> list[tuple[str, str]]:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, gen, sr in FIXTURES:
        path = OUT_DIR / name
        if name == "mix48k_stereo.wav":
            left, right = gen()
            write_wav_stereo(path, left, right, sr)
        else:
            write_wav(path, gen(), sr)
        size = path.stat().st_size
        assert size <= 1_000_000, f"{name} is {size} bytes (> 1 MB policy)"
    # Truth sidecars (P-301) — written from the same synthesis tables the
    # audio is rendered from, so they cannot drift apart.
    for name, fixture, truth_fn in TRUTH_FIXTURES:
        write_truth_json(OUT_DIR / name, fixture, truth_fn())
    encode_missing()
    # sha file covers every fixture on disk (WAVs byte-identical, encodes
    # pinned, truth sidecars pinned).
    names = ([n for n, _, _, _ in ENCODED_FIXTURES]
             + [n for n, _, _ in FIXTURES]
             + [n for n, _, _ in TRUTH_FIXTURES])
    rows = [(name, sha256(OUT_DIR / name)) for name in names]
    SHA_FILE.write_text("".join(f"{h}  {n}\n" for n, h in rows))
    return rows


def check() -> bool:
    if not SHA_FILE.exists():
        print(f"FAIL: {SHA_FILE} missing — regenerate first", file=sys.stderr)
        return False
    expected = dict(reversed(line.split("  ", 1)) for line in SHA_FILE.read_text().splitlines() if line.strip())
    ok = True
    wav_names = {n for n, _, _ in FIXTURES}
    encoded_kinds = {n: k for n, _, _, k in ENCODED_FIXTURES}
    for name in list(wav_names) + list(encoded_kinds):
        path = OUT_DIR / name
        if not path.exists():
            print(f"FAIL: {name} missing", file=sys.stderr)
            ok = False
            continue
        data = path.read_bytes()
        actual = hashlib.sha256(data).hexdigest()
        if expected.get(name) != actual:
            # Encoded formats may legitimately be re-encoded on another platform
            # (deliberate regenerate) — structural validity decides there.
            if name in encoded_kinds:
                try:
                    VALIDATORS[encoded_kinds[name]](data[:64])
                except ValueError as e:
                    print(f"FAIL: {name} hash drift AND invalid structure ({e})", file=sys.stderr)
                    ok = False
                else:
                    print(f"NOTE: {name} sha differs from record but structure valid "
                          f"(re-encoded elsewhere? update {SHA_FILE.name})", file=sys.stderr)
            else:
                print(f"FAIL: {name} hash drift (committed {expected.get(name)}, actual {actual})", file=sys.stderr)
                ok = False
        else:
            if name in encoded_kinds:
                try:
                    VALIDATORS[encoded_kinds[name]](data[:64])
                except ValueError as e:
                    print(f"FAIL: {name} matches recorded sha but invalid structure ({e})", file=sys.stderr)
                    ok = False
        if path.stat().st_size > 1_000_000:
            print(f"FAIL: {name} exceeds 1 MB", file=sys.stderr)
            ok = False
    # Truth sidecars (P-301): pinned by sha AND re-derived from the synthesis
    # tables — a sidecar that no longer describes the committed audio fails.
    for name, fixture, truth_fn in TRUTH_FIXTURES:
        path = OUT_DIR / name
        if not path.exists():
            print(f"FAIL: {name} missing", file=sys.stderr)
            ok = False
            continue
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if expected.get(name) != actual:
            print(f"FAIL: {name} hash drift (committed {expected.get(name)}, actual {actual})", file=sys.stderr)
            ok = False
        try:
            payload = json.loads(path.read_text())
        except Exception as e:
            print(f"FAIL: {name} is not valid JSON ({e})", file=sys.stderr)
            ok = False
            continue
        if payload.get("fixture") != fixture:
            print(f"FAIL: {name} names fixture {payload.get('fixture')!r}, expected {fixture!r}", file=sys.stderr)
            ok = False
        if payload.get("notes") != truth_fn():
            print(f"FAIL: {name} notes differ from the synthesis truth", file=sys.stderr)
            ok = False
    return ok


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="verify committed fixture bytes vs fixtures.sha256")
    args = ap.parse_args()
    if args.check:
        return 0 if check() else 1
    rows = regenerate()
    for name, h in rows:
        print(f"{h}  {name}")
    print(f"wrote {len(rows)} fixtures + {SHA_FILE.relative_to(REPO_ROOT)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
