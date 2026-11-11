---
name: simopt
description: "Simulation-optimization problem solving. Use when the user has a queueing, scheduling, resource allocation, capacity planning, or throughput optimization problem that benefits from discrete-event simulation. Also use when user says 'simulate', 'optimize throughput', 'what-if analysis', or describes a system with arrivals, queues, servers, and processing."
---

# SimOpt — Simulation-Optimization Skill

## Overview

SimOpt is a .NET 9 discrete-event simulation engine coupled with metaheuristic optimizers (PSO, EA, SA, Random Search). It lives at `~/simopt/` and has an MCP server for programmatic access.

**Announce at start:** "I'm using the SimOpt skill to model and solve this as a simulation-optimization problem."

## When to Trigger

Detect these patterns in user questions:
- **Queueing:** "customers waiting", "queue length", "wait time", "service rate", "utilization"
- **Scheduling:** "job scheduling", "machine allocation", "production planning"
- **Resource allocation:** "how many servers", "staffing levels", "buffer capacity"
- **Throughput:** "maximize output", "bottleneck", "processing rate"
- **What-if:** "what happens if we add", "what if demand increases", "sensitivity analysis"
- **Explicit:** "simulate", "optimize", "SimOpt"

## Workflow

### Step 1: Problem Framing
Identify the simulation components:
- **Sources** — what generates work? (customers, orders, raw materials)
- **Queues/Buffers** — where does work wait? (waiting rooms, inventory, backlogs)
- **Servers** — what processes work? (machines, workers, CPUs)
- **Sinks** — where does finished work go? (completed orders, departures)
- **Decision variables** — what can the user change? (buffer sizes, service rates, staffing)
- **Objective** — what to optimize? (minimize wait time, maximize throughput, minimize cost)

Present this mapping to the user: "Here's how I'd model this..."

### Step 2: Offer Visualization
Ask: **"Want to watch the simulation run?"**
- If yes: build and launch `SimOpt.Visualization` with the model
- If no: run headless via MCP server or direct code

**Headless-first rule:** Validate simulation models with xUnit headless tests before launching visualization — the user is not a tester.

### Step 3: Build the Model

**Option A — MCP Server (preferred for simple models):**
Use the `simopt` MCP tools:
```
create_model → topology JSON with nodes and connections
run_simulation → execute and get results
get_status → inspect state
```

**Option B — Direct code (for complex models):**
Write a model class in `~/simopt/src/SimOpt.Visualization/Models/` following the SqssDemo pattern:
1. Create `Model` with seed
2. Instantiate templates (SimpleSource, SimpleBuffer, SimpleServer, SimpleSink)
3. Connect them (Server.ConnectTo(Buffer), Sink.ConnectTo(Server))
4. Configure distributions (Gaussian, NegExponential, Constant)

### Step 4: Run & Optimize
- **Single run:** Model.Run(duration) for one scenario
- **Optimization:** Wrap as IProblem, use PSO/EA/SA to search parameter space
- Report: best solution, fitness progression, confidence intervals

### Step 4b: Visualization UX (when "watch" is requested)

When the user wants to watch the simulation, build a **professional-quality** visualization:

1. **Physical layout** — assign real-world coordinates (meters) to every node via `x`, `y`, `width`, `height` fields in VizTopology JSON. Don't use abstract auto-layout for complex models.
2. **Icon/graphics library** — for each domain, build appropriate visual assets:
   - Factory: machines as rounded industrial shapes, conveyors as animated belts, buffers as storage grids
   - Healthcare: waiting rooms, treatment rooms, patient flow
   - Logistics: docks, conveyor belts, sorting stations, trucks
   - Custom: create domain-specific node renderers in `SimOpt.Visualization/Controls/`
3. **Color coding** — use the `color` field on VizNode for custom per-node colors. Use a professional palette (Material Design or industrial).
4. **Labels** — use the `label` field for human-readable multi-line names (e.g., "Assembly\nLine 1").
5. **Scale** — include physical dimensions that make sense for the domain. A factory floor is 30-100m. An ER is 20-50m.
6. **Polish** — dark industrial theme, clean typography, gradient fills, status glow effects, animated entity flow, statistics overlay.

The visualization must look like a **professional SCADA/MES dashboard**, not a homework assignment. Invest rendering effort proportional to the model complexity.

### Step 5: Document & Report
- Save results to `~/simopt/docs/results/`
- Include: problem description, model topology, parameters tested, optimal solution
- If visualization was used, note the visual observations

## Architecture Reference

```
src/SimOpt.Basics        — Data structures, geometry
src/SimOpt.Mathematics   — Distributions, RNGs, matrix ops
src/SimOpt.Simulation    — DES engine: Model, EventScheduler, templates
src/SimOpt.Optimization  — IStrategy (PSO, EA, SA, Random Search)
src/SimOpt.Visualization — Avalonia 2D live rendering
src/SimOpt.McpServer     — MCP tools for programmatic access
```

## Key Classes

| Class | Purpose |
|-------|---------|
| `Model` | Simulation container — holds entities, scheduler, clock |
| `SimpleSource` | Generates entities at random intervals |
| `SimpleBuffer` | FIFO/LIFO/Priority queue with capacity |
| `SimpleServer` | Processes entities with stochastic service time |
| `SimpleSink` | Counts finished entities |
| `ParticleSwarmOptimization` | PSO optimizer (IStrategy) |
| `EvolutionaryAlgorithm` | EA optimizer (IStrategy) |
| `AnnealingAlgorithm` | SA optimizer (IStrategy) |

## Build & Run

```bash
# Build
~/.dotnet/dotnet build ~/simopt/SimOpt.slnx

# Run tests (472)
~/.dotnet/dotnet test ~/simopt/tests/SimOpt.Tests/SimOpt.Tests.csproj

# Launch visualization
~/.dotnet/dotnet run --project ~/simopt/src/SimOpt.Visualization/SimOpt.Visualization.csproj

# Run MCP server
~/.dotnet/dotnet run --project ~/simopt/src/SimOpt.McpServer/SimOpt.McpServer.csproj
```

## MCP Server Config

Add to `.mcp.json`:
```json
{
  "simopt": {
    "command": "/home/user/.dotnet/dotnet",
    "args": ["run", "--project", "/home/user/simopt/src/SimOpt.McpServer/SimOpt.McpServer.csproj"]
  }
}
```

## Example: SQSS Model (Source → Queue → Server → Sink)

```json
{
  "name": "Coffee Shop",
  "seed": 42,
  "nodes": [
    {"id": "arrivals", "type": "source", "params": {"mean_interval": 2.0}},
    {"id": "waiting", "type": "buffer", "params": {"capacity": 10}},
    {"id": "barista", "type": "server", "params": {"service_time": 1.8}},
    {"id": "served", "type": "sink", "params": {}}
  ],
  "connections": [
    {"from": "arrivals", "to": "waiting"},
    {"from": "waiting", "to": "barista"},
    {"from": "barista", "to": "served"}
  ]
}
```
