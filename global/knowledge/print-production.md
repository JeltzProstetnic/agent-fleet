<!-- consumed-by: global/CLAUDE.md (conditional loading), any project producing print-on-demand covers or interiors (cover build scripts, platform spec notes) -->

# Print production — what the press does to the file

Reference, not a gate. Read alongside the project's own cover-design notes (panel vs gradient is a design
call this file informs, not decides). Trim sizes, spine widths and ISBNs are platform- and title-specific and
belong in the project's own platform spec notes; this file is about ink.

**[Official]** = published platform spec. **[Practitioner]** = prepress/production literature or
reported experience, credible but not platform-issued. KDP publishes no numeric ink limit.

## Why a multi-edition POD batch is the risky case

POD is **unattended, file-to-press, zero-touch**. There is no press operator doing the
check-and-adjust pass that would catch a marginal file on offset. Digital presses also "might show
banding or roller marks, particularly on larger solid color areas" and carry a narrower gamut than
offset. A construction that "usually" prints fine becomes a real probability of at least one
visibly bad edition across many independent runs (e.g. eleven language editions) on two printer fleets
(KDP + IngramSpark for editions KDP cannot serve).
([Mixam](https://mixam.com/support/offset-printing-vs-digital-printing), [The Print Authority](https://theprintauthority.com/printing/offset_vs_digital_printing/))

Authors have reported exactly this on KDP — visible out-of-gamut banding on cover proofs from
gradients that looked clean on screen.
([KDP Community](https://www.kdpcommunity.com/s/question/0D5f4000017PSIuCAO/issue-with-cover?language=en_US))

## Gradient banding

Screens blend discrete tonal steps perceptually; print must reproduce each step as a physical
halftone dot pattern, and the eye is far more sensitive to stepped density in reflected ink —
**especially in shadow tones, which is exactly where a dark scrim lives**.
([Colour banding](https://en.wikipedia.org/wiki/Colour_banding))

**Worst-case conditions — a long dark scrim over cover art can hit three of them at once:**
- **Very dark fading to white/transparent.** The single most-cited failure case.
- **A near-white or near-transparent tail.** Halftone dots below ~2–3% coverage **drop out**
  entirely, giving patchy, uneven fade-out on top of any banding.
  ([Flexopedia](https://flexopedia.net/halftone-and-screening-in-flexo/))
- **Long, subtle ramps.** Keep blends **under ~7.5in**, and prefer a tonal swing of **≥50%** between
  the ends — small subtle swings band worse than big ones.
  ([LinkedIn — gradients for print](https://www.linkedin.com/advice/0/how-can-you-create-best-gradients-print-design-ns7pe))
- **Single-channel K-only ramps band worse than multi-ink CMYK ramps.** An alpha overlay on
  *illustrated* art composites to multi-ink, which helps.
  ([Adobe Community](https://community.adobe.com/questions-712/gradient-banding-in-photoshop-specifically-black-1075709))

**Mitigations, in order of effectiveness:** remove the gradient entirely → add noise/dither before
flattening → shorten the ramp → increase the tonal delta → stop the tail at 3–5% instead of 0 →
never build the ramp as pure K.
([Selfnamed](https://help.selfnamed.com/en/articles/10031908-fixing-gradient-banding-in-print-files),
[Illustrator dither control](https://helpx.adobe.com/illustrator/desktop/paint-and-fill/create-and-edit-gradients/control-dither-in-gradients.html))

## Ink limits — the trap for dark covers

- **Rich black** = K plus CMY underneath, typically C60 M40 Y40 K100 = 240% total. Use it for large
  solid dark panels; use flat K100 for text and fine detail, where registration matters more.
  ([Gentlever](https://gentlever.com/rich-black-vs-flat-black-in-packaging-printing/))
- **TAC ceilings:** ~320% general max; 300–340% coated offset; **240–260% uncoated**.
  ([Panda](https://pandagm.com/docs/total-area-coverage-tac-should-be-320-or-lower/))
- **[Practitioner] IngramSpark rejects covers whose solid areas exceed ~300%**, citing streaking,
  spotting and cracking. Their own recommended rich black is C60/M40/Y40/K100. **Work to 240%.**
  ([Humble Quill](https://humblequill.com/2019/03/14/fixing-ingramsparks-ink-coverage-error/))
- ⚠ **The composite trap.** Where a dark overlay sits on top of already-dark illustrated art, the
  *local composite* ink can approach or exceed the ceiling even though neither layer alone would.
  "Large, flat dark areas are problematic; gradual color changes are more forgiving." Check total ink
  at the darkest overlap, per edition — one language edition clearing does not clear the rest.
- **Exceeding it:** streaking, spotting, cracking, muddy grey-looking "black", slow drying that
  smears onto the facing surface.

## RGB → CMYK

- **[Official] eBook/Kindle covers must be RGB (sRGB).** Kindle does not support CMYK.
  ([KDP cover image guidelines](https://kdp.amazon.com/en_US/help/topic/G6GTK3T3NUHKLEFX))
- **[Official] Print covers: CMYK, and do NOT embed colour profiles** — "color profiles can produce
  unexpected results". Do not mix colour spaces in one file. Convert spot colours to CMYK.
  ([KDP — create a paperback cover](https://kdp.amazon.com/en_US/help/topic/G201953020))
- **Deep blues, purples and saturated reds desaturate** in conversion; KDP's own converter is called
  out as imperfect "particularly for highly saturated colours, deep blues, and certain reds".
  **Convert yourself; do not let the platform decide.**
- **Keep dark colours at ≥ RGB 15–20 in some channel** or they collapse into indistinguishable pure
  black. ([ebookpbook](https://www.ebookpbook.com/2026/04/30/rgb-vs-cmyk-book-covers/))
- **Dot gain darkens mid-tones** beyond the on-screen preview — again, the tonal band a scrim lives in.

## Transparency flattening — a distinct risk from banding

Complex transparency "can sometimes get lost or misinterpreted" by the printer's RIP, producing
unexpected white/coloured boxes, colour shifts at transparent edges, or jagged edges. Flattening
semi-transparent dark overlays over complex raster art is named as a known trouble spot. **Set the
transparency blend space to CMYK before designing**, flatten late at ≥300ppi.
⚠ A multi-edition batch flattens across **one PDF per edition**, each an independent RIP pass — an
artifact reproduces per edition, not once.
([Mainland Printing](https://www.mainlandprinting.com/fix-book-printing-transparency-errors-setup-flatten-guide/))

## Physical artefacts on dark POD covers

- **Matte hides fingerprints and scuffs far better than gloss on dark ink** — gloss shows every
  mark. Dark covers normally go matte.
- **But matte over very heavy ink can show adhesion marks along the spine fold**, and matte/soft-touch
  are "the most prone to visible surface marking" — scuffs read as lighter patches, maximally
  visible against a large uniform dark field.
- **Do not maximise ink density right at the spine crease.**
([ebookpbook — matte vs glossy](https://www.ebookpbook.com/2026/06/07/matte-vs-glossy-cover-finish/),
[Bookmobile](https://www.bookmobile.com/book-production/cover-lamination-beautiful-bad/))

## Platform specs

| | KDP **[Official]** | IngramSpark **[Official]** |
|---|---|---|
| Bleed | 0.125in top/bottom/outside | 0.125in all four; **0.625in** for case-laminate hardcover |
| Text safe margin | ≥0.125in inside trim; spine text ≥0.0625in from edge | ≥0.25in from trim; spine text ≥0.0625in (≥0.35in spines) |
| Barcode | 2×1.2in, lower-right of back cover, **solid white background**, 100% K bars only, ≥0.25in from spine/trim | 1.75×1in clear area, **100% K on white** |
| DPI | 300 | 300 |
| Colour | CMYK, no embedded profile | CMYK required |

([KDP paperback cover](https://kdp.amazon.com/en_US/help/topic/G201953020),
[KDP barcodes](https://kdp.amazon.com/en_US/help/topic/G5HDYGP4BXLX4RUW),
[IngramSpark file requirements](https://www.ingramspark.com/blog/file-requirements-for-print-books))

⚠ **The barcode zone must be genuinely white, not merely light.** A semi-transparent dark tint
drifting under the auto-placed barcode is a common rejection and scan-failure cause on both
platforms. Any full-width overlay must carve it out.

## Verdict for a dark cover with a text scrim, safest first

1. **Hard-edged solid panel** — removes the banding vector entirely. Residual risk is a one-time
   ink-coverage check at the panel/art boundary rather than a per-pixel gradient risk repeated
   across every edition's file.
2. **Short, noise-dithered ramp that stops at 3–5%, not 0%** — acceptable if the soft look is a hard
   requirement. Cap at ~0.75–1in, not 3in.
3. **Long undithered ramp to full transparency** — the riskiest. Hits three named worst-case
   conditions simultaneously.

**Non-negotiables regardless of which look wins:** convert to CMYK yourself; keep composite ink
≤240% at the darkest overlap, checked per edition; keep the barcode zone white; specify matte
lamination; **order one physical proof before green-lighting the whole batch.**
