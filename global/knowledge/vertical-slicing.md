<!-- updates: none -->
<!-- consumed-by: global/knowledge/needs-to-requirements.md (document 04 of the chain) -->
# Vertical Slicing — cutting work so every cut is demonstrable

Load when: planning a build order, writing a roadmap, cutting an MVP into releases, or replacing a phase/layer plan. Applies to software, process rollouts and documentation programmes alike.

**The rule:** each slice is a working end-to-end capability — engine, data, interface — **not a horizontal layer**. Each one can be demonstrated and tested on its own, and each leaves the system usable. A plan of layers ("first the database, then the API, then the UI") is undemonstrable until the end, which is exactly when the money runs out.

Target 4-6 slices. Fewer and they are phases; more and they are tickets.

## Anatomy of a slice

```
### Slice N — <Name>: <what the user can do after it>   · status
*One italic line: the theme.*
- **<Capability>** *(UN-003, UN-013)* — what it is, what is new versus what exists.
- **Depends on:** <slices, external tracks>
- **Open in this slice:** <decided-but-unbuilt items, with the reason they are cheapest here>
- **Delivered outcome:** <a sentence a person can execute as a demo>
```

Non-negotiable elements:

- **Status per slice**, honestly: *built and running; not stakeholder-validated* is a real status and far more useful than "done".
- **Need IDs on every bullet.** A slice bullet without a need ID is scope that arrived from nowhere — either find the need or drop the bullet.
- **Delivered outcome as an executable sentence.** *"Classify a project → scale its deliverables with justified overrides → see the tasks → read its business case."* If you cannot write the arrow chain, the slice is not vertical.
- **Existing vs new, marked.** *"mostly exists — consolidate and deepen"* vs *"new, green-field"*. Slices over an existing system are mostly consolidation, and pretending otherwise inflates the estimate and hides the real risk.

## Sequencing rules

1. **Data-model decisions come early, reasoning comes later.** Split every cross-cutting concern into **recording** and **reasoning**. Recording (capture the relation, persist it, type it) is cheap now and expensive to retrofit once the schema has hardened and real data is running on it. Reasoning over what was recorded (propagation, aggregation, cross-entity critical path) can wait, and usually gates a *later* milestone, not the first one. State this split explicitly — it is the argument that survives "can't we do that later?".
2. **A cross-cutting concern is not a slice.** Anything that changes the profile in slice 1, the timeline in slice 2 and the portfolio in slice 3 is not a module to bolt on at the end. It runs *through* the slices; say which part lands in each.
3. **Put a named milestone on the slice that changes the project's nature.** *"★ After slice 4 the system MUST be able to run a real pilot — mandatory."* One starred, dated, mandatory milestone beats a five-slice roadmap of equals.
4. **Order by what unblocks a decision, not by what is easiest.** The first slice should make the thing real enough to be argued about with evidence instead of slides.
5. **Independent slices are marked independent** and may interleave where they are cheap.

## Cross-cutting boundaries — declare them once, up front

Before the slices, a short section stating the boundaries that all of them respect. Each is 2-4 sentences, no more:

- **Ownership boundary.** What this system owns vs what an existing tool owns (*"we own workflow tasks and custom tasks; the dev tracker owns development work"*). Then the transparency plan for later, and the **discriminator field carried from day one** so the later phase is a data-flow addition rather than a rebuild.
- **Validation / compliance scope.** Which module falls under validated (regulated) procedure and which explicitly does not. Isolating it is *an architectural requirement, not a convenience* — say it in those words, because it will be challenged.
- **Pilot / rollout order.** How many pilots, in what order, and which slice each follows.
- **What is illustrative.** Any placeholder data — durations, effort, costs — flagged as illustrative here and in the UI, with the real source named as an open item.

## Closing sections

- **Coverage matrix** — `Slice | Need IDs`, all needs, plus the baseline count of built / partial / unbuilt.
- **Dependencies and open items** — external tracks, missing data sources, and the validation status of the inputs. Anything the plan rests on that is not yet true.
- **Related documents** — the needs, requirements, design docs and decision IDs, by path.

## Failure modes

| Symptom | Diagnosis |
|---|---|
| Slice named after a layer or a component | Horizontal plan wearing vertical clothes |
| No demoable outcome sentence | Not a slice — a work package |
| Cross-cutting concern parked in the last slice | Retrofit debt scheduled deliberately |
| Every slice equally important | No milestone; nothing forces a decision |
| Coverage matrix absent or stale | "Nearly done" is unfalsifiable |
| Estimates on green-field and consolidation slices look alike | Existing-vs-new not marked |

Related: [[needs-to-requirements]], [[user-roles-and-personas]], [[project-economics]].
