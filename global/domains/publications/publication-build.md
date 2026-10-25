# Publication Build — Generic Recipes

**Trigger:** load when building, verifying or depositing a paper/book/poster PDF (LaTeX, xelatex, pandoc, WeasyPrint, ReportLab), producing a review copy, mirroring `.md` edits into a hand-maintained `.tex`, or publishing to a DOI repository.

Complements `publication-workflow.md` (pipeline, canonical-PDF protection, review division, agent chunking, superscript gating, EPUB delivery) and `print-production.md` (what the press does to the file). Not repeated here.

## Core habit: a clean build is not a pass
- **pdflatex reports `! LaTeX Error: Unicode character …`, drops the glyph, carries on and still writes a PDF.** The non-zero exit arrives after the damage. Read the `.log` for lines starting `!`; never trust the exit code or the page count.
- A bare `&` mirrored from prose (`! Misplaced alignment tab character &.`) and a literal `⊆` both reached a build that still produced a plausible full-length PDF. Read the error section of the build output.
- **Build-then-promote.** Build into a scratch dir, gate (LaTeX errors from the `.log` + overflow check), and only then copy over the canonical — backing the previous canonical up with `cp` first. A builder that writes the canonical in place overwrites it even on a "FAILED" run.
- **A build wrapper that deletes the `.log` on success** makes any later log-reading check read whatever a previous *failed* run left behind, and report a fixed document as still broken. Keep aux files (`--keep-aux`-style flag) for any check that scores the log.
- Expect the inverse too: a gate that fails on overfull boxes can exit non-zero having produced a perfectly valid PDF. **Check for the output file, not the exit code**, and keep "no PDF produced" separate from "PDF produced with warnings" in a script's exit status.
- A clean build, a page count moving in the expected direction, resolving citations and no `??` are all compatible with duplicated, mis-ordered and dropped paragraphs.

## Baselines and before/after deltas
- **A committed PDF is not a valid "before".** Sessions commit `.tex` edits without rebuilding the PDF; one canonical was ~18 pages behind its own source, which made a +3-page change look like +21. Before quoting any delta (pages, words, layout), build the *pre-change source* (`git show <ref>:<path>.tex > <scratch>/paper.tex`, copy bib + figures, full bibtex cycle) and compare against that.
- **Check the `.bbl` too.** A stale committed `.bbl` missing keys present in the `.bib` makes a naive rebuild report undefined citations that have nothing to do with the current edit. Run `bibtex` before concluding new work broke the bibliography (in a sandboxed agent, bibtex may need the sandbox disabled to write the `.bbl`).
- **Rebuild before depositing.** A committed PDF was 4 pages / ~10k characters behind a build from its own unchanged `.md`; depositing it would have published a stale paper under a permanent DOI.
- **Byte-reproducible builds:** set a fixed `SOURCE_DATE_EPOCH` before before/after comparisons, or every rebuild differs in its creation date.
- **Moving a WeasyPrint build to a new directory cannot preserve the PDF byte-for-byte** — image XObject names are hashed from the image's absolute path. Verify such a move by the *rendered* output: content stream with `/i<32 hex>` identifiers normalised, embedded-image hashes, and a rasterised pixel hash (`fitz` `get_pixmap(dpi=…)`).

## Fonts and print-shop preflight
- **ReportLab's base-14 fonts (`Helvetica`, `Times-Roman`, …) are never embedded** — by design. A commercial print shop's preflight rejects the file and holds the order. LaTeX/pdflatex embeds by default; this bites weasyprint/ReportLab/Cairo outputs.
- Check before sending anything to a printer: `python3 -c "import fitz;d=fitz.open(F);print({x[3] for p in d for x in p.get_fonts(full=True)})"` — any font with `ext` `n/a` is unembedded.
- **When the artwork is already approved, convert text to paths rather than embedding a substitute face:** `gs -dNoOutputFonts -sDEVICE=pdfwrite -dDownsample{Color,Gray,Mono}Images=false -dAutoFilter{Color,Gray}Images=false -dColorConversionStrategy=/LeaveColorUnchanged` (bash brace syntax; verified on gs 10.02.1 — output carries no fonts and no extractable text). Outlining preserves the signed-off appearance; a substitute face changes glyphs and reopens approval. Re-verify page count, MediaBox, image dimensions and any QR afterwards.

## Overflow (Overfull \hbox) — mandatory hygiene
- Long URLs/DOIs and long tokens run past the margin because URLs don't break by default and pandoc's template lacks `microtype`/`emergencystretch`. TeX only emits a silent `Overfull \hbox` warning.
- Shared preamble for every md→PDF build: `xurl` + `microtype` + `\emergencystretch` + `\tolerance` + `\hbadness`. Wrap the build so it **fails if any `Overfull \hbox` > 2pt**, and run a standalone log check on hand-maintained `.tex` builds too. Never present a PDF without a clean overflow check.
- Long author/affiliation lines: `\author` does not wrap — use `author: "Name\\thanks{affiliation, ORCID, email}"`.
- A book builder separate from the paper pipeline needs the same fix: `\emergencystretch=4em`, `\tolerance=3000`, `\hbadness=10000`, `\usepackage{xurl}`, and a break-after-slash rule in the LaTeX escaper (`(?<=\w)/(?=\w)` → `/\allowbreak{}`). KDP rejected translated interiors as "text outside the margins" (long URL + long Romance-language words + slash-joined pairs). KDP's message cites insufficient gutter, but the real defect was overflow.
- **Gate every print interior with a per-page margin checker** (recto/verso-aware; ≤5pt = optical punctuation hang, safe). Visual/sampled reviews do not catch per-page overflow.
- **Vertical overflow is a second failure:** `tabularx` never page-breaks, so a tall table runs off the bottom margin. Use `xltabular` (X-columns + longtable paging) with `\midrule\endhead`; set `\small`/`\footnotesize` without a `{..}` group (longtable must not sit inside one). Never gate a table-bearing PDF on horizontal only. A layout special case keyed on an English header string silently falls through on translated copies.
- **Pandoc pipe tables allocate column widths from the separator row's dash count**, so a column whose separator is `---` gets the narrowest share no matter how long its text. One table produced 11 of 12 overfull boxes; widening the wide column's separator and sizing numeric columns to their widest token fixed it. Shrink narrow columns too far and single-token headers overflow instead.
- **Raw LaTeX preamble tweaks must go through `-H <file>.tex`, not YAML `header-includes`** — pandoc markdown-processes metadata and mangles backslash commands (geometry and spacing changes silently did not apply).
- Verify layout changes by page count (`fitz.open(p).page_count`), not by eye. A 1-line orphan is usually a long reference wrapping the page break, fixed by recovering vertical space (e.g. `\geometry{margin=0.9in}`).

## Unicode in pdflatex builds
- pdflatex **aborts** on bare Unicode maths/typography (`₂`, `⊂`, `←`, `σ`, `⊆`, `⟹`, `≡`, superscript digits…) with `! LaTeX Error: Unicode character X (U+NNNN)` and no PDF. Keep a per-document `unicode-header.tex` of `\newunicodechar{X}{\ensuremath{\cmd}}` lines and pass it with `-H`.
- **Any edit adding maths notation needs a header check before the build.** Headers are per-document and easy to outgrow; one document had not built at all for some time because its header lacked `∝`.
- **A repeated `\newunicodechar` mapping for the same character is an error, not a no-op** — when combining a shared preamble with a per-document header, copy the needed lines rather than `-H`-including both.
- `microtype` changes line breaking and therefore pagination; don't add it to a document mid-release just because it builds clean without it.
- For a one-off build of a document you must not edit, sanitize a *copy*: map Greek letters/operators to ASCII words (`σ→sigma`, `≈→~`, `→→->`, `≥→>=`, …), then strip any residual codepoint > U+2000 outside a keep-set of typographic characters (dashes, curly quotes, ellipsis, common accented letters).
- After a bulk programmatic edit of a `.tex`, scan for non-ASCII: `collections.Counter(c for c in text if ord(c)>0x2000)`, plus a `(?<!\\)&` scan on non-tabular lines.

## Hand-maintained `.tex` beside a `.md` source
- If `.tex` is hand-maintained (the build only *compiles* it), every content edit lands twice, and when that slips nothing warns: build clean, tests green, drift ships. Edit both in the same session and **verify parity before any build** (grep a recently changed string in both, or compare last-commit dates; port spec = `git diff <last-.tex-commit>..HEAD -- <the .md>`).
- A `.tex` generated once by pandoc and then left alone goes stale (one was missing whole sections and ~40 references). Regenerate from the `.md`; don't hand-patch.
- **Converter defects that reached a public preprint**, all invisible to the citation gate: natbib pre-notes left as literal prose with a stray `;` (`(see also; Author, 2012)`); page number dropped from `\citep[p.~1]{}` → `(; Author, 2009)`; author names left in front of a `\citet` that already prints them; whole passages never ported (one left the published PDF asserting a causal claim the `.md` had hedged months earlier).
- **Programmatic mirroring trap:** trying the markdown string verbatim against the `.tex` first and converting only on failure means plain-prose matches are inserted with **no LaTeX escaping**. Escape on every branch.
- **Converter discipline:** a converter must reproduce untouched paragraphs with zero round-trip failures before it is trusted on new text; diff placement must dry-run first and skip (not guess) any paragraph it cannot locate uniquely.
- Defect classes a large mirror still produced, none caught by the build: citation commands double-escaped to `\textbackslash{}citep{…}` (an inline-markup pass ran over already-converted commands — lift generated commands out before escaping); environments consumed when the paragraph carrying `\begin{…}` was replaced wholesale (count `\begin` vs `\end`); paragraphs duplicated or out of order (only a drift check finds these); possessive citations ("Author's (1962)") degraded to plain text (only an uncited-bibitem check finds these).
- **Anchoring traps:** anchoring a replacement on a string that also appears inside a co-author list splits the reference entry — diff the reference list against HEAD for entries *lost*, not just changed. `rindex` on a common word lands in the wrong section — anchor on a full sentence, never a token.
- Reference-list ordering drifts independently in the two files; run an alphabetical-order check whenever either list is touched.

## Verifying the built PDF against its source
- **Diff the `.md` against the built PDF's text, not against the `.tex`.** Extract with PyMuPDF, normalise both sides (de-hyphenate, unify dashes/quotes, strip markdown emphasis, collapse whitespace), drop reference lists, `difflib.SequenceMatcher` at word level, filter noise classes. In one run ~80 of ~97 raw segments were noise; the remaining ~15 were all genuine drift.
- Compare drift segment lists between runs rather than absolute counts (`comm -13` on sorted segment lines isolates what is new).
- **Noise classes to filter (narrowly, so a changed number or author still drifts):** hyphenation (a line-end hyphen is indistinguishable from a real compound — collapse all dash variants on both sides); heading numbering; curly quotes; HTML comments; math-operator spacing; a page folio landing inside a word ("docu15 mented") or mid-phrase; natbib's ampersand separator; TeX glyph substitutions (`$\Delta$` extracts as U+2206, `$^2$` as a plain digit); Computer Modern's `∫` extracts as `R`; subscripted tokens extract split.
- **Render before believing a drift segment** — crop the region to PNG and look.
- **Naive `phrase in pdf_text` checks false-alarm:** the PDF has `’` (U+2019) where the search string has `'`, and page numbers interleave mid-phrase. Search short fragments without apostrophes; on a miss, re-check a sub-fragment before concluding.
- **A checker whose default target is a build artifact reports staleness in the vocabulary of drift**, and the two read identically. Default to the canonical PDF and refuse loudly (mtime check) when the PDF predates the `.md`; a false alarm after a fresh checkout is the safe direction.
- **Reference-order checkers that compare surnames as raw strings mis-flag:** APA same-first-author ordering runs on the second author (`Boyle, Finn & Turok` precedes `Boyle & Turok`); diacritics fold (`Gödel` after `Gibbons`); apostrophe-initial surnames (`'t Hooft`) file under T.

## References and citations
- **Reference existence gate:** resolve each entry against Crossref/arXiv once, store verdict + a fingerprint of the entry text in a manifest, gate offline thereafter. Editing an entry changes its fingerprint, so a rewritten reference fails instead of inheriting the old verdict. Statuses: verified / verified-manual (row must name its evidence) / needs-review / defective (blocks the build).
- **A human verdict outranks a machine one only while it describes the same entry text** — carry `defective`/`verified-manual` across a re-resolve only if the fingerprint matches, or a repaired entry keeps blocking the build forever.
- A whole-document re-resolve exceeds a 2-minute foreground tool limit — run it as a background job.
- **What such a gate cannot do:** decide whether a sentence says what its source says, or catch a real author cited for the wrong work by the same author. Claim↔source agreement stays a human step.
- **Citation-command regexes:** a pattern requiring `{` right after the command misses `\citep[p.~3]{K}`, `\citealp[see][for X]{K}`, bare `\citeyear`, starred forms and capitalised `\Citet`/`\Citep`. Accept up to two optional args.
- A citation written as **literal text** rather than a command renders correctly and is invisible to renderer-based checks; only an uncited-bibitem check catches it.
- **pandoc `.docx`:** pass a non-Chicago CSL (e.g. `--csl=apa.csl`) — Chicago replaces repeated author names with em-dashes ("———").
- **bioRxiv's 2026 DOI prefix is `10.64898/`** (migrated from `10.1101/`; Crossref lists `10.64898` under openRxiv, `10.1101` under Cold Spring Harbor) — do not "correct" it back.
- **Retrieving bot-blocked open-access PDFs:** headless `curl` fails on PMC's JS viewer and publisher Cloudflare/Akamai. With Playwright, navigate `www.ncbi.nlm.nih.gov/pmc/articles/<PMC>/pdf/` (the `www.` host redirects without reCAPTCHA; `pmc.ncbi.nlm.nih.gov` does not), then same-origin `fetch(url,{credentials:'include'})` → base64 → file. OUP/Cell unblock once real Chromium passes the Cloudflare challenge.

## Review copies
- **Default review artifact for a revision = change-tracked HTML** (word-level red strikethrough / green additions, sidebar of changed sections); a PDF pair only when layout/typography is under review. Keep the generator tracked, not in `tmp/` — a previous generation was lost with a `tmp/` cleanup.
- Review PDFs should be the submission-quality `.tex` build, never a weasyprint/pandoc markdown render when a `.tex` build exists.
- **latexdiff tracked-changes PDF:** `latexdiff old.tex new.tex > diff.tex`, build inside a copy of the document dir (figures + bib). Default `UNDERLINE` markup uses `ulem` `\uwave`, which defeats line-wrapping — use `--type=CFONT` and inject before `\begin{document}`:
  ```
  \microtypesetup{expansion=false,protrusion=false}
  \setlength{\emergencystretch}{3em}\sloppy\hbadness=10000
  ```
  The `microtypesetup` line fixes `! pdfTeX error (font expansion): auto expansion is only possible with scalable fonts` (CFONT selects a face microtype cannot expand); the stretch line fixes overflow — a different failure, neither alone suffices.
- latexdiff's `WARNING: Inconsistency in length of input string and parsed string` is non-fatal; don't chase it. With inline `\bibitem` bibliographies no `.bbl` merge is needed.
- **Additions-only view:** after latexdiff, `\renewcommand{\DIFadd}[1]{\textcolor{blue}{#1}}`, `\renewcommand{\DIFdel}[1]{}`, neutralise `\DIFaddbegin/end`, `\DIFdelbegin/end`. Yellow highlight via `soul` fails on `\cite`/math — use coloured text.
- **CWD footgun:** never `rm -rf "$WORK"` while the shell's CWD is inside `$WORK` — latexdiff then cannot create temp files.
- **`.docx` review copy, two pandoc traps:** (1) highlight whole paragraphs/headings with `[text]{.mark}`, not `<mark>…</mark>` — a paragraph-level `<mark>` is parsed as a raw-HTML block and the highlight is silently dropped (zero `<w:highlight>` runs); (2) normalise every `---` rule to have blank lines on both sides (`re.sub(r'\n[ \t]*---[ \t]*\n', '\n\n---\n\n', text)`, collapse `\n{3,}`) — a bare `---` directly above a heading makes `multiline_tables` swallow whole chapters into a single-column table. Verify: count `<w:tbl>` in `word/document.xml`, expect ~0 beyond genuine tables.

## Figures and posters
- **Figure QA:** inspect each arrow, label and junction as a crop rendered at ≥200 DPI; a page-scale view is not inspection. QA cover text at readable resolution (≥150 DPI) — a thumbnail pass missed a clipped back-cover paragraph.
- **Cover LaTeX quotes:** `\'\'` is two acute-accent commands, not a closing quote — it renders `´´` and swallowed the rest of a paragraph. Use ` ``…'' `, German `\quotedblbase{}…\textquotedblleft{}`, guillemets `\guillemotleft{}…\guillemotright{}` (T1-safe, no babel).
- cairosvg does no reflow: after any font scale-up, check every label against its `<rect>` and widen boxes.
- **WeasyPrint A0 poster:** `@page { size: 841mm 1189mm }`; assert exactly 1 page at 841×1189 mm — a silent second page is easy to miss.
- **A flex column container does not fragment — it moves.** If the columns are taller than the remaining page, the whole block jumps to page 2, leaving page 1 with only the header.
- Overflow is a content problem: 24 pt is the floor for 1.5–2 m reading distance. Cut copy; binary-search size only to learn how far over you are.
- Paper figures do not survive the poster scale (bullet text ~7 pt at A0 column width); build a simplified poster variant and never modify the canonical figure.
- QR codes pointing at a concept DOI always resolve to the newest version — so an out-of-date paper contradicts the poster.
- Always render the PDF to PNG and look; column imbalance and clipped labels are invisible in HTML and page count.
- A build that copies its assets back over the tracked originals on every run silently reverts approved repairs. Builds write to scratch only; promotion copies outputs, never source figures.

## Build-time typography for translations
- Typography that would break line-alignment of translated sources belongs in a pure, idempotent, tested build-time pass.
- **CJK emphasis → bold, content-aware:** `*x*` → italic is wrong on Hanzi/Kana (slanted or silently upright). Bold only when the span contains a CJK codepoint; Latin emphasis (titles, species names) stays italic.
- **French EPUB spacing:** pandoc `smart` already curls French apostrophes. The gap is high-punctuation spacing (babel-french gives print this, pandoc's EPUB does not): narrow NBSP U+202F inside « » and before ; ! ?, full NBSP U+00A0 before :.
- Edition lines belong on the print copyright page only; eBooks carry only the © line.
- Print covers are spine-driven: rebuild only if the interior page count moved from the value baked into the cover, or the cover's own text changed.

## Bulk text substitution
- A global swap of a term that is a **substring of another word** corrupts it (`preensão → garra` turned `compreensão` into `comgarra` at 8 sites; caught only by a native reviewer). Edit-tool `replace_all` does the same plain-substring match as `sed s///g`. Worst in morphologically rich languages.
- Before any global swap, `grep -no "<old>"` and read every hit; if it occurs inside a larger word, do anchored single edits. Afterwards, two greps must pass: `grep -n "<old>"` returns only intended leftovers, and `grep -Eno "[[:alpha:]]<new>|<new>[[:alpha:]]"` returns 0.
- Pattern-sweep greps: on systems where `grep` is ugrep, a long `\(a\|b\|…\)` alternation with `.\{0,N\}` context bounds errors on complexity or times out — and a timeout silently drops the later patterns, so a sweep reports "clean" for checks that never ran. One pattern per invocation; truncate with `cut -c1-N`.

## Repository hygiene for binaries
- **git-LFS phantom modifications:** binaries committed as raw blobs before LFS was enabled show as perpetually modified, with `git diff --stat` reading `Bin <big> -> 131 bytes` (131 = LFS pointer size). Content is intact. Diagnose: `stat -c%s`, compare `sha256sum <file>` with `git cat-file blob HEAD:<file> | sha256sum`, and `git lfs status` (equal OIDs = phantom).
- **`git checkout HEAD -- <file>` does not restore such a file** — `HEAD:` holds a pointer under the LFS filter, so checkout writes the 131-byte pointer. Back up with `cp`, restore with `cp`, verify by sha. Durable fix: `git add --renormalize` (check LFS objects push to every remote) or exempt the paths; `--assume-unchanged` is local-only and does not last.

## DOI repository deposits (Zenodo-style)
- **Never hardcode deposit metadata in the script.** A helper carrying another paper's title/abstract would have minted a permanent DOI describing the wrong work. Require a metadata file, validate non-empty title/creators, test that no two shipped metadata files share a title.
- Deposit as draft first, inspect, then publish — a published DOI is permanent.
- A versioning script must target one explicit concept record; pointing it at a different work appends that work as a new version. A new work needs a new deposition.
- **Changelog guard:** a changelog file appended verbatim as release notes must declare the version being published (leading `vN` on a line); fail closed on no declaration, wrong form or missing file, before any network call. A stale changelog from another paper once went out as public release notes. Keep per-version changelogs tracked, not in scratch.
- **Filename trap:** a PDF name containing spaces breaks an unencoded bucket URL; the upload aborts silently under `set -e`, the draft stays empty and the run exits 0. Stage under a space-free name. Run deposits as background jobs, not inside a `timeout`-wrapped call.
- **Editing metadata on a published record works:** `POST /actions/edit` → `PUT /` with the full metadata object → `POST /actions/publish` (201/200/202). Metadata is mutable, files are not. If the PUT fails the record stays in edit state — re-publish; verify on the public `/api/records/<id>`, not the deposit endpoint.
- Concept DOIs are not fetchable via `/api/records/<concept-id>`; query a version id. **Tell concept from version DOI via DataCite** (`api.datacite.org/dois/<doi>`): concept carries `HasVersion`, version carries `IsVersionOf`. Take the concept DOI from the API's `conceptdoi` field, never by guessing — concept and first-version ids can differ by one, which reads like a typo.
- **Publish the concept DOI, never a version DOI** — every stale link in one audit was a version DOI that was correct when written. Prefer no version numbers anywhere on live surfaces; where a direct file link is needed, link a stable URL whose file is replaced on each release, and enforce with a test that fails on version DOIs or versioned file links.
- **Verify a publish by downloading the file back and comparing hashes** with the canonical; confirm openness (`access`, `license`, rendered landing page) independently, since the API answers the same when you hold a token.
- Zenodo has 403'd a generic `Mozilla/5.0` User-Agent from at least one network; a 403 does not mean the record is private — retest with a polite UA (`<tool>/1.0 (mailto:…)`).

## Publishing hygiene
- Before publishing a version, review the **whole document**, not just its open backlog items — closing every open item is not examining the artifact, and a fabricated citation can survive any number of closed items.
- Audit public surfaces (README, wiki, landing pages) against the paper's text, not just for dead links: retired terminology, outdated submission status, "peer-reviewed" claims for preprints.
- Quoting a GPU-computed dynamical figure: non-deterministic floating-point reductions set a reproducibility floor across reruns. Within-run comparisons on one shared trajectory are safe at full precision (the noise is common-mode); integer/graph quantities are exact; cross-rerun floating-point results must not be quoted beyond the measured floor.
- A subagent that dies on an API/rate-limit error may still have returned findings in its result — read and verify before discarding.
- Never run two large parallel agent fan-outs concurrently: server-side rate limiting silently killed 37 of 89 agents in one (each turned into an empty result). Per-workflow concurrency caps do not protect across workflows; serialize, and re-run failed segments alone.

## Journal submission systems (Editorial Manager via Playwright)
- Forms submitted outside the `Default.aspx` frameset fail silently (`if (top == self)` redirects to a blank page — no error, no mail, no account). Submit inside the content frame.
- Remove the OneTrust overlay (`#onetrust-consent-sdk`) that intercepts clicks. File upload: click "Browse…" and answer the file-chooser modal; `setInputFiles` on the hidden input does nothing. Use visible buttons — hidden duplicates exist.
- jQuery dialogs block every click until their own OK is pressed; `history.back()` clears password boxes. Personal Classifications are often required and open in a separate tab.
- "Approve Submission" may refuse until the submission PDF has been viewed in the same page load — call the row's view-PDF action, then the approve link (`eid=4`; another eid may be REMOVE) without reloading.
- The number shown while the PDF awaits approval (`…-S-…`) is not the manuscript number; record the final `…-D-…` number from the confirmation mail.
