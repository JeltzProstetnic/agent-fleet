<!-- updates: none -->
<!-- consumed-by: global/knowledge/deliverable-authoring.md (deck format rule), global/knowledge/office-templates.md (deck build path) -->
# Presentation Design — a slide is a backdrop for a speaker

Load when: building or restructuring any slide deck / `.pptx`, or reviewing one.

## The one principle

A deck is an **aesthetic, information-anchoring background for a convincing speaker** — not a document, and not the speaker's notes. The audience listens to the person; the slide gives the eye an anchor.

**If a slide can be read instead of heard, it has failed.**

## Hard rules

- **≤ 7 words on a slide.** More than seven words is a sin. Headline + visual, never paragraphs and bullet stacks.
- **Big type.** Titles large; any word on screen readable from the back row. Never small.
- **Air.** Generous whitespace; one idea per slide. Never small-and-cramped.
- **Visual, not textual.** Each slide earns its place with an image, diagram, chart, mockup, or a single bold number or phrase.
- **The speaker carries the content.** Detail lives in the talk and in the companion document — never on the slide.

## In practice

- Convert each text slide into **one headline (≤ 7 words) + one visual**. Push the detail into the written handout.
- **Speaker notes for a speaker who presents freely = reminder keywords only** — 2–5 short bullets per slide carrying the facts and numbers the speaker must not get wrong, never full sentences or a script (user directive 2026-10: *"notes should be reduced to reminder words no sentences, i speak freely always"*). Reference impl shape: a deck builder `<project>/<deck>/build_deck.py` with `parse_keywords` / `verify_kw` helpers.
- Prefer a full-bleed image, mockup or big number over a list.
- Dense evidence — requirement tables, sourced figures — belongs in the handout. On screen, show only the takeaway.
- Section dividers are cheap and make a deck navigable: one big word on a colour field.
- The failure mode to avoid: **a wall of small grey text.**

## Deck ≠ document

Every deck has a companion document, and they are written differently:

| | Deck | Companion document |
|---|---|---|
| Carries | The point | The evidence |
| Read by | Nobody — it is watched | The reader, alone, afterwards |
| Density | ≤ 7 words / slide | Whatever the argument needs |
| Survives the meeting | No | Yes |

If there is no companion document, the deck will grow into one. Write the document first.

## Tooling reality

Hand-assembled slides from a scripting library (python-pptx and friends) top out at **draft quality** — no layout engine, no illustration. That is fine for an internal working deck and not fine for a sponsor pitch. Until a real design pass happens, keep decks minimal, lean on rendered mockups and real visuals, and put the substance in the written deliverable. Build path and the fleet template: [[office-templates]].

## Verifying renders — do NOT flood context with images

Reading rendered PNGs or PDF pages into the agent's own context accumulates and hits a per-conversation image cap. After roughly 10-15 images every later turn throws *"an image in the conversation could not be processed and was removed"*, and it only clears with a fresh context (`/clear` or `/exit`). The delivered files are unaffected.

So, to verify a deck or a rendered document:
1. **Prefer structural checks** — file size, slide/page count, embedded-image count, text extraction.
2. Read at most one or two **downscaled** (< 1 MP) images, sparingly, and only when a structural check cannot answer the question.
3. **Let the user do the visual review** by opening the file.

## Arrowheads — a recurring defect, invisible at slide scale

Wrong-way arrowheads have shipped twice: cairosvg rendered SVG `<marker>` heads reversed (measured in a fleet project, 2026-08), and a matplotlib refresh icon with hand-placed head vertices pointed backwards through two deck versions and passed visual review (event deck, 2026-10). Applies to any diagram or figure, not only decks.

1. **Never hand-place arrowhead vertices and never rely on SVG markers** — compute the head from the tangent at the path end. For a CCW arc at angle *a* the tangent is (−sin *a*, cos *a*): tip ahead along the tangent, base perpendicular to it. Reference impl shape: an `arc_arrow()` helper in the deck builder (`<project>/<deck>/build_deck.py`); SVG polygon version: a `<project>/scripts/<symbol>.py` that emits the head as an explicit `<polygon>`.
2. **Render, then crop and zoom every arrowhead (≥ 4×) before delivery.** Slide-scale review misses the reversal. This is the one case where an image read is required — crop tightly so it stays small.

Related: [[deliverable-authoring]], [[office-templates]].
