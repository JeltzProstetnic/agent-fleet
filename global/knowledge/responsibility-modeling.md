<!-- updates: none -->
<!-- consumed-by: none -->
# Responsibility Modeling — No RACI

Load when: documenting ownership, responsibility, governance, decision rights, or accountability for any process, policy, initiative, or deliverable — or when someone proposes/requests a RACI matrix.

**Standing preference:** never use RACI to document responsibility — use the alternatives below. Evidence base: a ~75-source teardown of RACI's failure modes. The analysis applies to any responsibility-design work, not just regulatory or compliance contexts.

## Why RACI is rejected

RACI splits each task across Responsible / Accountable / Consulted / Informed. The split is the problem:

1. **Semantic incoherence (A-vs-R paradox).** "Accountable" and "Responsible" are near-synonyms in English — both mean *answerable for the outcome*. The artificial split produces nonsense roles: Accountable-without-doing-the-work is oversight theatre; Responsible-without-authority is a manufactured scapegoat.
2. **Authority–accountability gap.** RACI routinely separates the *power to decide*, the *duty to execute*, and the *obligation to answer* — the three things that must stay synchronized. Result: figureheads who take blame without control, or executors who wait for permission.
3. **n×m mapping fallacy.** Participants × tasks = a grid of cells, each needing consensus (20 people × 50 tasks = 1,000 cells). You cannot correctly and exhaustively enumerate every Consulted/Informed in a real process.
4. **Static rot.** The matrix is outdated within weeks of any reorg or scope change; nobody updates it; it becomes misinformation.
5. **C-role bloat.** "To be inclusive," everyone gets Consulted → meeting bloat and too many vetoes. Too many stakeholders end up with a vote or a veto.
6. **CYA culture.** RACI's real institutional function is plausible deniability ("per the matrix, that was someone else's"), not accountability. It survives on inertia and MBA/PMI legitimacy, not merit.
7. **Kills ownership.** RACI is assigned externally and bounds people to a scope ("not my responsibility"). Genuine ownership is self-driven and crosses boundaries. RACI breeds a my-vs-your culture.

## What to use instead

| Model | Shape | Use when |
|-------|-------|----------|
| **Single owner + plain delegation** *(default)* | One named accountable owner per item; who does what stated in prose | Almost always — the lightweight default for any responsibility note |
| **Owner / Support / Informed** | One Owner per item, plus supporters and people kept informed | A simple at-a-glance overview table is genuinely wanted |
| **DACI** (Intuit/Atlassian) | Driver (runs the process) / single Approver (decides) / Contributors / Informed | A cross-functional decision genuinely needs coordinated inputs with one clear decider — fast, light, for routine operational decisions |
| **STO — Single Threaded Owner** (Amazon) | One person 100% accountable end-to-end, with real authority + resources + a dedicated team | A major initiative or transformation needs unambiguous end-to-end ownership and focus. STO names one accountable owner per area. Collapses into scapegoating if execs override the owner — needs genuine autonomy |
| **DARE** (McKinsey) | Deciders (vote) / Advisors (influence, no veto) / Recommenders / Execution | Higher-impact, matrixed decisions where "who decides" must be explicit |
| **RAPID** (Bain) | Recommend / Agree (narrow, time-boxed veto) / Perform / Input / single Decide | Specialists (legal/finance/security) must protect *specific* constraints but you still need speed |
| **Team Topologies / ownership patterns** | End-to-end ownership of a value stream by an autonomous team (interaction modes: X-as-a-Service / Facilitating / Collaboration) | Reducing cross-team dependency and coordination overhead; standing teams rather than one-off decisions |

All of these fix RACI by making one thing explicit that RACI fuzzes: *who decides and owns the outcome.* DACI/DARE/RAPID name a single decider; STO/Team Topologies fuse authority with accountability in one owner or one team.

## The default

For any responsibility or ownership documentation:

- **Default to a single named accountable owner + plain-prose delegation.** That *is* the governance — named ownership, decision trees, explicit approval flows. No matrix needed.
- **Reach for DACI** only when a cross-functional decision genuinely needs Driver / Approver / Contributors / Informed.
- **Use real names, not role titles**, in owner columns. If the owner is unknown, say so — never a role placeholder.
- **Never produce a RACI matrix.** If asked for one, surface this preference and offer the closest alternative above.
