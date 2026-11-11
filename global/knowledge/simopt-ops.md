<!-- updates: global/skills/simopt/SKILL.md -->
<!-- consumed-by: foundation/session-protocol.md (workflow reference) -->

# SimOpt Operations — Agent Fleet Knowledge

**Load when:** SimOpt skill triggers, user mentions simulation/optimization, or you need to build/run/visualize a simulation model.

## Product Positioning — Agent-Driven Sim-Opt

SimOpt is aimed at **non-experts using Claude Code or agent fleet with
this skill** to build preliminary or even final sim-opt systems. Deployment
modes include production use, research pre-studies, and throwaway what-if
analysis.

**This means:**

- **Do not propose import schemas or ETL layers.** When a user has data
  (CSV, spreadsheet, PDF, photograph of a whiteboard, spoken numbers in a
  meeting), YOU read it and call the builder directly. No user-facing
  "import screen", no schema contract — those re-introduce the expert
  configuration burden we exist to eliminate.
- **Prefer conversational parameterization over configuration UI.** The
  user says "four operators at packing"; you change `operators_pack` in
  the solution vector. The UI is for *seeing* results and *steering*
  (start/stop/apply-to-viz), not for entering parameter matrices.
- **Recognize domain patterns and reach for domain classes.** When a user
  mentions batching, fan-out, rejection, or any recurring physical
  behavior, map it to an existing template (e.g., `RolandPrinter`,
  `SimpleRejectServer`) or build a new one with tests. Don't just bolt
  params onto `SimpleServer`.
- **Test-driven even for throwaway models.** A failing test is the
  fastest way to validate that a spontaneously-assembled topology runs
  correctly. Tests also serve as evidence of what was built when the
  session ends. TDD is not an expert-only discipline here — write one
  test per topology stage, minimum.
- **The MCP server is the primary surface for agent automation**
  (SIM-19/20). When the user hands you a system description from outside
  the simopt repo, prefer MCP tool calls over direct file edits where
  possible.

**What is NOT negotiable regardless of positioning:**
- Discrete-event only (no ODE or continuous-time).
- Server→Buffer and Buffer→Server wiring patterns from the cookbook below.
- `createProduct: m => m[0]` for any pass-through server feeding a Buffer.

## Detection Patterns

Recognize these in user questions and **offer SimOpt proactively:**

| Pattern | Example | Model Type |
|---------|---------|------------|
| Queueing | "customers waiting too long", "queue growing" | Source → Buffer → Server → Sink |
| Throughput | "bottleneck", "maximize output", "utilization" | Multi-stage pipeline |
| Staffing | "how many servers", "add another worker" | Parallel servers |
| Capacity | "buffer too small", "overflow", "rejection rate" | Buffer sizing optimization |
| What-if | "what if demand doubles", "sensitivity" | Parameter sweep |
| Scheduling | "job scheduling", "machine allocation" | Custom topology |
| Inventory | "reorder point", "stock-out", "holding cost" | Supply chain model |

**Offering script:** "This looks like a [queueing/throughput/capacity] problem — I can model it as a discrete-event simulation and optimize the parameters. Want me to set it up? I can also show you a live visualization while it runs."

## Workflow

### 1. Frame → 2. Build → 3. Visualize → 4. Optimize → 5. Report

**Step 1: Frame the problem**
Map user's domain to simulation components:
- What arrives? → Source (with inter-arrival distribution)
- Where does it wait? → Buffer (with capacity)
- What processes it? → Server (with service time distribution)
- Where does it go? → Sink (counter) or next stage

**Step 2: Build the model**
Create a `VizTopology` JSON:
```json
{
  "name": "Coffee Shop",
  "seed": 42,
  "nodes": [
    {"id": "customers", "type": "source", "params": {"mean_interval": 2.0}},
    {"id": "line", "type": "buffer", "params": {"capacity": 10}},
    {"id": "barista", "type": "server", "params": {"service_time": 1.8}},
    {"id": "served", "type": "sink", "params": {}}
  ],
  "connections": [
    {"from": "customers", "to": "line"},
    {"from": "line", "to": "barista"},
    {"from": "barista", "to": "served"}
  ]
}
```

**Step 3: Offer visualization**
Ask: "Want to watch the simulation run?"
- Yes → Launch Avalonia viz: `~/.dotnet/dotnet run --project ~/simopt/src/SimOpt.Visualization/SimOpt.Visualization.csproj`
- No → Run headless

**Step 4: Optimize (if needed)**
Wrap the model as an `IProblem` where `Evaluate()` runs the simulation and returns a fitness value (e.g., -average_wait_time, throughput, -rejection_rate). Feed to PSO/EA/SA.

**Step 5: Report**
Document: problem description, model topology, parameters tested, optimal solution, key metrics. Save to `~/simopt/docs/results/`.

## Presets

Three built-in topologies for quick demos:

| Preset | Method | Topology |
|--------|--------|----------|
| SQSS | `VizTopology.Sqss()` | Source → Buffer(15) → Server → Sink |
| Parallel Servers | `VizTopology.ParallelServers()` | Source → Buffer(20) → 2×Server → Sink |
| Production Line | `VizTopology.ProductionLine()` | Source → Buf1 → Stage1 → Buf2 → Stage2 → Sink |
| Factory Floor | `VizTopology.FactoryFloor()` | 2×Source → Buffer → Inspect(5% reject→Waste) → 3×Assembly → QC → Pack → Ship. Physical layout (33×41m). |

## Multi-Stage Topology Cookbook

**Recipe: Build a factory model from a spec**

Given: "2 docks → inspection (5% reject) → 3 parallel assembly → QC → packing → shipping"

1. **Map nodes:** Each station = VizNode with type (source/buffer/server/sink), physical coordinates (meters), and params (mean_interval, service_time, capacity, reject_rate).
2. **Servers with downstream buffers need `createProduct: m => m[0]`** — or use `SimpleRejectServer` for reject flows.
3. **Wire connections** in topology order. `SimulationModel.Connect()` dispatches by type pair (see wiring patterns above).
4. **Mark reject targets** with `"is_reject_target": 1` in params. Connect reject server to waste before pass targets.
5. **Test headless first** — write xUnit test that builds the model, runs for N time units, asserts items reach the sink.
6. **Then visualize** — physical layouts render with conveyor animations, scale bar, legend automatically.

**Example topology JSON fragment (reject server):**
```json
{"id": "inspect", "type": "server", "label": "Inspection\n(5% reject)",
 "x": 14, "y": 11, "width": 5, "height": 3,
 "params": {"service_time": 0.33, "reject_rate": 0.05}},
{"id": "waste", "type": "sink", "label": "Waste",
 "x": 28, "y": 11, "width": 3, "height": 2,
 "color": "#9E9E9E", "params": {"is_reject_target": 1}}
```
Connections: `inspect → waste` (registered as reject target), `inspect → staging` (registered as pass target).

## Build Commands

```bash
# Build all
~/.dotnet/dotnet build ~/simopt/SimOpt.slnx

# Run tests (594 pass / 1 skip as of SIM-35)
~/.dotnet/dotnet test ~/simopt/tests/SimOpt.Tests/SimOpt.Tests.csproj

# Launch 2D visualization
~/.dotnet/dotnet run --project ~/simopt/src/SimOpt.Visualization/SimOpt.Visualization.csproj

# Run MCP server (stdio)
~/.dotnet/dotnet run --project ~/simopt/src/SimOpt.McpServer/SimOpt.McpServer.csproj
```

## MCP Server Tools

| Tool | Input | Returns |
|------|-------|---------|
| `create_model` | Topology JSON | model_id |
| `run_simulation` | model_id, duration | sink counts, queue depths, server states |
| `get_status` | model_id | current node states |
| `list_templates` | — | available node types with params |
| `list_models` | — | active model IDs |

## Key Constraints

- **Purely discrete event** — no continuous simulation or ODE solvers
- **.NET 9 SDK required** — install via `curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 9.0`
- **WSL:** dotnet at `~/.dotnet/dotnet`, not in system PATH
- **Headless first** — validate models with xUnit tests before launching visualization

### Connection Wiring Patterns

Five patterns needed for multi-stage topologies. Order matters in `SimulationModel.Connect()`.

| Pattern | From → To | Wiring | Notes |
|---------|-----------|--------|-------|
| Source → IItemSink | Source → Buffer/Server/Sink | `source.ConnectTo(sink)` | Source pushes via EntityCreated event |
| Buffer → Server | Buffer → Server | `server.ConnectTo(buffer)` + `buffer.ItemReceivedEvent` handler to start idle server | Server pulls from buffer |
| Server → Buffer | Server → Buffer | `buffer.ConnectTo(server)` | Buffer subscribes to server's EntityCreatedEvent (= entityFinishedEvent). **Buffer does NOT implement IItemSink — never cast.** |
| Server → Server | Server → Server | Set `PushAllowed=true` + `AutoContinue=true` on receiver, hook `EntityCreatedEvent` → `Put()` | Direct push. Receiver must accept Put. |
| Server → Sink | Server → Sink | `sink.ConnectTo(server)` | Sink subscribes to server's finish event |

### Critical Gotchas

- **`createProduct` delegate required for multi-stage pipelines.** Server's default `createProduct` generates `new TProduct()` with null Identifier — crashes `Buffer.Put()` which uses Identifier as a dictionary key. Always provide `createProduct: m => m[0]` for pass-through servers. Only safe to omit for single-stage Source→Buffer→Server→Sink.
- **`Server.EntityCreatedEvent` == `entityFinishedSimpleEvent`** — same event, different name (line 319 of Server.cs). All ConnectTo(IItemSource) patterns hook the "entity finished processing" event.
- **`SimpleRejectServer`** extends SimpleServer with probabilistic output routing. Set reject target via `SetRejectTarget(sink)`, pass targets via `AddPassTarget(buffer)`. Handles all output internally — do NOT wire downstream via standard Connect patterns.

## Known Limitations

- Visualization step size (0.1) means ~10 frames per time unit — fast events may batch
- Graph algorithms (Floyd-Warshall, A*, etc.) are stubs only — Dijkstra works
- NegExponentialDistribution needs Configure/ConfigureMean after construction, not constructor params
- Gaussian/Constant distributions are simpler — use those for quick models
- No probabilistic routing built into base Server — use `SimpleRejectServer` for reject flows
