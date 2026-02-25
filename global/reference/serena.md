# Serena MCP Server — Context-Efficient Code Navigation

**Serena provides semantic/symbolic code analysis that is dramatically more context-efficient than reading entire files.** Use Serena's tools whenever you need to understand code structure without consuming context on irrelevant lines.

---

## When to Use Serena

| Task | Use Serena | Use Read/Grep |
|------|-----------|---------------|
| Understand a class's API (methods, fields) | `get_symbols_overview` or `find_symbol` with `include_body=False` | No |
| Read a specific method body | `find_symbol` with `include_body=True` | No |
| Find all callers of a function | `find_referencing_symbols` | No |
| Edit a method/class body | `replace_symbol_body` | No |
| Add code before/after a symbol | `insert_before_symbol` / `insert_after_symbol` | No |
| Rename a symbol across codebase | `rename_symbol` | No |
| Read a non-code file (config, markdown) | No | `Read` |
| Search for a string pattern | `search_for_pattern` (faster) | `Grep` (also fine) |
| Explore directory structure | `list_dir` | `Glob` (also fine) |

---

## Key Tools

- **`activate_project`** — Must call first with project path before using other tools
- **`get_symbols_overview`** — List all symbols in a file (classes, methods, fields) without reading bodies
- **`find_symbol`** — Search for symbols by name pattern. Use `include_body=True` only when you need the implementation
- **`find_referencing_symbols`** — Find all code that references a symbol (callers, importers, etc.)
- **`replace_symbol_body`** — Edit a symbol's implementation precisely
- **`insert_before_symbol`** / **`insert_after_symbol`** — Add new code adjacent to existing symbols
- **`rename_symbol`** — Rename across the entire codebase
- **`search_for_pattern`** — Regex search (like Grep but integrated with Serena's project context)
- **`list_dir`** — List directory contents within the activated project

---

## Context Savings Example

**Without Serena** (reading a 500-line file to understand one class):
- `Read file.cs` -> 500 lines consumed in context

**With Serena** (targeted symbol navigation):
- `get_symbols_overview file.cs` -> ~20 lines (just names and signatures)
- `find_symbol "ClassName/MethodName" include_body=True` -> ~15 lines (just that method)
- Total: ~35 lines vs 500 lines = **93% context savings**

---

## Rules

1. **Always activate the project first** with `activate_project` before using Serena tools
2. **Prefer `include_body=False` first** to understand structure, then `include_body=True` for specific methods you need
3. **Use `find_referencing_symbols` before editing** to understand impact of changes
4. **Use symbolic editing tools** (`replace_symbol_body`, `insert_after_symbol`) for precise code modifications
5. **Fall back to Read/Edit** only for non-code files or when Serena's project isn't activated

---

## Server Configuration

| Field | Value |
|-------|-------|
| **Package** | `serena-mcp-server` (via `uvx` from git) |
| **Command** | `uvx --from git+https://github.com/oraios/serena serena-mcp-server --context claude-code --open-web-dashboard False` |
| **Config location** | `.mcp.json` (server name: `serena`) — vanilla: `~/.mcp.json`, cc-mirror: `~/.cc-mirror/<variant>/config/.mcp.json` |
| **Auth** | None (local tool) |
| **Env vars** | `PATH` and `DOTNET_ROOT` for .NET support |

---

## When NOT to Use Serena

- Pure authoring sessions (no code) — Serena tools in context are wasted tokens
- Reading non-code files (config, markdown, YAML) — use `Read` instead
- When you need raw text search without project activation — use `Grep`
