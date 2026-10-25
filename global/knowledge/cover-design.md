# Book cover design — type over artwork

**Trigger:** load when designing, building or QA-ing a book cover (print or eBook), especially when you are placing a title over busy or full-bleed artwork, choosing a scrim or panel, or writing a cover legibility gate.

This is a reference, not a gate. It records professional practice so a session does not have to re-derive it from first principles, or from a screen-accessibility standard that does not apply to print.

**Companion:** `print-production.md` covers what the press does to the file (banding, ink limits, dot dropout, barcode zone, proofs). On one question the two files disagree; see *Design vs print tension* below. KDP geometry (wrap, spine, barcode position) is in `kdp-publishing.md`.

## Treatments, and which ones read amateur

| Treatment | What it is | Reads as |
|---|---|---|
| **Gradient scrim** | Dark, directional, fades toward the art's focal zone | **Professional default** for busy imagery |
| **Full overlay** | Flat tint across the *whole* image, no gradient | Professional; used when type spans the image |
| **Solid colour block** | Opaque field, hard edges, defined zones | Professional **only** when it is part of the composition (bleeds to an edge, sits on a grid). A rectangle sized to the text's bounding box is the classic self-published "text box on a stock photo" tell |
| **Image darkening / multiply** | Blend-mode version of the overlay | Editorial/magazine polish |
| **Duotone / desaturation** | Region mapped to two tones | Stylish; dates badly if the rest of the cover does not commit |
| **Blur behind type** | Soft "copy space" under the title | Good when the art has a focal hierarchy; wrong on flat, evenly detailed illustration |
| **Drop shadow** | One soft, low-opacity, tight-radius shadow | **Acceptable and recommended** for reversed type on busy photographs, used *once* |
| **Outline / stroke** | Contrasting stroke around each letter | **Amateur tell.** It fights the letterforms, and at thumbnail size stroke and fill blur into grey mush |
| **Stacked effects** | Shadow + glow + stroke together | **Amateur tell.** One effect maximum |
| **Coloured band / banner** | Thin full-bleed strip | Signals commercial genre fiction or business nonfiction, not literary or big-idea science |

Sources: [IngramSpark — cover design styles](https://www.ingramspark.com/blog/9-book-cover-design-styles-that-stand-the-test-of-time),
[Barker Books](https://barkerbooks.com/book-cover-design-tips/),
[KDP Easy — cover design principles](https://www.kdpeasy.com/guides/book-cover-design-principles),
[Smashing Magazine — accessible text over images](https://www.smashingmagazine.com/2023/08/designing-accessible-text-over-images-part1/),
[prepressure — reversed type](https://www.prepressure.com/design/basics/reversed-type).

## ⚠ WCAG is the wrong instrument for a printed cover

Do not build a cover gate on WCAG 2.x contrast minima. There are three separate problems:

1. **WCAG 2.1 is a standard for self-illuminated RGB displays.** Print has no equivalent numeric standard. Accessible-print sources warn that measured contrast "can greatly diverge from the calculated outcome" once lighting and paper are involved. ([netz-barrierefrei](https://netz-barrierefrei.de/en/print.html))
2. **It compares one flat colour with another flat colour.** A cover background varies across its area, so a single ratio says nothing about a highlight sitting under the crossbar of one letter. That local highlight is the defect that recurs on dark, glowing art. ⇒ **A legibility gate must measure per glyph and take the worst pixel**, not an average or a percentile over a whole box.
3. **A cover title counts as "large text" even inside WCAG**, so the applicable tier is **3:1**, not 4.5:1. Quoting 4.5:1 at a title applies the wrong tier of the wrong standard. A small subtitle (normal-text size) does fall under 4.5:1 if WCAG is used at all.

The WCAG 2 formula is blunt even for screens: APCA testing found it "incorrectly passed 49% of colors that were too low in contrast to read". ([APCA / Myndex](https://gist.github.com/Myndex/069a4079b0de2930e72d5401bde9af98))

**What practitioners use instead. Adopt both as the real acceptance tests:**
- **Greyscale test.** Convert the finished cover to greyscale. Title, subtitle and author must each still separate from the art at a glance.
- **Thumbnail test.** Render the cover at about 160 px wide and check the same. If either test fails, the fix is a deeper or wider scrim, or a re-crop. It is **never** a stroke or a heavier shadow.

## Thumbnail legibility

Amazon browse thumbnails run about **100–200 px tall**. 160 px is the standard benchmark, and testing down to 100 px is recommended.
([Creative Paramita](https://creativeparamita.com/book-cover/book-cover-thumbnail-that-survives-the-amazon-test/))

- **The title should fill 40–60 % of the cover's height**, up to 70 % for very short titles. Non-fiction titles want 4–5× the visual weight of the byline.
- **Subtitles longer than five words are flagged as a mistake.** The subtitle is the element that fails first at thumbnail size. A long subtitle is a copy decision, not a rendering bug.
- **Three colours maximum.** Beyond that "you are no longer designing, you are decorating."
- **What disappears first as the cover shrinks, in order:**
  1. fine artwork detail
  2. thin or ornate fonts
  3. subtle lighting gradients
  4. drop shadows and bevels
  5. the subtitle
- **An effect that is barely there at print size is invisible at 160 px.** Any legibility treatment must survive a downscale of roughly 10–15×.

## Reversed (knockout) type — the print rules

White-on-dark is *reversed type*. Print had hard rules for it long before any web standard:
- **Minimum 10 pt** in offset print (12 pt on newsprint).
- **No hairline or high-contrast serifs** (Bodoni/Didone class). Keep the minimum stroke at about 0.5 pt at print size. Use semibold or bold cuts.
- **Open the tracking slightly.** Light type on dark reads tighter than black on white.
- **On busy photographs, add a drop shadow.** This is the named professional fix.
- **Prefer backgrounds with darker, more consistent values.** "Irregular or vibrant patterns" and "variable values" are called out as the worst case.

([creativepro](https://creativepro.com/setting-readable-reversed-type/), [prepressure](https://www.prepressure.com/design/basics/reversed-type))

Colin Wheildon's print readership research found good comprehension in **0 %** of readers for white body text on a mid-value colour, against 70 % for black on white. That was body copy, not display type, so the size of the effect does not carry over to a title. The direction does, and it is much stronger than designers assume.
([summary](https://cuttingedgepr.com/articles/using-reverse-typeface-on-a-page-can-dramatically-reduce-readership/))

## Genre: what successful "big idea" science covers do

**Almost none of them put type over dense, evenly detailed, full-bleed art.** They avoid the problem at the concept stage:

- **Sapiens:** flat orange-red field, one symbolic fingerprint, title *embossed*. No photograph.
- **Thinking, Fast and Slow:** bold type on a simple background with one faint pencil drawing.
- **Gödel, Escher, Bach:** three carved blocks on a plain ground.
- **The Disappearing Spoon:** the illustration *is* the typographic device.
- **A Brief History of Time:** black boards, silver stamping, a calm starfield.
- **Cosmos**, **The Elegant Universe:** atmospheric imagery, art-directed with a calm, low-detail zone kept free for the title.

**Consequences:**
- A dense, dark, glowing, full-bleed cover with white serif type belongs to the atmospheric space-science register, not the flat-field register. That is a positioning choice, not an error. But it **creates** a legibility problem, which then has to be solved by treatment.
- **The most professional move is to art-direct the highlights, not patch them.** Every successful atmospheric cover keeps copy space free. If the art is generated or composited, moving the hot spots out from under the title beats any overlay.

## Design vs print tension — surface it to the author, do not resolve it silently

| | says | because |
|---|---|---|
| **This file** (design) | **A gradient scrim beats a hard panel** | A panel fights organic artwork and, sized to a text box, reads amateur. Genre precedent is atmospheric art with a scrim |
| **`print-production.md`** (press) | **A hard-edged solid panel is safest** | No gradient means nothing to band, across many independent, unattended POD press runs |

**Each file is right within its own domain.** The compromise both tolerate:
- a **panel with a short, soft inner edge**: short enough to dodge the banding risk the print side flags, soft enough to avoid the bolted-on box the design side flags;
- the ramp **must not taper to full transparency** (see `print-production.md` on highlight-dot dropout).

The author chooses the look. These are the constraints on it.

## Cover QA habits that held up

- **Visually check the rendered wrap at print size before calling any cover done.** A subtitle-over-artwork overlap shipped twice when only the code was reviewed.
- Anchor the subtitle to the title's bounding box (e.g. below the title's south edge) so a longer title or a translation cannot push it into an overlap.
- In multi-language editions, size the title per language so it fits on a set number of lines. Switching the rendering engine partway through a set of editions requires another full visual QA pass.
- Back and spine as a **solid** field is the low-risk default when no art is needed there (no gradient, so no banding).
