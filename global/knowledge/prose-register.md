<!-- consumed-by: global/CLAUDE.md (conditional loading), global/knowledge/deliverable-authoring.md (sweep before drafts reach the reader) -->
# Prose Register — the overused AI-tell class in human-facing prose, and the sweep that catches it

**Canonical home for this rule class.** Load this file whenever writing or revising any human-facing text
longer than a few lines (papers, books, reports, posts, mails, briefs). It exists as a loaded file rather than
a remembered lesson because a recalled rule failed repeatedly: nothing triggered the memory while prose was
being written, so the same tells came back draft after draft.

## The drafting workflow — the sweep is a step, not a reminder

The sweep kept losing to the main task. It is step 4, and no draft reaches the reader before it runs.

0. **Load this file for any prose sent to a named human, including replies to existing correspondents,
   and cut every sentence that explains your reasoning rather than asking the question.**
   *(Observed: a reply to an academic correspondent ran roughly three times its needed length and staged
   its reasoning at him — two readings of a result set out in full before the question that mattered. The
   author cut most of it. Both mechanisms that should have caught it scoped themselves to "outreach prose"
   and "pitch emails", and a reply to a live correspondent reads as neither, so neither fired.
   Correspondence is the case where the ask is short and the temptation to narrate is highest.)*

1. Draft the substance. Fold each scope into the claim it bounds, and end sections on something other than the
   thesis (see *Structural slop*).
2. Verify every citation entering the draft (title, authors, venue, volume, DOI) — and every citation
   already in the passage you touched. If the project keeps hand-maintained sources alongside generated
   ones (e.g. a `.tex` next to a `.md`), mirror the edit into every source the build actually reads; an edit
   that lands only in a file the build copies rather than generates never reaches the output.
3. Run the project's own gate scripts, if it has any (register checker, structural-slop gate, draft linter).
4. **Run the register sweep below over everything newly written.** Both halves: the phrase list AND the
   register hunt. The phrase list alone is not sufficient. Then measure the four gated ceilings in
   *Structural slop* (per profile) over the whole document and report the numbers with the draft.
4a. **Every red-team, review or refiner pass carries the rhythm budget in its brief**, verbatim, and its
   fixes are re-measured against the four ceilings before they land.
5. Build, check overflow, then do one plain reading pass — start to finish, as the reader will meet it —
   before showing it to anyone.
6. **Before any public release or archival deposit, the WHOLE document body passes the sweep, not only the
   newly written parts.** Steps 1–5 sweep only what was newly written; a new version once reached the author
   carrying *"That framing should be rejected, and this paper rejects it"*, text from the previous version
   that no sweep had ever covered. The whole-body pass adds the class a phrase checker cannot see: the paper
   or section announcing its own stance, intent or honesty. Plain signposting ("This section develops…")
   passes.

## Watched register — overused in any human-facing prose

**Density, not bans.** No entry below is forbidden on a single use; each is a problem when it accumulates or
stands in for the reason it should state. A gate counts them per 1,000 words and fails on accumulation. The
one hard ban is a version number in a live surface.

**Every entry names a construction, not a sentence.** Match any grammatical form of it — verb, noun,
participle, tense-shifted, negated. A quotation under an entry illustrates the entry; the entry is the rule.

- **Lecturing the reader on scientific method or epistemology.** Any sentence whose subject is how science,
  credibility or belief works. "over-claiming is how a theory loses credibility"; "a simulation study is how
  that specification earns or loses credibility"; a section titled "what an X can and cannot show"; "the
  price of a program that hopes to be believed".
- **Throat-clearing.** Any *worth …-ing* frame (stating, noting, recording, emphasising, stressing,
  mentioning, saying); "the key point is"; sentence-initial "Importantly," or "Crucially,".
- **Empty superlative dressed as insight.** *The <superlative> <abstract noun>* standing in for the reason
  itself: "the deepest lesson", "the deepest one", "the durable one", "the real point".
- **Empty-praise predicate.** Copula plus evaluative noun carrying no claim: "is a gift", "is a genuine
  gift".
- **"Load-bearing", in any form, as a habit.** Also "does the load-bearing work", "carries the load". Say what the
  thing does, and what fails without it.
- **"Bite" (and "buys"), for conflict, constraint or gain — watch the density (gated as pet words, see *Structural slop*).** "does it bite", "does it bite against", "where the
  constraint bites", "the bit that bites". Name the conflict: what contradicts what, and under which
  condition.
- **Cadence tics.** Canned aphorisms dressed as insight; not-X-but-Y chains for rhythm; rule-of-three
  triads; empty value-words ("does real work", "carries the program"); pre-answering a
  hypothetical critic inline. Em-dash density belongs here too: an em-dash in most paragraphs is rhythm,
  not punctuation. So do short punchy fragments standing as their own sentences for effect.
- **Self-narration of the document's own moves.** Any sentence whose subject is the document, the section,
  the reader's route through it, or the act of reading. "We give only…"; "Read together,"; "One boundary
  holds throughout:"; "A reader who finds the repo should meet our reading first".
- **Narrating the paper's own rhetorical strategy, or addressing peer review from inside the manuscript.**
  "lead with a consequence"; "the bulk of the paper is spent earning it"; "tested to destruction";
  "kept brief so a demoted consequence does not become an attack surface"; "reviewers will slot the theory
  into a camp"; "we own the inheritance"; "honesty requires marking it". **A manuscript states its claims;
  it never stages its own moves, advertises its own honesty, or names reviewers, camps or attack-surfaces.**
- **Narrating the document's own revision history.** "An earlier version of this section…"; "That anchor is
  withdrawn"; "the quantitative skeleton that previously accompanied this connection must be demoted".
  Nothing needs withdrawing from a preprint or a draft — delete the old claim and state the current position.
  This applies to pre-existing text too: if a passage you are editing narrates a past revision, remove it
  while you are there.

## Length and posture — the failure the phrase list cannot see

The phrase list measures words. This section measures how much was written and what the writing is doing.
An author on a rejected draft: it read *"like a student trying to prove to the teacher how smart he is"*,
with the instruction *"if he claims necessity but doesn't explain it, just ask him why."*

- **State the observation and ask the plain question.** Where a source claims necessity, importance or
  inevitability and does not explain it, say what you observed and ask why. Building the explanation the
  other side owes is the error.
- **Ground every assertion in the same paragraph.** "necessary", "central", "fundamental", "must" each need
  their reason on the spot. Supply the reason or delete the word.
- **Length is not evidence of effort.** A passage that survives because it demonstrates range gets cut.
  Hold the strongest unused point back for a later section, a second message, or nothing.
- **Cut what performs competence.** Signals: a second example making the first example's point; a
  qualification nobody asked for; a display of reading; a sentence whose work is to show that the writer
  could have written it.

Applies to papers, book prose, reports and outreach alike. The outreach form of the rule: *cold outreach
states the observation and asks the plain question.*

## Structural slop — fencing, verdicts, thesis endings, stamps

A reader on a 61.8k-word AI-drafted book: *"after about 100 pages hard not to register as ai slop … less
single idioms, more a structural thing over multiple sentences or short chapters."* The phrase list and the
sliding window both passed it, because the pattern runs at the same density on every page and each sentence
is clean on its own. Four constructions, measured on that book:

- **Fencing.** Claim → what it does not show → the smaller remainder, at sentence, paragraph and section
  scale. The book: **42 % of 2,597 sentences carry a negation** — but so do Hume (43 %), Mill (47 %) and
  Russell (40 %), because argument negates; the separator is the **denial opener** (1.66 per 1k words vs
  human max 0.61). Fold the scope into the claim — "under these two assumptions, X" — and state the claim
  positively wherever no real misreading needs blocking.
- **Verdict template.** Suspicion stated → where it overreaches → parts sorted into stands and falls, in a
  judge's voice ("It is true, and it is empty." "The third part stands."). The book: **67 sentences open
  "The first / second / third"**, 1.1 per 1,000 words. Keep an ordinal only where the count does work; use
  the template in at most one chapter per Part.
- **Thesis cadence.** Section-final sentences restate the title thesis in new words, until the endings become
  interchangeable. End at least half the sections on an example, a question, a concrete handover or a plain fact.
- **Coinage stamps.** A coined term re-applied as a label in place of its meaning; "Chapter N" callbacks that
  only point. The book: **121 callbacks, 2.0 per 1,000 words**; debt/price/owes/pays 59 hits. When a coinage
  returns after more than a chapter, re-explain it in a clause. Cut every callback that only points.

Two more moves, measured on the next revision of the same book after the reader's review (*"I have read this
exact sentence 1000 times"*):

- **Contrast verdict.** Two things named, declared different, one ruled open or settled: "Those are different acts, and only the second is open"; "… is a separate question"; "… is another matter". Revision: **0.39 per 1,000 words** (23 sentences); human books 0.00–0.07.
- **Undecidability tag.** A clause announcing that nothing settles the choice: "and nothing says which is the right one"; "nothing in the rule says which…". Revision: **0.10 per 1,000**; human books 0.00.

**A de-patterning pass cuts; it does not respell.** That revision's pass moved the denial openers into contrast verdicts (contrast rate 0.25 → 0.39) while the denial gate read clean. Keep a distinction only where the argument turns on it; otherwise delete the sentence.

**Density, never bans.** A pet word (buys, bites) or a construction is a problem when it accumulates, not when it occurs once; the gate counts it per 1,000 words and fails only on accumulation. The one hard exception is version numbers in a live surface.

**Absolute ceilings, applied to the whole document whatever its own baseline.** The sliding window measures
density against the document itself, so a text saturated throughout sets its own threshold and passes.
Calibrated on AI drafts against public-domain human exposition (Russell, Hume ×2, Mill, Darwin, Einstein) and
7 human arXiv papers. Per 1,000 words, gated from 1,500 words:

| Measure | book | paper | essay | Human reference |
|---|---|---|---|---|
| denial openers ("It/This/That … is/does not…", "Nothing…", "None…", "It/They cannot…", "No observer…", "And no…", "There is no…") | 1.6 | 1.2 | 1.6 | widened pattern: human books max 1.46 (Mill), papers max 1.01; the AI-drafted book 2.59 before de-patterning, 0.86 after |
| ordinal openers ("The first/second/third…") | 1.0 | 1.0 | 1.0 | Hume *Treatise* 0.62, review paper 0.72 |
| Chapter/Section/§ callbacks | 2.0 | 2.5 | 1.0 | Einstein popular 1.76, human papers ≤ 1.74 |
| scope fences ("only that", "says nothing", "does not show/establish/follow", "as stated", "narrower", "under the stated assumptions", "scope") | 0.6 | 0.8 | 0.6 | — |
| contrast verdicts | 0.15 | 0.20 | 0.15 | human books 0.00–0.07; AI-drafted book 0.39, after a cutting pass 0.07 |
| undecidability tags | 0.05 | 0.08 | 0.05 | human books 0.00; AI-drafted book 0.10, after a cutting pass 0.02 |
| pet words (buys, bought, buying, bites); fails only at ≥ 3 | 0.10 | 0.10 | 0.10 | Mill 0.058, Russell 0.047 — catches accumulation, does not separate AI from human |

**Reported, never gated:** share of negated sentences (argument negates). **Reading check only:** section
endings that restate the thesis — title-vocabulary, negated-generalisation and embedding detectors all scored
Russell like the AI-drafted book. No looser "formal" profile: human formal papers stay low.

Gate: if the project has a structural-slop script, run it with the matching profile (book / paper / essay)
and report the numbers with the draft; otherwise count the measures by hand or with a short regex pass.
Below 1,500 words, check by reading: each claim carries at most one fence, and the ending lands on something
other than the thesis. Known failures at calibration: several long AI-assisted papers failed denial openers
and callbacks; formalization papers ran 6.3–6.9 callbacks per 1,000 words and failed scope fences; a
published AI-assisted book failed denial openers (1.81).

**A regex gate can be written around.** One revision scored 0.00 denial openers because its fences moved to
forms the first pattern did not count ("It cannot…", "No observer…", "There is no…"). A rewrite aimed at the
numbers is not a fix, and a measure dropping to about zero is a reason to read the text.

**Disproved, do not chase:** punchline sentences at paragraph ends (in the AI-drafted book, final sentences
ran longer: median 23 words vs 19).

**Cause:** stacked red-team "don't overclaim" passes, each scoping fix right on its own. Every review brief
therefore carries the rhythm budget below.

### Rhythm budget — paste verbatim into every red-team, review or refiner brief

> **Rhythm budget** (`~/.claude/knowledge/prose-register.md`, *Structural slop*). Fold every scoping fix
> into the claim it scopes ("under assumption A, X"). A fix that adds a sentence saying what the claim does not
> show is the pattern this budget exists to stop. Report, before and after your fixes, the four gated measures
> for the passage you touched, per 1,000 words (paper ceilings: denial openers 1.2, ordinal openers 1.0,
> Chapter/Section/§ callbacks 2.5, scope fences 0.8). A fix that pushes any measure past its ceiling needs
> rewording. If the claim itself is too wide, tell the orchestrator and propose the narrower claim. Keep every
> bound the argument needs, stated once, inside the claim.

## The measurable half — sliding window, never per document

The cadence tic is countable, and counting it is what exposed one failure: **8.3 per 1,000 words of new prose
against 2.3 in the surrounding paper — 3.6×**. A rate far above the document's own baseline means the
construction is doing rhythm.

**The density sweep runs on a sliding window. There is no per-document mode and no per-chapter mode.**
Averaging over a whole chapter hides the clustering a reader feels. One book chapter scored 3.39 per 1,000
words against a 2.23 book baseline — passing at chapter level — while a single passage in it stacked three
negation-pairs inside 25 lines.

Settled parameters for any implementation: **window 400 words, step 100, factor 4.0.** The window is roughly
one long paragraph, the unit a reader feels; the step stays below the window so a cluster cannot fall between
two windows. Factor 4.0 was set by measurement — at 1.8 a full book manuscript reported 48 windows, most of
them two constructions in 400 words, and a gate that always fires gets ignored.

**Excerpts anchor on the cluster.** An excerpt taken from the window boundary shows calm prose and points
the author at the wrong sentence; centre it on the first construction inside the window.

### ⚠ The gate cannot fire on a document whose baseline is already saturated — measure the NEW prose against the document's PRIOR baseline

The factor is **relative to the file being checked**. So a document that is *already* heavy in the
construction raises its own threshold, and prose that would fail inside a clean paper passes inside a
dirty one. **A green gate on the whole file is not clearance for a new draft.**

Measured on a paper rewrite: the windowed checker reported **`0 register hits, 0 dense windows`** on the
whole paper — while the ~7,000 words written that session ran at **6.85 antithesis constructions per 1,000
against the paper's own pre-rewrite baseline of 5.20**, with **`rather than` alone appearing 35 times.** The
gate was working exactly as specified and still said green, because 6.85 is nowhere near 4.0 × 5.20.

**⇒ The check to actually run, and it is two lines:** diff the new prose out of the file, count the
constructions in the *added lines only*, and compare that rate against the same count over the file at the
last commit before the work started. If the new prose is denser than the prose it is joining, it is doing
rhythm — regardless of what the windowed gate says. The whole-file gate stays useful for catching clusters
inside otherwise-clean text; it cannot certify a new draft. Both comparisons are relative: a document
saturated from its first draft passes both, and the absolute ceilings in *Structural slop* catch that case.

**Provenance, and it is the point of the entry:** the author caught two sentences by eye in a draft whose
writer had this file loaded, had run the phrase list, and had reported the gate as passing —
*"Section 3 continues that critique rather than opening a new one"* and *"This contrast is widely cited and
it is easy to state badly, so it is stated carefully here."* Both are self-narration of the document's own
moves; the second also advertises the paper's own care, which the offender list bans by name. **The phrase
list and the windowed gate both passed them.** Neither instrument sees a sentence whose subject is the
document — only reading does.

For short drafts (posts, mails), a grep-able checker covering the phrase list, em-dash density and
copy-block character counts is enough; the windowed gate needs at least a few windows of text to mean
anything.

Cut the constructions carrying no real opposition; **keep** the ones the argument runs on (constitutive vs
correlate, artifact vs structural fact, prediction vs finding). Scrubbing to zero costs precision.

## What a human editor cuts from agent-drafted replies — reference pairs

What gets cut from agent-drafted replies: restatements of the recipient's position, unrequested offers,
supporting examples, and lines that position the sender. What gets added: the plain practical question.

| Situation | Draft | Sent |
|---|---|---|
| Friendly logistics reply | thanks + offer of a one-page comparison list nobody asked for | "Thank you, I look forward to Thursday!" |
| Recipient clarified their view | "that makes the disagreement clear: you take X as given and challenge the mechanism, and on your view…" | "Thank you, I understand better now." |
| Cold pitch | "takes the opposite side"; a supporting example; "Since we disagree, I'd rather ask than assume." | "takes a different view"; example and opener cut |
| Order to a supplier | specs + price question | added the plain deadline question: can it still be done in time? |
| Enquiry after a conference | "It was good to talk with you both at the conference." | "Just back from the conference." — pleasantry replaced by a plain fact |
| Update after informal feedback | "I have revised … after a referee pass" | "after some first feedback" — no claim of a formal review that did not take place |

## What is NOT a tell — do not strip these

Genuine scientific caution is content: "consistent with", pre-conceding a shared result, stating a
disconfirmation criterion, bounding a result once and flatly. Keep it, and state each bound once, inside the
claim it bounds: "under A, X" carries the same caution as "X. This does not show Y." with half the
sentences. A bound repeated at paragraph and section scale is fencing (*Structural slop*).

## Claim fidelity, same pass

Any claim a reviewer or refiner *strengthens* to clear a blocker must be checked against the author's actual
claims before it lands. An over-corrected "unfalsifiable" blocker once introduced a false "X iff Y"
over-claim where the author had only claimed a signature, not a requirement.

## Why the rule class looks like this

A draft once survived a self-described "de-AI pass" and still read as explaining to the reader how science
works "in the style of a tiktok post", with "many ai tells / aidioms" — the register is a blind spot from
inside. Later failures added the strategy-narration class, the revision-history class and the density
measurement.

A voice pass over one book chapter ran against a tell list invented by reading the chapter, never opened this
file, and let `load-bearing` — listed here by name — survive into a tighter sentence. Separately, `bite` was
reproduced in a grammatical form the file did not carry, because the file stored it as a quotation. Hence the
rule at the head of the offender list: entries name constructions.

**The same two classes again, in a draft written with this file loaded.** The author, verbatim: *"'not a
defect in this architecture but a prediction of it,' as well as 'and is marked as one' - seriously?"*
The first is the **cadence tic** (not-X-but-Y for rhythm) and had been defended in-session as a *genuine*
opposition; it was not, because a thing can be both a defect and a prediction, so the pair carried no work.
The second is **self-narration of the document's own moves**, compounded by advertising the text's own honesty.
⇒ **Two things this instance adds.** (1) *"Is it a real opposition?"* is the wrong test to apply to oneself —
the reliable one is **"does the sentence still say the same thing with the pairing removed?"** If it does, the
pairing was rhythm. (2) The self-narration class fires hardest on **status and hedging sentences** — the place
a writer reaches to concede a limitation — because conceding honestly and *announcing* that one is conceding
feel identical from inside. State the limitation; never state that you are stating it. Both were caught by
the reader on sight, in a session that had the file loaded, which is the pattern the entry above already names.
