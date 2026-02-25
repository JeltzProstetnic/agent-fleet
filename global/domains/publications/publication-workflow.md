# Publication Workflow — MANDATORY

**Read this file at session start if the session involves authoring, editing, or building any publication (paper, book, or pop-sci piece).**

---

## 1. Pipeline — Single Direction, No Shortcuts

Every publication follows this strict pipeline:

```
.md  →  formatting-rules.md  →  .tex  →  .pdf
 ▲              ▲
 │              │
 CONTENT        FORMATTING
 (edit here)    (LaTeX-only rules here)
```

| Stage | File | Purpose | Who edits |
|-------|------|---------|-----------|
| **1. Content source** | `<document>.md` | All prose, structure, references, figures | Author + Claude |
| **2. Formatting rules** | `<document>.formatting-rules.md` | LaTeX-only formatting that .md cannot express | Claude (with author approval) |
| **3. LaTeX output** | `<document>.tex` | Generated from .md + formatting rules | Build script ONLY |
| **4. PDF output** | `<document>.pdf` | Compiled from .tex | `pdflatex` / build script ONLY |

### Document registry

| Document | Content source | Formatting rules | Build script | Generated .tex | Generated .pdf |
|----------|---------------|-----------------|--------------|----------------|----------------|
| Book | `pop-sci/book-manuscript.md` | `pop-sci/book-manuscript.formatting-rules.md` | `tmp/build_book_pdf.py` | `pop-sci/book-manuscript.tex` | `pop-sci/book-manuscript.pdf` |
| Full paper | `paper/full/four-model-theory-full.md` | `paper/full/four-model-theory-full.formatting-rules.md` | TBD | `paper/full/biorxiv/paper.tex` | — |
| Intelligence paper | `paper/intelligence/paper.md` | `paper/intelligence/paper.formatting-rules.md` | TBD | `paper/intelligence/paper.tex` | — |
| Cosmology paper | `paper/cosmology/sb-hc4a.md` | `paper/cosmology/sb-hc4a.formatting-rules.md` | `tmp/build_cosmology_pdf.py` | `paper/cosmology/sb-hc4a.tex` | `paper/cosmology/sb-hc4a.pdf` |
| Cosmology formalization | `paper/cosmology_formal/sb-hc4a-formalization.md` | `paper/cosmology_formal/sb-hc4a-formalization.formatting-rules.md` | `tmp/build_cosmology_pdf.py` | `paper/cosmology_formal/sb-hc4a-formalization.tex` | `paper/cosmology_formal/sb-hc4a-formalization.pdf` |
| Trimmed paper | `paper/trimmed/noc/four-model-theory-noc.md` | — | — | — (needs .docx) | — |

---

## 2. Content Source Rules

**.md is ALWAYS the single source of truth for content.**

1. **NEVER edit a .tex file directly.** All content changes go to the .md first.
2. **NEVER edit a .pdf.** It is disposable output.
3. **After editing .md, regenerate .tex and .pdf.** Never leave them out of sync.
4. **If you catch yourself about to edit .tex: STOP.** Edit the .md instead.
5. **Subagents must follow these rules too.** Include them in agent prompts.

**Why this rule exists:** Sessions 25, 39, 43, and 70 wrote content or formatting directly to .tex files. The .md was never updated. ~8,000 words were orphaned in earlier sessions. Session 50 partially recovered them. This must never happen again.

---

## 3. Formatting Rules Files

A `<document>.formatting-rules.md` file sits alongside each content .md and captures **LaTeX-only formatting decisions** that Markdown cannot express. These are consumed by the build script when generating .tex.

### What goes in formatting rules

- Title page layout (line breaks, spacing, font sizes)
- Custom LaTeX commands or environments
- Page break overrides
- Special character rendering
- Float placement directives
- Column/margin adjustments
- Any `\\`, `\vspace`, `\newpage`, or similar directives

### What does NOT go in formatting rules

- Prose, headings, paragraphs (→ .md)
- Reference list entries (→ .md)
- Figure captions or alt text (→ .md)
- Section ordering (→ .md)

### Format

```markdown
# Formatting Rules for [Document Name]

Rules collected during editing sessions. Consumed by the build script.

## Title Page
- Subtitle line break: insert `\\[0.2cm]` after "Architecture of" in subtitle
- Author spacing: `\vspace{2cm}` between subtitle and author name

## Chapter Breaks
- Force page break before Chapter 10 (long preceding chapter)

## Special Characters
- Use `\textsuperscript{th}` for ordinal numbers in formal passages
```

### How build scripts use them

Build scripts must:
1. Read the .md (content)
2. Read the .formatting-rules.md (presentation overrides)
3. Apply formatting rules during .tex generation
4. Never require manual .tex editing

### CRITICAL: Formatting rules must be built into scripts IMMEDIATELY

When a new formatting rule is identified (e.g., a line break in the subtitle, a forced page break, custom spacing):

1. **Document it** in `<document>.formatting-rules.md`
2. **Implement it** in the build script **in the same session** — not "later", not "TODO"
3. **Verify** by running the build script and confirming the .tex output is correct
4. **Never hand-edit .tex as a workaround.** If the build script can't express the rule yet, extend the build script first.

The formatting-rules.md file is both documentation AND the specification for what the build script must implement. If they disagree, the build script is wrong.

**Why this is non-negotiable:** Session 70 hand-edited a line break (`\\[0.2cm]`) into the .tex instead of updating the build script. The next rebuild from .md would have silently clobbered it. Formatting rules that exist only in .tex are invisible, undocumented, and fragile.

---

## 4. Content Review — HTML

Content review is **always in HTML**, never by reading raw .md diffs or .tex.

### Requirements for review HTML

1. **Full text** — show the complete document, not just changed sections
2. **Navigation** — clickable sidebar or jump links to reach each edited section
3. **Change tracking** — two modes:

| Mode | Visual | Use case |
|------|--------|----------|
| **Highlight new** | Yellow background on changed/added passages | Quick scan of what's different |
| **Track changes** | Strikethrough (red) for removed text + highlight (green) for new text | Detailed review of every edit |

4. **Section anchors** — every heading gets an `id` for direct linking
5. **Change count** — summary at top: "N sections modified, M words added, K words removed"

### Existing review scripts (consolidation TODO)

These scripts exist in `tmp/` and overlap significantly:

| Script | What it does |
|--------|-------------|
| `render_tracked_paper.py` | Insertion markers → highlighted HTML (paper) |
| `render_book_changes.py` | Old/new text pairs → labeled diff HTML (book) |
| `create_highlighted_book.py` | Git diff → yellow highlights (book) |
| `create_book_diff_html.py` | Another book diff variant |
| `create_tracked_paper.py` | Another paper variant |

**TODO:** Consolidate into a single `tmp/review_changes.py` with:
- `--mode highlight` (highlight-new-only)
- `--mode track` (track-changes with strikethrough)
- `--source <file.md>` (input document)
- `--against <ref>` (git ref, file, or "staged")
- `--output <file.html>` (output path)

Until consolidated, **reuse existing scripts — do NOT write new ones.**

### Opening review HTML

```bash
python3 tmp/<script>.py && powershell.exe -Command "Start-Process '\\\\wsl.localhost\\Ubuntu\\home\\jeltz\\aIware\\tmp\\<output>.html'"
```

---

## 5. Review Division — Machine vs Human

**Claude reviews source; the user reviews rendered output. Never confuse the two.**

| Review type | Who | Format | Examples |
|-------------|-----|--------|----------|
| **Structural correctness** | Claude (automated tests) | .md, .tex source | Section counts, canary phrases, word volume |
| **Content accuracy** | User | HTML (change-tracked) | Prose correctness, meaning preservation |
| **Layout & typography** | User | PDF or Word | Page breaks, figure placement, fonts |
| **Version comparison** | User | Side-by-side PDFs | Before/after build scripting, before/after edits |

**When the user asks to "compare" two versions of a paper, deliver compiled PDFs (or Word docs) — never source-level diffs.** The user does visual inspection on final rendered products. Source diffs are for Claude's debugging, not for human review.

### Producing comparison materials for the user

1. Compile both versions to PDF (or Word if the target format is .docx)
2. Name them clearly: `tmp/<paper>-BEFORE.pdf`, `tmp/<paper>-AFTER.pdf`
3. Open both for the user
4. Optionally provide a brief text summary of what changed (section-level, not line-level)

### CRITICAL: Never overwrite or recompile canonical paper PDFs for comparison

**Canonical PDFs** (`paper/*/paper.pdf`, `paper/cosmology/sb-hc4a.pdf`) are compiled products that may have been built with multi-pass pdflatex+bibtex, hand-verified, and used for submissions. They are **not disposable**.

Rules:
- **NEVER compile into `paper/` directories** for comparison or testing purposes. Always compile into `tmp/`.
- **NEVER overwrite a canonical PDF** without explicit user instruction ("rebuild the paper PDF").
- When you need a "before" PDF, **use the canonical PDF as-is** — do not recompile it.
- When you need an "after" PDF, **compile the new .tex into `tmp/`** with a clear name.
- If a canonical PDF is accidentally damaged, restore from git: `git checkout HEAD -- <path>`
- **Before any pdflatex run**, verify the output directory is `tmp/`, never a `paper/` directory.

**Why this rule exists:** Session 106 recompiled ORIGINAL .tex files in `tmp/` without bibtex, producing PDFs with broken citations (`???`). The user's canonical PDFs with resolved citations were also overwritten by a prior build script run. Both "before" and "after" were damaged simultaneously, making comparison impossible.

### Layout review checklist (PDF only)

- Page breaks, orphans/widows
- Figure placement and sizing
- Table formatting
- Title page appearance
- Header/footer correctness
- Font rendering

---

## 6. Session Shutdown Protocol — Publications

**Before every session restart or shutdown**, if any publication files were modified:

1. **Ensure .md is up to date** — all content changes are in the canonical .md
2. **Update formatting rules** — if any LaTeX-only formatting decisions were made, record them
3. **Regenerate .tex** — run the build script so .tex matches current .md + formatting rules
4. **Regenerate .pdf** — compile so the user has a current PDF to review offline
5. **Commit all files** — .md, .formatting-rules.md, .tex, .pdf
6. **Push** — `bash scripts/push.sh`

The user must be able to open consistent, up-to-date files after the session ends. Stale .tex or .pdf is unacceptable.

---

## 7. Parallel Agent Chunking — HARD LIMITS

When launching parallel agents to edit or revise a book-length document:

| Parameter | Limit | Why |
|-----------|-------|-----|
| **Max lines per chunk** | 60 | Agents hit context limits above ~100 lines. 60 is safe. |
| **Target lines per chunk** | 40-55 | Sweet spot: enough context, plenty of room for reasoning |
| **Min lines per chunk** | 20 | Below this, context is too fragmented for coherent edits |
| **Split points** | Chapter/section boundaries, blank lines | Never mid-paragraph |
| **Model for German text** | Opus only | Weaker models produce translationese |
| **Output strategy** | Write to numbered tmp files, assemble after | Never have multiple agents edit the same file concurrently |

**Why this rule exists:** Sessions 97 used 200-300 line chunks. 6 of 7 agents hit context limits and wasted tokens. Session 98 used 40-63 line chunks — all 14 agents completed successfully.

**The math:** A 2400-line book needs ~40-60 agents at 40-60 lines each. This is fine — launch them all in parallel, they write to tmp files, you assemble. The token cost of 40 small agents that succeed is far less than 7 large agents that fail.

**Assembly protocol:**
1. Each agent reads its assigned lines, revises, writes to `tmp/rev-chunk-NN.md`
2. After all complete, verify each output: correct line count, starts/ends at right content
3. Concatenate: existing-good-lines + chunk-outputs + existing-good-lines
4. Verify: heading count, total lines reasonable, spot-check seams
5. Deploy to main file (backup first)

---

## 8. Checklist — Before Committing Publication Changes

- [ ] Content changes are in .md (NOT .tex)
- [ ] New formatting rules (if any) are in .formatting-rules.md
- [ ] .tex was regenerated from .md + formatting rules (not hand-edited)
- [ ] .pdf was recompiled from .tex
- [ ] Content integrity tests pass: `pytest tmp/test_content_integrity.py -v`
- [ ] Review HTML was generated if content review is needed
- [ ] All four files (.md, .formatting-rules.md, .tex, .pdf) are staged and committed together

---

## 9. Test-Driven Authoring (TDA)

Content integrity tests catch silent content loss during .md → .tex conversion. See `~/.claude/domains/publications/test-driven-authoring.md` for the full protocol.

**Quick reference:**

| Command | What it tests |
|---------|--------------|
| `pytest tmp/test_content_integrity.py -v` | Structural parity, volume guards, canary phrases (Tier 1-3) |
| `pytest tmp/test_pdf_verification.py -v -m slow` | PDF page count, text extraction, unresolved refs (Tier 4) |
| `pytest tmp/test_build_scripts.py -v -m "not slow"` | Build script unit tests (citations, preamble, conversion) |
| `python3 tmp/update_test_baselines.py` | Print current calibration values for review |

**Run Tier 1-3 before every .tex commit. Run Tier 4 before submission.**
