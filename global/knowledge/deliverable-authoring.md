<!-- updates: global/knowledge/prose-register.md -->
<!-- consumed-by: global/knowledge/needs-to-requirements.md (document discipline for the chain), global/knowledge/presentation-design.md (companion document rule) -->
# Deliverable Authoring — point-of-action checklist

Load when: writing or restructuring any stakeholder-facing deliverable — needs, requirements, MVP offers, proposals, reports, reviews, decks, board papers. Read it *before* the first draft, not after the first correction round.

## Clarify before building

Before building any multi-artefact deliverable set, clarify **audience, framing, format and design constraints** up front. Treat the first build as **a spec to confirm, not a draft to correct**. Skipping this reliably costs ten to twenty rounds of rework on a set of four documents — the single most expensive avoidable failure in this kind of work.

Four questions, asked before writing:
1. Who reads it, in what language, and what do they decide or do with it?
2. Is it an offer, a report, a request for decision, or a record?
3. What format lands with this audience — document, deck, one-pager, table?
4. What is fixed (template, house style, classification) and what is mine to choose?

## Audience first

- **One audience per document.** Split by reader: engineering (build & maintain), product/PMO (what it does, workflow, transition), management (vision, value, roadmap, money). **Never one catch-all deck.** A four-document set that each reader can finish beats one document nobody does.
- **Write from the reader's side** — what they need to decide or do, not what was produced.
- Where a set exists, ship a routing sheet (`00_Read-me-first`) that says which document to read first for which purpose.

## No process-meta

Deliverables contain the content, never the making of it. Strip:
- "we ingested X", "N requirements were derived", "this document/deck…"
- tool and AI mentions
- change-logs and provenance in the front matter

Provenance belongs in a separate appendix or in the repository, not in the reader's first screen.

## Status fidelity

- **Drafts stay marked draft.** A blockquote at the top, not a footnote.
- **Derived deliverables inherit input status.** Unvalidated inputs make the derived work provisional — say so, in the derived document.
- **Unmade choices stay open, with the deciding owner named** — *"the database platform is IT's call; Postgres assumed, not locked"*. Never harden a "probably" into a decision.
- Marking something draft is not weakness; it is the thing that makes the review request answerable.

## Numbers

- **No number without a cited source.** No effort, currency, headcount or percentage figure without an explicit reference — inline, or in the companion sources file for a rounded figure.
- In the reader's text, round figures that keep changing to a stable lower bound and put the exact value, source and date in a companion sources file.
- Use the project's real data. If a figure the document "wants" is not documented, **say it is not documented and propose how to get it** (a baseline study, an extract, a survey). Do not invent it, and do not borrow an adjacent number that looks similar.
- **Programme-level KPIs are not project ROI.** Presenting one as the other is the most common quiet dishonesty in these documents.
- Anything illustrative is labelled *(illustrative)* at every occurrence, not once in a preamble.

## Format (readability)

- Prefer **a short metadata table + headers + free text**, with a one-line inline metadata note per item, over dense multi-column tables. Category and traceability go inline, in italics, not as extra columns.
- Tables are for enumerations that are genuinely tabular (roles, coverage, dependencies). Prose is for everything with a *because* in it.
- **Lead with the point** — first sentence of each section states the conclusion; the rest supports it.
- Keep decks short and audience-scoped ([[presentation-design]]); the evidence goes in the companion document.

## Framing & direction

- Match the organisation's real ownership and flow. A proposal from a build team is **an offer to** the deciding function, not a mandate.
- Name the governance path when one exists, and flag any shortcut you took as a shortcut — with the reason it was worth taking.
- Where you defer something, defend the deferral in the document. A deferral with a reason is a decision; a deferral without one is a gap.

## Mechanics

- **META block** at the top of the source (status, version, date, accountable owner, scope, basis, classification) as an HTML comment, so it travels with the source but not into the rendered artefact.
- **One accountable owner named**, never a committee, never a RACI grid ([[responsibility-modeling]]).
- Version in the filename (`_v1.5`), circulation date in the folder name.
- Source (`.md`) and built artefact (`.docx`/`.pdf`/`.pptx`) live side by side and are committed together — the built file is the deliverable, the source is the truth. See [[office-templates]] for the build path.
- Work products are committed in the session that produced them. `tmp/` is for throwaway only.
- Run the prose-register sweep, both the gate scripts and a reading pass, before any draft reaches the user.

Related: [[needs-to-requirements]], [[presentation-design]], [[office-templates]], [[user-roles-and-personas]].
