<!-- updates: global/knowledge/vertical-slicing.md, global/knowledge/deliverable-authoring.md -->
<!-- consumed-by: global/knowledge/vertical-slicing.md (slices are cut against need IDs), global/knowledge/user-roles-and-personas.md (needs are addressed to roles) -->
# Needs → Requirements → MVP → Slices

Load when: eliciting or writing user needs, system requirements, an MVP scope, or a build plan for any system — software, process, or organisational. Also load before restructuring an existing requirements set.

The chain is four documents, in this order, each derived from the one before and each written for a **different reader**. It is a communication instrument as much as an engineering one: the same content, cut four ways, so each audience reads only what it can act on.

| # | Document | Written for | Answers |
|---|---|---|---|
| 01 | **User Needs** | Reviewers, sponsors | What the users need — stable IDs, grouped in themes |
| 02 | **System Requirements** | Development, IT, compliance | What the system must do — testable, implementation-neutral, traced |
| 03 | **MVP Offer** | Product owner, product manager, management | What the first release contains, what it depends on, what must be decided |
| 04 | **Build Slices** | Development, PMO | In what order it gets built, what exists, what blocks what |

Ship them as a numbered folder with a **`00_Read-me-first`** routing sheet: the table above, plus *"Read 01 if you are validating the needs. Read 03 if you are deciding whether to fund it."*, plus **the decisions the set asks for** as a numbered list, plus **what it supersedes**. That sheet is what makes a four-document set land instead of intimidate.

## The two hard invariants

1. **Everything derived from a draft is a draft.** If the needs are not signed off, the requirements, the MVP scope and the build sequence are all provisional and must say so in a blockquote at the top of each file. Never harden a "probably" into a decision on the way down the chain.
2. **Every artefact carries a stable ID and a trace.** `UN-nnn` → `SR-xnn` → slice → test. IDs are never renumbered, never reused, and never reordered when the document is restructured — they are the vocabulary people will use in meetings for years.

## 01 — User Needs

**Structure:** front-matter META comment (status, version, date, accountable owner, scope, reviewers, classification) → draft warning → one-paragraph statement of what the system *is* → Chapter 1: who it is for ([[user-roles-and-personas]]) → chapters 2..n: one per **capability theme** → coverage matrix.

**Theme clustering is the instrument.** Group needs into 6-10 themes named after *what the user gets*, not after system modules — *Process Guidance & Orchestration*, *Document Intelligence*, *Knowledge & Onboarding*, *Risk*, *Portfolio & Capacity*. Each theme opens with one italic sentence saying what it is about. The theme list survives into the requirements sections, the MVP offer and the slice plan, so the reader learns the vocabulary once.

**Each need:**

```
### UN-017: Process-Step Automation & Task Tracking
**As a** Project lead, **I want** <capability>, **so that** <outcome>.
- 2-5 acceptance-shaped bullets — observable behaviour, not design.
- **System boundary:** what this need explicitly does NOT own.
- Extends UN-001; consumes UN-002 output.
```

Discipline:
- **Title is a noun phrase**, 2-5 words, and becomes the name everyone uses.
- **One need = one capability.** If the "so that" needs an "and", split it.
- **Relations between needs are stated inline** (`extends`, `consumes`, `shared with`) — this is the cheap version of a dependency graph and it survives editing.
- **Needs are stated at need altitude.** No screens, no tables, no technology. If it names a widget, it is a requirement or a design decision in the wrong document.
- **Needs are added, not renumbered.** A late need gets the next free number and a `— added <date>` marker, even if it belongs conceptually in chapter 2.

## 02 — System Requirements

**Structure:** META → draft warning → a preamble that defines the metadata line → lettered sections `A, B, C…` **mirroring the User Needs themes** → requirements.

**Preamble does three jobs** in about four sentences: states requirements are at system altitude, testable and implementation-neutral; defines the category vocabulary; and states that *because user roles nest, a requirement serving an outer role serves every role inside it* — so nothing has to be restated. Also state where the MVP is scoped (in document 03, not here).

**Each requirement:**

```
### SR-A08: Persisted task store with custom tasks and delegation
The system shall <single testable obligation>.
*Category: M · Serves: PDP user, Project lead · Traces to: UN-017, UN-016, UN-001*
```

- **`shall`**, one obligation per requirement, phrased so a tester can write a pass/fail case.
- **Category: M / D / I** — Must, Desire, Info. Three levels is enough; MoSCoW's four invites debate about "should".
- **Serves** = user roles, by name. **Traces to** = need IDs. Both on one italic line, never as extra table columns.
- **Section letter carries the theme** — `SR-A*` orchestration, `SR-B*` scoping engine, and so on. New theme → new letter, appended (`Section I`, `Section J`), never inserted.
- **Implementation-neutral.** "The system shall persist tasks with a source discriminator" — yes. "…in a Postgres table" — no; that belongs in a design doc or an open IT decision.
- Where a later phase is anticipated, encode the *hook* in the requirement now (a discriminator field, a bounded module contract) so the later phase is **a data-flow addition rather than a refactor**. Say that in the requirement text — it is the cheapest architectural argument you will ever write.

## 03 — MVP Offer

Not a scope document — **an offer that asks for a decision**. Framing matters: an MVP from the build team is *an offer to* product/management, not a top-down mandate. Match the organisation's real ownership flow and name the governance path (*"the PM holds the minimum requirements, the PO negotiates and writes the MVP, the PM validates with sponsors, the PO applies it to the backlog, the team executes"*), then flag any shortcut you took as a shortcut.

Sections that earn their place:
- **The offer** — two sentences. What a named role gets, end to end.
- **What the first release does** — one bold sentence per capability + one short paragraph. Written as user outcomes, in the theme vocabulary.
- **Who it serves** — roles served, roles served last, **and why last**. Turn the deferral into a defended position rather than an apology: *"new people are already accompanied by mentors, and the point of the system is that the process stops being the thing a newcomer must learn — if the UI is still a bottleneck for them, that is a design defect, not a missing module."*
- **What is deliberately later** — a plain list.
- **The scope decision we need** — exactly two options, A and B, with a recommendation and one sentence on what each does *not* buy. Two options decide; three options adjourn.
- **What this offer depends on** — table of dependency · owner · status. Every open item has a named owner.
- **On return on investment** — if there is no measured figure, say so and **propose how to get one** (fund a baseline study alongside the build), rather than inventing a number or borrowing a programme-level KPI. The structural case (rule-driven work, repeated every project, auditable trail) is usually stronger than a fabricated percentage anyway.
- **Decisions requested** — numbered, each answerable yes/no or by naming a person.

## 04 — Build Slices

See [[vertical-slicing]]. The one thing that belongs here: the **need-coverage-by-slice matrix**, a two-column table `Slice | Need IDs`, plus a one-line baseline count (*"18 built, 5 partial, 7 unbuilt; 2 needs added → 34 total"*). It is the only honest answer to "are we nearly done", and it takes four minutes to maintain.

## Working rules for the whole chain

- **Version each document independently** (`v1.5`, `v0.4`, `v0.3`) and state each one's basis in its META block (*"Basis: User Needs v1.5 (DRAFT) · Requirements v0.4 (provisional)"*). Then anyone can see at a glance whether a derived doc is stale.
- **One folder per circulation date**, files prefixed `00_`…`04_`, both `.md` (source) and the built office format. Supersession is stated in `00_`, and the superseded set is kept, not deleted.
- **A need that changes late changes downward, in one pass** — need → requirement → MVP wording → slice → coverage matrix. A chain updated halfway is worse than one not updated at all.
- **Dogfooding check:** if the system being specified is itself supposed to derive requirements from needs, then this authoring discipline *is* a system requirement, not house style. Say so.

Related: [[user-roles-and-personas]], [[vertical-slicing]], [[deliverable-authoring]], [[project-economics]].
