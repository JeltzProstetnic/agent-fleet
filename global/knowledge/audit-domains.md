# Audit Domain Architecture

**Trigger:** When auditing targets outside code/config (academic papers, regulatory compliance, product quality, medical device documentation), or when planning audit agent personas.

The fleet auditor is a multi-domain audit engine. The 8-step protocol (`audit-protocol.md`) is the meta-process; this file provides domain-specific frameworks, personas, and criteria.

## Meta-Pattern

Every audit domain shares a structure:

1. **Persona** — the reviewer's expertise, posture, and institutional context
2. **Framework** — the standard, regulation, or criteria set being evaluated against
3. **Evidence standard** — what counts as "verified" in this domain
4. **Finding taxonomy** — severity and type classification
5. **Output format** — how findings are communicated

The 8-step workflow applies universally. Steps 0c (Project Intelligence Gathering) and 0d (Data Health) adapt per domain: for regulatory audits, "intelligence gathering" means reading the QMS manual and prior audit reports; "data health" means checking complaint databases and CAPA logs.

## Domain Catalog

### D1: Code & Architecture (current capability)

| Field | Value |
|-------|-------|
| Personas | Security engineer, architect, test specialist, DX reviewer |
| Frameworks | ISO 25010 (product quality), OWASP ASVS, CMMI-DEV, project-specific rules |
| Evidence | Test results, code traces, import graphs, runtime metrics, deployment state |
| Findings | Critical / High / Medium / Low |
| Output | Fix plan with dependency ordering, backlog items, evidence file |

ISO 25010:2023 quality characteristics (use as checklist):
- **Functional suitability** — completeness, correctness, appropriateness
- **Performance efficiency** — time behavior, resource utilization, capacity
- **Compatibility** — co-existence, interoperability
- **Interaction capability** — appropriateness recognizability, learnability, operability, user error protection, accessibility
- **Reliability** — maturity, availability, fault tolerance, recoverability
- **Security** — confidentiality, integrity, non-repudiation, accountability, authenticity, resistance
- **Maintainability** — modularity, reusability, analysability, modifiability, testability
- **Flexibility** — adaptability, scalability, installability, replaceability

### D2: Academic Peer Review

| Field | Value |
|-------|-------|
| Personas | Domain expert (field-specific), hostile Reviewer 2, methods specialist, citation auditor, journal editor |
| Frameworks | Journal-specific review criteria, field norms, epistemic standards |
| Evidence | Citations, data provenance, methodology rigor, logical structure, prior art coverage |
| Findings | Fatal flaw / Major concern / Minor concern / Suggestion |
| Output | Structured review with numbered points, recommendation (reject / major revision / minor revision / accept) |

**Adversarial review pattern** (proven on a long-form theory-paper review):
- Deploy N parallel reviewers (minimum 3, ideally 5-6) with distinct expertise personas
- Each reviewer independently reviews without seeing others' findings
- Include at least one "hostile" reviewer who assumes the work is wrong and tries to prove it
- Include at least one "citation/prior art" reviewer who checks all references and identifies missing literature
- Synthesize across reviews, identifying where multiple reviewers converge = high confidence; where only one raises an issue = check carefully for false positive
- The most valuable findings are internal contradictions and circular reasoning — these are the load-bearing failures that reviewers from different perspectives independently identify

**Review dimensions per persona:**
- Weakest claim identification (which single claim, if removed, collapses the most?)
- Circular reasoning (where are conclusions smuggled into premises?)
- Unfalsifiable claims (what's structured to survive any possible evidence?)
- Logical gaps (where does the argument jump without bridging?)
- Missing literature (whose work should be engaged but isn't?)
- Stale or mischaracterized citations (are sources accurately represented?)
- Methodological weaknesses (could the same data support a different conclusion?)
- Novelty assessment (is this genuinely new or repackaged existing work?)

### D3: Medical Device QMS — ISO 13485 / FDA 21 CFR 820

| Field | Value |
|-------|-------|
| Personas | Internal QMS auditor, notified body assessor (TÜV, BSI), FDA QSR inspector |
| Frameworks | ISO 13485:2016, 21 CFR 820, MDR 2017/745, ISO 14971:2019, ISO 62304:2006+A1 |
| Evidence | Documented procedures, objective evidence of implementation, records, design history files |
| Findings | Major nonconformity / Minor nonconformity / Observation / Opportunity for improvement |
| Output | Audit report with NCR (Non-Conformance Report) per finding, CAPA timeline |

**Manufacturer context — load it first:** the auditor needs the audited company's product range, MDR classification, notified body and product-specific harmonized standards (biocompatibility ISO 10993 plus the product family's own standards). Keep these in the company's domain file (`domains/<company>/`) and load it before the audit; without it the persona applies generic criteria where an assessor would apply product-specific ones.

**ISO 13485 clause structure** (top-level — expand on demand):
- §4 Quality Management System (documentation, QM manual, control of records)
- §5 Management Responsibility (commitment, customer focus, policy, planning, review)
- §6 Resource Management (competence, infrastructure, work environment)
- §7 Product Realization (planning, customer requirements, design & development, purchasing, production, monitoring & measurement)
- §8 Measurement, Analysis, Improvement (monitoring, NC product, data analysis, CAPA)

**Critical audit areas for medical devices:**
- **Design controls (§7.3)** — design input/output, verification, validation, transfer, changes. The most common FDA warning letter topic.
- **Risk management (ISO 14971)** — hazard identification, risk estimation, risk evaluation, risk control, residual risk evaluation, risk management review. Must be traceable through the entire design history.
- **CAPA (§8.5.2/8.5.3)** — corrective and preventive action. Must demonstrate: investigation, root cause, action, verification of effectiveness. The second most common FDA warning letter topic.
- **Complaint handling (§8.2.2)** — all complaints investigated, trend analysis, regulatory reporting (MDR vigilance, FDA MDR reports).
- **Supplier controls (§7.4)** — qualification, monitoring, re-evaluation. Critical materials must have full traceability.
- **Process validation (§7.5.6)** — special processes (sterilization, bonding, sintering) with documented IQ/OQ/PQ.
- **Software lifecycle (IEC 62304)** — if the device includes software: classification, development planning, requirements, architecture, detailed design, unit/integration/system testing, release, maintenance. Safety class determines rigor.

**FDA-specific focus areas** (for QSR simulation):
- 483 observations and warning letter patterns
- QSIT (Quality System Inspection Technique) — the subsystem-based approach FDA uses
- Design controls emphasis (21 CFR 820.30)
- Production and process controls (820.70/75)
- CAPA (820.90/100)
- Medical device reporting and corrections/removals

**TÜV/Notified Body audit pattern:**
- Stage 1: Documentation review (QMS manual, SOPs, technical documentation per Annex II MDR)
- Stage 2: On-site assessment (implementation evidence, interviews, record sampling)
- Annual surveillance audits (subset of system, rotating focus)
- Unannounced audits (MDR Article 44(4))
- Technical documentation review (GSPR checklist, clinical evaluation, risk management file)
- Special process assessments (sterile barrier system, biocompatibility)

### D4: Product Safety & Certification (TÜV / CE Marking)

| Field | Value |
|-------|-------|
| Personas | CE marking consultant, safety engineer, TÜV product tester |
| Frameworks | MDR 2017/745, relevant harmonized standards (ISO 6872, ISO 4049, ISO 10993), GSPR (Annex I MDR) |
| Evidence | Technical documentation, test reports, clinical evaluation, labeling |
| Findings | Non-compliance (blocks certification) / Condition (must fix before certificate issue) / Recommendation |
| Output | Conformity assessment checklist with clause-by-clause status |

**GSPR (General Safety and Performance Requirements) — Annex I MDR:**
- Chapter I: General requirements (risk/benefit, risk management, design for safety)
- Chapter II: Design and manufacture (chemical/physical/biological properties, infection/microbial contamination, mechanical/thermal/electrical characteristics)
- Chapter III: Information supplied with the device (labeling, IFU)

### D5: Software Quality — IEC 62304 / FDA SaMD

| Field | Value |
|-------|-------|
| Personas | Software QA auditor, SaMD regulatory specialist, V&V engineer |
| Frameworks | IEC 62304:2006+A1:2015, FDA guidance on SaMD, ISO 25010 (quality model), AAMI TIR45 (ML guidance) |
| Evidence | Software development plan, requirements traceability, architecture documentation, test protocols/reports, anomaly records, SOUP management |
| Findings | Major NC (Class C software: patient safety risk) / Minor NC / Observation |
| Output | Gap analysis against 62304 clauses with safety classification justification |

**Safety classification (determines rigor):**
- Class A: No injury or damage to health
- Class B: Non-serious injury
- Class C: Death or serious injury

**Key process areas:**
- Software development planning (§5.1)
- Software requirements analysis (§5.2) — must link to risk management
- Software architectural design (§5.3)
- Software detailed design (§5.4, Class C only)
- Software unit implementation and verification (§5.5)
- Software integration and integration testing (§5.6)
- Software system testing (§5.7)
- Software release (§5.8)
- SOUP (Software of Unknown Provenance) management (§8)
- Software configuration management (§8)
- Software problem resolution (§9)

### D6: Risk Management — ISO 14971

| Field | Value |
|-------|-------|
| Personas | Risk management specialist, clinical expert, design engineer |
| Frameworks | ISO 14971:2019, ISO/TR 24971:2020, ISO 13485 §7.1 |
| Evidence | Risk management plan, hazard analysis, FMEA/FTA, risk evaluation matrix, risk control verification, overall residual risk evaluation, production/post-production information |
| Findings | Unacceptable risk (blocks release) / ALARP not demonstrated / Missing hazard / Inadequate risk control verification |
| Output | Risk management file completeness checklist, uncontrolled hazard list |

## Cross-Domain Principles

These apply to ALL audit domains:

1. **Persona fidelity matters.** A TÜV auditor behaves differently from an FDA inspector. TÜV focuses on system compliance, documentation completeness, and harmonized standard conformity. FDA focuses on design controls, CAPA effectiveness, and "show me the evidence." An academic Reviewer 2 looks for methodological gaps. Match the persona to the audit objective.

2. **The adversarial review pattern is universal.** For any critical audit target, deploy multiple independent reviewers from different perspectives. Convergent findings are high-confidence. Divergent findings need triage.

3. **Evidence ≠ documentation.** Documentation proves intent. Evidence proves implementation. "We have a procedure" ≠ "we follow the procedure." Always ask: show me the last 3 instances of this procedure being followed.

4. **Findings need traceability.** Every finding must trace to: (a) the requirement it violates, (b) the evidence that demonstrates the violation, (c) the risk if unaddressed.

5. **Audit output quality rules apply universally.** Whether writing a code refactoring spec, a peer review, or an FDA inspection report: label claims as verified/inferred/estimated, distinguish behavioral from structural requirements, and track post-handover corrections.

6. **The "directionally true, factually wrong" trap applies in all domains.** A regulatory gap analysis that correctly identifies systemic weaknesses but incorrectly lists specific clause references is as dangerous as a confidently wrong inventory list. Always verify specific references (clause numbers, section references, standard versions) mechanically.

## Expanding the Domain Catalog

When adding a new audit domain:
1. Define the persona(s) with institutional context and review posture
2. Map the applicable frameworks with version numbers
3. Define the evidence standard (what constitutes proof?)
4. Define the finding taxonomy (how are issues classified?)
5. Define the output format (how are findings communicated?)
6. Identify the domain's equivalent of "data health" — what's the non-obvious dimension that surface analysis misses?
7. Add the domain to the auditor CLAUDE.md quick commands if it warrants a keyword trigger

## Integration Notes

- A 6-persona parallel adversarial review is P4-equivalent effort for academic targets. For quick checks (P1-equivalent), a single hostile reviewer suffices.
- An ISO 13485 simulation should be informed by the company's product classification, its harmonized standards and its notified body's audit style — all from the company domain file.
- FDA simulation is most valuable as pre-inspection preparation: "what would an FDA inspector focus on given our recent 483s and our product type?"
- TÜV simulation is most valuable before Stage 2 on-site assessments and surveillance audits.
