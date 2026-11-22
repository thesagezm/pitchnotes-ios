#!/usr/bin/env python3
"""P-201 threading patch for the vendored demucs.cpp (D-32.4, PAUL lane).

WHAT: branch-parallel std::thread pairing of the INDEPENDENT frequency and
time encoder/decoder chains inside `demucscpp::model_inference` (htdemucs
path only — the v3 section is untouched, we ship the 4-source htdemucs).

WHY SAFE (recorded for Leto's patches.log entry):
  - freq and time chains read/write DISJOINT buffers (x_* vs xt_*), the model
    struct is read-only during inference, and every op is deterministic →
    output is BIT-IDENTICAL regardless of thread count (asserted by the
    benchmark: 1-thread == 2-thread stem bytes).
  - The per-source mask/ISTFT section is NOT parallelized: it mutates the
    SHARED stft_buf per source — restructuring it for thread-local stft
    buffers is deliberately deferred (risk ≫ reward for M2).
  - DEMUCSCPP_NUM_THREADS env: unset/1 = EXACT stock serial behavior
    (benchmark baseline); >= 2 = parallel pairs. Extra threads beyond 2 add
    nothing today (pairs are the only free parallelism) — the 4-thread
    benchmark number documents that honestly.
  - Progress callbacks (cb) move AFTER each pair — they are chatter-only
    (fraction monotonicity is preserved via ImportProgressEmitter clamp).

MECHANICS: exact-string replacements against the pinned intake
(upstream 4edae497, byte-identical per patches.log). Idempotent (refuses to
double-apply), leaves a .orig backup, --revert restores it. Leto applies this
to vendor/demucs.cpp/src/ with a patches.log line (X-201); until then the
benchmark applies it to the READ-ONLY scratch extraction.

Usage:
  python3 apply_demucs_threading.py <vendor>/src/model_inference.cpp [--revert]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

MARKER = "P-201 THREADING PATCH (D-32.4)"

HELPER = f"""
// {MARKER}: branch-parallel freq/time pairs. DEMUCSCPP_NUM_THREADS: unset/1 =
// exact stock serial behavior; >= 2 = parallel pairs (disjoint buffers —
// bit-identical output, see Tests/Spikes/apply_demucs_threading.py).
static int demucscpp_thread_pair_threshold(void)
{{
    const char *env = std::getenv("DEMUCSCPP_NUM_THREADS");
    int n = env ? std::atoi(env) : 1;
    return n < 2 ? 2 : n;
}}
"""

INCLUDE_ANCHOR = "#include <tuple>\n"
INCLUDE_NEW = "#include <thread>\n#include <tuple>\n"

# (old, new) pairs — exact pinned-upstream text. {T} = threshold helper.
PAIR = """    {parallel_open}
        std::thread t([&]() {{
            {call_a}
        }});
        {call_b}
        t.join();
    }} else {{
        {call_a}
        {call_b}
    }}
    {cb_a}
    {cb_b}"""

SITES = [
    # ---- encoder pairs (freq and time chains are independent) ----
    dict(kind="enc", layer=0,
         call_a="demucscpp::apply_time_encoder(model, 0, buffers.xt, buffers.xt_0);",
         cb_a='cb(current_progress + segment_progress * 1.0f / 26.0f, "Time encoder 0");',
         call_b="demucscpp::apply_freq_encoder(model, 0, buffers.x, buffers.x_0);",
         cb_b='cb(current_progress + segment_progress * 2.0f / 26.0f, "Freq encoder 0");'),
    dict(kind="enc", layer=1,
         call_a="apply_time_encoder(model, 1, buffers.xt_0, buffers.xt_1);",
         cb_a='cb(current_progress + segment_progress * 3.0f / 26.0f, "Time encoder 1");',
         call_b="apply_freq_encoder(model, 1, buffers.x_0, buffers.x_1);",
         cb_b='cb(current_progress + segment_progress * 4.0f / 26.0f, "Freq encoder 1");'),
    dict(kind="enc", layer=2,
         call_a="apply_time_encoder(model, 2, buffers.xt_1, buffers.xt_2);",
         cb_a='cb(current_progress + segment_progress * 5.0f / 26.0f, "Time encoder 2");',
         call_b="apply_freq_encoder(model, 2, buffers.x_1, buffers.x_2);",
         cb_b='cb(current_progress + segment_progress * 6.0f / 26.0f, "Freq encoder 2");'),
    dict(kind="enc", layer=3,
         call_a="apply_time_encoder(model, 3, buffers.xt_2, buffers.xt_3);",
         cb_a='cb(current_progress + segment_progress * 7.0f / 26.0f, "Time encoder 3");',
         call_b="apply_freq_encoder(model, 3, buffers.x_2, buffers.x_3);",
         cb_b='cb(current_progress + segment_progress * 8.0f / 26.0f, "Freq encoder 3");'),
    # ---- decoder pairs (freq and time chains are independent) ----
    dict(kind="dec", layer=0,
         call_a="demucscpp::apply_freq_decoder(model, 0, buffers.x_3, buffers.x_2,\n                                  buffers.saved_3);",
         cb_a='cb(current_progress + segment_progress * 19.0f / 26.0f, "Freq: decoder 0");',
         call_b="demucscpp::apply_time_decoder(model, 0, buffers.xt_3, buffers.xt_2,\n                                  buffers.savedt_3);",
         cb_b='cb(current_progress + segment_progress * 20.0f / 26.0f, "Time: decoder 0");'),
    dict(kind="dec", layer=1,
         call_a="demucscpp::apply_freq_decoder(model, 1, buffers.x_2, buffers.x_1,\n                                  buffers.saved_2);",
         cb_a='cb(current_progress + segment_progress * 21.0f / 26.0f, "Freq: decoder 1");',
         call_b="demucscpp::apply_time_decoder(model, 1, buffers.xt_2, buffers.xt_1,\n                                  buffers.savedt_2);",
         cb_b='cb(current_progress + segment_progress * 22.0f / 26.0f, "Time: decoder 1");'),
    dict(kind="dec", layer=2,
         call_a="demucscpp::apply_freq_decoder(model, 2, buffers.x_1, buffers.x_0,\n                                  buffers.saved_1);",
         cb_a='cb(current_progress + segment_progress * 23.0f / 26.0f, "Freq: decoder 2");',
         call_b="demucscpp::apply_time_decoder(model, 2, buffers.xt_1, buffers.xt_0,\n                                  buffers.savedt_1);",
         cb_b='cb(current_progress + segment_progress * 24.0f / 26.0f, "Time: decoder 2");'),
    dict(kind="dec", layer=3,
         call_a="demucscpp::apply_freq_decoder(model, 3, buffers.x_0, buffers.x_out,\n                                  buffers.saved_0);",
         cb_a='cb(current_progress + segment_progress * 25.0f / 26.0f, "Freq: decoder 3");',
         call_b="demucscpp::apply_time_decoder(model, 3, buffers.xt_0, buffers.xt_out,\n                                  buffers.savedt_0);",
         cb_b='cb(current_progress + segment_progress * 26.0f / 26.0f, "Time: decoder 3");'),
]


def old_text(site: dict) -> str:
    return f"""    {site['call_a']}
    {site['cb_a']}

    {site['call_b']}
    {site['cb_b']}"""


def new_text(site: dict) -> str:
    body = PAIR.format(parallel_open=f"if (demucscpp_thread_pair_threshold() == 2) {{",
                       call_a=site["call_a"], call_b=site["call_b"],
                       cb_a=site["cb_a"], cb_b=site["cb_b"])
    return body


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("model_cpp", type=Path)
    ap.add_argument("--revert", action="store_true")
    args = ap.parse_args()
    f = args.model_cpp
    orig = f.with_suffix(f.suffix + ".orig")

    if args.revert:
        if not orig.is_file():
            print("no .orig backup — nothing to revert", file=sys.stderr)
            return 1
        f.write_text(orig.read_text())
        orig.unlink()
        print(f"reverted {f}")
        return 0

    text = f.read_text()
    if MARKER in text:
        print("already patched (marker present) — refusing to double-apply",
              file=sys.stderr)
        return 1

    if INCLUDE_ANCHOR not in text:
        print("include anchor missing — file does not match the pinned intake",
              file=sys.stderr)
        return 1
    text = text.replace(INCLUDE_ANCHOR, INCLUDE_NEW, 1)

    # Insert the helper right before `void demucscpp::model_inference(`
    anchor = "void demucscpp::model_inference("
    if anchor not in text:
        print("model_inference anchor missing", file=sys.stderr)
        return 1
    text = text.replace(anchor, HELPER + "\n" + anchor, 1)

    applied = 0
    for site in SITES:
        o, n = old_text(site), new_text(site)
        if o not in text:
            print(f"site {site['kind']}{site['layer']} not found verbatim — "
                  "file does not match the pinned intake; aborting", file=sys.stderr)
            return 1
        text = text.replace(o, n, 1)
        applied += 1

    orig.write_text(f.read_text())
    f.write_text(text)
    print(f"patched {f}: {applied}/8 pairs, backup {orig}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
