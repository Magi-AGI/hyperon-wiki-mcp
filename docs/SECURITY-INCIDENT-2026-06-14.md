# Security incident — unauthenticated access via privileged default identity (2026-06-14)

## Summary
The hosted MCP HTTP server served **unauthenticated** requests through a
**privileged default identity**, so anyone on the internet could read
restricted/GM wiki cards without logging in. Confirmed by a no-token request:

```
curl -s -X POST https://mcp.magi-agi.org -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call",
       "params":{"name":"get_card","arguments":{"name":"Games+Butterfly Galaxii+GM Docs"}}}'
# -> returned the full GM-only card content (HTTP 200)
```

It also caused the "the connector never prompts me to sign in" symptom: because
no-token requests returned `200` instead of `401`, Claude.ai connectors never
initiated the OAuth login flow.

## Root cause (three compounding factors — all in the MCP front-end)
The Decko permission layer itself is correct; it just enforces against whatever
account a request resolves to, and unauthenticated requests resolved to an admin.

1. **Privileged default identity.** `bin/mcp-server-rack-direct` builds a default
   `Tools.new` from env credentials and dispatches no-token requests through it
   (`lib/magi/archive/mcp/rack_app.rb`, the `mcp_server_instance.handle` branch).
   Production env pointed that default at a privileged service account
   (`mcp-admin@magi-agi.org` on MA via `.env`, which the gem's dotenv loaded with
   precedence over `.env.production`; `admin@hyperon.dev` + `MCP_ROLE=admin` on HW).
2. **Bypassed auth gate.** `OAUTH_REQUIRE_AUTH` is skipped for "localhost-origin"
   requests (`localhost_origin?`). The MA nginx vhost set
   `proxy_set_header Host 127.0.0.1:3002`, so **every** external request looked
   local and skipped the gate. (HW had the gate off entirely.)
3. **Served, not rejected.** No-token requests fell through to the privileged
   default identity instead of returning `401`.

## Fix (applied 2026-06-14)
- **Default identity → unprivileged `mcp-user`** (no roles) on MA prod + dev
  (`.env` and `.env.production`).
- **MA nginx** `sites-available/mcp-magi-agi`: `proxy_set_header Host 127.0.0.1:3002`
  → `proxy_set_header Host $host` (×3). Now external no-token requests are gated.
- **HW**: enabled `OAUTH_REQUIRE_AUTH=true` (its gate is not bypassed).
- Verified on all three: no-token request → `401` / "Authentication required";
  restricted card read denied; OAuth `register` + `/authorize` still serve the
  login page; the connector now prompts for Decko sign-in.

## Audit / blast radius
- `mcp-admin` write history (Decko acts): legitimate GM authoring only
  (Butterfly Galaxii campaign content), no malicious/injected edits.
- Reads are not logged by Decko. The MCP server logs tool calls (`search_cards` /
  `get_card`) to journald; available history showed only legitimate GM activity,
  but journald retention does not cover the full exposure window, so unauthorized
  reads in the older window cannot be ruled out.

## Regression protection added
- `spec/magi/archive/mcp/rack_app_auth_gate_spec.rb` — no-token external request
  → 401; `localhost_origin?` only true for genuine localhost (not a proxied Host).
- `scripts/smoke_test_auth_gate.sh` — deployment/monitor check: no-token request
  must be rejected and a restricted card must not be readable. Run after every
  MCP/nginx deploy. **This is the check that would have caught the nginx Host
  misconfiguration**, which unit tests cannot see.

## Open follow-ups
1. Rotate exposed credentials (`mcp-admin@magi-agi.org`, `admin@hyperon.dev`, and
   the owner account whose password sat in plaintext `.env`).
2. Set a persistent `OAUTH_SIGNING_KEY` (currently regenerated each boot, so
   tokens die on restart → connector keeps needing re-auth).
3. Remove the `"public-access"` fallback token and harden/remove the
   Host-header localhost bypass in `rack_app.rb` (give same-box callers a scoped
   token instead).
4. HW defense-in-depth: create an HW `mcp-user` and repoint its default identity.
5. Note: same-box callers hitting `127.0.0.1:3002` directly now resolve to the
   unprivileged `mcp-user` (not admin); any that needed elevated access must
   authenticate with their own token.
