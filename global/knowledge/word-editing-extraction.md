# Word Inline Editing — Extraction & Generation

<!-- consumed-by: none (standalone knowledge, triggered by conditional loading) -->

Knowledge for authoring projects that read author marks back out of a .docx (**Extraction**, below) AND that emit .docx (**Generation**, further down). Applies broadly — "we will be editing Word documents in general often" (user directive).

## Three Mark Types

1. **Strikethrough** = delete this text. Detected via `w:strike`/`w:dstrike` in run properties.

2. **Yellow highlight** (shading `FFFF00` or highlight `yellow`) = poorly written passage, rewrite it. Not a deletion — a rewrite request.

3. **Direct text changes** = user retyped words, fixed phrasing, changed examples. No formatting marks — text simply differs from source. **Must be detected by diffing docx paragraph text against source .md line by line.**

## Extraction Protocol

1. Extract formatting marks (strikes, highlights, shading) from Word XML
2. **Diff full paragraph text** against source .md for the edited region — this catches direct rewrites
3. Check BOTH `w:highlight` AND `w:shd` for yellow (Word uses shading for manually applied yellow, highlight for toolbar yellow)
4. Direct edits may contain typos — apply the intent, fix obvious typos
5. If ambiguous (comment vs. edit), check context or ask
6. **Never overwrite the user's review file** — always write rebuilt .docx to a new filename

## Generation Protocol (.docx output)

The generation side has its own traps (double-numbered headings, tables full of empty cells with a heading floating in them). Learned the hard way building a corporate guideline document, 2026-06.

1. **Don't pandoc-generate onto a reference template.** `pandoc --reference-doc=template.docx` double-numbers headings when the template's Heading styles carry style-level auto-numbering (`numId`) AND the markdown hardcodes `1.`/`3.1` in heading text → Word renders both; it also makes messy tables (empty header rows from `| | |`, phantom columns).
2. **Build with python-docx from the reference doc instead.** Open the template (inherits styles/header/footer/theme), wipe the body but KEEP the trailing `w:sectPr`, rebuild with the template's named styles (`Title` unnumbered; `Heading 1/2/3` auto-number via the style — pass heading TEXT ONLY, no manual numbers), move `sectPr` back to the end, save, then patch the header title by zip string-replace.
3. **Clean tables.** `Table Grid` style + fixed layout + explicit per-cell `Cm()` widths + `autofit=False`; never an empty header row (use a headerless 2-col label/value table for doc-control blocks); never a heading inside a cell.
4. **Markdown vs Word numbering.** The `.md` source KEEPS manual section numbers (markdown can't auto-number; `§`-refs need them); the Word build OMITS them (style auto-numbers) — displayed numbers come out identical.
5. **Always render & LOOK before delivering.** docx→PDF via LibreOffice headless (Windows-side on WSL: `/mnt/c/Program Files/LibreOffice/program/soffice.exe`, use a separate `-env:UserInstallation` profile), then read the PDF. `.~lock.<name>#` = LibreOffice has it open (Word uses `~$`) — never overwrite while locked.

Worked example shape: a project-level `<project>/knowledge/document-templates.md` how-to plus a `<project>/docs/<document>/build-docx.py` builder.

## Native Tracked-Changes Output (Accept/Reject-ready `w:ins` marks)

To produce a tracked-changes `.docx` (real revision marks, not just visible diffs) — e.g. an author review round:

1. pandoc BOTH baseline and current markdown → `.docx` with **identical** options.
2. LibreOffice headless **`.uno:CompareDocuments`** (officehelper-bootstrapped `soffice`), baseline → current.
3. Optional: python zip-rewrite to set the revision author.

Two gotchas to persist:
- Headless compare **SIGSEGVs on the Qt6 VCL plugin** — export **`SAL_USE_VCLPLUGIN=svp`**.
- `pkill -f soffice` **self-matches the caller's own command line** → use **`pkill -x soffice.bin`**.

Source: measured in a fleet project, 2026-07.

## Three SILENT extraction losses — the extraction succeeds and returns the wrong content

All three measured in a fleet project, 2026-09, against a corporate process-template corpus. Each one returns a
plausible result, so nothing looks wrong until somebody checks the document by eye.

1. **Template markup is SPLIT ACROSS RUNS, so grepping `word/document.xml` misses it.** The process
   templates carry Xporter-for-Jira markup (`&{for issues|filter=…}`, `${Key}`, `#{for links}`).
   A grep over the raw `word/document.xml` found **zero** hits; rebuilding each paragraph's text from
   its `<w:t>` nodes first found **45 files and 439 link references**. Word splits a literal like
   `${Key}` across several `<w:r>` runs whenever formatting or spell-check state changes mid-token.
   ⇒ **Always concatenate `<w:t>` per `<w:p>` before any regex.** Cost ~20 min of concluding "there is
   no exporter code in these templates", which was the exact opposite of true.

2. **Applicability markers can be EMBEDDED IMAGES, and text extraction reads them as "applies to
   everything".** One procedure SOP marks each step with project-type badges (MSD / PSD / ASD /
   USD). Measured: the badge paragraphs carry **no** run colour, **no** highlight and **no** shading —
   all four look identical in the XML — while the document holds **140 `<w:drawing>` elements, 63
   media files and zero `<w:sym>`**. So the "which type does this step apply to" signal is carried by
   pictures, and plain text extraction returns all four badges for every step. Same failure class as
   losing a planning board's cell colours on export. ⇒ **Before trusting an extracted procedure's
   applicability, count `<w:drawing>` and `word/media/*`**; if they are non-trivial, the markers are
   probably images.

3. **A template's fill-in contract can be carried by FONT COLOUR — and it is machine-extractable.**
   One governing SOP states it normatively: *"Never change texts or other elements that are not in red
   color."* Red is `FF0000` in `<w:rPr><w:color w:val="FF0000"/>`, and the split is real: **273 of 855**
   text runs in one form template, **163 of 228** in another. ⇒ **For any Word template you have to
   fill or generate, extract the red runs FIRST** — they are the slot list, free, and plain text
   extraction throws them away. Worth a helper in the office template toolkit.

⚠ **Small companion, same session:** Word lock files (`~$<name>.docx`, 162 bytes) get committed by a
`git add -A` and nobody notices — one project carried one in git for a week before it was spotted. Adding `~$*`
to the default project `.gitignore` prevents the whole class.

## Origin

Extraction learned in a book-authoring project (2026-03) — missed direct text changes (heading rename, example swap, parenthetical reword) and yellow highlights (shading vs highlight distinction) across three review rounds. Generation + tracked-changes recipes added 2026-07 (from fleet project sessions 2026-06 and 2026-07).
