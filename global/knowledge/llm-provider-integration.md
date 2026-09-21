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
