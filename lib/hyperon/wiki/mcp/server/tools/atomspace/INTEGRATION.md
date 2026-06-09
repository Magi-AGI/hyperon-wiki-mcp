# AtomSpace Read Toolset — Integration Points (Lane C)

Canonical spec: Magi Archive card *…+Hyperon Wiki AtomSpace Mirror Implementation Plan+Level 9 -- Read API*
(the wiki is the source of truth; this file is an implementation pointer, not documentation).

These touch **shared auth infra** — coordinate with Chris (Lane A) before wiring:

1. **JWT issuance (`oauth/token_issuer.rb` + rack_app `scopes_for`)** — today the token carries
   `role` only; `scope` is derived (role→`mcp:read/write/admin`). Add an explicit space-delimited
   `scope` claim. `mcp:atomspace:read` must be a **deliberate grant** (per-account allowlist
   `AtomspaceGrants.granted?(account)`), NOT role-derived:
   `base_scopes_for(role) + (account && AtomspaceGrants.granted?(account) ? %w[mcp:atomspace:read] : [])`

2. **Tool-list visibility (rack_app `create_user_tools` / tools-list path)** — append
   `Registry.visible_for(token_scopes)` to the advertised tool set so principals without the
   scope never see the AtomSpace tools.

3. **Invocation enforcement (dispatch)** — call `Registry.gate!(tool, token_scopes)` before
   `tool.call(...)`. Visibility filtering alone is not enforcement.

4. **MagiTools (`Hyperon::Wiki::Mcp::Tools`)** — add 8 thin HTTP wrappers
   (`atomspace_query_atoms`, `atomspace_get_card_atom`, …) that POST to the deck endpoints
   `/api/mcp/atomspace_mirror/*` and return parsed JSON.

5. **Base rescue taxonomy** — extend `Atomspace::Base::TRANSPORT_ERRORS` with the gem's real
   `Client` transport error classes; keep it NARROW (no `rescue StandardError`).

Deck side (hyperon-wiki, separate branch): `Api::Mcp::AtomspaceMirrorController` + routes
`namespace :atomspace_mirror`, `Atomspace::ReadConsistencyPort` (Lane A L7 injection),
`Atomspace::ReadClient`/`SidecarReadClient` (Lane B read-IPC verb TODO).
