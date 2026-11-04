<!-- Generic, literature-level knowledge. Safe for the public template. Source of the extraction is recorded privately in cfg. -->
# Manufacturing simulation modelling

Guidance for an agent that turns a real manufacturing operation into a discrete-event simulation
(DES) model: how such an operation is structured and measured, which planning rules the model must
hold to behave like the plant, how to learn it from the plant's own records instead of inventing
parameters, the engine semantics that silently corrupt results, and how to prove the model against
recorded history before anyone optimises on it.

## 1. How a multi-site operation is laid out

| Concept | Practice |
|---|---|
| Equipment hierarchy | ISA-95: enterprise > site > area > line or work centre > equipment. Every machine resolves to exactly one path; KPIs roll up along it. |
| Process hierarchy | Value stream > process > step > activity. Each process follows one case object (purchase order, material lot, production order, batch, shipment, customer order). |
| Site roles | Typical split: a central plant buys raw material and makes an intermediate (bulk, sub-assembly); converting plants turn it into finished goods; distribution sites hold finished stock and serve customer orders. Transfers between own sites are intercompany sales. |
| Value stream stages | Inbound (purchasing, receipt, quarantine, incoming inspection) > stock before the core > core processes > outbound (transfer to the next plant, or customer delivery). |
| Product structure | Raw lot (with supplier certificate) > batch of intermediate > containers (drums) > finished-good lot > unit > carton. A lot usually inherits the expiry of the intermediate it was made from. |
| Machine pools | Interchangeable machines differing only in capacity (batch size) form a pool; a batch is assigned to the smallest machine it fits. A shared machine serving several lines couples those lines. |

## 2. What the plant measures — reproduce the definitions exactly

| Measure | Definition | Notes |
|---|---|---|
| OEE | Availability x Performance x Quality. Availability = (planned time - downtime) / planned time, with changeover and stops as downtime; Performance = ideal time for everything made / run time, from a configured ideal rate per equipment type; Quality = good / everything made. | No ideal rate, no performance figure: do not guess one. Roll up per machine, line, site. |
| Utilization | Minutes machines ran orders / planned shift time (shifts a day x hours a shift x days a week). | Can exceed 100 % (overtime); different denominator from OEE. |
| Lead time | Inventory converted to days (on hand / daily use) before the core + median core lead + median wait from completion to release + transit to the plant. Network lead time = the longest chain of plant lead times. | Value-stream-mapping practice; count only lanes that actually carried goods. |
| First-pass yield | Cases completed without a failed check or a repeated step, divided by cases started. | Reworked cases are not first-pass. |
| Service level | Deliveries shipped by their promised day / deliveries shipped. | "In full" needs its own record; say when it is missing. |
| Takt, customer takt | Available production time / demand in the same period. | Needs demand records; without them only the observed rhythm exists. |
| MTBF / MTTR | Machine run hours between stops; minutes from stop to running again. | Classify stops by reason; only breakdown reasons feed MTTR. |
| Release lead time | Median days between a batch leaving production for QC and its release. | Often the largest hidden wait in regulated plants. |
| Days on hand | Stock / average daily consumption, usually for A items only. | Weight line averages by volume made. |

## 3. Planning rules the model has to hold

**Pull, not forecast.** Consumption against stock targets releases production; forecasts feed only
capacity planning. A model releasing orders at the recorded rhythm whatever stock needs is open-loop
where the plant is closed-loop, and overstates late orders and stock swings.

**Demand statistics.** Average daily consumption (ADC) over a trailing window (often 12 months). A
items make up ~80 % of volume. Volatility as MAPE of weekly use against ADC x 7, or WAPE for
low-volume items, where MAPE explodes on near-empty weeks.

**Rhythm (EPEI) and levelling.** Each item gets a production interval: weekly, two-, three- or
four-weekly, or make-to-order. Recommend the fastest interval whose weekly changeover hours still fit
the line's free time (most hours it has demonstrated it can work in a week, minus run hours), A items
first by volume. Every N days release N days' worth of the level, rounded into real order sizes, and
carry the rounding surplus forward. Stagger the lines of one plant across the N days. The
level is reviewed on a fixed cycle from recent actual demand. Up the chain, an intermediate is
levelled on the demand it ends in, converted by the quantity of intermediate per finished unit.

**Stock corridors (min/max with traffic lights).** Safety stock = rhythm days x ADC plus a surcharge
for demand and transport volatility, or alternatively the highest consumption ever seen within one
lead time (rolling max). Corridor = rhythm days x ADC x a cover factor (about 1 to 3, higher for
volatile items and busy machines); maximum = safety + corridor. Signals: above max stop replenishing,
inside the corridor make regularly, below safety add capacity or an extra order. Items at or above
max get no order; size every order so stock on receipt does not pass max.
Position = on hand + in transit (configurable per transport mode) + in work - open backorders.
A real minimum batch may exceed the corridor: a slow mover then sits above max after each batch.

**Purchasing.** Keep agreed and measured supplier lead times apart and never overwrite one with the
other. Minimum = usage over the agreed lead time; maximum = minimum + cover days of usage; reorder
point = minimum + usage over the measured lead time. At or below it, order the quantity that brings
stock to max when the delivery lands, rounded up to the minimum order quantity. A delivery later
than measured but within agreed lead time has used the buffer: count how often per supplier.

**Sequencing.** Group a week's orders by formulation (one run per formulation a day); place groups,
largest changeover first, on the day with least changeover so far. Spread an available intermediate
over its finished goods by their room to max; leftover goes to the highest-ADC item.

**Lot size vs frequency.** Smaller lots more often cut stock but add changeovers, orders and
shipments; a lane's transport rhythm is a natural pull signal. Model both as levers, not constants.

## 4. Records, genealogy and the event log

- **Object-centric event log (OCEL 2.0).** Objects, events, event-to-object links with a qualifier
  (order, equipment, input lot, output), object-to-object links, and attributes with their validity
  time. One event may touch several objects (a filling step: order, container, component lot,
  finished lot). One store serves genealogy, conformance and discovery.
- **Genealogy.** Build a material-flow graph from object links (container part of batch, lot made by
  order, unit packed in carton) and consumption events (order consumes lots, delivery carries lots,
  complaint concerns lot). Backward trace walks upstream to supplier lots; forward walks downstream to
  every customer delivery. A recursive query over the link table is adequate at plant-scale volumes.
- **Batch record (eDHR / eBR).** Per order: batch, material, quantities and times; inputs (weighed
  lots, components, containers); steps on their equipment with operator; in-process checks; lab
  results; deviations; label and UDI check; signatures. Review by exception: show QC only values out
  of range, missing required values, failed checks, wrong device type, label mismatches, open holds.
- **Discovery and conformance.** Directly-follows graph per object type, with counts and
  median/mean durations per edge and start/end counts. Conformance replays each case's events in time
  order through the approved model; break ties between simultaneous events by the model's step order;
  treat unfinished cases as in progress rather than as deviations.
- **Lot rules that change flow.** FIFO or first-expiry-first picking; quarantine until release;
  minimum remaining shelf life at shipment and release; ratio correction for an overweight ingredient
  (raise every other one by actual/target, since material cannot be taken out).
- **Analytics on the same rows.** EWMA charts catch drift before a spec limit (short-run charts on
  multi-product machines). Root cause: one row per order, only factors known before the outcome.
  Prediction: time-ordered split; the same machine's previous outcome is a strong feature.

## 5. Reading and linking messy exports

- Score every column against candidate roles (timestamp, identifier, step, machine, quantity, unit,
  value) on header match, on content that proves the role by itself, and on type fit; keep the ranked
  alternatives and leave thresholds to the linking step and the user.
- Record per source: date convention (a dot separator usually means European day-first, a slash US
  month-first), time zone (ask once per source system; never assume), decimal mark (the uploader's
  locale), list separators, and identifier shapes.
- Normalise identifiers to a key: strip separators, unify case, drop leading zeros, map sub-batch
  suffixes. Three systems writing one batch number three ways is normal.
- Link records by key; by machine plus time-window overlap where a system (typically SCADA or a
  historian) carries no order number; by sequence and quantity consistency. Estimate each source's
  clock offset from paired start/stop events (median difference) before windowing.
- Every link carries its method and a confidence; publish a link report of what joined and what did
  not. Every value keeps its provenance (file, sheet, row, cell; or page, field, line).
- Hand-made planning sheets: header below title rows, periods across columns (missing years from
  neighbours), "tbd" cells, formula total rows, products named by description. Exports lose rows.
- Check sufficiency first: declare per KPI which records it requires; report gaps, never fill them.

## 6. From a learned plant to DES building blocks

| Learned from records | Block | How the parameters are mined |
|---|---|---|
| A line's production orders | Source | Inter-arrival = gaps between completions of the last stage; order quantity from the last stage that ran on machines (a release wait after it records no quantity). |
| A process run on machines | Buffer + one server per machine | Process time per machine = its own records of run + changeover. Let the stage's servers pass straight to the next shared point; an extra buffer after the stage invents a queue that never appears in the data. |
| Breakdowns | Server failures | Time to failure = machine run hours between stops (operating time, not calendar time); repair = stop-to-running minutes. No stops recorded, no failures. |
| A wait without capacity records (QC release, quarantine) | Parallel delay | Items wait independently and concurrently, each for its own drawn time. Flag it as a stand-in until lab or warehouse capacity is recorded. |
| Shipping on a timetable | Dispatch + transit delay | First departure at a recorded time of day, later ones a drawn number of days apart; the truck takes everything ready. Merge shipments that left at the same instant into one departure before mining gaps. |
| Customer demand at a distribution site | Shelf | Daily order counts sampled per calendar day, including days with no orders; pieces per order; promised days. Fill from stock if possible, else by earliest promise, without letting a large unfillable order block smaller ones. |
| Pulled replenishment | Pull source | At each review tick compare the position with the corridor; below safety release orders until max. Include what is made but not yet arrived. |
| Intermediate stock at a converting plant | Stock | Production draws from it; an order short of material starts when the next delivery arrives. |
| One lot shared by several plants | Split, or routing by shares | Divide by recent downstream demand, falling back to recorded shares. |
| Planned downtime | Outage on a server | Let the current order complete, then block new starts for the outage window. |

Rules: every parameter is a mined sample drawn by bootstrap (equal chance per recorded value), not a
fitted or interpolated histogram; a machine or step without records is left out and listed, never
filled in; items carry their order quantity; a batch server turns N items into one product carrying
their sum; times are minutes from zero; the opening state (stock on hand, in transit, open orders,
signals) comes from the records at the window's end, and a shipment already booked in at its
destination but arriving later is counted once, as in transit.

## 7. Engine semantics that bite

- **Ties.** Mined durations are whole minutes, so a failure due exactly when a batch finishes is
  common; break the tie deterministically (finish, then fail between batches), or the engine may throw
  a causality error or lose the batch. Resumed batches must keep their product: items that vanish
  mid-model are missing from every lead-time statistic and bias it low (survivorship).
- **Small traps.** A single-slot delay silently serialises a wait many items spend at once; many
  engines refuse to schedule into the present (raise at once instead); batch completion checks may be
  asked about empty slots (refuse them); a zero quantity inside "release until max" never terminates.
- **Observable events.** Failures, repairs and full-buffer rejections need public events; inferring
  them from state changes is fragile, and unreported rejections hide lost work.
- **Granularity.** Drawing intermediate stock in whole-order chunks against a small average stock can
  starve a line the records show running; check the balance before switching material limits on.
- **Seeds per entity.** Seed each block's stream from (run seed, block ID) so adding a block leaves
  other draws unchanged; antithetic runs use 1 - u, kept off the ends of (0, 1).
- **End of horizon.** Close busy, down and stock-time integrals at the horizon (time-weighted stock is
  an integral, not a sample) and count open orders past their promise as late.

## 8. Validating against recorded history

- Fix the window (e.g. the last three months) and a tolerance agreed up front (±10 % on monthly
  output per line and mean stock per site is a common start; raw stock is noisier). Judge on the mean
  of twenty or more replications, not a handful, and check day-zero state against the records too.
- Read deviations as missing mechanisms: service better than the records usually means a constraint
  is absent (upstream material arrival, raw materials, machines shared between lines); late orders
  worse than the records usually mean the release rule is missing (open-loop production).
- Keep a minimal independent implementation of the block rules as a test double, so the pipeline is
  testable before the production engine is wired in; label its output as not for answers.
- Synthetic plants with switchable planted problems and a ground-truth file make analytics testable;
  pick affected objects by rule, not position, and key random streams by entity. Signals from simple
  physics (first-order lags, viscosity falling with temperature) plus drift, gaps and stuck sensors.

## 9. Reference runs and reproducibility

- Freeze a few cases (a textbook single-queue server, a line with breakdowns and a release wait, a
  timetabled dispatch, a customer shelf, a pulled replenishment) with seed, horizon and replications;
  store per-block mean counts. The same engine build must reproduce them exactly; another engine or
  stream design must agree on means within sampling error, else a block rule is read differently.
- Pin the engine to a commit, record its version with every run, rerun the cases on every upgrade.
- Emit simulated runs as the same time-stamped event log as history, so replay and trace work on both;
  for optimisation ask for counts only, as serialising the event list dominates run time.

## 10. Scenarios and optimisation

- Run each scenario against its baseline on the same seeds (common random numbers); confidence = the
  share of paired runs that beat the baseline. Report "breaks", not only averages: first day a stock
  leaves its corridor, a machine over its shift baseline for a week, runs of late days, a line waiting.
- Levers: corridor size and rhythm per item group, lot size and release cadence per purchased
  material, shift patterns, sourcing splits between plants and distribution sites, temporary
  rebalancing of articles to a plant with spare hours, shorter changeovers, fewer stops. Keep recipes
  and formulas out: they belong to process approval, not to planning.
- Objective: goals in priority order (service first is the usual default, then least stock), floors and
  caps as constraints scored by relative shortfall, each goal normalised to the baseline, and a tie band
  (about 1 %) so noise on a high-priority goal does not outrank real gains on the next.
- Search: try every single lever move, combine the moves that helped, then evolve on few
  replications; keep the unchanged baseline in the final comparison and re-run finalists fully. Open
  only levers that carry most stock or value. The winner is a proposal a person signs, not a change.
- Costing: labour by shift pattern plus overtime, machine hours, changeover and scrap per batch,
  freight per shipment and unit, carrying as a yearly share of stock value, material at purchase
  price. Without the site's own rates, report no cost rather than an invented one.
