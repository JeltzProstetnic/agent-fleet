<!-- updates: global/knowledge/needs-to-requirements.md -->
<!-- consumed-by: global/knowledge/needs-to-requirements.md (role layer used to address needs), global/knowledge/vertical-slicing.md (coverage matrices) -->
# User Roles & Personas — addressing a need to somebody

Load when: writing User Needs, requirements, personas, audience analysis, onboarding flows, or any document that says "the user wants…". Also load before designing role-scoped UI, permissions, or notification routing.

**The whole point:** a need addressed to "the user" is addressed to nobody. The role layer is what turns a wish list into a checkable, reviewable, buildable artefact — and it is the single most efficient communication instrument in the needs→requirements chain, because it lets one sentence serve twelve audiences without being written twelve times.

## 1. Three kinds of role — separate them or nothing works

Almost every organisation overloads the word "role" with three incompatible meanings. Write the distinction down explicitly, in a table, at the top of the User Needs document:

| | What it describes | Set by | Example |
|---|---|---|---|
| **Job role** | The position — grade, department, reporting line | HR / the org chart | *Director of Multi-Project Management* |
| **Process role** | What a person is **on a piece of work** — the accountability codes of the process being supported | The project/process, per assignment | `PL`, `PO`, `RT`, `RAD` — often 20-40 of them |
| **User role** | How a person relates to **the system being built**, and what they need from it | *This* document | `ROLE-01 … ROLE-nn` — typically 8-14 |

They are **independent**. One job holds several process roles across several projects; each process role maps to one or more user roles.

**The system needs its own user-role layer** rather than reusing the process codes. Process codes describe accountability for artefacts — the right instrument for *who signs this document*, the wrong one for *what should this screen show*. Several codes need exactly the same thing and collapse into one user role; a single code can sit in two. Views built against 31 codes would be 31 variants of the same four screens.

Rule of thumb: if two process codes would see an identical screen, they are one user role.

## 2. Role kinds — nested, positional, situational

Tag every user role with its kind. It determines how the system treats it:

- **Nested** — an inheritance layer (`PDP user ⊃ team member ⊃ participant`). A need stated at an outer layer is inherited inward by every role inside it. This is what stops the document from repeating itself.
- **Positional** — an accountability *held* on a piece of work (project lead, domain lead, PMO). Stable while the assignment lasts.
- **Situational** — held **for a moment**, not a permanent property (*decision maker*, *new participant*). A person fluent in one context is genuinely new in another, in the same week.

**Consequences that fall straight out of the kinds, and must be stated as such:**

- *Roles are held simultaneously.* One person is a system user **and** a team member **and** a domain lead **and**, for twenty minutes, the decision maker. So **personalisation cannot be a role selector** — the view is the **union** of a person's active roles, scoped to the context they are currently in.
- *Situational roles have no flag.* There is no "novice" checkbox on a person. Guidance engages per **role-per-context pairing**, not per user account.
- *Nesting is transitive.* "Serves: system user" in a requirement means it serves all twelve roles. Say this once, in the requirements preamble, and never restate it.

Quantify the overlap if you can — *"of 143 people, 14 hold more than one role and 54 work on more than one project"* — because that number is the argument against role-selector UI.

## 3. The role table

One table, one row per role, with these columns:

`ID · User role · Layer · Nests inside · Kind · Typical process roles · Contact frequency · In first release`

- **Contact** is an *expected engagement pattern*, not a measurement — say so, or someone will ask for the data behind it. ("daily", "per gate", "intense, then it stops".)
- **In first release** turns the role table into a scope instrument: the MVP discussion becomes "which roles are served", which is a conversation management can actually have.
- **Deferred roles get a row too**, marked deferred, with the reason. Recording it makes the eventual split *a decision rather than a discovery*.

Then one paragraph per role in prose: who they are, their characteristic problem, what changes for them, which needs they own. End each paragraph with the need IDs — `(UN-005, UN-010 · shares UN-007)`.

Useful moves inside those paragraphs:
- **Absorption**, stated explicitly: *"Project lead absorbs the Product Owner — from the system's side the PO needs what a project lead needs."* Fewer roles, no lost coverage, and the reader sees the decision.
- **Name the adoption gate.** Usually one role can veto the whole thing (Regulatory, Security, Works Council). Say which one and why.
- **Name the role that will subdivide later**, so the later split is expected.
- **Watch for a name collision with product-domain personas** (the customers the product serves). If both exist, disambiguate in a footnote — those are an *input the system carries*, not users of it.

## 4. Personas

A persona stands in for a user role so that a need can be checked against *somebody* rather than against an abstraction. How you build one depends on whether you can reach your actual users — and usually you cannot.

**The normal case: constructed personas.** Most products are built for users the team has no standing access to. Then a persona is a synthesised archetype, and its only defence against being fiction is being **grounded in evidence you can cite** — interviews, support tickets, telemetry, field studies, sales calls. Practice:
- One persona per user role, named and described in a paragraph, each claim traceable to a source.
- Record what the evidence base actually is, and how thin it is. A persona built from three interviews is legitimate; a persona built from nobody's input and presented as research is not.
- Re-check it when the evidence changes. Constructed personas rot silently.
- Skip the demographic garnish. Age, a stock photo and a favourite coffee order add nothing a requirement can be tested against; the behaviour, the constraints and the goal do.

**The exception: real named people.** Occasionally the users are reachable — internal tooling, in-house process work, a small organisation, a design partner. Then a persona can be **a real, named person nominated to stand in for a user role**, someone who holds all three role kinds at once. Take that option whenever it is genuinely available, because it is strictly stronger:

1. **Validation** — every need becomes checkable. *"The project lead needs the deliverable set derived rather than looked up"* is an assertion until a named project lead agrees or does not.
2. **Design** — *"would this work for the project lead"* is unanswerable; *"would this work for **that** project lead"* takes ten minutes.
3. **Adoption** — a named person per role, involved from the needs stage, is the cheapest insurance against building something capable and unused.

But it is the rarer case, and it does not scale past the room. Do not plan a project around it, and do not treat a constructed persona as a failure when no real user is reachable.

When you can use named people:
- Table of `PP-nn → stands in for ROLE-nn → nominee`, with `*open*` where unfilled. Open slots are a visible ask, not a gap.
- **Make the persona list and the review panel the same list.** Nominating them *closes* the validation question the draft carries rather than adding to it.
- Large or about-to-subdivide roles get more than one nominee (suffix the ID).
- Settle two things when nominating: **who nominates** (propose it), and **whether situational roles get a persona at all** — a decision maker is a moment, so the alternative is to take those needs to whoever held the last real decision.
- Consent and turnover are real: the person must know they are the standing reviewer, and the slot needs a successor when they move on.

## 5. Coverage — the closing check

Two matrices, both cheap, both load-bearing:

- **Role → needs.** Every role must have at least one need, or it is not a role.
- **Need → role.** Every need must resolve to a role, or it is not a need. Close the chapter with the sentence *"Every need resolves to a user role."* — and only write it once it is true.

Anything left over is the finding: an unstated role, or a need nobody actually has.

## 6. Failure modes

| Symptom | What went wrong |
|---|---|
| Needs written for "the user" | No role layer — nothing is checkable or reviewable |
| One screen per process code | Process roles reused as user roles |
| Needs repeated across roles | Nesting not modelled; state at the outer layer instead |
| Role selector in the UI | Simultaneity ignored — must be a union of active roles |
| A "novice mode" toggle on the account | Situational role treated as a permanent property |
| Persona with an age, a photo and a coffee order | Demographic garnish standing in for evidence — nothing here is testable |
| Persona with no citable evidence behind it | Fiction presented as research; say what the evidence base is, however thin |
| Constructed personas while the users sit down the corridor | The stronger option was available and not taken |
| Persona list ≠ reviewer list (named-people case) | Two parallel validation tracks, neither finished |

Related: [[needs-to-requirements]] (how needs and requirements are written against this layer), [[deliverable-authoring]] (audience discipline), [[responsibility-modeling]] (ownership — no RACI).
