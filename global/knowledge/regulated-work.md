<!-- updates: global/foundation/session-protocol.md (Work block rigor clause), global/CLAUDE.md (conditional trigger table) -->
<!-- consumed-by: global/hooks/lib-pending-work.sh (names this file as what rigor=regulated loads) -->
# Regulated Work — additive gates for `rigor=regulated`

Load when: a pending file's Work block carries `rigor=regulated`, or the work is under a QMS, a regulatory filing, a clinical or a legal process and the file is about to be created. Read it before the first artefact, not after the first finding.

## Scope

- The flag lives in the pending file's Work block and covers exactly that file's task, bundle, feature or phase. There is no project-level default: a project with regulated work has the flag on each regulated pending file, and a task in such a project without the flag is ordinary work.
- Set it when the pending file is created and name it in the backlog proposal; MG confirms in the normal priority review. Work that turns out to be regulated mid-way gets the flag added, every artefact produced so far re-run through the gates below, and `[?]` until that is done.
- The flag only adds. Every gate that applies to ordinary work (TDD, risk tiers, verification before completion, Meta-Rules consent, `[?]` with its closing observation, the credential and boundary rules) applies unchanged.

## Gates

1. **Approval before build.** `approved=<YYYY-MM-DD who>` in the Work block before any code or any artefact that will be released; `approved=none` means plan only. The approval is bound to a payload: a `docs/decisions.md` line `Approved <date> <who>: <plan or artefact> sha256=<64 hex>` (`sha256sum` of the approved file). A change after approval breaks the hash, and a broken hash means a new review and a new line — the CFG-949 clearance logic, carried by the record rather than a hook.
2. **Document control in every released artefact.** A visible block (not only the source's META comment from [[deliverable-authoring]]): document ID, version, status (draft / review / released), author, approver with date, classification. An artefact without the block is a draft whatever its filename says.
3. **Traceability.** Every requirement cites a need ID; every test, verification or validation record cites a requirement ID; the chain is in the artefacts, not in a session's memory. An orphan in either direction is a finding — recorded in the pending file with its disposition, never fixed silently.
4. **Evidence, not documentation.** A release claim cites the record: the test log path and commit, the measured value, the review findings file. "The suite passes" is a sentence; the suite's output at commit `<sha>` with its counts is evidence ([[audit-domains]], cross-domain principle 3).
5. **Independent review before release.** A reviewer who did not write the artefact: a Fable subagent where the project's roster pre-clears Fable, otherwise ask MG before routing to Fable; one Opus subagent when Fable credits are out, after telling MG once that Fable is out for the week. Findings are recorded with a disposition each, and release waits on that record.
6. **No third-party processor.** No regulated content reaches Artifact/claude.ai, external hosting, a cloud routine or any processor outside the owner's own document control, whoever the owner is; the company-content egress rule's one standing exception (`azure-ai.py` to the company's own AI platform) stands.
7. **Governing standard and clause named.** The pending file names the standard with version and the clause the work answers to (e.g. ISO 13485:2016 §7.3.6, IEC 62304:2006+A1 §5.5, 21 CFR 820.30(f)); load [[audit-domains]] for the clause map and verify clause numbers mechanically — a right finding under a wrong clause is a wrong finding.

## When the file closes

- The pending file is demoted (`status=done`, `Action: reference`) only when every gate has its record: approval line with hash, document-control block, trace check, evidence citations, review findings with dispositions.
- The release commit message cites the decisions.md approval line and the review record.

Nothing in this file removes a default gate; `rigor=regulated` is a label that adds and never a label that excuses.

Related: [[audit-domains]], [[risk-management]], [[deliverable-authoring]], [[needs-to-requirements]].
