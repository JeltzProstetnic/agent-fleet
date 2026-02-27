# Test-Driven Authoring (TDA) Protocol — MANDATORY

**Load this rule when a session involves building, debugging, or modifying paper build scripts (.md → .tex → .pdf pipeline).**

---

## Purpose

The publication pipeline has suffered repeated silent content loss (Sessions 25, 39, 43, 70 — ~8,000 words collectively). TDA prevents this by running automated tests that verify content survives the .md → .tex conversion.

---

## 1. The 4-Tier Test Architecture

| Tier | Name | What it catches | Speed |
|------|------|----------------|-------|
| 1 | Structural Parity | Section/table/figure drops between .md and .tex | Fast |
| 2 | Content Volume Guards | Regex eating paragraphs, reference truncation | Fast |
| 3 | Canary Phrases | Content from specific sections surviving conversion | Fast |
| 4 | PDF Verification | Compilation issues, unresolved refs, missing images | Slow |

### Test files

| File | Content | Run command |
|------|---------|-------------|
| `tmp/test_content_integrity.py` | Tier 1 + 2 + 3 | `pytest tmp/test_content_integrity.py -v` |
| `tmp/test_pdf_verification.py` | Tier 4 | `pytest tmp/test_pdf_verification.py -v -m slow` |
| `tmp/test_build_scripts.py` | Build script unit tests | `pytest tmp/test_build_scripts.py -v -m "not slow"` |

Shared fixtures live in `tmp/conftest.py`.

---

## 2. When to Run Tests

| Event | Which tests | Why |
|-------|------------|-----|
| After editing a build script | All Tier 1-3 | Catch regressions immediately |
| After editing .md content | Tier 3 canaries | Verify canaries still exist in source |
| **After ANY PDF build** | **All Tier 1-4** | **Catch broken citations, missing floats, unresolved refs** |
| Before committing .tex | All Tier 1-3 | Pipeline publication checklist |
| Before a submission | All Tier 1-4 | Full verification including PDF |
| After major content changes (>500 words) | Tier 2 | Verify word counts still in range |

**CRITICAL — Session 109 lesson:** The `??` and missing-table bugs shipped because Tier 4 tests were not run after the PDF build. Checking the `.tex` for `???` is NOT sufficient — bibtex failures only manifest in the compiled PDF. **Every PDF build MUST be followed by Tier 4 tests.** No exceptions. The cost is 0.4 seconds. The cost of shipping a broken preprint to Zenodo is catastrophic.

---

## 3. Tier 2 Recalibration

Constants in `test_content_integrity.py` define plausible ranges:

```python
PAPER_BODY_WORD_RANGE = (13_000, 21_000)    # Adjust to your paper's expected length
SHORT_PAPER_WORD_RANGE = (5_500, 10_500)    # Adjust for shorter papers
```

**Update protocol:** If a Tier 2 test fails, ask: "Did I intentionally add/remove a large amount of content?"
- **Yes** → run `python3 tmp/update_test_baselines.py`, review output, update constants
- **No** → conversion bug. Investigate the build script.

The 25% tolerance means recalibration is needed approximately once per year at current editing cadence.

---

## 4. Tier 3 Canary Maintenance

Canary phrases are selected for stability — they are core theoretical terms that will never be removed. A canary failure means:

1. **`STALE CANARY`** — the phrase was removed from the .md. Remove it from the canary list and optionally add a replacement.
2. **`CANARY DEAD`** — the phrase is in .md but not in .tex. This is a **conversion bug**. Fix the build script.

When adding new content to a paper, consider adding 1-2 canary phrases from the new section, especially near:
- Float injection anchors
- Special characters (&, umlauts, em dashes)
- Complex citation patterns

---

## 5. Adding Tests for New Papers

When a new paper enters the build pipeline:

1. Add fixtures to `tmp/conftest.py` (build module, .md reader, .tex generator)
2. Add Tier 1 structural tests (section/subsection counts)
3. Calibrate Tier 2 ranges using `tmp/update_test_baselines.py`
4. Select 15-30 canary phrases covering every section
5. Add Tier 4 PDF tests with appropriate page/word ranges
6. Run all tests to establish baseline

---

## 6. Integration with Publication Workflow

TDA is part of the publication checklist (see `publication-workflow.md` Section 8):
- Run `pytest tmp/test_content_integrity.py -v` before committing .tex
- Run `pytest tmp/test_pdf_verification.py -v -m slow` before submission

Build script modifications follow TDD:
1. Write/update test for the new behavior
2. Verify test fails (red)
3. Implement the change
4. Verify test passes (green)

---

## 7. Machine vs Human Review — Know Your Lane

**Tests (Tiers 1-4) are Claude's job. Visual inspection of rendered output is the user's job.**

- When the user asks to "compare versions" → compile both to PDF, open for visual inspection
- When the user asks to "check the paper" → run tests (machine), then compile PDF (human)
- NEVER present source-level diffs (.tex, .md) as the comparison artifact for the user
- Source diffs are debugging tools for Claude, not review materials for humans
- Deliver rendered outputs: PDF for layout, Word for track-changes, HTML for content review
