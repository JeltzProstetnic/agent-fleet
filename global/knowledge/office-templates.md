<!-- updates: none -->
<!-- consumed-by: global/knowledge/deliverable-authoring.md (build path), global/knowledge/presentation-design.md (deck build path) -->
# Office Templates — building DOCX, PDF and decks

Load when: producing any document, PDF or slide deck as a deliverable. Read `deliverable-authoring.md` for *what* to write and `presentation-design.md` for deck content discipline; this file is *how the artefact gets built*.

**Location:** `~/agent-fleet/setup/templates/office/` — one template, all machines, referenced by absolute path. Full usage in its `README.md`.

## The three build paths

| Output | Command | Engine |
|---|---|---|
| DOCX | `python3 <D>/build-docx.py <src.md> <out.docx> "Title"` | python-docx over a generated branded template |
| PDF | `bash <D>/build-pdf.sh <in.docx> [outdir]` | headless LibreOffice |
| PPTX | `build-deck.py` `Deck` class | HTML slide → headless Chrome PNG → python-pptx |

`<D>` = `~/agent-fleet/setup/templates/office`.

**Markdown is canonical; the office file is rebuilt from it.** Never hand-edit a built `.docx` and never treat it as the source. Commit source and artefact together.

## How the DOCX path works

`assets/fleet-template.docx` is generated once from `tokens.py` + the logo. The builder then **opens that template as the document, clears its body (keeping `sectPr`), and writes new content into it** — so the styles, the header logo and the footer `PAGE`/`NUMPAGES` fields survive without being rebuilt each time. Header and footer placeholders are patched afterwards by rewriting the package XML, because python-docx cannot edit literal header text through its API.

The leading `<!--META ... -->` block of the source becomes the document-control table (any key/value pairs; the table is generated from whatever is present), and `Status` / `Version` are additionally patched into the footer. The first `# H1` is consumed as the title and not repeated.

## Rules

- **`tokens.py` is the only place a colour, font, size or margin may be defined.** If a builder hardcodes `#12707F`, that is the bug.
- **Never paste an employer's or client's brand colours or licensed typeface into the fleet template.** It is used across unrelated work; a client palette leaking into a personal deliverable is the failure mode. The test suite asserts the absence of the palette this template was derived alongside.
- **Structural verification only.** Check slide/notes/media counts, PNG byte sizes, heading/table/bullet counts, and that the header patch landed. **Do not read rendered images into context** — the per-conversation image cap breaks the session after ~10-15, and it only clears with `/clear`. Visual review is the user's job.
- **A failed render must raise.** The pipeline this was derived from swallowed Chrome's exit code and inserted a blank slide while still reporting success. Any renderer wrapper checks the return code *and* that the output file exists at a plausible size.
- **A signature block that splits across a page break is a real defect, not a cosmetic one** — a rebuild once put the signature rule on page 1 and the name label on page 2, which on a signed document invites *"which page was actually signed?"*. Set `paragraph_format.keep_with_next` on all but the last line of the block and `keep_together` on all of them, then **assert the page count after the PDF conversion** — page count cannot be read from the `.docx` at all (see Platform gotchas), so the assertion has to live after the LibreOffice step. That assertion is what caught the second attempt.
- **The fleet template is BRANDED** (logo header, document-control table, footer fields), which makes it **wrong for private legal correspondence to an authority** — that needs a plain document from a dedicated minimal builder, and the markdown-is-canonical rule above still applies to it. Worked example: `~/life/drafts/build-bestaetigung-unterhalt.py`.
- **Run `bash <D>/test-office-template.sh` after touching anything in that directory.** 22 structural checks, ~30 s; skips the deck checks with a message when no browser is present.

## Platform gotchas

- **WSL + Chrome:** Windows Chrome cannot read WSL `/home` paths. The render directory must be under `/mnt/c`, images are copied there and referenced *relatively*, and `--screenshot=` takes the Windows path while the read-back takes the WSL path. Handled inside `build-deck.py`; the same trap applies to any new renderer.
- **WSL + LibreOffice:** no Linux LibreOffice on the fleet machines — the Windows install is driven from a real `C:\` staging directory (the UNC path guard rejects `\\wsl.localhost\...` as a CWD) with its own `-env:UserInstallation` profile so a running GUI instance does not block the conversion. Re-verified working verbatim on WSL 2026-09-17; it emits a harmless `Could not find platform independent libraries` on stderr and still converts, so do not read that line as a failure.
- **Word comments are INVISIBLE in a default LibreOffice PDF render** — which reads exactly like *"the comments were not written"*. To verify a generated `.docx`'s comments, render them into the margin: `--convert-to 'pdf:writer_pdf_Export:{"ExportNotesInMargin":{"type":"boolean","value":"true"}}'`. Verified on WSL with Windows LibreOffice (pdp 2026-09-24).
- **Page geometry:** the template is true A4 (210 × 297 mm). Inherited corporate templates frequently mix A4 width with US-Letter height — prints short on Letter, clips on A4. Check `pgSz` before trusting any template you did not generate. **A bare python-docx `Document()` is US Letter (216 × 279 mm) outright, and nothing warns you** — an Austrian Unterhaltsbestätigung for an Austrian authority sat on American paper for two days before anyone noticed. Any builder not using the fleet template MUST set `sec.page_width, sec.page_height = Mm(210), Mm(297)` explicitly **and assert it afterwards**.
- **Page counts cannot be read back** from a python-docx artefact: `docProps/app.xml` `<Pages>` is never updated. Convert to PDF if a page count matters.

- **pandoc → weasyprint HTML is capped at 36em wide by pandoc's default template**, and that embedded CSS beats a `weasyprint -s` user stylesheet. Use `pandoc -s -V document-css=false -c file://<css>` and put `html,body{margin:0;max-width:none}` in the stylesheet (life 2026-10-08).

## Branding a fork (onboarding)

Replace `assets/logo.svg` (keep the `0 0 400 100` viewBox — 4:1 — and all geometry stays valid), rasterise it to `assets/logo.png` at 1600×400, edit the tokens, run `make-template-docx.py`, re-run the tests. Four steps, all in the template's `README.md`.

## Corporate .pptx templates: footer placeholders are not copied

**python-pptx does not copy footer-type placeholders (infoline, date, slide number) from the layout to a new slide.** So `ph(slide, 11).text = …` raises `StopIteration` on a slide built with `add_slide(layout)`. Fix: deepcopy the layout's placeholder element into `slide.shapes._spTree`. Reference implementation: `_clone_from_layout` in the corporate progress-report kit (2026-10-28, CFG-849).

## Diagrams

No charting library is involved anywhere. Options, in order of preference: **mermaid** (`mmdc`, committed `.mmd` alongside the render — set the light theme so it matches the palette), **hand-authored SVG** on a `0 0 1600 900` viewBox rasterised at 1.5×, or **HTML + CSS primitives** screenshotted through the same Chrome path as the slides. Embed diagrams into decks with the image slide type's `diag=True`, which drops the border, radius and shadow that photographic mockups get.

Related: [[deliverable-authoring]], [[presentation-design]], [[needs-to-requirements]].
