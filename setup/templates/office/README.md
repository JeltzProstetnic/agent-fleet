# Agent Fleet Office Template

The fleet's default look for documents, PDFs and decks. Structure modelled on a
production corporate template; the typeface, palette and logo are the fleet's
own — generic families, an independent blue-green hue family, and a placeholder
mark meant to be replaced.

```
tokens.py                 the single source for every colour, font, size, margin
make-template-docx.py     generates assets/fleet-template.docx from tokens + logo
build-docx.py             markdown -> branded DOCX
build-pdf.sh              DOCX -> PDF (headless LibreOffice, WSL-aware)
build-deck.py             HTML slide -> PNG (headless Chrome) -> PPTX
test-office-template.sh   structural verification of all of the above
assets/logo.svg           PLACEHOLDER logo — replace this
assets/logo.png           rasterised from the SVG, 1600x400
assets/fleet-template.docx  generated; do not hand-edit
```

## Quick use

```bash
D=~/agent-fleet/setup/templates/office

python3 $D/build-docx.py  needs.md  01_User-Needs_v1.0.docx  "Project — User Needs"
bash    $D/build-pdf.sh   01_User-Needs_v1.0.docx  ./deliverables/2026-08-07/
python3 -c "
import sys; sys.path.insert(0,'$D')
from importlib.machinery import SourceFileLoader
Deck = SourceFileLoader('bd','$D/build-deck.py').load_module().Deck
d = Deck('offer')
d.cover('AGENT FLEET','MVP Offer','What the first release does','2026-08-07')
d.statement('SCOPE','Two scopes, one recommendation')
d.build('offer.pptx')"
```

Markdown supported by `build-docx.py`: `#`..`######`, `- `/`* ` bullets (two
levels), `> ` blockquotes, GitHub pipe tables, `---`, `**bold**`, `*italic*`,
`` `code` ``, and a leading `<!--META ... -->` block that becomes the
document-control table. The first `# H1` is consumed as the title and not
repeated in the body.

The header carries the logo and the document title; the footer carries the
status, the version and a live `page N of M` field pair. Both are patched from
the META block at build time.

## Branding a fork — the onboarding step

1. **Replace `assets/logo.svg`.** Keep the `0 0 400 100` viewBox (4:1) and the
   whole geometry stays valid. Then rasterise:
   ```bash
   python3 -c "import cairosvg; cairosvg.svg2png(url='assets/logo.svg', write_to='assets/logo.png', output_width=1600, output_height=400, background_color='transparent')"
   ```
2. **Edit the colour and font tokens** at the top of `tokens.py`. Roles, not
   names — `PRIMARY`, `ACCENT`, `INK`. Nothing else in this directory may
   hardcode a colour.
3. **Regenerate the document template**: `python3 make-template-docx.py`
4. **Re-run the tests**: `bash test-office-template.sh`

Do not paste an employer's or client's brand colours or licensed typeface into
`tokens.py` — a fleet template is used across unrelated work. The test suite
asserts this for the palette this template was derived alongside; extend those
assertions if your situation adds others.

## Design decisions worth knowing

- **True A4** (210 x 297 mm). Mixing A4 width with US-Letter height is a common
  inherited template defect: it prints short on Letter and clips on A4.
- **Slides are rendered images, not editable shapes.** python-pptx has no layout
  engine, so hand-assembled native shapes top out at draft quality. Rendering
  HTML gives real typography; the cost is that recipients cannot edit the slide.
  Detail lives in the speaker notes and the companion document, which is where
  the design law wants it anyway.
- **Chrome's exit code is checked.** The pipeline this was derived from
  swallowed it and inserted a blank slide on failure while still reporting
  success. Here a failed render raises.
- **Verification is structural.** Slide/notes/media counts, PNG byte sizes,
  heading/table/bullet counts, header-patch confirmation — never reading the
  renders into an agent's context. Visual review is the user's job; see
  `~/.claude/knowledge/presentation-design.md` for why.

## Platform notes

| | Documents | PDF | Decks |
|---|---|---|---|
| **WSL** | works | Windows LibreOffice, driven from a `C:\` staging dir with its own profile | Windows Chrome; render dir must be under `/mnt/c` because Windows Chrome cannot read `/home` |
| **Native Linux** | works | `soffice` from PATH | `chromium` / `google-chrome` from PATH |
| **No browser** | works | works | `test-office-template.sh` skips the deck checks and says so |

Requires `python-docx`, `python-pptx`, and `cairosvg` (logo rasterisation only).
