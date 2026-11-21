#!/usr/bin/env python3
"""Seeded synthetic audio fixture generator (PitchNotes P-001, PAUL lane).

Generates the git-committed fixture set for Tests/Spikes (all SYNTHETIC, all
<= 1 MB, no copyrighted audio — PLAN M0 fixture policy / AGENTS §4):

  sweep_46_2100Hz_16k.wav   8 s log sine sweep 46.9 -> 2093.75 Hz (contract V11
                            band edges), 16 kHz mono PCM16
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

Determinism policy (P-001 AC: "fixtures regenerate byte-identically"):
  - Fixed seeds per fixture; numpy Generator(PCG64) streams are stable per numpy
    stream-stability policy; stdlib `wave` writes deterministic headers.
  - Tones use np.sin on IEEE-754 doubles. Cross-LIBC last-ULP differences could
    in principle flip an int16 rounding boundary; `--check` exists precisely to
    catch any such drift on CI. The committed fixtures are the canonical bytes.
  - Regenerate + verify:
        python3 scripts/fixtures/gen.py            # regenerate into Tests/Spikes/Fixtures
        python3 scripts/fixtures/gen.py --check    # verify bytes vs committed fixtures.sha256

Dependency-light: numpy + Python stdlib only (no scipy/soundfile).
"""
import argparse
import hashlib
import sys
import wave
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = REPO_ROOT / "Tests" / "Spikes" / "Fixtures"
SHA_FILE = OUT_DIR / "fixtures.sha256"

SR = 16000
SR_HIGH = 44100

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


def gen_mix44k() -> np.ndarray:
    """2.5 s 44.1 kHz melody+chord mixture (spike input for M2 separation / M3
    transcription): melody C4-A3-B3-C4 with vibrato-ish detune + sustained chord."""
    dur = 2.5
    n = int(SR_HIGH * dur)
    buf = np.zeros(n, dtype=np.float64)
    melody = [(0.0, 60), (0.625, 57), (1.25, 59), (1.875, 60)]  # C4 A3 B3 C4
    for start, midi in melody:
        f = midi_hz(midi) * 2.0 ** (-12.0 / 1200.0)  # slight flat singer (-12 cents)
        place(buf, start, SR_HIGH, tone(f, int(0.55 * SR_HIGH), SR_HIGH, amp=0.35,
                                        harmonics=((1, 1.0), (2, 0.35), (3, 0.2))))
    # Backing sustained chord C3/E3/G3 under the melody.
    for midi in (48, 52, 55):
        place(buf, 0.0, SR_HIGH, tone(midi_hz(midi), int(dur * SR_HIGH), SR_HIGH, amp=0.15,
                                      harmonics=((1, 1.0), (2, 0.2))))
    rng = np.random.default_rng(0x4411)
    buf += 0.001 * rng.standard_normal(n)
    return buf


FIXTURES = [
    ("sweep_46_2100Hz_16k.wav", gen_sweep, SR),
    ("satb_mixture_16k.wav", gen_satb, SR),
    ("click_track_16k.wav", gen_clicks, SR),
    ("silence_16k.wav", gen_silence, SR),
    ("noise_burst_16k.wav", gen_noise_burst, SR),
    ("mix44k_short.wav", gen_mix44k, SR_HIGH),
]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def regenerate() -> list[tuple[str, str]]:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rows = []
    for name, gen, sr in FIXTURES:
        samples = gen()
        path = OUT_DIR / name
        write_wav(path, samples, sr)
        size = path.stat().st_size
        assert size <= 1_000_000, f"{name} is {size} bytes (> 1 MB policy)"
        rows.append((name, sha256(path)))
    SHA_FILE.write_text("".join(f"{h}  {n}\n" for n, h in rows))
    return rows


def check() -> bool:
    if not SHA_FILE.exists():
        print(f"FAIL: {SHA_FILE} missing — regenerate first", file=sys.stderr)
        return False
    expected = dict(reversed(line.split("  ", 1)) for line in SHA_FILE.read_text().splitlines() if line.strip())
    ok = True
    for name, _, _ in FIXTURES:
        path = OUT_DIR / name
        if not path.exists():
            print(f"FAIL: {name} missing", file=sys.stderr)
            ok = False
            continue
        actual = sha256(path)
        if expected.get(name) != actual:
            print(f"FAIL: {name} hash drift (committed {expected.get(name)}, actual {actual})", file=sys.stderr)
            ok = False
        if path.stat().st_size > 1_000_000:
            print(f"FAIL: {name} exceeds 1 MB", file=sys.stderr)
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
