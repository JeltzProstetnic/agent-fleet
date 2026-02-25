# TDD Protocol — MANDATORY

**Default methodology: Test-Driven Development.** Write tests before implementation.

## Standard TDD Flow

1. **Define interface** — Extract or create the interface for the unit under test
2. **Write test cases** — Cover expected behavior, edge cases, error conditions
3. **Implement** — Write the minimum code to make tests pass
4. **Refactor** — Clean up while keeping tests green
5. **Verify** — Build + run tests

## Escape Hatches

TDD is the default, but these exceptions are allowed. **Always document the reason** when using an escape hatch:

| Exception | When | Example |
|-----------|------|---------|
| **Bootstrap** | No test infrastructure exists yet (first session of a new project) | Setting up test project, creating first test |
| **Spike** | Exploratory code to prove feasibility; will be rewritten with TDD | "Can we even connect to this API?" |
| **Thin wrapper** | Pure delegation to external API/SDK with zero logic | A method that just calls `httpClient.GetAsync()` |
| **Generated code** | Scaffold or boilerplate from a generator | `dotnet new`, code-gen output |

## Test Infrastructure Requirements

Every project with code should have:
- A test project (e.g., `ProjectName.Tests`) with xUnit (C#), pytest (Python), or vitest (TypeScript)
- The test project referenced in the solution/build system
- At minimum: unit tests for business logic, integration tests for service boundaries

## When Implementing a Service (TDD)

```
1. Create/verify test project exists
2. Create test file: ServiceNameTests.cs
3. Write test cases for the interface contract
4. Run tests → all should FAIL (red)
5. Implement the service
6. Run tests → all should PASS (green)
7. Refactor if needed → tests stay green
```
