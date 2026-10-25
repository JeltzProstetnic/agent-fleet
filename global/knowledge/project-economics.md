<!-- updates: none -->
<!-- consumed-by: global/knowledge/needs-to-requirements.md (the ROI section of an MVP offer), global/knowledge/vertical-slicing.md (what a milestone is worth) -->
# Project Economics — the productivity dimensions

Load when: arguing for or against a project, ranking a portfolio, writing the ROI section of a proposal, designing a business-case or profitability feature, or being asked "is this worth doing?".

**The premise:** budget-versus-actual is backward-looking and rewards under-spending even when under-spending means under-staffing and slip. Every metric below is **forward-looking** and answers a decision question. Together they are the productivity dimensions of a project — the small set of numbers on which continue / kill / accelerate can honestly rest.

## The four anti-patterns these exist to kill

| Anti-pattern | What it looks like |
|---|---|
| **Sunk-cost ranking** | Ranking by total value or by money already spent, so almost-finished weak projects beat young strong ones |
| **Assumption laundering** | Value figures whose price, volume and probability assumptions are buried in a slide nobody owns |
| **Budget theatre** | "Green, because we spent what we planned to spend" — while the market assumption quietly died |
| **Point-estimate optimism** | A single NPV answering "what is this worth *if everything works*" — the wrong question for most of a project's life |

## The metric family

**1 · eNPV — expected (risk-adjusted) net present value.** *The headline.* NPV where every future cash flow is weighted by the cumulative probability of surviving the gates between now and that flow.

```
eNPV(t0) = Σ_t [ P_surv(t) × CF(t) ] / (1 + r)^(t − t0)
P_surv(t) = Π p_g   over all gates g between t0 and t
```

It prices in the most important fact about a development project: **it might die at the next gate.** It also behaves correctly by construction — as a project passes gates its eNPV *rises without any assumption changing* (risk burns off), which makes gate progress visibly valuable and a gate slip an immediately quantified loss.

**2 · ETC / EAC — estimate to complete / at completion.** Remaining cost from today to done, from the phase cost plan, **cross-checked against the forward staffing commitment** (allocations × rate card). Report the *larger* of the two and flag divergence above a threshold: a plan that says "cheap" while the staffing table says "expensive" is **a finding, not an average**. ETC answers the decision question — *what will it still cost to get the value* — and staffing allocations are usually a live cost forecast nobody is using as one.

**3 · PI — productivity index.** *The ranking metric.* `PI = eNPV / ETC` — value still expected divided by money still needed.

This is the single number that makes portfolio ranking **sunk-cost-free**. Two projects with equal eNPV but 1:4 ETC are not equal; PI says so and total NPV does not. It is also the natural **kill-threshold metric**: a configurable floor (e.g. PI < 1.0 — remaining spend exceeds the risk-adjusted value it buys) triggers a mandatory continue/kill review. And under a capacity constraint, portfolio funding = fund down the PI ranking until people or cash run out — the constrained-knapsack result, computed rather than negotiated.

**4 · Payback period & break-even year.** Time from launch until cumulative contribution equals cumulative investment (EAC basis), in months plus the calendar year. Discount-rate arithmetic is invisible to most stakeholders; *"pays back 34 months after launch"* is universally legible and is what management intuitively cross-checks eNPV against. Also the most sensitive early indicator of a post-launch ramp problem.

**5 · Contribution margin.** `(price − variable unit cost) / price`, per product or segment, stored as **explicit assumptions** — price and unit cost entered, margin *derived*, never entered directly, so the parts stay honest. Margin is where business cases quietly rot.

**6 · Gate-conditional value.** The decision-tree / real-options view: what the project is worth *conditional on* passing the next gate. Turns "should we keep going" into "what are we buying with the next phase's spend".

**7 · Portfolio value-at-risk & concentration.** How much of the portfolio's expected value sits behind a single gate, a single technology or a single market. A portfolio of good projects can still be a bad portfolio.

**8 · Assumption drift index.** *The honesty metric.* How stale the inputs are — how long since each assumption was reviewed by its owner. A confident number computed from year-old assumptions is worse than no number.

## Assumptions are first-class records

Not a slide. Each assumption carries: **an owner (a person), a source, a confidence rating, and a review date.** A metric computed from unowned assumptions is decoration. Consequences:

- **Identical inputs must yield identical results.** The valuation engine is deterministic. AI or analysts may *propose* inputs; **no proposed number counts until a named person approves it.**
- **Version the business case.** Compute from the approved version plus actuals — never from the working draft.
- **Snapshot over time**, and attribute every value change to a **named cause** ("gate probability revised", "launch slipped one quarter"), so the value curve is explainable rather than merely plotted.

## Monitoring

Deterministic, configurable alert rules — value drop beyond a threshold, EAC versus approved envelope, PI below the kill floor, assumption staleness, launch slip, gate-linked re-approval. Open alerts roll up into **one per-project signal** that must include an explicit **"insufficient or stale data"** state. A project with no credible data must not render as green.

Every threshold breach requires a **named human acknowledgement**. An alert nobody owns is a log line.

## Using this in a proposal

- If there is **no measured baseline**, say so and **propose funding a baseline study alongside the build** — measure what the current process costs before claiming a reduction. Do not invent a figure ([[deliverable-authoring]]).
- **Programme-level KPI targets are not project ROI.** Never present one as the other.
- Where the numbers do not yet exist, the **structural case** is usually stronger anyway: the work is rule-driven and therefore automatable with an auditable trail, and the same work is redone every cycle.
- The strongest argument is one where **the work is required either way** — a mandated corrective action, a regulatory obligation, an audit finding. That case does not have to win a priority argument.
- Mark every placeholder figure *(illustrative)* at each occurrence.

Related: [[needs-to-requirements]], [[vertical-slicing]], [[deliverable-authoring]], [[responsibility-modeling]].
