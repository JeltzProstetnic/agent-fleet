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
**not required** for this path. The C# provider in `batch_langextract` is a *wire-protocol reference*,
not importable code — read it for the header/body shape and then write the client directly.

The practical consequence: do not let "it's on Azure" pull a cloud SDK, a credential chain and a
service principal into a project that needs one POST with one header.

---

## Outsourcing a job: `azure-ai.py` (CFG-861)

Owner decision 2026-10-28: the employer's projects and cfg-agent-fleet send context-free text jobs to the
employer's Foundry instead of spending Claude Code tokens. The rule arrives as `AZURE_AI:` at SessionStart,
only in trees listed in `setup/config/azure-ai-allowlist.txt`; the CLI refuses anywhere else.

```bash
python3 ~/cfg-agent-fleet/setup/scripts/azure-ai.py --prompt-file prompt.md \
    --input a.md --input b.txt [--system-file sys.md] [--out answer.md] [--max-tokens N]
```

- Answer → stdout (or `--out`); `model=… input_tokens=… output_tokens=…` → stderr.
- Inputs are appended in full inside `<file name="…">` tags; the model sees nothing else, so put
  every fact it needs in the prompt or an input. Check the answer before you use it.
- Model: `claude-opus-4-5`, the only deployment on the resource (weaker than the session model).
  Hence final creative prose stays with the writer subagent; Azure gets bulk and mechanical text.
- Never send personal data: the owner's profile, contacts, family or health, other private projects' content.
- Key: `~/.config/azure-ai/key`, written by `secrets/vault-manage.sh deploy` from vault key
  `azure_ai_foundry`. Exit 2 = config/usage (missing key, not allowlisted), 1 = provider error.

---

## Claude on Amazon Bedrock (Opus 4.7+) is the "Mantle" Messages endpoint

Source: competitor-radar WSL 2026-09-28, verified on platform.claude.com "Claude in Amazon Bedrock (Opus 4.7 and later)".
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

## Checklist for any new provider client

- [ ] Redirects refused, not followed, on every call that carries a credential.
- [ ] Endpoint validated (scheme + host) before the first request, not after a failure.
- [ ] Error text redacted **before** truncation.
- [ ] Key read from the vault or env, never a literal — see `knowledge/vault-ops.md`.
- [ ] The key never appears in output the terminal will render (it reaches the session log and the
      clipboard from there). Name where it is stored instead.
