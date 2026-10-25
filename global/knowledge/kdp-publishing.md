# Amazon KDP publishing — specs, arithmetic and traps

**Trigger:** load before building, uploading or correcting any Amazon KDP paperback, hardcover or Kindle eBook: cover wraps, spine maths, barcodes, ISBNs, listing metadata, language support, rejections.

Measured facts from titles that shipped on KDP in several languages and formats, paperback and hardcover. **Out of scope:** what the press does to ink (bleed, ink limits, gradients, CMYK, scrims, lamination, proofing). That lives in `print-production.md`. Cover look and legibility live in `cover-design.md`.

**Authority order when sources disagree:** a working builder whose output KDP accepted > KDP rejection feedback > the KDP calculator > a template PDF > a web search. Never re-derive a shipped geometry from a web search.

## Trim, paper and spine

- Reference trim: **6″ × 9″**. Print is B&W interior, on white or cream stock.
- **Spine thickness per page depends on the paper stock. Two measured values:**
  - **White paper: `pages × 0.002252″`.** Examples: 251 pp → 0.565″, 208 pp → 0.468″.
  - **Cream paper: `0.0025″/page`.**
  - Neither figure is wrong. Pick the one for the stock the listing actually uses.
- **Every interior change moves the spine.** Adding images, fixing typesetting or swapping the interior file changes the page count, so the wrap width changes with it. A re-upload needs the **recut cover as well as the new interior**, or KDP rejects the mismatch. Rendering ten previously missing images added 4 pages per edition and moved each wrap by 3 px.
- Keep the page count **in one place** that the cover builder reads. A hardcoded `PAGES` constant and pinned test widths both have to follow the interiors.
- One interior file can serve both paperback and hardcover. Paperback interior = hardcover interior is a valid setup.
- **Interior margins used in practice:** inner 0.875″, outer/top/bottom 0.75″. At 208 pp the KDP minimum is 0.5″ inner / 0.25″ outer, so these margins are generous, not minimal.
- **KDP minimums:** images 300 DPI, line weight 0.75 pt.

## Paperback wrap geometry

- Layout L→R: `[bleed][back][spine][front][bleed]`, with bleed 0.125″ on each edge.
- **Width = 2 × 0.125 + 2 × trim_w + spine. Height = trim_h + 2 × 0.125.**
  - 6×9 at 208 pp white: **12.718″ × 9.250″** (measured).
- **Pixel form at 300 DPI, 6×9 cream:** width px = **`3675 + pages × 0.75`**, exactly. Height is a constant **2775 px**.
- ⛔ **Compute in exact arithmetic (`Fraction` or integers), never float.** `(0.125 + 6 + 0.37 + 6 + 0.125) * 300` evaluates to `3785.999…` in binary float, so `int()` truncation gives 3785 and the wrap ships **one pixel short**. KDP then rejects it or silently rescales it. Four of eight recorded widths were wrong for exactly this reason.
- **Round half UP.** One pixel over is absorbed by the bleed. One pixel under is a rejection.
- The three panels must reassemble to the full wrap exactly. When `wrap − spine` is odd, give the extra pixel to the **front** panel. Dropping it puts the spine off the fold.

## Hardcover (case laminate) wrap geometry

- Constants: turn-in wrap **0.591″** per edge; joint (hinge) **0.197″** per side; board overhang **0.094″** left/right and **0.1175″** top/bottom; text safety **0.635″**.
- Layout L→R: `[wrap][board = trim_w + overhang_w][joint][spine][joint][board][wrap]`.
- **Width = 2×0.591 + 2×(trim_w + 0.094) + 2×0.197 + spine.**
- **Height = 2×0.591 + trim_h + 2×0.1175 = 10.417″** for a 9″ trim.
  - Measured: 14.329″ × 10.417″ at spine 0.565″, which KDP rejection feedback confirmed. 14.232″ × 10.417″ at spine 0.468″.
  - These constants were reverse-engineered from KDP calculator output, then confirmed against rejections and against wraps that went live.
- ⚠ **A wrong formula that circulates:** `width = 2×trim_w + spine + 0.394 + 2×0.591`, `height = trim_h + 0.2` (9.2″). It misses by a consistent **+0.188″ wide and +1.217″ tall**. A verification pass built on it reported seven false failures against covers that were correct. The builder was right and the doc was stale.
- **The case wrap is taller than the paperback front panel** (10.417″ vs 9.25″). A paperback front cannot be reused as-is. Recompose the hardcover front from the text-free artwork, using the same lettering positions.
- **Adding a hardcover to an existing title:** Bookshelf → the paperback → **"+ Create hardcover"**. It gets a **new** free ISBN, which then has to go into the copyright page and the barcode, followed by a rebuild.

## Barcode zone

- **Spec:** EAN-13, **2″ × 1.2″**, 300 DPI, **≥ 0.25″ from the hinge/spine fold**. One logged defect had the box at 0.200″ and had to be moved.
- **Distance from the bottom: two values exist. Keep both and know which applies:**
  - **≥ 0.76″ from the bottom** is the hardcover figure (`margin_y + 0.76`).
  - The paperback path uses the lower **bleed + 0.5″**, i.e. 0.5″ up from the trim bottom.
  - When a single conservative paperback rule is needed: 0.5″ up from the trim bottom, 0.25″ in from the spine fold.
- **Position: bottom-RIGHT of the back panel, next to the spine.** This is not a mirror error. On a flat wrap the back panel reads normally with the spine to its right.
- ⚠ **Do NOT reserve an empty white box and wait for Amazon to fill it.** Amazon's auto-placed barcode did not land in the reserved box, which left a white rectangle in one place and the barcode in another. The fix that shipped was to **bake a real EAN-13, in its own white box, into the cover**, which requires knowing the ISBN first.
  - Until the ISBN exists (free KDP ISBNs only exist once the listing does), leave the artwork intact and keep copy out of the zone. The bake becomes part of the ISBN round-trip: ISBN → copyright page → barcode → rebuild interior and cover.
  - `print-production.md` records KDP's official requirement that the barcode sit on solid white with 100 % K bars. A baked box satisfies that. A dark tint under an auto-placed barcode does not.
- **Gate the baked barcode on the rendered cover:** decode it at 300 DPI (e.g. zxing-cpp) and assert that it reads as **exactly** this format's ISBN and sits inside its white box. The first bake overflowed its box. Reading the code is not verification.
- **Each print format has its own ISBN and barcode.** A hardcover wrap that reused the paperback back panel shipped the **paperback** barcode. Choose the back panel per format.

## ISBNs (concept)

- **KDP assigns free ISBNs at listing creation**, one per print format: paperback and hardcover each get one, and the eBook needs none on KDP. Free KDP ISBNs are 979-8 prefixed.
- Free assignment means **no number exists before the listing does.** Plan the interior and cover rebuild after creation.
- **Non-KDP channels (e.g. PublishDrive, IngramSpark) may assign no ISBN.** The author then supplies and buys them. Count them before buying.
  - Open question, not verified: whether PublishDrive requires an ISBN for an **eBook**.
- Store each ISBN in one place, the build's record of truth, and generate the copyright page and the barcode from it.

## Language support is uneven, per FORMAT

Measured from a live KDP dashboard, Aug 2026. Re-check, because KDP's lists change.
- **No Greek and no Korean on KDP in any format**, neither print nor eBook. These go to a distributor (e.g. PublishDrive/Ingram) end to end.
  - "The eBook list is longer than the print list, so the eBook might work" was a reasonable guess. It was **wrong** for these two languages.
- **No Japanese hardcover.** Japanese ships as paperback + Kindle only.
- **No Simplified Chinese eBook.** KDP offers only **Chinese (Traditional) (experimental, beta)**, which requires a **.docx** upload (not EPUB) and **horizontal text only**.
  - Uploading Simplified content under the Traditional tag worked in practice.
  - Chinese **print** is not on KDP. Use a distributor.
- **Never assume a language is a KDP print language because its eBook shipped there.** Check KDP before routing anything elsewhere. KDP is free for ISBNs and has the widest reach, so distributors are the fallback.

## Japanese listing fields

- KDP asks Japanese listings for: title and subtitle **katakana pronunciation**, **romanized** title and subtitle, and **author-name katakana**.
- Rules KDP enforces:
  - Pronunciation fields take **katakana only**: no `、` commas and no 「」 brackets.
  - Romanized fields are **ASCII only**: macrons (ē/ū/ā) are rejected, so write `Akitekucha`, not `Ākitekuchā`.
- ⚠ **These fields live only on Amazon's servers.** No manuscript or builder carries them, so a subtitle sweep across the book cannot reach them, and no test goes red when they drift. Record the submitted values in the project's own notes.
- Pronunciations derived without a native speaker should be marked as derived.

## Metadata, categories, keywords

- **Editing the title or subtitle on a live listing can send it back through review**, and authors report losing accumulated reviews that way. A deliberate divergence (new subtitle in the interior and cover, old subtitle in live metadata) is a legitimate choice, not a defect. Do not build a gate that forces them to match unless the author wants that.
- **BISAC category paths reconstructed from memory are unreliable.** Read them off the live KDP picker at upload.
- **Contributor fields are metadata, not the printed page.** KDP does **not** require an on-page translator credit. Tests that asserted it did were wrong.
  - KDP separately asks whether a translation is AI-generated. Any printed claim, such as "translated by…", must stay consistent with that form answer. With no printed claim, the form answer stands alone.
- **The copyright page is buyer-visible via Look Inside.** Treat it as public listing copy.
- Amazon's detail-page **"Print length" can lag up to 72 h** after publication. The page count also identifies **which interior version** is live, provided each upload wave had a distinct count.
- Right after publication, amazon.de refused dispatch to Austria for both print formats. This is likely a propagation delay. Link the marketplace that works.

## Pricing, Select, DRM

- **KDP Select forbids the same eBook being available free elsewhere**, for example a free PDF on a repository. If a free edition exists, publish the Kindle eBook **outside Select**. Amazon may then price-match it down.
- List prices are set per marketplace in KDP. Record the intended live prices in the project once confirmed, because they are the ruling, not earlier drafts.
- ⚠ **Unverified:** whether the DRM setting is fixed at publication. Some notes say it is reversible at any time, and that conflicts with other understanding. Not checked against live terms. Off is the safer default.

## Manuscript rejections and build traps

- **"Remove all template text and guides… see PDF page N"** usually means **markup residue** (literal `![alt](path)` image tags printed on the page), not template text.
  - **Amazon names ONE example page.** One rejection citing a single page hid ten tags across six pages, in two languages, plus EPUBs with zero embedded images. Sweep every edition before trusting the scope of the letter.
- **weasyprint prints `Failed to load image` on stderr and exits 0.** It produces a PDF with a blank where the image belongs. Treat that string as fatal in the build.
- **weasyprint `--base-url` must be the root that image paths are relative to.** Otherwise they resolve against the HTML file's build directory and every one misses.
- **Residue tests must sweep for families, not single constructs.** Per-construct tests (literal asterisk, lost backslash…) left image tags unguarded, and 86 tests passed while ten tags shipped. Sweep the rendered output for `![`, `](`, `{width=`, `{height=` and extend that sweep.
- **Gate superscripts/exponents in the RENDERED output of every format.** Markup presence is not evidence.
  - pandoc's default `epub.css` resets `sup`/`sub` to baseline/100 %, so `2^300` rendered as "2300" on Kindle while the XHTML said `<sup>300</sup>`.
  - `pandoc --css` **replaces** the default stylesheet. Append to `pandoc --print-default-data-file epub.css` rather than passing bare rules.
  - Unclosed caret markup prints a literal `^`.
- **Kindle clips a long table to one screen** (seen in the KDP online previewer with a 206-row table). Split EPUB tables into short chunks of about 12 rows. A header repeated per chunk can land mid-page.

## Delivering a test build to a Kindle

- **Send-to-Kindle by email** (Amazon converts). EPUB sideload over USB did **not** work on a new-generation Paperwhite.
- **Two Kindle addresses on the same account do not cross-deliver.** Mail to an old device's address is accepted with **no bounce** and never reaches the new device. Confirm the address belongs to the target device.
- Gmail's 25 MB cap applies to the encoded message, so the raw attachment limit is about **19 MB** per mail.

## Inbound "author marketing" solicitations

- Paid "Author Spotlight", book-club and book-marketing pitches target live KDP listings. **Treat them as scams until proven otherwise.**
- **Decisive tell:** the sender name and the signature do not match (a template farm).
- Supporting signs:
  - flattery that quotes the Amazon blurb back
  - unverifiable reader numbers
  - a free-mail address
  - **no price until after you say yes**
- Never send manuscripts, KDP credentials, ID copies or bank details. Classify, report to the author, do not reply.

## Pre-upload checklist

1. Page count final, and the wrap rebuilt from that count with exact arithmetic.
2. Correct paper-stock spine factor and the correct format geometry (paperback vs case laminate).
3. Barcode baked per format, decodes as that format's ISBN, sits inside its white box, in the zone.
4. Rendered-output sweeps clean: markup residue, missing images, flattened exponents, clipped tables.
5. Language/format combination supported by KDP. Otherwise route to a distributor and count the ISBNs.
6. Copyright page consistent with the KDP form answers (translation/AI disclosure, contributors).
7. Physical proof per `print-production.md` before green-lighting a batch.
