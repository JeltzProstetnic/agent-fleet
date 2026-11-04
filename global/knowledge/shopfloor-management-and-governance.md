<!-- Generic, literature-level knowledge. Safe for the public template. Source of the extraction is recorded privately in cfg. -->
# Shopfloor management and project governance, for simulation and PDP work

Purpose: for a reader trained in computational science with no plant experience, how manufacturing companies steer daily operations and their improvement projects (short meetings at visual boards, a fixed KPI set per board, a standard response to every red figure, strategy deployment, stage-gate decisions), what data each routine produces, and how that data serves product-development-process (PDP) governance and discrete-event simulation (DES) as model input, validation target and source of what-if questions.

## 1. What shopfloor management is

Shopfloor management (SFM) is the leadership routine that makes a deviation from plan visible within hours at the place where the work happens, lets the people closest to it act first, and passes upward only what they cannot solve. Its parts: one board per team or unit with a fixed set of key figures and targets; a short standing meeting at that board on a fixed rhythm; a rule for what must happen when a figure turns red; and leaders who go to the floor regularly to see for themselves. Software versions keep these parts and add roll-up across levels, history, and a display mode for a screen next to the line, so the meeting can still happen standing in front of the board.

A **value stream** is the full chain of steps that turns material into a product a customer pays for, across departments (Rother and Shook 1999). A value stream manager owns that chain end to end, which is why the middle level of boards is often cut by value stream rather than by department.

## 2. The board cascade

| Level | Board of | Meets | Typical agenda |
|---|---|---|---|
| 1 | a team or shift on the line, led by its team leader | daily at shift start, 10–15 min, standing | last shift's figures, safety, today's staffing and plan, problems found |
| 2 | a department or value stream: team leaders plus support (maintenance, quality, planning, logistics) | daily or several times a week | level-1 figures rolled up, problems the teams could not solve, help requested |
| 3 | a plant or site, with its department heads | daily or weekly | plant KPIs, the plant's top issues, decisions that need plant authority |
| 4 | a corporate function across sites (head of production, finance, HR, sales) | weekly | sites compared, problems escalated by plants |
| 5 | the executive board | weekly or monthly | company figures, strategy status |

Meetings are staggered through the morning so that a problem seen on the line at shift start reaches the plant manager the same day. A board escalates a problem when solving it needs authority, money or people the board does not have, or when its own deadline has passed; the answer (a decision, resources, help from a support function) goes back down to the board where the problem started. Every board has an owner, fixed members, a fixed start time and a fixed length. Attendance and meeting length are tracked, and a meeting that habitually overruns is read as a sign that the board carries the wrong content.

## 3. KPI boards

Figures are grouped by letter, most often **SQCDP**: Safety, Quality, Cost, Delivery, People (variants add Output or Environment; safety always comes first). Each figure is shown as a tile:

| Element | Meaning |
|---|---|
| Name and unit | e.g. scrap in %, output in pieces |
| Period | shift, day, or ISO calendar week ("CW", weeks 1–53 starting Monday), matched to how fast the team can influence the figure |
| Target or corridor | one limit, or a band with lower and upper bound where both directions are bad (capacity use: idle below, overloaded above) |
| Red/green rule | the comparison that colours the tile, fixed in advance and visible to everyone |
| Actual | the latest period's value |
| Trend strip | the last few days or calendar weeks, sometimes with planned weeks ahead, so a single red day reads differently from a drift |
| Change vs previous period | in percent |
| Deviation note | one line per red period naming the cause, linked to its countermeasure |

The rule that turns a board into a control loop: a red figure is a deviation, recorded the same day, and it gets a countermeasure with owner and due date within a short deadline the board sets for itself. Two meta-figures then measure the routine itself, and level-2 and level-3 leaders watch them across their sub-teams: red KPIs without a measure, and overdue countermeasures.

| KPI | What it measures | How a model uses it |
|---|---|---|
| Accident-free days, safety cross | days since the last recorded incident; a calendar cross coloured per day | context only |
| Scrap rate | share of units discarded | yield probability per operation |
| Nonconformances (NC) | recorded internal deviations from specification | defect events, rework routing |
| Customer complaints, ppm | defects reaching customers, per million units | validation of end-of-line inspection |
| OEE | overall equipment effectiveness = availability × performance × quality | validation target; splits into failure, speed and yield parameters |
| Output vs plan | pieces made per period | primary throughput validation |
| Productivity | output per labour hour against a standard | calibration of labour models |
| Levelled-plan adherence | whether production started and ran to the levelled schedule | release process and its deviations |
| OTIF | share of orders delivered on time and in full | service level of supply-chain models |
| Cost per unit | total cost divided by units | cost layer on top of throughput |
| Absenteeism | share of planned staff hours missed | stochastic staff availability |
| Energy per unit | kWh per unit | energy use per machine state |
| Machine status | running, planned maintenance or down, per machine and shift | failure and repair distributions (MTBF, MTTR) |
| Team capacity use | planned work hours divided by available hours | utilisation of people treated as servers |

## 4. Acting on a deviation

Responses come in three depths. Containment stops the damage today (sort the suspect parts, add an inspection). A countermeasure removes the cause and carries an owner, a date and a link to the deviation. Structured problem solving starts when the cause is unknown. A countermeasure closes only after an effectiveness check shows the figure stayed green, and any action that must keep happening is written into standard work or onto a T-card.

| Method | What it is | Used when | Produces |
|---|---|---|---|
| PDCA | plan, do, check, act: a hypothesis, a trial, a check of the result, then adopt or adjust (Shewhart, Deming) | the frame around every countermeasure | a dated plan and a check result |
| 5-why | asking "why" repeatedly until reaching a cause someone can act on | local problems with a short causal chain | a causal chain |
| Pareto analysis | ranking causes or defect types by frequency or cost; a few causes usually carry most of the loss | choosing which problem to attack first | a ranked bar chart |
| Ishikawa (fishbone) | candidate causes sorted into categories: people, machine, method, material, measurement, environment | structuring a discussion before data exists | causes to test |
| A3 report | one sheet: background, current state, target, root cause, countermeasures, plan, follow-up (Shook 2008) | problems that need several people, several weeks, or a manager's approval | a reviewable decision record |
| 8D | an eight-step team method with containment and prevention, common in automotive and with suppliers | customer complaints, supplier defects | a formal report to the customer |
| Top-issue list | the few problems a board above team level is driving right now | problems escalated from below | owner, due date, status |
| Go and see | an agenda slot or visit where the team shows the problem at the machine | when the figures alone do not explain it | observations, new tasks |

## 5. Leader standard work and the routines around the board

Leader standard work (Mann 2005) schedules a leader's recurring duties as explicitly as an operator's: board meetings, floor walks, one-to-ones, process confirmation, reviews and planning. Each task carries a category and planned hours, and comparing planned hours per week with available hours shows how a leader's week is really split and when someone is overloaded. Typical categories: planning, regular communication (meetings, one-to-ones), on-site support, process confirmation, waste walks, improvement (CIP) tasks, workshops, project tasks, problem solving.

| Routine | What it is | Day to day |
|---|---|---|
| Gemba walk | the leader goes to the actual place of work ("gemba"), watches and asks open questions | scheduled weekly or daily; findings become tasks or countermeasures |
| Obvious-waste walk | a walk aimed at the classical wastes: transport, inventory, motion, waiting, overproduction, over-processing, defects, unused skills | short and regular per area; each waste seen becomes a small improvement task |
| Process confirmation | a scheduled check that a defined standard is followed, by leaders on several levels at decreasing frequency (layered process audit) | a card with a few yes/no questions; a "no" is a deviation like a red KPI |
| T-card board | a rack of cards, one per recurring check or duty per shift, flipped or moved when done, so a missed check is visible at a glance | where a countermeasure that must recur every shift ends up |
| Standard work | the documented current best way to do a job: sequence, timing, parts in process | baseline for training and for judging a deviation |
| Process checklists | templated step sequences assigned to people, e.g. onboarding a new hire | appear as cards in each assignee's queue |

## 6. Continuous improvement

The continuous improvement process (CIP, kaizen) is many small changes made by the people doing the work, each tracked as a task with owner and date. A kaizen event or kaizen week puts a cross-functional team on one area or machine for several days with the mandate to change it.

| Concept | What it is | Data for a model |
|---|---|---|
| 5S, red-tag area | sort, set in order, shine, standardise, sustain; items of doubtful use go to a marked area for a decision | search and walking time, rarely modelled |
| SMED | single-minute exchange of die: shorten changeovers by doing setup work while the machine still runs and simplifying the rest (Shingo 1985) | setup-time distributions; smaller lots become economical |
| Value stream map | process steps drawn with cycle time, changeover time, uptime, inventory between steps and total lead time | first draft of a DES model's structure and parameters |
| Kanban and supermarket | pull control: a buffer of parts kept at the supplying process and refilled only when the consumer takes from it | buffer capacities, replenishment signals |
| Milk run | material delivered on a fixed route at fixed intervals | a periodic transport process |
| Heijunka | levelling the product mix and volume released to production across the day or week | the release schedule |
| TPM | total productive maintenance: operators do basic care, maintenance plans preventive work in a CMMS (maintenance management system) (Nakajima 1988) | preventive-maintenance intervals, failure rates |
| FMEA | failure mode and effects analysis: each failure mode rated by severity, occurrence and detection, actions ranked | failure modes and their likelihood |
| Bowler chart | a grid of plan versus actual per metric and month, each month coloured red or green | monthly validation series |

## 7. Strategy deployment

Hoshin Kanri (Akao 1991; Jackson 2006) sets a few breakthrough objectives at the top for several years. Each level then translates the objectives of the level above into its own quarterly or annual objectives, the improvement priorities (mostly projects) meant to move them, and the metrics with targets that show progress.

- **X-matrix**: one sheet holding those four lists around a central grid, with correlation marks (strong or weak) linking each objective to the priorities and metrics serving it, and a named owner per row. One level's objectives become the "where to" of the level below.
- **Catchball**: the level above proposes objectives, the level below answers with how and how much it can contribute, and the two iterate until each named owner accepts the target.
- **Monthly review**: each owner states confidence (on track, at risk, off track) next to a computed progress figure. The review lists the red items behind each objective (red KPIs, red projects, overdue countermeasures, off-track objectives of the boards below) and records decisions as tasks with owner and date.
- **Alignment check**: an active project that serves no objective is flagged, and either gets linked or gets questioned.

## 8. Project portfolio and stage-gate governance

Stage-gate (Cooper 1990) splits a project into phases separated by gates. At each gate a board decides go, kill, hold or recycle against the deliverables due, and releases budget for the next phase only. A common sequence: idea, preparation (scope, feasibility), concept (solution and business case), execution, review (results against the business case), closed.

| Artefact | What it is | Used for | Data it produces |
|---|---|---|---|
| Project criteria | a checklist (duration, cost, effort, number of departments, strategic impact) deciding whether work is a project or stays a task | keeps small items off the portfolio board | yes/no per criterion |
| Work hierarchy | program (projects toward one outcome) > project > work package (a deliverable) > task (one assignee) | planning and progress roll-up | planned effort per task |
| Portfolio board (project steering board) | one board per organisational level, all its projects shown by phase, meeting weekly or monthly | gate and change decisions | decision dates |
| Gate request and sign-off | the project manager requests a gate, fixed board members sign off, the board owner decides | auditable decisions | request, signature and decision timestamps |
| Gate authority | small projects are decided locally with the level above informed; large or costly ones by the level above | matching authority to risk | which board decided |
| Change request | a proposed change of time, cost or scope; within tolerance the local board decides, beyond it the level above | controlling drift | values before and after |
| Escalation | a problem sent to the level above with a date, open until answered | getting a decision or help | send and answer times |
| Status lights | one colour each for scope, time and finance, plus overall | scanning many projects quickly | colour history |
| Progress and finance | % complete as finished planned effort; budget vs actual, one-time vs recurring; NPV, payback | tracking the business case | monthly series |
| WIP limit | a maximum number of active projects per board | stops starting more than the organisation can finish | count against limit |
| Gate history | the record of all gate decisions per project | audits and learning | phase durations, recycle counts |

## 9. Role-based views

| Role | Opens to | Acts on |
|---|---|---|
| Engineer or specialist | own tasks per week against capacity, assigned countermeasures | tests, analyses, project tasks |
| Project manager | own projects with status lights and next gate | status updates before the board meets, gate and change requests |
| Team leader (level 1) | team board, shift plan, T-cards | staffing, the day's deviations |
| Value stream or department manager (level 2) | department board, sub-team health, own strategy board | countermeasures, team escalations, improvement work |
| Plant director (level 3) | plant board, top issues, the plant's portfolio board | gates of plant projects, escalations upward |
| Function head, e.g. head of production (level 4) | figures rolled up across sites, gates of large projects | escalations from plants, cross-site priorities |
| CEO (level 5) | company figures, strategy review | objectives, resources |

A home screen built on this opens with a count and list of what needs the person today: sign-offs, decisions, escalations, overdue items, items due today. Leaders add a team-health table per sub-team (attendance, meeting length vs target, red KPIs without a measure, overdue countermeasures, overdue tasks), who is away, and each person's planned load against a capacity band.

## 10. Connection to product development and its governance

- PDP governance runs on the same skeleton: phases and gates, decision boards with fixed members, change requests with tolerances, escalation by level, a WIP limit on the portfolio, and links from projects to strategic objectives. The artefacts in section 8 transfer with little change.
- What flows through development differs: work items vary widely in size, gates can send a project back (rework loops), and specialists are shared across projects. Waiting for the next board meeting can dominate lead time when boards meet monthly, so measure gate waiting time (request to decision) per level.
- In regulated industries (medical devices, pharmaceuticals) gates line up with design reviews and design controls: design inputs, design outputs, verification, validation, transfer to production, and formal change control. Shopfloor artefacts reappear at transfer: process FMEA, validation protocols, and production KPIs such as scrap and OEE used as acceptance criteria.
- Team boards work for development teams as well (an obeya room is the project-level version), with milestone adherence, open issues, test backlog and load per person in place of output and scrap.
- Planned effort per person and week against available hours, the same view leaders use for themselves, shows overload in a development organisation before a milestone slips.

## 11. Connection to simulation modelling

Boards mostly hold daily or weekly aggregates, which make good validation targets and weak model inputs. Distributions come from the event-level data behind the boards: machine states from the MES (manufacturing execution system), work orders from the CMMS, orders and stock movements from the ERP, and timestamps of tasks, countermeasures and gates. When a board shows the figure you want to model, ask for the log that feeds it.

| Artefact | Model input | Validate against | What-if |
|---|---|---|---|
| Machine status, maintenance plan | failure and repair distributions, PM intervals | availability, OEE | another PM interval, a spare machine |
| Cycle and changeover times, SMED results | service and setup times | output per shift | shorter changeovers, smaller lots, effect on WIP |
| Output, scrap and OEE per shift | yield per operation | daily output distribution, OEE | bottleneck capacity needed for a higher output target |
| Supermarket and kanban sizes, milk-run interval | buffer capacities, replenishment | stockouts, line stops | buffer sizing |
| Levelled plan and its adherence | release schedule | schedule adherence | levelled versus batched release |
| Staffing, absenteeism, skill matrix | operator pools and their availability | productivity | an extra shift, cross-training |
| Task boards with planned hours | tasks as jobs, people as servers | overdue counts, lead times | target utilisation band, effect of absences |
| Countermeasures and top issues with dates | problem-solving lead time, escalation delay | closure times | faster escalation, more problem-solving capacity |
| Portfolio board and gate history | phase durations, gate outcomes, meeting cadence, WIP limit, shared specialists | projects per phase over time | WIP limit versus throughput, meeting cadence versus gate wait |
| Strategy metrics (output per operator, cost and energy per unit, OTIF) | targets | targets reached or missed | feasibility of a target before it is committed |

- Little's law (Little 1961): in a stable system, average work in process = throughput × average lead time. It holds for a line, a task queue and a project portfolio, and checks a proposed WIP limit before any model is built.
- Waiting time grows steeply as utilisation approaches 100 % (Hopp and Spearman 1996). A capacity corridor should therefore end below full load, and planning people to 100 % of their hours produces overdue tasks.
- Report model results in board form, the format managers read every day: the figure, its target or corridor, red or green, a trend, and the countermeasure the result suggests.

## Further reading

- Rother, M. and Shook, J. (1999). *Learning to See*. Lean Enterprise Institute.
- Liker, J. K. (2004). *The Toyota Way*. McGraw-Hill.
- Mann, D. (2005). *Creating a Lean Culture*. Productivity Press (later editions exist).
- Shook, J. (2008). *Managing to Learn*. Lean Enterprise Institute.
- Akao, Y. (ed.) (1991). *Hoshin Kanri: Policy Deployment for Successful TQM*. Productivity Press.
- Jackson, T. L. (2006). *Hoshin Kanri for the Lean Enterprise*. Productivity Press.
- Cooper, R. G. (1990). Stage-gate systems: a new tool for managing new products. *Business Horizons* 33(3).
- Shingo, S. (1985). *A Revolution in Manufacturing: The SMED System*. Productivity Press.
- Nakajima, S. (1988). *Introduction to TPM*. Productivity Press.
- Hopp, W. J. and Spearman, M. L. (1996). *Factory Physics*. Irwin.
- Little, J. D. C. (1961). A proof for the queuing formula L = λW. *Operations Research* 9(3).
