You're right to push back. The previous report had real problems: it misread "SDA" (Seventh-day Adventist acapella, not "Sweet Dreams Acapella"), it quietly moved your heavy processing to a *server* when you said 100% on-device, and several of its citations/claims don't survive checking. Let me do this properly — verified repos, verified model names, verified licenses, and a realistic on-device plan for an A14/6GB iPhone. Starting with your own repo and the current state of the art.
You're right to push back. The earlier report had real errors — it misread **SDA as "Sweet Dreams Acapella"** (you mean **Seventh‑day Adventist** male‑voice acapella: T1/T2/baritenor/baritone/bass, the King's Heralds / Breath of Life Quartet / Take 6 / Committed tradition), it proposed a **server‑side pipeline that violates your 100% offline requirement**, it conflated Smule's model with separation, it recommended CREPE/pYIN as primary pitch engines (both are *not* the best available), and it cited repos I could not verify. I went and did the actual combing — GitHub, Hacker News, FMHY, arXiv, Hugging Face, and **your own repo** — and verified everything below by opening the pages. This is the source pack your agent needs.

First, what I found in **your** stack, because it changes the recommendation: `thesagezm/speechnotes-ios` is Swift, generated via **XcodeGen** on GitHub Actions macOS runners, sideloaded unsigned via SideStore/LiveContainer (so **static linking is mandatory**), and it already runs **four ONNX TTS engines on CPU through ONNX Runtime via your SPM mirror `onnxruntime-swift-package-manager` tag 1.24.2** — Kokoro (~341 MB fp32 / ~92 MB int8), Nano Edge (~157 MB), Phonon (~192 MB), Supertonic (~399 MB), with CI "spike" contract tests per model. You also have `speechnotes-android` (Kotlin) and `speechnotes-linux` (Rust). **That is exactly the pattern this music app should reuse: one ORT runtime, many models, CPU‑first, int8/fp16, CI spike tests, static link, cross‑platform core.** A 80–230 MB separation model is *smaller* than Kokoro fp32 you already ship. Feasibility is not the question; accuracy on close male harmony is.

> **Changelog:** 2026-11-21 — Addendum A appended (dettato & Muskey, verified by Leto against primary sources; §1–10 below are the original M0 source pack, unchanged).
> **Ownership:** Docs/RESEARCH.md is now maintained by Leto (AGENTS §12 file map, D-26).

---

## 1. The honest feasibility map (read this before anything else)

Your instinct is correct: **parts 1 and 2 are the hard part, and nobody has fully solved them.** Here is what the verified evidence actually says, with numbers:

| Your requirement | State of the art (verified) | Realistic expectation on iPhone 12 Pro Max CPU |
|---|---|---|
| **1. Separate 5 male voices** | Per‑singer a cappella separation is an active 2025–2026 research frontier. Fine‑tuned HTDemucs on ACappellaSet gives **NSDR S 4.05 / A 4.41 / T 7.91 / B 10.50 dB** ([ACappellaSet paper](https://openreview.net/pdf?id=rAPN9Ir7jt)). Pretrained jaCappella MRDLA gives **SI‑SDR lead 8.7 / S 11.8 / A 14.7 / T 11.3 / B 10.2 / VP 22.1** ([model card](https://huggingface.co/jaCappella/MRDLA_jaCappella_VES_48k)). | Bass/baritone separate well; **T1 vs T2 vs baritenor bleed heavily** (overlapping ranges, same vowels, same lyrics). Unison passages are *physically* inseparable by pitch. Plan for bleed, not perfection. |
| **2. Notes per voice** | First end‑to‑end part‑aware choral AMT (**PawCT**, Oct 2026) reports **macro part‑aware note F1 = 0.225 @50 ms** ([arXiv 2610.09861](https://arxiv.org/abs/2610.09861)). That is the *best published* number — and it is low. | Per‑voice note tracks are achievable but noisy. **Grade against a note track, not against a "perfect" stem.** Use score alignment when you have the hymn score. |
| **3. Mute/attenuate others** | Trivial once you have stems (mix bus). | Works, but muted parts will be faintly audible (bleed). Offer "focus mix" (target loud, others −12 dB) rather than hard solo. |
| **4. Simply Sing / Smule pitch matching** | Solved. Live monophonic pitch is mature and tiny. | **SwiftF0: F1 0.781, 180× real‑time on one CPU core, 14,386 params, MIT, ONNX** ([repo](https://github.com/lars76/swift-f0), [benchmark](https://github.com/lars76/pitch-benchmark)). Fully feasible live. |
| **5. Learner mode + grading** | Solved at the algorithm level (UltraStar/Performous/Nightingale scoring). | Custom Swift scoring on top of pitch + note tracks. |
| **6. Music theory from the song** | Solved *symbolically* once you have note tracks (chords = vertical pitch‑class sets; no ML needed). | Deterministic, tiny, offline, explainable. |
| **7. Ear training / chord completion** | Solved (play N−1 stems or re‑synth, grade the missing voice). | Feasible; barbershop tags + hymn scores give ready content. |

**The strategic reframe that makes this buildable:** do **not** bet the app on perfect 5‑way audio separation. Build a **hybrid pipeline**: (a) optional instrumental removal, (b) per‑part separation *with bleed*, (c) **multi‑f0 estimation + voice assignment** to get per‑voice pitch contours even when stems bleed, (d) **optional score‑informed alignment** using the SDA hymnal SATB score (you have these — see §8), and (e) grade on the resulting **note track**. This is precisely the architecture the research converges on (Cuesta, Schramm, PawCT, ACAMate). It is also what makes the theory/ear‑training sections robust.

---

## 2. The recommended stack (CPU‑first, ORT‑centric, matches your app)

| Layer | Pick | License | Why / source |
|---|---|---|---|
| **Inference runtime** | **ONNX Runtime 1.24.2 via your SPM mirror** (CPU MLAS now; CoreML EP later) | MIT | You already ship it. [ORT iOS build](https://onnxruntime.ai/docs/build/ios.html), [CoreML EP](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html), [SPM](https://swiftpackageindex.com/microsoft/onnxruntime-swift-package-manager) |
| **Live mic pitch + note segmentation** | **SwiftF0** (primary) | MIT | 14,386 params, ONNX, 16 ms frames, confidence + loudness, **`segment_notes()` + `export_to_midi()` built in**, `fmin/fmax` range filter (perfect for voice‑part priors), streaming push/flush. [repo](https://github.com/lars76/swift-f0), [paper](https://arxiv.org/abs/2508.18440), [ONNX weights](https://huggingface.co/aaatmy/swift-f0-onnx) |
| **Zero‑lookahead live pitch + singing VAD** | **NanoPitch** (Smule Labs) | check LICENSE | ~333K params, **pure C inference engine** (`nanopitch.c`: mel+GRU+Viterbi), causal (no lookahead), RTF 0.1–0.3 even in WASM → trivially real‑time native on A14. [repo](https://github.com/smulelabs/NanoPitch) |
| **Offline reference pitch (highest accuracy)** | **RMVPE** (ONNX) | verify weights | F1 0.768, statistically tied with SwiftF0, robust in polyphony. [RVC](https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI), [paper](https://doi.org/10.21437/Interspeech.2023-528) |
| **Polyphonic note transcription (per stem)** | **basicpitch.cpp** (Spotify Basic Pitch, C++20 + ORT) | MIT | Higher‑level notes→MIDI, **ort‑builder minimal ORT build** (trim ops, compile weights to .c/.h → tiny binary). [repo](https://github.com/sevagh/basicpitch.cpp), [upstream](https://github.com/spotify/basic-pitch) (Apache‑2.0, CoreML/TFLite/ONNX) |
| **Vocals vs instrumental (on‑device)** | **demucs.cpp** (htdemucs fp16, 81 MB) | MIT | C++17 + Eigen + ggml‑format weights, no Python, quality ≈ PyTorch, low‑memory design. [repo](https://github.com/sevagh/demucs.cpp) |
| **Efficient SOTA vocal separation** | **windowed‑roformer** (Smule) | MIT | MB‑R class, **11.17 dB SDR (92% of full), 44.5× fewer attention FLOPs**, designed for edge CPUs. [repo](https://github.com/smulelabs/windowed-roformer), [paper](https://arxiv.org/abs/2510.25745) |
| **Per‑singer separation (research baseline to fine‑tune)** | **SepACap** + **jaCappella MRDLA/XUMX** | research/verify | SepACap: 7 stems incl. finger_snap+VP, 24 kHz, SOTA JaCappella. [repo](https://github.com/ETH-DISCO/SepACap), [HF](https://huggingface.co/Tino3141/sepacap). MRDLA pretrained 6‑part. [HF](https://huggingface.co/jaCappella/MRDLA_jaCappella_VES_48k), [code](https://github.com/TomohikoNakamura/asteroid_jaCappella) |
| **Multi‑f0 + voice assignment** | **Cuesta multi‑f0 CNN** + range‑prior Viterbi | verify | [multi‑f0 repo](https://github.com/helenacuesta/multif0-estimation-polyvocals), [voice assignment TISMIR 2022](https://transactions.ismir.net/articles/121), [Schramm ISMIR 2017](https://archives.ismir.net/ismir2017/paper/000026.pdf) |
| **Portable DSP core (Android/Linux)** | **sevagh/pitch-detection** (MPM/YIN/ACF, C++) + vDSP/Accelerate on iOS | MIT | [repo](https://github.com/sevagh/pitch-detection). Avoid aubio (GPL) in the shipped core. |
| **Mic cleanup / VAD** | **silero-vad** (ONNX) + **GTCRN/DeepFilterNet** | MIT | silero <1 ms/30 ms chunk. [silero](https://github.com/snakers4/silero-vad), [DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) |
| **Key/tempo practice shift** | **AVAudioUnitTimePitch** (native) → **signalsmith-stretch** later | MIT (stretch) | [stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch) (C++11 header‑only) |
| **Reference tone synth (ear training)** | **TinySoundFont** + FluidR3/GeneralUser GS choir patch | MIT (tsf) | Re‑synth SATB from note tracks, transposed, zero artifacts. [tsf](https://github.com/schellingb/TinySoundFont) |
| **Notation rendering** | **OSMD + VexFlow** in WKWebView (or **Verovio** C++) | BSD/MIT (OSMD/VexFlow); LGPL (Verovio) | [OSMD](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay), [VexFlow](https://www.vexflow.com/), [Verovio](https://www.verovio.org/) |
| **Theory engine** | **tonaljs/tonal** | MIT | chords/scales/keys/intervals. [repo](https://github.com/tonaljs/tonal) |
| **Scoring/UX reference** | **Nightingale**, **UltraStar Play**, **Performous**, **UltraSinger** | GPL (study only) | see §5 |

---

## 3. Separation dossier (the hard part)

### 3a. Accuracy ranking — what "best" actually means
The community benchmark is **MVSEP Quality Checker** ([leaderboard](https://mvsep.com/quality_checker), [platform paper TISMIR](https://reference-global.com/download/article/10.5334/tismir.366.pdf)). Verified finding: **Mel‑Band‑RoFormer and BS‑RoFormer variants dominate vocal separation; SCNet wins bass/drums/other.** The Smule windowed‑roformer paper confirms MB‑R/BS‑R "dominate the top positions for vocal separation" and cites the [KimberleyJensen Mel‑Band‑Roformer‑Vocal‑Model](https://github.com/KimberleyJensen/Mel-Band-Roformer-Vocal-Model) and viperx `bs-roformer-1297` as the top community checkpoints. Architectures: [BS‑RoFormer](https://arxiv.org/abs/2309.02612), [Mel‑Band RoFormer](https://arxiv.org/abs/2310.01809), [Mel‑RoFormer (also does vocal melody transcription)](https://arxiv.org/pdf/2409.04702). Training framework: [ZFTurbo/Music‑Source‑Separation‑Training (MSST)](https://github.com/ZFTurbo/Music-Source-Separation-Training) (MIT, [MSST paper 2026](https://arxiv.org/abs/2607.23395), even a [53‑stem BS‑Roformer release](https://github.com/ZFTurbo/Music-Source-Separation-Training/releases)). Model zoo / CLI: [nomadkaraoke/python-audio-separator](https://github.com/nomadkaraoke/python-audio-separator) (MDX/VR/Demucs/MDX23C/BS‑R/Mel‑R, ONNX, CPU). Implementations: [lucidrains/BS‑RoFormer](https://github.com/lucidrains/BS-RoFormer), [SonyResearch/mimo-audio-separation](https://github.com/SonyResearch/mimo-audio-separation).

**But these are 2‑stem (vocals/instrumental) or 4‑stem pop models. They do NOT separate T1 from T2.** For that you need §3c.

### 3b. On‑device candidates (CPU, your phone)
- **demucs.cpp** — MIT, C++17/Eigen, **fp16 ggml weights: htdemucs‑4s 81 MB, 6s 53 MB, ft‑vocals 81 MB (bag of 4 = 324 MB), v3 160 MB**, "quality practically identical to PyTorch," low‑memory design, multithreaded. Pre‑converted weights on HF. This is your **baseline instrumental‑removal engine** and it is *smaller than Kokoro fp32 you already ship*. Port note: OpenMP → GCD/std::thread; Eigen uses NEON on arm64.
- **windowed‑roformer (Smule)** — MIT, **11.17 dB vs 12.12 dB full MB‑R (−0.95 dB, 92%), 44.5× fewer attention FLOPs**, W=10 window + 8 sink tokens. The paper explicitly targets "consumer devices… limited parallelism… raw FLOPs bottleneck." **Caveat:** Bleedless score drops (30.14 vs 41.00) — more residual bleed in *silent* segments; and it uses PyTorch **FlexAttention** (CUDA‑only) — for ONNX/iOS you must re‑express the window+sink mask as a standard additive attention bias (the mask is trivial: `|i−j|≤W/2 OR i<S OR j<S`). Params unchanged from MB‑R (large) → fp16/int8 + benchmark on A14.
- **demucs‑rs** ([nikhilunni](https://github.com/nikhilunni/demucs-rs), [HN Mar 2026](https://news.ycombinator.com/item?id=47234566)) — Rust/Burn, F16 safetensors, **4‑stem 84 MB / 6‑stem 84 MB / ft bag 333 MB**, Metal/Vulkan/WASM, VST3/CLAP+SwiftUI. Confirms the real model sizes (the earlier "1.26 GB" claim was wrong).
- **Proof it runs on Apple:** [transposify (evanhu1)](https://github.com/evanhu1/transposify) — **HTDemucs converted to CoreML**, sliding windows, real‑time macOS ([HN Aug 2026](https://news.ycombinator.com/item?id=49425400)); [TrackSplit](https://tracksplit.co/) — Swift+HTDemucs, ~90 s/4‑min on M1, **shipped on Mac App Store** ([HN Dec 2025](https://news.ycombinator.com/item?id=46238502)); [Soniqo Music](https://soniqo.audio/music) — **free on‑device vocal separation on iPhone/iPad/Android** ([HN Nov 2026](https://news.ycombinator.com/item?id=50424177), [github.com/soniqo](https://github.com/soniqo)). Your phone is the *target* of this ecosystem, not an outlier.

### 3c. Per‑singer / choral separation — the actual research your agent must fork
This is where the SDA‑specific work lives. Verified, directly relevant:

- **ACappellaSet + ACAMate** (Pan, Ju, Dong — U. Michigan, [OpenReview](https://openreview.net/pdf?id=rAPN9Ir7jt)): 55 pro a cappella songs, **SATB+VP stems** (+ occasional baritone/mezzo), rough/dry/wet versions, 44.1k/24‑bit. **Fine‑tuned HTDemucs NSDR: S 4.05 / A 4.41 / T 7.91 / B 10.50**; **two‑stage (VP first → 5‑stem) beats one‑stage 6‑stem**; **wet/reverb degrades** (VP 8.73 dry → 4.84 wet). The proposed **ACAMate workflow is literally your app**: separate parts → custom mixes → pattern visualization → pitch/rhythm/dynamics feedback → iterative practice. **Read this paper first.**
- **SepACap** (Lanzendörfer, Pinkl, Grötschla — ETH, [arXiv 2509.26580](https://arxiv.org/abs/2509.26580), [code](https://github.com/ETH-DISCO/SepACap), [HF checkpoint](https://huggingface.co/Tino3141/sepacap)): SepReformer (speaker‑separation SOTA) adapted with **periodic activations + composite loss for silent stems + power‑set augmentation** → SOTA on JaCappella full‑ensemble *and* subset (variable singer count). **7 stems: alto, bass, finger_snap, lead_vocal, soprano, tenor, vocal_percussion**, 24 kHz. This is the most advanced multi‑singer a cappella separator and the best fine‑tuning starting point for SDA male parts.
- **jaCappella pretrained models** (Nakamura, [ICASSP 2023 corpus](https://arxiv.org/abs/2211.16028), [demo](https://tomohikonakamura.github.io/Tomohiko-Nakamura/demo/jaCappella_sep/), [code](https://github.com/TomohikoNakamura/asteroid_jaCappella)): **ready‑trained 6‑part separators** [MRDLA](https://huggingface.co/jaCappella/MRDLA_jaCappella_VES_48k) (multiresolution wavelet, [TASLP 2021](https://doi.org/10.1109/TASLP.2021.3072496)) and [XUMX](https://huggingface.co/jaCappella/XUMX_jaCappella_VES_48k) (Open‑Unmix based), 48 kHz, SI‑SDR lead 8.7/S 11.8/A 14.7/T 11.3/B 10.2/VP 22.1. **You can run these on SDA acapella today** (Japanese‑trained; fine‑tune to T1/T2/baritenor/baritone/bass).
- **Choral separation lineage:** [Petermann et al. ISMIR 2020 "Deep Learning Based Source Separation Applied To Choir Ensembles"](https://arxiv.org/abs/2008.07645); [Chandna et al. Frontiers 2022 choral framework](https://www.frontiersin.org/journals/signal-processing/articles/10.3389/frsip.2022.808594/full); [Gover & Depalle ISMIR 2020 **score‑informed** Wave‑U‑Net choral separation](https://program.ismir2020.net/static/final_papers/135.pdf); [Sarkar et al. Interspeech 2021 "Vocal Harmony Separation Using Time‑Domain Neural Networks"](https://www.isca-archive.org/interspeech_2021/sarkar21_interspeech.pdf); [Chen et al. ISMIR 2022 "Improving Choral Music Separation through Expressive Synthesized Data" + code/dataset](https://github.com/RetroCirce/Choral_Music_Separation) (8.2 h synth from JSB Chorales + sampled plugins → improves real choral separation).
- **Score‑informed note separation (new):** [arXiv 2609.29071 (Sep 2026)](https://arxiv.org/abs/2609.29071).
- **Target‑speaker extraction (the unison fallback, research):** [VoiceFilter‑Lite (on‑device, streaming)](https://arxiv.org/abs/2009.04323) + [Google blog](https://research.google/blog/improving-on-device-speech-recognition-with-voicefilter-lite/), [VoiceFilter impl](https://github.com/maum-ai/voicefilter), [SpeakerBeam](https://github.com/BUTSpeechFIT/speakerbeam), embeddings [3D‑Speaker/CAM++](https://github.com/modelscope/3D-Speaker) + [WeSpeaker](https://github.com/wenet-e2e/wespeaker) + [speakeronnx (pure ORT)](https://github.com/TigreGotico/speakeronnx). Idea: enroll each singer from a solo passage → extract that singer even in unison. Ambitious phase‑3, not baseline.
- **Prompted separation (future):** [Meta SAM‑Audio (Dec 2025)](https://github.com/facebookresearch/sam-audio) — text/visual/temporal‑prompted "segment anything in audio" ([paper](https://arxiv.org/abs/2512.18099), [HF large](https://huggingface.co/facebook/sam-audio-large), [community kit](https://github.com/openmirlab/sam-audio-kit)). Too big for phone now; watch for distilled variants ("bass singer" prompt).

### 3d. The fine‑tuning data recipe (both pretrained + custom, as you asked)
**Pretrained path:** start from jaCappella MRDLA / SepACap / HTDemucs, fine‑tune on SDA‑style stems. **Custom path (the commercial‑safe goldmine):** synthesize unlimited perfectly‑labeled SATB stems from hymn MIDI/MusicXML:
- **Singing synthesis:** [OpenUtau](https://openutau.com/ENUNU-NNSVS-Support/) (multi‑track, MIDI import, ENUNU/NNSVS/DiffSinger voicebanks), [NNSVS](https://github.com/nnsvs/nnsvs), [DiffSinger](https://github.com/MoonInTheRiver/DiffSinger) (+ [openvpi refactor](https://github.com/openvpi/DiffSinger)). ACappellaSet authors confirmed **Synthesizer V Studio 2 Pro / VOCALOID6** produce satisfactory English a cappella from MIDI+syllables; [Moises Voice Studio](https://studio.moises.ai/voice-studio/) for timbre cloning augmentation.
- **Augmentation:** pitch‑shift ±1 semitone, voice‑clone to different timbres, **church reverb IRs** ([OpenAIR](https://www.openairlib.net/), [pyroomacoustics](https://github.com/LCAV/pyroomacoustics) MIT, [pedalboard](https://github.com/spotify/pedalboard) Apache‑2.0). ACappellaSet showed wet mixes *hurt* separation — train on dry+rough, augment with reverb for robustness.
- **Power‑set augmentation** (SepACap): mix subsets of parts so the model handles variable active‑singer counts (SDA arrangements drop voices in verses).

**Datasets (with the license flags that matter for a commercial app):**

| Dataset | Parts | License / commercial flag | Source |
|---|---|---|---|
| ACappellaSet | SATB+VP (+Bar) | research; check release | [OpenReview](https://openreview.net/pdf?id=rAPN9Ir7jt) |
| jaCappella | lead+S+A+T+B+VP, 35 songs | **copyright‑leared corpus; model license "see dataset page"** | [arXiv](https://arxiv.org/abs/2211.16028), [HF](https://huggingface.co/jaCappella) |
| Cantoría | SATB quartet + organ | research | [Zenodo](https://zenodo.org/records/5878677) |
| Choral Singing Dataset (CSD) | SATB, 16 singers | research | [Zenodo](https://zenodo.org/records/2649950) |
| Dagstuhl ChoirSet (DCS) | SATB, larynx mics | research | [Zenodo](https://zenodo.org/records/3956666), [TISMIR](https://transactions.ismir.net/articles/10.5334/tismir.48), [mirdata loader](https://mirdata.readthedocs.io/en/stable/_modules/mirdata/datasets/dagstuhl_choirset.html) |
| ChoralSynth | SATB synth, 20 songs | check | [MTG/ChoralSynth](https://github.com/mtg/choralsynth), [arXiv](https://arxiv.org/abs/2311.08350) |
| Chen synth choral (JSB) | SATB synth 8.2 h | check | [RetroCirce](https://github.com/RetroCirce/Choral_Music_Separation) |
| **GTSinger** | 20 singers, 9 langs, 80.59 h, scores | **CC BY‑NC‑SA 4.0 — NON‑COMMERCIAL** | [GitHub](https://github.com/AaronZ345/GTSinger), [arXiv](https://arxiv.org/abs/2409.13832) |
| **M4Singer** | SATB, 20 singers, 29.77 h | **CC BY‑NC 4.0 — NON‑COMMERCIAL** | [site](https://m4singer.github.io/), [NeurIPS](https://proceedings.neurips.cc/paper_files/paper/2022/hash/2de60892dd329683ec21877a4e7c3091-Abstract-Datasets_and_Benchmarks.html) |
| VocalSet | 20 singers, 10.1 h solo | CC BY (verify) | [Zenodo](https://zenodo.org/records/1193957), [ISMIR](https://ismir2018.ircam.fr/doc/pdfs/114_Paper.pdf) |
| SingStyle111 | multilingual incl. English | **CC BY 4.0 — commercial OK w/ attribution** | [CMU PDF](https://www.cs.cmu.edu/~music/shuqid/SingStyle111__A_Multilingual_Singing_Dataset_With_Style_Transfer.pdf) |
| MUSDB18‑HQ | pop 4‑stem | check (commonly NC‑SA) | [zenodo](https://zenodo.org/records/3338373) |

**Honest licensing conclusion:** GTSinger/M4Singer (the best multilingual SATB corpora) are **non‑commercial** — you cannot use them to train weights for a paid app without permission. **The clean commercial path is synthetic data** (your own hymn MIDI + permissively‑licensed voicebanks + CC‑BY solo corpora + church IRs). This is exactly what Chen/ACappellaSet validated. Flag this to your agent on day one.

---

## 4. Pitch + notes dossier (the other hard part)

### 4a. The empirical pitch ranking (this settles "most accurate")
[lars76/pitch-benchmark](https://github.com/lars76/pitch-benchmark) (MIT, v2.1 Sep 2026): **19 monophonic trackers × 10 corpora × 9 conditions** (clean + 8 noise/reverb/mic combos), scored **pitch F1 @50 cents**, speed pinned to one CPU core:

| Tracker | F1@50c ↑ | Speed (×RT, 1 core) |
|---|---|---|
| **SwiftF0** | **0.781** | **179.6** |
| **RMVPE** | 0.768 | 13.6 |
| FCPE | 0.728 | 27.8 |
| TorchCREPE / CREPE | 0.691 / 0.689 | **0.4** (slow!) |
| PESTO | 0.680 | 20.0 |
| SWIPE | 0.610 | 50.3 |
| Harvest | 0.600 | 18.4 |
| PENN | 0.560 | 4.7 |
| BasicPitch (as mono tracker) | 0.557 | 59.7 |
| **pYIN** | **0.506** (weakest) | 9.6 |

SwiftF0 ≈ RMVPE (statistically tied). **This corrects the earlier report: CREPE is too slow for live use (0.4× RT) and pYIN is the *least* accurate — neither should be your primary engine.** The benchmark dataset is CC BY‑NC‑SA (research); the *code* is MIT. Use it as your evaluation harness.

### 4b. The pitch engines to ship
- **SwiftF0 (primary, MIT):** 14,386 params, **only deps numpy + onnxruntime** → drops straight into your ORT SPM stack. 16 kHz, 16 ms frames, F♯1–C7 (covers bass low C2 through soprano high C6), per‑frame **confidence + loudness_db**, **`fmin/fmax` band restriction** (set per voice part: bass ~E2–G3, baritone ~A2–D4, baritenor ~C3–F4, T2 ~E3–A4, T1 ~G3–E5 — calibrate per group), **`segment_notes()` → `Note(start,end,pitch_hz)` + `export_to_midi()`** (the higher‑level note output you asked for), streaming `push/flush` (176 ms lookahead — fine for singing feedback), 30 s windows = constant memory. [repo](https://github.com/lars76/swift-f0), [training/ONNX export](https://github.com/lars76/swift-f0-training), [live ONNX‑Web demo](https://swift-f0.github.io/).
- **NanoPitch (zero‑lookahead live ribbon + singing VAD, Smule Labs):** ~333K params, RNNoise‑style causal conv + 3×GRU, **360 sigmoid pitch bins @20‑cent resolution (6 octaves)**, VAD head, **Viterbi decoding (offline + realtime)**, **pure C engine `nanopitch.c/h`** (mel FFT + GRU + Viterbi) → compile directly into iOS/Android/Linux *without ONNX*. RTF 0.1–0.3 in WASM ⇒ native A14 ≪ real‑time. Trained on GTSinger (RMVPE pseudo‑labels) + FSDNoisy18k noise; clean RPA ~89%. [repo](https://github.com/smulelabs/NanoPitch), [data](https://huggingface.co/datasets/smulelabs/NanoPitch-PreExtract). **Use NanoPitch for the instant Smule‑style pitch ribbon (causal, no lag) and SwiftF0/RMVPE for the graded note track.** Check NanoPitch's LICENSE file before shipping.
- **RMVPE (offline reference, highest robustness in polyphony):** [Dream-High/RMVPE](https://github.com/Dream-High/RMVPE), ONNX in [RVC assets](https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI), pure‑ONNX deployment pattern in [rvc-onnx](https://github.com/dev6699/rvc-onnx) / [voiceclonnx](https://github.com/TigreGotico/voiceclonnx). Verify weight license.
- **CREPE (MIT, fallback/baseline):** [marl/crepe](https://github.com/marl/crepe), [torchcrepe](https://github.com/maxrmorrison/torchcrepe), [onnxcrepe](https://github.com/yqzhishen/onnxcrepe). Fine for offline, not live.
- **PESTO:** fast, ONNX export + streaming (~0.7 ms), **but LGPL‑3.0** ([repo](https://github.com/SonyCSLParis/pesto)) — static‑linking into your LiveContainer build is legally awkward; prefer MIT SwiftF0. [FCPE](https://github.com/CNChTu/FCPE) ([ONNX](https://huggingface.co/gzivdo/fcpe-onnx)) is a lighter alternative; verify license.

### 4c. Multi‑f0 + voice assignment (how you get *per‑voice* notes when stems bleed)
- **Cuesta, McFee, Gómez — "Multiple F0 Estimation in Vocal Ensembles using CNNs" (ISMIR 2020):** [arXiv](https://arxiv.org/abs/2009.04172), [code](https://github.com/helenacuesta/multif0-estimation-polyvocals). Outputs a pitch‑salience matrix over all voices.
- **Cuesta et al. — "Voice Assignment in Vocal Quartets Using Deep Learning Models Based on Pitch Salience" (TISMIR 2022):** [paper](https://transactions.ismir.net/articles/121). Assigns salience peaks to S/A/T/B.
- **Schramm, McLeod, Steedman, Benetos — "Multi‑pitch Detection and Voice Assignment for A Cappella Recordings of Multiple Singers" (ISMIR 2017):** [paper](https://archives.ismir.net/ismir2017/paper/000026.pdf) — *exactly* your barbershop‑style problem.
- **PawCT (Oct 2026, first end‑to‑end part‑aware choral AMT):** [arXiv 2610.09861](https://arxiv.org/abs/2610.09861) — joint onset/offset/frame + part‑presence + **range prior + ordered‑continuity** (bass always lowest, no voice crossing). F1 0.225 part‑aware / 0.382 part‑agnostic. Code+demos linked. **This is your north‑star architecture for requirement 2.**
- **Basic Pitch (Spotify, Apache‑2.0):** polyphonic note transcription per stem; [repo](https://github.com/spotify/basic-pitch) (CoreML/TFLite/ONNX, [iOS issue #61](https://github.com/spotify/basic-pitch/issues/61)), **[basicpitch.cpp](https://github.com/sevagh/basicpitch.cpp)** (MIT, C++20+ORT+Eigen+libremidi, ort‑builder minimal build). Run it on each separated stem → note events → filter by part range + confidence + min duration.
- **The assignment algorithm your agent should implement (tractable, no ML required):** per frame, take multi‑f0 peaks (Cuesta/basic‑pitch) → **Viterbi/HMM over pitch candidates with costs = (a) voice‑range prior, (b) melodic smoothness, (c) cross‑part ordering (bass<baritone<baritenor<T2<T1), (d) harmonic plausibility**. SDA arrangements rarely cross voices and bass is always lowest — these are *strong* constraints that make assignment far more reliable than generic pop. When a hymn score exists, **DTW‑align the score to the audio** ([libfmp](https://github.com/meinardmueller/libfmp), [partitura](https://github.com/CPJKU/partitura)) and snap note tracks to the score — this is the score‑informed path (Gover, Ewert/Müller) and it is your accuracy escape hatch.

### 4d. Scoring, visualization, and the UltraStar shortcut (higher‑level libs you asked for)
- **Nightingale** ([rzru/nightingale](https://github.com/rzru/nightingale), **GPL‑3.0**, 1.6k★, v1.4.1 Nov 2026): the closest existing app to your vision — Rust core + React/Tauri UI + persistent Python analyzer (loopback IPC, **BLAKE3‑hash artifact caching**), UVR Karaoke/Demucs separation, WhisperX word‑timed lyrics, **microphone pitch scoring**, key/tempo, guide‑vocal mix, **room‑latency compensation**, 2–4 player multiplayer. **Study its scoring docs and architecture; do not copy GPL code into a closed product.** [HN](https://news.ycombinator.com/item?id=47422942), [architecture writeup](https://www.negabaro.com/en/blog/tech/how-nightingale-karaoke).
- **UltraStar ecosystem** (the de‑facto open singing‑game standard, `.txt` note format = `start length pitch lyric`): [USDX](https://github.com/UltraStar-Deluxe/USDX) (Pascal, 6 players, pitch+rhythm scoring), [UltraStar Play](https://ultrastar-play.com/) (Unity, **desktop+mobile**, song editor, companion‑app‑as‑mic, cooperative score; [uses aubio YIN](https://github.com/UltraStar-Deluxe/Play/issues/12)), [Vocaluxe](https://www.vocaluxe.org/) (C#), [Melody Mania](https://open-music-games.org/faq/) fork. **Adopt the UltraStar note format as your internal reference track** → instant compatibility with existing editors/players for prototyping.
- **UltraSinger** ([rakuri255/UltraSinger](https://github.com/rakuri255/UltraSinger)): audio → stems → pitch → **UltraStar .txt + MIDI + notes** automatically. Forkable pipeline. Also [ultrasongs](https://github.com/pablopramparo/ultrasongs) (Demucs→torchcrepe→UltraStar), [ultrastar_pitch](https://github.com/paradigmn/ultrastar_pitch).
- **Performous** ([performous/performous](https://github.com/performous/performous), GPL): C++ singing game, study its pitch/scoring engine.
- **Grading math (implement in Swift, no lib needed):** `cents = 1200·log2(f_user/f_ref)`; per‑note score = weighted(pitch accuracy within ±tolerance, coverage, sustain); defaults ±50 cents (configurable ±25/±10), onset grace 80–120 ms, **octave‑equivalence toggle** (bass singing a tenor part), vibrato tolerated if mean centered, breath gate via loudness_db/RMS, "golden note" bonus, per‑phrase aggregate, A–F grade + per‑note heatmap, SQLite history. Reference scoring docs: [frank_karaoke scoring.md](https://github.com/akitaonrails/frank_karaoke/blob/master/docs/scoring.md), [olincollege/Pitch-Detection](https://github.com/olincollege/Pitch-Detection).

---

## 5. On‑device engineering (iPhone 12 Pro Max, A14, 6 GB, CPU‑first)

- **Reuse your exact pattern:** ORT SPM 1.24.2 + XcodeGen + CI spike tests. Add CI jobs `separation-spike`, `pitch-spike`, `transcription-spike` mirroring your `kokoro-small-spike` (run each ONNX model on the macOS runner, assert valid output). Models live in your HF repo, downloaded once, offline after (airplane‑mode tested, like your TTS).
- **Memory/size budget:** you already ship Kokoro 341 MB fp32 / 92 MB int8. demucs.cpp htdemucs fp16 = **81 MB**; SwiftF0 ≈ **60 KB** (14k params); NanoPitch ≈ **1.3 MB**; basic‑pitch ≈ **2 MB**; silero ≈ **2 MB**; RMVPE ≈ **180 MB** (optional). Core bundle well under 200 MB. **int8 dynamic quant** (you already do Kokoro int8) for transformer/MatMul ops; conv‑heavy U‑Nets quantize less cleanly — fp16 first.
- **A14 realities:** 2 performance + 4 efficiency cores; set ORT `intra_op_num_threads ≈ 2–4` (don't oversubscribe); sustained CPU **throttles after ~1–2 min** → chunk separation (5–10 s windows, overlap‑add) and pace with `ProcessInfo.thermalState`. App jetsam limit ~3 GB on 6 GB devices (higher with `com.apple.developer.kernel.increased-memory-limit` entitlement) — keep peak <1.5 GB via chunking. Long imports: foreground progress, or `BGProcessingTask` when charging ("quality mode overnight").
- **Audio I/O (native, no ffmpeg):** `AVAudioFile`/`ExtAudioFile` decode **MP3 + FLAC natively** (FLAC since iOS 11); `UIDocumentPickerViewController` for import; `AVAudioConverter` resample; **encode stems as ALAC `.m4a`** (Apple Lossless, native encoder, ~half WAV size) — 5 stems × 4 min ≈ 100–120 MB/song, fine on 256 GB. Live mic: `AVAudioEngine` input tap (1024@48k ≈ 21 ms), `.playAndRecord`; **headphones + disable voiceProcessing** for fidelity (AEC/AGC distorts singing); speaker mode → voiceProcessing on so the mic rejects the backing track.
- **CoreML EP = phase 2 accelerator, same ONNX models, no retrain:** [ORT CoreML EP](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html) (explicit registration; prebuilt ORT Mobile iOS includes it; [minimal build](https://fs-eire.github.io/onnxruntime/docs/build/eps.html); [6.8× Apple Silicon speedup writeup](https://www.xybrid.ai/blog/onnx-runtime-6x-faster-apple-silicon-coreml); caveat [issue #25869](https://github.com/microsoft/onnxruntime/issues/25869)). Keep STFT/iSTFT in vDSP *outside* the model to avoid CoreML op‑coverage fallbacks. **Alternatives if needed:** [ExecuTorch iOS](https://docs.pytorch.org/executorch/stable/using-executorch-ios.html) (ObjC/Swift/C++, CoreML+MLX backends), ncnn/pnnx, LiteRT — but **one ORT runtime for everything** is the cleanest match to your app.
- **Portable C++ core for Android/Linux:** demucs.cpp + basicpitch.cpp + sevagh/pitch-detection + NanoPitch.c + signalsmith-stretch + TinySoundFont are all C/C++ → compile arm64 iOS / Android NDK / Linux. **Avoid GPL/AGPL in the shipped core:** [aubio is GPL](https://aubio.org/) ("not MIT or BSD"), [TarsosDSP GPL‑3.0](https://github.com/JorenSix/TarsosDSP/blob/master/LICENSE), essentia AGPL, FFTW GPL, Rubber Band GPL, PESTO LGPL, Nightingale/Performous/USDX GPL, Verovio LGPL, FluidSynth LGPL. **Safe (MIT/Apache/BSD):** SwiftF0, demucs.cpp, basicpitch.cpp, windowed-roformer, MSST, basic-pitch, CREPE, silero-vad, signalsmith-stretch, TinySoundFont, tonaljs, VexFlow, OSMD, mir_eval, museval, libfmp, partitura, pyroomacoustics, pedalboard. (Your sideload/static‑link context makes LGPL static linking especially awkward; and **NC training data bites commercial use regardless of distribution channel**.)
- **Minimal ORT binary trick:** [basicpitch.cpp's ort-builder](https://github.com/sevagh/basicpitch.cpp) converts ONNX→ORT format, **includes only needed ops/types, compiles weights into .c/.h** → cuts binary size. Apply to every model.

---

## 6. Theory + ear training + UI (requirements 6 & 7)

- **Notation rendering (clickable glyphs):** [OpenSheetMusicDisplay](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay) (MusicXML→VexFlow, BSD) + [VexFlow](https://www.vexflow.com/) (MIT) in an offline `WKWebView`; or [Verovio](https://www.verovio.org/) (C++, MEI/MusicXML→SVG, LGPL — flag); [alphaTab](https://github.com/CoderLine/alphaTab) (MPL‑2.0, cross‑platform Kotlin/Swift). Your "sigma / upside‑down G" = the **treble clef (G clef)** and **bass clef (F clef)** — build a tappable symbol glossary (clefs, key/time signatures, accidentals, ties, dots, dynamics). Content: [Open Music Theory](https://github.com/openmusictheory/openMusicTheory) (CC BY‑SA, adaptable with attribution).
- **Theory engine:** [tonaljs/tonal](https://github.com/tonaljs/tonal) (MIT) — notes/intervals/chords/scales/modes/keys. **Key insight: once you have per‑voice note tracks, chord/theory analysis is purely symbolic** — vertical pitch‑class sets → triad/inversion/roman‑numeral labeling, Krumhansl‑Schmuckler key detection from note histograms. No ML, deterministic, explainable, tiny. The "arrange the notes so they fit coherently" exercise = drag‑and‑drop SATB note blocks onto a staff, validated against the song's actual harmony.
- **Ear training / chord completion:** [GNU Solfege](https://www.gnu.org/software/solfege/) (GPL, study exercise design), [Functional Ear Trainer method](https://www.miles.be/) (tonic‑anchored scale‑degree hearing → transfers across keys, exactly your "harmonics in different keys"), [teoria.com](https://www.teoria.com/en/exercises/), [musictheory.net](https://www.musictheory.net/exercises), [musicca](https://www.musicca.com/exercises), [muted.io](https://muted.io/), [ToneSavvy](https://tonesavvy.com/) (UX references). **Your chord‑completion exercise:** pull a chord from the aligned note tracks → play N−1 voices (stems, or re‑synth via TinySoundFont) → user sings the missing voice → grade f0 vs target ±cents; **octave up/down variants** (your "harmonics over/under an octave"); **different keys** = re‑synthesize the note tracks transposed (zero artifacts, better than pitch‑shifting audio). **Barbershop bonus:** offer **just‑intonation** reference tuning (major third −14¢, fifth +2¢, barbershop 7th ≈ −31¢) vs equal temperament — a genuine differentiator for SDA/barbershop ears.
- **Ready content:** [BarbershopTags.com](https://www.barbershoptags.com/) — **7,175 free tags with learning tracks + sheet music** (perfect chord‑completion drills); [barbershop.org free music](https://www.barbershop.org/music/free-music-and-tags).

---

## 7. SDA hymn scores & lyrics (your score‑informed escape hatch)

You have a huge advantage most apps don't: **SDA hymns have known SATB scores.** Use them for score‑informed separation/alignment and theory exercises:
- [sdahymnals.com/Hymnal](https://sdahymnals.com/Hymnal/), [sdahymnal.org](https://www.sdahymnal.org/), [sdahymnal.net](https://sdahymnal.net/) (PowerPoint/PDF/sheet music/MP3/video per hymn), [transposedhymns.com](https://www.transposedhymns.com/) (SDA Hymnal 1985 transposed, 3‑part, audio+chords, PD hymns), [hymnsforworship.org SDA Hymnal 1985](https://hymnsforworship.org/sda-hymnal/the-seventh-day-adventist-hymnal-1985-edition/), [sdahymna.blogspot hymn list with keys](https://sdahymna.blogspot.com/p/sda-hymn-list.html).
- [Hymnary.org](https://hymnary.org) (tune metadata/keys/meters), [Cyber Hymnal](https://www.cyberhymnal.org/) (7,700+ hymns, MIDI+lyrics, PD emphasis), [Mutopia](https://www.mutopiaproject.org/)/[CPDL](https://www.cpdl.org/)/[IMSLP](https://imslp.org/) (PD scores, MusicXML/LilyPond). **Copyright note:** the 1985 SDA Hymnal compilation is copyrighted (Review & Herald); many individual hymn tunes are PD. User‑uploaded audio processed locally = private use; **distributing stems of copyrighted recordings or training on NC datasets is the legal risk** — keep processing on‑device, train on synthetic/PD/CC‑BY data.
- **Lyrics alignment (singing is hard for Whisper):** [STARS (unified singing transcription+alignment, 2025)](https://arxiv.org/abs/2507.06670), [HubertFA](https://github.com/wolfgitpr/HubertFA) / [SOFA_AI](https://github.com/colstone/SOFA_AI) / [SOFA](https://github.com/voicepaw/sofa) (singing‑oriented forced aligners), [AutoLyrixAlign](https://github.com/chitralekha-gupta/AutoLyrixAlign), [easyaligner](https://huggingface.co/blog/KBLab/easyaligner), [Charsiu](https://github.com/lingjzhu/charsiu), [forced-alignment-tools list](https://github.com/pettarin/forced-alignment-tools). Simplest robust path: user pastes hymn lyrics → align to your note track via DTW; optional [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT, CPU/Metal) for auto‑transcription with the caveat that it struggles on singing.

---

## 8. Landscape — what's built (HN / FMHY / apps), what to fork vs study vs avoid

**Verified Hacker News threads (real, opened):**
- [Soniqo Music — on‑device iPhone vocal separation (Nov 2026)](https://news.ycombinator.com/item?id=50424177) — proof your exact target ships.
- [demucs‑rs — Rust/Burn Demucs, browser/native/plugin (Mar 2026)](https://news.ycombinator.com/item?id=47234566) — real model sizes.
- [transposify — HTDemucs→CoreML real‑time macOS (Aug 2026)](https://news.ycombinator.com/item?id=49425400).
- [TrackSplit — Swift+HTDemucs, Mac App Store (Dec 2025)](https://news.ycombinator.com/item?id=46238502).
- [Nightingale — open‑source karaoke with scores (Mar 2026)](https://news.ycombinator.com/item?id=47422942).
- [StemDeck — local stem separation, mobile UI (Jul/Aug 2026)](https://news.ycombinator.com/item?id=48984326).
- [sevagh — free client‑side music demixer, Open‑Unmix C++→WASM (Jul 2023, 190 pts)](https://news.ycombinator.com/item?id=36707877).
- [Meta SAM‑Audio discussion](https://news.ycombinator.com/item?id=46293932); [Ask HN: enhance old SATB choir recordings (Dec 2025)](https://news.ycombinator.com/item?id=46184050) — *exactly your problem, validates demand*; [Ask HN: estimate notes from music (Oct 2020)](https://news.ycombinator.com/item?id=24752055); [Audio Decomposition (Nov 2024)](https://news.ycombinator.com/item?id=42098491); [Audionaut multitrack editor (Oct 2026)](https://news.ycombinator.com/item?id=49931031).

**FMHY:** [fmhy.net/ai → "Voice Removal / Separation"](https://fmhy.net/ai) lists MVSEP (50 free/day), MultiSong Leaderboard, Splitter, VocalRemover, etc.; [fmhy.net/audio](https://fmhy.net/audio) for Linux/Mac audio tools. (I could not identify "artcraft" as a relevant directory — if you meant a specific site, tell me and I'll comb it.)

**Commercial UX north stars:** **Melodyne DNA** (polyphonic per‑note editing — the accuracy gold standard, validates the multi‑f0+assignment approach), **RipX** (audio‑as‑notes per voice, mute/edit — closest commercial UX to your vision), Moises/LALAL/AudioShake (separation), Simply Sing/Smule/Sing Sharp/Vanido/Erol Singer's Studio (learning UX). Study these; build open.

**Fork list (permissive, ship‑safe):** demucs.cpp, basicpitch.cpp, windowed-roformer, MSST, python-audio-separator (prep), swift-f0, NanoPitch (check license), sevagh/pitch-detection, silero-vad, signalsmith-stretch, TinySoundFont, tonaljs, VexFlow/OSMD, mir_eval/museval, libfmp/partitura, pyroomacoustics/pedalboard, OpenUtau/NNSVS/DiffSinger (data gen).
**Study only (GPL/AGPL/LGPL — reimpl, don't copy):** Nightingale, Performous, USDX, Vocaluxe, UltraStar Play, aubio, essentia, TarsosDSP, PESTO, Verovio, FluidSynth, Rubber Band, GNU Solfege.
**Verify weights license before commercial:** RMVPE, FCPE, jaCappella models, UVR/MDX community checkpoints, SepACap, NanoPitch.

---

## 9. Agent‑ready build plan (phased, with acceptance criteria)

**Phase 0 — benchmark harness (week 1).** Fork [pitch-benchmark](https://github.com/lars76/pitch-benchmark) + [mir_eval](https://github.com/craffel/mir_eval) + [museval](https://github.com/sigsep/sigsep-mus-eval). Build a small SDA test set (your own recordings + PD hymns). Metrics: pitch F1@50c, RPA/RCA, voicing; separation SDR/NSDR (museval/fast_bss_eval); multi‑f0 P/R/F1; note onset/offset F1; part‑aware F1 (PawCT/MV2H). **Acceptance:** reproducible numbers on A14 (RTF, peak RAM, thermal) for every candidate model. *Benchmark before you commit — this is the discipline the earlier report lacked.*

**Phase 1 — live pitch + tuner ribbon (weeks 2–3).** Integrate **SwiftF0 ONNX** via your ORT SPM wrapper + **NanoPitch.c** for zero‑lag ribbon + silero-vad gating. CI `pitch-spike`. **Acceptance:** live cents‑deviation ribbon at <100 ms feedback, RTF <0.3, correct note names, octave toggle.

**Phase 2 — import + instrumental removal + stems (weeks 4–6).** MP3/FLAC import → **demucs.cpp htdemucs fp16** (or windowed-roformer) → ALAC stems → focus‑mix player (mute/attenuate). CI `separation-spike`. **Acceptance:** 4‑min song processed on‑device with progress + thermal pacing; usable vocal stem; A/B vs MVSEP reference.

**Phase 3 — per‑voice note tracks (weeks 7–12, the hard R&D).** Fine‑tune **SepACap / jaCappella MRDLA / HTDemucs** on synthetic SDA SATB (OpenUtau/DiffSinger + hymn MIDI + church IRs, power‑set augmentation). Add **Cuesta multi‑f0 + range‑prior Viterbi assignment** + **basicpitch.cpp** per stem; optional **score‑informed DTW** when hymn score provided. Adopt **UltraStar note format**. CI `transcription-spike`. **Acceptance:** per‑part note tracks with honest confidence; bass/baritone reliable, T1/T2 best‑effort; grading works off note tracks.

**Phase 4 — learner mode + grading (weeks 13–16).** Swift scoring engine (§4d), Simply‑Sing‑style scrolling canvas, sustain/vibrato/onset metrics, per‑phrase grades, SQLite history, customization (tolerance, octave equiv, tempo/key via AVAudioUnitTimePitch). **Acceptance:** end‑to‑end learn‑a‑part loop with reproducible grades.

**Phase 5 — theory + ear training (weeks 17–20).** tonaljs symbolic analysis from note tracks; OSMD/VexFlow notation + clickable glyph glossary; chord‑completion exercises (stems or TinySoundFont re‑synth), octave/key variants, JI/ET toggle; BarbershopTags + hymn content. **Acceptance:** exercises generated from any uploaded song.

**Phase 6 — acceleration + port (ongoing).** CoreML EP (fp16/ANE) on the same ONNX models; int8 where ops allow; port C++ core to Android (NDK) + Linux; ExecuTorch/ncnn only if ORT CPU proves insufficient.

---

## 10. What to tell your agent (the honest caveats)

1. **Perfect 5‑way separation of close male harmony does not exist yet.** Published per‑part SDR is ~4–14 dB (bleed is real); part‑aware note F1 is ~0.225. Design for bleed: focus mixes, confidence scores, note‑track grading, score alignment. Anyone promising clean T1/T2 isolation is selling you something.
2. **Unison is physically inseparable by pitch** — only timbre/target‑speaker methods (VoiceFilter‑Lite/SpeakerBeam) or score priors help; treat as phase‑3 research.
3. **Reverb hurts** (ACappellaSet: dry 8.73 → wet 4.84 VP SDR). Church recordings need de‑reverb ([MDX23C/UVR de‑reverb models via audio-separator](https://github.com/nomadkaraoke/python-audio-separator)) or dry‑trained models. Organ backing leaks into vocals — flag as a known failure mode.
4. **License landmines:** aubio/essentia/TarsosDSP/Performous/USDX/Nightingale/PESTO/Verovio are copyleft — **study, don't ship**. GTSinger/M4Singer are **non‑commercial** — don't train commercial weights on them. **Synthetic data is your clean path.** Verify every checkpoint's weight license.
5. **CPU‑first is right, but benchmark on the A14, not a laptop.** CREPE is 0.4× RT (too slow live); SwiftF0 is 180× RT (trivial). demucs.cpp fp16 81 MB is phone‑feasible; full MB‑R/BS‑R are heavy — use windowed‑roformer's 44.5× FLOP cut + quantization, and keep "quality mode" for overnight charging.
6. **Match your existing app:** ORT SPM 1.24.2, XcodeGen, CI spike tests, static link, HF model repo, ALAC stems, native AVFoundation I/O. Don't introduce Python on‑device, don't introduce a second runtime, don't introduce a server.

This is the verified, source‑rich foundation. The two papers to hand your agent **first** are [ACappellaSet/ACAMate](https://openreview.net/pdf?id=rAPN9Ir7jt) (your exact app, with real SDR numbers and a fine‑tuning recipe) and [PawCT](https://arxiv.org/abs/2610.09861) (per‑voice notes, the hardest part). The two repos to fork **first** are [swift-f0](https://github.com/lars76/swift-f0) (live pitch, MIT, ONNX, notes built‑in) and [demucs.cpp](https://github.com/sevagh/demucs.cpp) (on‑device separation, MIT, 81 MB). Everything else builds around those.

If you want, I can next produce (a) a concrete `project.yml` + CI spike‑job spec for the music module mirroring your speechnotes-ios setup, (b) a Swift/ORT integration sketch for SwiftF0 streaming + the grading engine, or (c) the synthetic SATB data‑generation pipeline (hymn MIDI → OpenUtau/DiffSinger → IR augmentation → MSST fine‑tune config). Tell me which and I'll go deep on it.

---

# Addendum A — dettato & Muskey (Nov 2026)

> **Verification (Leto, 2026-11-21):** every load-bearing fact below was checked against
> primary sources — GitHub repos + LICENSE/NOTICE files, HF model cards, and
> dettato's `retune.py` source. Benchmarks are **author-self-reported** but
> reproducible via the public HF dataset `kobimusic/dettato-benchmark`. Items I could
> not find in primary sources are marked **VERIFICATION PENDING**.

## A.1 · kobimusic/dettato — audio→MIDI, 4 stages, 28.1M params (Apache-2.0)

**Repo (verified):** https://github.com/kobimusic/dettato — LICENSE Apache-2.0 (verbatim),
NOTICE: "Dettato, Copyright 2026 KobiMusic. This product includes software and model
weights developed by KobiMusic." Python; active (pushed 2026-11-20); 174 stars observed
(fact sheet said ~127 — it is growing). Models (HF, all Apache-2.0 metadata):
transcriber 15.3M [`kobimusic/dettato`] · evidence repairer 4.9M [`kobimusic/dettato-evidence`]
· grouper 2.9M [`kobimusic/dettato-grouper`] · drums 5.0M [`kobimusic/dettato-drums`]
(drums needs ≥40 kHz audio — irrelevant for a cappella).

**Transcriber architecture (verified vs card):** pitch-equivariant lane network; harmonic
log-frequency spectrogram of 16 kHz mono audio, 3 bins/semitone from A0, one channel per
harmonic 0.5..7 plus a short-window channel; stem 2× 3×3 conv + strided conv → 20 ms
frames; trunk 368 ch, 15 ConvNeXt-style lane blocks at 40 ms with dilated time conv +
sparse pitch mixing at 1/2/12/19/24/28/31 semitones; axial attention on pitch and time
after blocks 5/10/15 plus a bidirectional GRU per lane; 2 refine blocks → 20 ms; heads =
onset/frame/offset for 88 keys × **2 voices per key**; windows 8 s every 2 s,
Hann-weighted average; thresholds onset 0.25 (voice2 0.30), offset 0.30, frame 0.40;
**confidence = onset probability**.

**Benchmarks (author-run; mir_eval + MuScriptor-paper rules, 50-cent tolerance;
reproducible via HF dataset `kobimusic/dettato-benchmark`):** composite **59.2** (9 sets:
8 MuScriptor-paper sets + Slakh2100 test) vs MuScriptor 1.3B **45.1** — at ~65× fewer
params. **CHORAL ROWS (verified verbatim from the card):** Dagstuhl ChoirSet dettato
**onset 55.9 / frame 82.0 / offset 44.4** vs MuScriptor **14.4 / 80.7 / 11.5**; Bach10
**91.9 / 94.2 / 87.7**. These are **PART-AGNOSTIC note scores** (instrument does not
count) — NOT part-aware; our PawCT ceiling (0.225 macro part-aware) still governs
assignment honesty (§3). Evidence repairer measured alone: +0.30 composite.

**Training data / license split (verified):**
- **Transcriber: TIER B (D-45, 2026-11-24) — NOT "commercially clean" by our
  verification.** Code + weights Apache-2.0 (upstream: "the code and the weights are
  under Apache-2.0, so commercial use is fine"); trained on synthetic instruments + CC
  URMP solos + **~20 morphed soundfonts** (the published ["soundfont babies"](https://kobi.music/research/making-soundfont-babies)
  technique) + CC vocals; "no copyrighted recordings"; no benchmark leakage. **THE
  RESIDUAL IS NOW RULED, NOT PENDING:** upstream **never names the ~20 soundfonts**
  (repo README + transcriber card + evidence card all say the training audio was
  "made in-house" and **"I will not be releasing it"**), and the upstream NOTICE
  attributes **no third-party samples** ⇒ **their file licenses are NOT VERIFIABLE
  from published sources.** The published technique's own reference implementation
  (`kobimusic/babymaker`) attributes its demo samples to **Sonatina Symphonic Orchestra
  (CC Sampling Plus 1.0)** — a sampling license, not a plain permissive software
  license — and names FluidR3_GM / TimGM6mb / A320U as the fonts it morphs (their own
  terms were NOT verified here, so nothing is asserted about them). ⇒ **Tier B: ship
  with recorded risk + human sign-off before commercial/App Store distribution; never
  describe these weights as clean.**
- **Evidence repairer: TIER B (D-45, 2026-11-24).** Apache-2.0; trained ONLY on
  in-house synthetic audio generated from an earlier transcriber checkpoint where exact
  notes are known — **and that in-house audio descends from the same unnamed ~20
  soundfonts**, so it inherits the same provenance residual (the earlier "card verified
  clean 2026-11-21" note was about the LICENCE, not the training-data provenance).
- **METHOD vs DATA (the actionable split):** the soundfont-babies TECHNIQUE is
  Apache-2.0 code and may be implemented/used; our own synthetic pipeline (X-301) must
  use **only soundfonts whose file license we verify one by one**, and we never
  redistribute fonts or rendered samples in the app.
- **Grouper: NC-ENCUMBERED — NEVER SHIP.** CC BY 4.0 sets (Slakh2100, MusicNet,
  GuitarSet, Medley-solos-DB; OpenMIC-2018 CC-BY labels + FMA CC audio) PLUS
  **MUSDB18 (academic use, tracks CC BY-NC-SA) and IRMAS (CC BY-NC-SA 3.0)**. Card's
  own words: "You should check if these terms matter for how you use the weights."
- **Drums: NC-ENCUMBERED — NEVER SHIP.** README: "Some of the grouper's and the drum
  model's training datasets carry non-commercial terms."

**Grouper decode (verified — reusable as an ALGORITHM, reimplement + retrain on clean
synthetic SATB per X-301):** per-note token = pitch embedding + 12 note numbers + 3
transcriber taps (368 each); 24 s windows starting 12 s apart; 7 transformer blocks with
rotary positions on onset time; predicts 73 GM instrument classes + a 32-dim track
embedding; "distinct-tracks decode": cluster per window by embedding+class → chain
clusters across windows → merge song-wide → fold tracks <30 notes into the most similar
big track → keep a short track (<¼ of notes) only if clearly a different instrument →
merge same-named tracks → merge same-pitch notes within 30 ms. Author states grouping is
the WEAKEST stage (jazz: ~25% of sax notes land in piano).

**Tuning (verified in `src/dettato/grouper/retune.py`):** `MIN_CENTS = 10.0` — if the
estimate sits ≥10 cents off A440 (circular mean of refined spectral maxima, ±50c), the
audio is resampled onto A440 (pitch and time move together), processed, and times are
mapped back. **VERIFICATION PENDING:** the fact sheet's "detuned +35c test: F1 0.81 →
0.96" figure (not present in README, cards, or source — treat as human-reported until
reproduced by us).

**Limits (verified):** 88 keys A0–C8; **at most 2 notes on the same key** (3+ singers in
unison drop voices); **NO metre/downbeat**; performance MIDI (unquantized).

**Cost (verified):** RTX 5060: 4-min song ≈15 s, 6-min ≈25 s, <4 GB GPU. Laptop CPU:
15 s clip → 87 s INCLUDING model load (~5.8× RT). **A14 CPU cost unknown → P-307 must
measure** (D-21 adoption threshold). Offline weights supported (`DETTATO_WEIGHTS`
folder). Python/PyTorch; **no ONNX export shipped — we port.** Apache-2.0 requires the
NOTICE attribution in our repo NOTICE + in-app licenses screen (D-26).

## A.2 · FuzzyIdeas/Muskey — AGPL-3.0, macOS — STUDY-ONLY

**Repo (verified):** https://github.com/FuzzyIdeas/Muskey — AGPL-3.0, Swift 91.4%,
macOS 26 (Tahoe)+ Apple silicon, v1.1.1 (2026-11-19), active. Static deps: **Essentia
AGPL-3.0 (static)**, **Rubber Band GPL-2.0-or-later**, **PitchTap GPL-3.0**; private
APIs (MediaRemote via helper signed `com.apple.controlcenter.Muskey`; Core Audio process
taps) — not iOS-portable. **STUDY-ONLY: never link or copy code; never hotlink the
lowtechguys.com model CDN — convert from upstream weights ourselves (D-26).**

**Verified techniques worth reimplementing (DEVELOPMENT.md):**
1. **Dettato transcriber ported to Swift + Core ML, "cut at its three GRUs into four
   models, because Core ML runs those GRUs much slower than Accelerate does. The GRUs
   run with Accelerate between the four models."** Spectrogram front end + peak picking
   ported from dettato's Python. Downloaded model = 33 MB. Hears 8 s @16 kHz, window
   every 2 s, Hann-weighted mean per 20 ms frame.
2. Separation = BS-RoFormer, **BS-Roformer-SW checkpoint converted to Core ML, run on
   GPU**, 6 stems, windows **4.5 s overlapping by 1 s, crossfaded**. Winds stem from a
   second model: woodwind/brass heads of **MVSep's 53-stem BS-RoFormer**, taken out of
   Other. (Both checkpoint licenses UNVERIFIED → X-310.)
3. Live windows first → whole-song stem cache in background → takeover with 10 ms
   crossfade; stems cached 16-bit ≈1.2 MB/s of song, 2 GB LRU (our ALAC choice is
   smaller — D-8).
4. Notes UX: tab / sheet music / piano roll as **STATIC PAGES with a line moving
   through**; page split into top/bottom halves — the top turns to the next page when
   the line reaches the bottom half, the bottom turns when the line reaches the top
   again; click a note → seek to that beat; drag across notes → region loop; arrows
   transpose; portrait/landscape page shapes; notes follow the pitch change.
5. Notes placed on Essentia beats; dettato finds no metre → every bar 4 beats, first
   beat starts bar 1, each note rounded to a sixteenth; bass/guitar get string+fret
   heuristics; staff written an octave above sounding pitch.
6. Key = Essentia KeyExtractor `shaath` profile run once per second; tempo =
   RhythmExtractor2013; chords placed on beats fitted to key. (Essentia is AGPL → we
   reimplement symbolically from note tracks per D-5.)
7. Lyrics: whisper.cpp large-v3-turbo, **ONE VOCAL PHRASE AT A TIME cut at pauses**;
   heard words matched to known lyrics IN ORDER so a repeated chorus maps to the right
   verse; Apple SpeechTranscriber/DictationTranscriber fallback.
8. Varispeed changes pitch, so pitch compensation = **−12 × log2(speed) semitones** on
   top of any key change (confirms our P-402 math).
9. **`--dettato-check DIR` compares the spectrogram and the network's maps against
   reference tensors saved by `make dettato-model`** → numerical-PARITY testing
   methodology for Python→Apple ports (adopted as D-24).

## A.3 · THE CRITICAL INSIGHT (adopted as D-22 — tuning reference)

Neither repo states it; it follows from dettato's retune step. **Our grader assumes
A440 equal temperament. If an SDA recording sits +35 cents sharp (old tape, varispeed,
group tuning by ear), a user singing CORRECTLY relative to the recording is marked
~35 cents flat on EVERY note — a systematic, invisible failure.** We must estimate the
recording's tuning reference at IMPORT, store it (`tuning_cents`, C-2.1), and consume it
in transcription (engine-side retune when |tuning| ≥ 10c, dettato-style) and in grading
(offset the reference — audio stays byte-true). UI indicator required. Default behavior
ruled in D-22.
