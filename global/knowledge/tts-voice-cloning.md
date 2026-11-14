# Cloned-Voice Line Production — local TTS, unattended batches, automatic verify gate

<!-- consumed-by: global/CLAUDE.md (conditional-loading row), global/knowledge/INDEX.md -->

How to produce spoken lines in a cloned voice with local open-weight TTS so that a human only listens
to takes a machine has already checked. Distilled from a production pipeline that has made several
thousand takes for two cloned voices (2026-09-29 … 2026-11-13); its last full script in the reference
voice (33 lines, a 7-minute assembled listening file) transcribed at **0.2 % WER** and was accepted as is.

**Source key** (numbers are measured unless marked *[obs]* = observation from listener verdicts):
**[K]** the pipeline's engine notes (engine source reading + verdict log), **[S]** the batch runner and
its helpers (generation, headless server launcher, post-process, keep-awake), **[B]** the batch
orchestrator, **[G]** the verify gate, **[C]** take choice, cue cutting and install into the player,
**[R]** the listening-stage READMEs and gate records of 2026-11-13, **[M]** machine notes of a WSL2 +
RTX 4090 box.

## 1. The pipeline at a glance

```
true recording ─► reference window (15 s) ─► line list (one phrase per line, wordings)
   ─► unattended batch: engine A then engine B, N seeded takes per line (resumable, watchdog, GPU lease)
   ─► post-process (trim, two-pass loudness, MP3) ─► verify gate (Whisper, duration, junk, speaker, clip)
   ─► take choice (gate score − slow-read penalty; short cues cut from carrier sentences)
   ─► staged folder + numbered README ─► listener deletes what is bad ─► keepers stored + catalogued
```

## 2. Reference recording — the voice is the window you feed

- **Never clone a clone.** Only a true recording of the speaker is a reference. A TTS output used as a
  reference drifts the voice and inherits its artifacts (clipping, prosody tics) [K §1].
- **Both engines only listen to the start of the file.** IndexTTS-2 cuts every reference to its first
  **15 s**; Chatterbox Turbo uses the first **10 s** for decoder timbre and **15 s** for prompt tokens
  (its speaker embedding sees the whole file), asserts the reference is **> 5 s**, and loudness-normalises
  it to **−27 LUFS** internally; Chatterbox Original uses 6 s / 10 s [K §1, engine source lines cited there].
  ⇒ Cut the window you want to a **15 s file** and feed that same file to every engine.
- **Audition two or three windows by ear.** For the reference voice, the 16–31 s window of a 43.4 s
  recording "sounds more like" the speaker than 0–15 s and became canonical; the second voice uses a 15 s
  window (5.9–20.9 s) of a 35.8 s recording [K §1].
- **Pitch-check a candidate window before a batch.** Measure the median F0 of voiced frames and the share
  of frames inside the speaker's expected range; a window not ≥ ~90 % in range is a mixed-speaker or noisy
  clip. Measured failure: a reference at median 164 Hz produced outputs at 114–134 Hz (off-voice), one
  pinned at the 400 Hz tracker ceiling (noise) produced erratic 213–400 Hz output; the listener kept
  nothing from either. A good reference sat at 184–198 Hz and its outputs matched [K §5, 2026-10-07].
- The original recording is irreplaceable: never modify it, keep checksummed copies on every backup tier,
  work on copies [K §1]. A best-of of generated takes as a seed is cloning a clone — owner sign-off only.

## 3. Engines — settings as used, and how they compare

**IndexTTS-2** (production default). Python API one-shot in its own venv (no server), fp16, **defaults:
temperature 0.8, top_p 0.8, top_k 30, num_beams 3, repetition_penalty 10.0, max_mel_tokens 1500,
max_text_tokens_per_segment 120, interval_silence 200 ms, no emotion vector**; seed `torch` and `random`
per take so a take is reproducible [K §2, S `gen_indextts.py`, R].
Traps: `emo_alpha` is a no-op unless an emotion prompt or vector is given; a "firm" vector
(angry .45 / disgusted .15 / calm .35 at alpha 0.8) clipped 653 and 184 full-scale samples and was rejected
by ear — keep Σweights ≤ ~0.4 or let the reference carry the manner; output is 22,050 Hz int16 with **no
normalisation and a hard clamp**, so hot takes carry isolated full-scale samples (upstream fix #773,
2026-08-18) [K §2]. The log line "Use the specified emotion vector" prints for every take, also without a
vector — it is the speaker-derived vector, not an applied emotion [S].

**Chatterbox** (devnen Chatterbox-TTS-Server; model Turbo for English, Multilingual for other languages).
`POST /tts` with temperature 0.8, an explicit non-zero seed per take (0 = unseeded), `split_text: false`
for lines (it only splits above 1.5 × chunk_size and then joins chunks with a fixed 200 ms pause), clone
reference passed as a **filename** in its `reference_audio/` dir. Turbo **ignores** `exaggeration`,
`cfg_weight`, `min_p`; top_p/top_k/repetition_penalty are not exposed by the server [K §2].

| | IndexTTS-2 | Chatterbox Turbo / Multilingual |
|---|---|---|
| Languages | zh, en [K] | Turbo en only; Multilingual incl. de [K] |
| Load | 20.8–23.4 s warm, 167 s cold [K] | 31 s to a healthy `/api/model-info` [K] |
| Per take | 3.4–10.6 s short line [K]; 135 narration takes (median 10.9 s audio) in 24.5 min [K, R] | 1–1.7 s short line; first request 6.9 s [K] |
| VRAM | ~5.4 GB per process [K] | not measured |
| Output | 22.05 kHz, clamps (see above) | 24 kHz |
| Licence | bilibili, non-commercial [K] | MIT [K] |

**Listener keep rates** (takes kept ÷ offered, both engines on the same lines) *[obs]*:

| Material | IndexTTS-2 | Chatterbox | Source |
|---|---|---|---|
| 25 short cue lines × ≤ 3 wordings, 294 takes (239 kept) | 13 deleted | 42 deleted | [K §5 batch 3] |
| 12 short reaction lines (1–4 words) | 21/36 | 26/36 | [K §5] |
| Three narration batches (long, multi-clause lines) | 74–83 % | 33–49 % | [K §5] |
| Second-language speaker reading English, two batches | 35/58 | 9/57 | [K §5] |
| German with regional dialect (Multilingual) | — | 35/192 | [K §5] |

Engine behaviour seen more than once:
- **Chatterbox reads ALL-CAPS words as initialisms** ("DRINK" → "D-Rink"). Send lowercase to Chatterbox
  and keep capitals only for on-screen text; the lowercase redo kept 19/36 vs 14/36 for the capitalised
  originals (small n, different seeds) [K §3 rule 8, §5]. For IndexTTS, capitalise ALL-CAPS words
  ("SAY IT" → "Say it"), which it may otherwise spell out [C].
- **Very short lines (≤ 3 words): IndexTTS reads in slow motion, Chatterbox sometimes fills seconds with
  garbage.** Give such lines one extra take per engine (4 instead of 3) and split them into their own
  batch [K §3 rule 11] — or, better for single cue words, use carrier sentences (§6).
- **Chatterbox Multilingual tails run 1–6 s too long** (noise, cracks, nonsense words after the line); the
  gate's junk check catches this. One-word lines and heavy dialect spelling die; plain language with light
  dialect survives [K §5].
- **Cross-language cloning works on IndexTTS-2:** a German-speaking reference reading English, 216 takes
  (2026-11-13): 175 passed the gate (136 top-ranked staged for listening + 39 surplus), 41 rejected — 37
  for a word error, 4 for clipping only, 1 for tail junk; speaker similarity to the German reference median
  0.74 (0.47–0.84) [R]. Chatterbox Turbo mostly failed the same speaker in English (row above).

**Other tools measured on the same box** [M]:
- **VibeVoice-7B** (community fork): RTF ~0.9 (123 s script in 121 s), 21.6 GB VRAM, but it **inserts
  phrases not in the script** (2 in 2 min; Whisper base.en WER 36.5 %). Use only where sound matters more
  than wording, never for word-exact content.
- **Windows SAPI** (`System.Speech` from PowerShell, zero install): ~100 s of speech in < 1 s, word-exact by
  construction — a timing and pipeline dummy, not a production voice. Whisper base.en still measured 21.6 %
  WER on it: that is the **floor** of a cheap base.en check, so compare engines against SAPI, not against 0.
- **faster-whisper** `base.en`, CPU int8: ~2 min of audio in 3–4 s — cheap screen; `large-v3` gates (§5).
  With system CUDA 13, CTranslate2 needs `nvidia-cublas-cu12` + `nvidia-cudnn-cu12` in the venv and their
  `lib/` dirs on `LD_LIBRARY_PATH` before the process starts (read at exec only) [M, G].

## 4. Writing lines and the unattended batch

**Line rules** [K §3]: one sample = one phrase (a full stop inside a line makes both engines pause —
0.26–0.42 s measured); a line with two ideas becomes two lines; a cue word that must be repeatable is its
own sample; short commands are trimmed tight; up to 3 wordings per line id so playback varies the wording;
**several takes per line, always** (the pool needs variability). An on-screen cue phrase *mentioned*
mid-sentence is put in quotes for the TTS so it is read as a mention, not a command [C].

**Line list**: `id: wording | wording | wording`, `#` comments (or JSON/YAML with the same fields).
Take name `<voice>__<line>__w<N>__<engine>__t<NN>`; seed = `base + 100·(wording−1) + take`, the same seed
on both engines; order engine-major (all IndexTTS takes in one process, then Chatterbox) [B].

**Runner behaviour** — the parts that made overnight batches finish without supervision [B, S]:
- **Validate the list in the foreground first** (dry run, seconds) so a bad list fails now, not overnight.
- **Every take is idempotent:** a `.wav` ≥ 1000 bytes counts as done; each take is written to
  `<name>.__part__.wav` and renamed, so a kill never leaves a half take that looks finished. **Re-running
  the same command resumes**; one failing line is logged and never kills the batch.
- **IndexTTS watchdog:** overall budget = 600 s load + 60 s per pending take, **stall kill after 300 s
  without output**, whole process group killed, **3 attempts**, each resuming.
- **Chatterbox server:** reuse a server that already answers and never stop it; otherwise start our own
  headless (launch timeout 300 s × 2 attempts); a crash mid-batch restarts it (≤ 3 restarts), each take
  gets 2 attempts and a 120 s timeout; at the end stop **only our own PID and its descendants**, verified.
  Measured: a competing GPU job starved the server mid-batch (3 restarts → INCOMPLETE); the re-run
  resumed only the 86 missing takes [K §5].
- **Keep the host awake** for the run (Windows `SetThreadExecutionState`, no admin, bounded by a max-hours
  argument) — a GPU job gets no compute while the host sleeps [S, M].
- Runs as a tmux job behind a **non-expiring** keepalive tmux server (a `sleep 86400` keepalive expires
  after 24 h); **GPU lease** via the fleet's `tmux-launch.sh --resource gpu:<card>=<MiB>` (~5600 MiB for
  one IndexTTS-2 process). Last log line is `BATCH DONE` or `BATCH INCOMPLETE` with the reasons;
  every failure logs `<STAGE> FAILED: <reason>` [S, B].

## 5. Post-processing and the verify gate

**Post-process** (ffmpeg, per take; never overwrite the raw WAV) [S `postprocess.sh`]: trim leading and
trailing silence at −45 dB (30 ms / 80 ms hold) → measure integrated loudness and true peak (`ebur128`)
→ apply **one linear gain to −16 LUFS** → limiter 0.5 dB under the **−1.5 dBTP** ceiling → **48 kHz mono
MP3 192 kbps**. Two-pass is mandatory: single-pass `loudnorm` falls back to dynamic mode on clips < 3 s and
left them at −18…−22 LUFS; two-pass landed −16.2…−17.1 [K §3 rule 7]. QC line per take: duration, LUFS,
true peak, raw clipped-sample count, internal pauses ≥ 150 ms.

**Verify gate** — generate more, let the machine reject, the human hears only survivors. Introduced
because the listener reported the rate of bad takes as high; generation then went from 3 to **8 takes per
wording per engine**, of which the best 3 per line per engine reach the listener [G, S]. Per take (staged
MP3 + raw WAV), reject on any of:

| Check | Rule [G] |
|---|---|
| ASR round-trip | faster-whisper **large-v3**, word timestamps, beam 5, no previous-text conditioning, no VAD. Script and transcript normalised (case, punctuation, contractions, digits → words, known homophones, British spellings). **Any word error rejects** — except a single-word line, where one heard word within one letter, or a known mishearing pair (eight/eat, three/tree, two/to, four/for), passes with a note. |
| Duration | Reject below 0.15 s/word (truncated) or above **1.8 s + 0.6 s/word** (≈ p99 of what the listener kept; beyond it is slow motion or padding). A tighter class target (1 word ≤ 1.0 s, 2–4 words ≤ 1.6 s, sentence ≤ 3.0 s) only costs rank. Narration profile: max(6 s, 2 s + 0.8 s/word). |
| Junk | Energy islands (10 ms RMS frames within 35 dB of the loudest frame, above −55 dBFS, gaps < 0.1 s bridged) lying outside the recognised words ± 0.25 s; **> 150 ms of sound before the first or after the last word rejects**. Whisper's word times drift early after a pause, so a candidate island is re-transcribed alone first — if it is the script's own word it is speech, not junk. |
| Speaker similarity | Cosine of pyannote WeSpeaker ResNet34 embeddings (`pyannote/wespeaker-voxceleb-resnet34-LM`, ~26 MB, CC-BY-4.0) vs the reference; **reject < 0.22**, judged only on takes ≥ 1 s (shorter embeddings are unreliable). Calibration: listener keepers ≥ 1 s scored ≥ 0.27, a different speaker's takes ≤ 0.18. |
| Clipping | Any full-scale sample in the raw take (but see the tolerance rule below). |

Ranking per line id × engine, across wordings: **score = 0.6 · similarity + 0.4 · mean word probability
− junk seconds − 0.1 per second over the class target**; the top 3 stay in the stage root, other passers
go to `_surplus/`, rejects to `_rejected/` — **nothing is deleted** [G]. `GATE.txt` lists per take the
verdict, reasons, WER, duration, junk, similarity and what the ASR heard vs the script; `gate.jsonl` is
the same, machine-readable, and the resume cache (keyed on the gate config, so changing only the keep
count re-ranks without re-transcribing). Device: CUDA only with ≥ 6 GB VRAM free, else CPU int8 (~4 s per
take); run the gate as its own process so the card is free when it ends [G].

**Measured gate quality:** on 100 takes the listener had already kept, the gate would have rejected 6
(all ASR word errors — mishearings like "three"→"tree") [K §4]; first gated batch: 144 generated → 18
survivors → listener kept 11 = **61 % precision** [K §5]. Track precision per batch — it is the number
that tells whether thresholds need moving. Re-check rejects on multi-word lines for pure mishearings.

**Clipped-sample tolerance** (for IndexTTS on long lines) [C, K]: on 12–20 s narration nearly every take
carries a few isolated full-scale samples (runs ≤ 3 samples, < 0.14 ms); "any clip rejects" threw out 62
of 93 takes in one batch [K] and was the sole reason for 66 of 75 rejects in another [R]. Rule: a take
whose **only** gate reason is clipping is usable with **≤ 30 full-scale samples in runs of ≤ 3 samples**
(inaudible). Longer runs stay rejected.

## 6. Take choice and one-word cues

**Take choice** [C]: candidates are gate keeps and surplus plus clip-tolerated rejects, never a take whose
text no longer matches the current script and never one the listener deleted from the stage. Rank by gate
score **minus 1.0 per unit the read is slower than 1.05 × the median duration of that line's takes**
(IndexTTS slow-motion reads lose to normal-paced ones).

**Single cue words → carrier sentences, cut at the pause** [C, K]. Rendering a one-word cue alone gives
slow motion or garbage (§3); instead render it at the start (lead) or end (tail) of short carriers —
generic form `<Cue>. Do it now.` / `Do it now. <Cue>.` / `<Cue>. Right now.` — and cut it out:
1. Whisper word times locate the cue/carrier boundary (± 0.3 s; they drift).
2. ffmpeg `silencedetect` finds the pause there at a threshold **relative to the loudest 10 ms frame:
   −35, then −30, then −25 dB** (min 80 ms); a fixed −40 dB found no pauses at all. Take the longest pause
   in the window.
3. Cut: lead = speech start − 30 ms to min(pause start + 0.10 s, pause middle); tail = max(pause end −
   0.06 s, pause middle) to speech end + 0.12 s; **10 ms fade-in, 40 ms fade-out**; then the normal
   post-process.
4. Re-check: Whisper on the cut must return **exactly** the cue; length ≤ 0.9 s + 0.2 s per word; the cut
   edge must lie in silence. Try the next-ranked carrier take if one fails. Measured: 15 of 18 cuts passed.

## 7. Staging, verdicts, storage

- **Stage** survivors in one folder per batch with `README.txt` (header: voice, reference + window, engine
  settings, post-processing, gate summary; one row per file: file | text | engine | wording | seed). The
  listener's preferred format: **a folder where they simply delete the bad ones**, ≤ 10 lines / ~60 takes
  per folder [K §5]. For a script, also stage an **in-order listening copy**: numbered `01_<slot>.mp3 …` +
  README with position, kind, duration, source take and why it was chosen [R].
- **Record verdicts** the same session: kept/deleted per file, the listener's words verbatim, and gate
  precision; a pattern seen twice becomes a production rule [S §6].
- **Store keepers only after the verdict** — named `<line>.<engine>.<batch-tag>w<N>t<NN>.mp3`, copied to
  every storage tier in one operation with checksums compared, catalogued, never overwriting an existing
  take [S §7]. Keep the −16 LUFS master; apply playback level as a **per-file gain in a manifest**:
  gain = min(target − LUFS, ceiling − peak). One deployment plays at **−21.5 LUFS, true-peak ceiling
  −1.0 dB** because its existing cues measured median −21.6 LUFS — measure your own mix [C, K §4].
  If a web client caches audio by URL, put a content hash in the file name [C].

## 8. Environment traps that generalise

- **GPU sizing on a 24 GB card:** one IndexTTS-2 process ~5.4 GB; with another project's 16 GB job resident
  the card sat at 23.8/24.5 GB and 100 % — two voice processes do not fit; a 22 GB local LLM plus IndexTTS-2
  does not fit — unload it first [K]. **Never run two heavy models at once.** For queued batches, start
  only when GPU utilisation averages < 50 % over 60 s and ≥ 9 GB is free, with a 2-minute break between
  jobs [K §1]. On WSL, `nvidia-smi --query-compute-apps` does **not** list Windows-side processes (an LLM
  holding 22.3 GB showed nothing) — decide on card-level `memory.used` [M].
- **Windows-side engines driven from WSL** [K, S, M]: run Windows executables from a `/mnt/c` working
  directory, never a `\\wsl.localhost` path (a `.ps1` there hangs invisibly on the "run only scripts you
  trust" prompt — copy it to `C:\` first). **Never start a long-lived Windows server with
  `Start-Process -RedirectStandard*`**: the child inherits the WSL interop pipe and the WSL caller blocks
  until the server exits (reproduced: 20 s block vs 0 s without; it cost a 14-minute hang). Use plain
  `Start-Process -WindowStyle Hidden -PassThru`; the child redirects its own stdout/stderr at fd level.
  A server that opens a browser tab on start goes headless via a launcher that replaces `webbrowser.open*`
  in-process, then `runpy`-runs the server (no install patch, survives upgrades). Find Windows processes
  with `Get-CimInstance Win32_Process`, never `tasklist` via `cmd.exe` (blind to interop-launched
  processes); stop by PID tree, never by name pattern.
- **Subprocesses in tmux jobs:** pass `-nostdin` to ffmpeg and `stdin=DEVNULL` to every child — a job that
  reads stdin gets SIGTTIN and sits stopped forever [M, G]. Never wait on `pgrep -f` loops (they match
  themselves); check the tmux session with exact match `-t=<name>`.
- **Resume semantics:** "done" = a complete file (size floor + atomic rename), never "a file exists"; a
  verdict cache keys on the config that produced it, so a changed threshold re-evaluates [B, G].
- **Three later traps (2026-11-14):** (1) the ASR check needs a tolerance list beyond digits and spelling —
  homophones (base/bass, peak/peek) and a plural -s merged into a following s-word reject good takes
  otherwise; (2) IndexTTS-2 with the same seed renders byte-identical audio, so a re-render needs a NEW seed
  base, not just a re-run; (3) a gate cache keyed on the config replays its old verdicts for the same files —
  re-judge re-rendered takes in a NEW stage directory.

## 9. Starting a new voice — checklist

1. Find a **true recording** of the speaker (≥ ~30 s, one speaker, little noise). No TTS outputs.
2. Cut 2–3 candidate **15 s windows**; pitch-check each (median F0, ≥ ~90 % of voiced frames in the
   speaker's range); keep the original untouched and backed up.
3. Render 4–6 neutral test lines × 3 takes on each installed engine from each window; the listener picks
   the window (and notes which engine suits the voice — second-language speakers favoured IndexTTS-2).
4. Pick the gate's similarity floor from that test: keepers ≥ 1 s should clear 0.22 with margin; a
   different speaker's takes should fall below it.
5. Write the line list per §4 (one phrase per line, wordings, cue words as carriers or own samples,
   lowercase caps for Chatterbox).
6. Dry-run the list, then launch the unattended batch with the gate (8 takes per wording per engine, keep
   the best 3 per line per engine), under the GPU lease, with nothing else heavy on the card.
7. Stage survivors + README; the listener deletes what is bad; record verdicts and gate precision.
8. Store keepers to every tier with checksums, catalogue them, rebuild the playback manifest.
9. Monthly: scan for newer open-weight TTS models (Hugging Face `pipeline_tag=text-to-speech`, engine repo
   releases); test a candidate on the same window, lines and post-process, staged beside current takes
   under neutral names. Upgrading an engine in place is the owner's call [K §7].
