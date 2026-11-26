<!-- consumed-by: global/reference/mcp-catalog.md (provider auth patterns) -->

# LLM Provider Integration

Load when writing or reviewing code that calls a model provider directly — an HTTP client, a batch
extractor, a scraper that summarises, anything holding an API key. Measured on a customer-facing project
(WSL, 2026-09-20/21); both findings generalise to any fleet project that calls a model.

---

## Azure AI Foundry serves the NATIVE Anthropic Messages API

There is no Azure-shaped wrapper to learn and **no dependency to install**.

| | |
|---|---|
| Endpoint | `POST {endpoint}/v1/messages` |
| Headers | `x-api-key: <key>` and `anthropic-version: 2023-06-01` |
| Auth | The API key. **No OAuth, no Azure SDK, no `api-version` query parameter.** |

A working Python client is **~100 lines of stdlib `urllib`**. The `openai` and `azure-*` packages are
**not required** for this path. The C# provider in a fleet extraction project is a *wire-protocol reference*,
not importable code — read it for the header/body shape and then write the client directly.

The practical consequence: do not let "it's on Azure" pull a cloud SDK, a credential chain and a
service principal into a project that needs one POST with one header.

---

## Outsourcing a job: `azure-ai.py` (CFG-861)

Allowlisted projects send context-free text jobs to a Foundry deployment instead of spending Claude Code
tokens. The rule arrives as `AZURE_AI:` at SessionStart, only in trees listed in
`setup/config/azure-ai-allowlist.txt`; the CLI refuses anywhere else.

```bash
python3 ~/cfg-agent-fleet/setup/scripts/azure-ai.py --prompt-file prompt.md \
    --input a.md --input b.txt [--system-file sys.md] [--out answer.md] [--max-tokens N]
```

- Answer → stdout (or `--out`); `model=… input_tokens=… output_tokens=…` → stderr.
- Inputs are appended in full inside `<file name="…">` tags; the model sees nothing else, so put
  every fact it needs in the prompt or an input. Check the answer before you use it.
- Model: `claude-opus-4-5`, the only deployment on the resource (weaker than the session model).
  Hence final creative prose stays with the `writer` agent (Opus 4.6); Azure gets bulk and mechanical text.
- Never send personal data: the owner's profile, contacts, family or health, other private projects' content.
- Key: `~/.config/azure-ai/key`, written by `secrets/vault-manage.sh deploy` from vault key
  `azure_ai_foundry`. Exit 2 = config/usage (missing key, not allowlisted), 1 = provider error.

---

## Claude on Amazon Bedrock (Opus 4.7+) is the "Mantle" Messages endpoint

Source: a fleet project, WSL 2026-09-28, verified on platform.claude.com "Claude in Amazon Bedrock (Opus 4.7 and later)".
- Endpoint `https://bedrock-mantle.{region}.api.aws/anthropic/v1/messages`, header `anthropic-version: 2023-06-01`.
- Model ids `anthropic.<bare>` with **no geo prefix** (e.g. `anthropic.claude-opus-5-5`).
- Auth: SigV4 service `bedrock-mantle` (IAM `bedrock-mantle:CreateInference`), or a short-term token from
  `aws-bedrock-token-generator` sent in **`x-api-key`** — not `Authorization: Bearer`.
- Residency follows the endpoint region: `eu-central-1` is "Global, EU" (needs an EU inference profile to stay in
  the EU); only `eu-west-1` and `eu-north-1` are "In-region only" in the EU.
- Legacy `InvokeModel`/`Converse` on `bedrock-runtime` with ARN-versioned ids remains for Opus 4.6 and earlier.
- **Trap:** a research subagent confidently claimed bedrock-runtime + an `eu.` prefix + Bearer auth — all wrong for
  Mantle. Verify Bedrock specifics against that page, not model memory.

---

## ⚠ SECURITY: CPython's default opener re-sends `x-api-key` across a redirect

**Verified against a loopback server on CPython 3.12.** `urllib.request.HTTPRedirectHandler` follows
a 3xx and **re-sends every header you set — including the credential — to the redirect target**, even
when that target is a different host or a scheme downgrade.

So any credentialed call made with a default `urlopen` opener hands the key to whatever a 302 points
at: a captive portal, a typo'd hostname sitting behind a parking page, a corporate proxy that
redirects to an auth page. Nothing in the call site looks wrong, and the request succeeds.

**The fix is to refuse ALL 3xx on a credentialed API call**, not to filter by host:

```python
class _NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code,
                                     f"refusing redirect to {newurl}", headers, fp)

opener = urllib.request.build_opener(_NoRedirects)
```

Refusing outright is correct here because **Foundry never legitimately redirects `/v1/messages`**, and
because even a same-origin `307` re-sends both the credential *and* the request body. An allowlist of
"safe" redirect targets is a larger thing to get right than the zero-redirect rule it replaces.

**Redact before you truncate.** Server-supplied error text gets logged; if the truncation runs first,
a key straddling the cut survives into the log in two halves. Redact the full string, then truncate.

A worked implementation exists in the fleet under the names `_NoRedirects`, `validate_endpoint`
and `_redact` — grep for them if you want the tested version rather than the sketch above.

---

## JSON batches of translations break on native quotation marks

When an LLM returns a JSON object of translations, a language with its own quotation marks (German/Polish „…“) often closes them with a bare ASCII `"` inside a value. `json.loads` then fails and the whole batch is lost. Seen live 2026-10-29: Claude via Azure Foundry, 1 of 13 languages. Working fix:
1. Number the inputs (`{"1": text}`) and tell the model never to use ASCII `"` inside a value.
2. On `JSONDecodeError`, repair by escaping every `"` that has neither `{`, `,` or `:` before it nor `:`, `,` or `}` after it, ignoring spaces.
3. Re-validate each value after the repair.

Reference implementation: a fleet i18n project's `_repair()` helper.

---

## Claude Code headless as a program's brain (measured WSL 2026-11-25, CC 2.1.280)

Source: a fleet voice-assistant project's measurement log.
1. **`--bare` is unusable with subscription OAuth** — it accepts only `ANTHROPIC_API_KEY`/`apiKeyHelper`. Instead give
   the child a clean `CLAUDE_CONFIG_DIR` plus `CLAUDE_SECURESTORAGE_CONFIG_DIR=<mirror config dir>`: it borrows the
   fleet login without hooks or CLAUDE.md (~500-token requests).
2. **`ultrathink` no longer raises thinking under `--effort`** (332 vs 399 thinking tokens).
3. In `--input-format stream-json` mode, the control request
   `{type:"control_request", request:{subtype:"apply_flag_settings", settings:{effortLevel:"high"}}}` changes effort
   mid-session (control_response success); `set_max_thinking_tokens` is accepted but has no visible effect under `--effort`.
4. Opus 5.5 effort on one planning question: low 6.6 s / 480 thinking tokens, high 20 s / 1,650, xhigh 29 s / 2,100,
   max 268 s / 26,700.
5. Headless tool scoping that works: `--permission-mode dontAsk` + `--allowedTools 'Bash(<abs python> -m pkg *),Read(/<abs dir>/**),Edit(/<abs file>)'` + `--add-dir`.
6. **Start it OUTSIDE `$HOME`.** From a working directory under HOME it walks up and loads the fleet's global
   CLAUDE.md even with a clean `CLAUDE_CONFIG_DIR` (27k vs 5.7k tokens per request); a `/tmp/<app>` cwd avoids it.
7. **Under `dontAsk` the model writes compound Bash and every such call is refused** (`cd` first, shell variables,
   chained commands: 27 of 27 runs). Tell it in the system prompt: one command per Bash call, written exactly as shown.
8. **The `result` event's `usage` sums every API call of the turn** (a tool turn showed 81k against a real 28k context):
   take context size from the LAST assistant message's per-call usage.
9. The stream-json control request subtype `interrupt` ends a turn at once (next answer 0.8 s after a cancelled xhigh think).
10. **Effort, not prompt size, drives answer time:** a thinking question takes 5 s at low, 9 s at high, 30 s at xhigh,
    while a cached 100k–300k prompt adds ~0.3 s. MCP servers add ~3 s per process start and must stay deferred
    behind ToolSearch, or all their tools load up front (364 tools = 216k–300k tokens).

---

## Checklist for any new provider client

- [ ] Redirects refused, not followed, on every call that carries a credential.
- [ ] Endpoint validated (scheme + host) before the first request, not after a failure.
- [ ] Error text redacted **before** truncation.
- [ ] Key read from the vault or env, never a literal — see `knowledge/vault-ops.md`.
- [ ] The key never appears in output the terminal will render (it reaches the session log and the
      clipboard from there). Name where it is stored instead.
