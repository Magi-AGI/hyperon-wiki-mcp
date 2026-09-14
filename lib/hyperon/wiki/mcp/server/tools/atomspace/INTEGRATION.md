# AtomSpace Read Toolset — Integration Points

Canonical spec: Magi Archive card *…+Hyperon Wiki AtomSpace Mirror Implementation Plan+Level 9 -- Read API*
(the wiki is the source of truth; this file is an implementation pointer, not documentation).

Reflects POLICY REV4 (`McpApi::AtomspaceGrants`, deck repo
`mod/mcp_api/lib/mcp_api/atomspace_grants.rb`) and the dedicated-toolset decision of 2026-06-08
(Card 17184). Steps 1-2 previously carried REV3 allowlist-only wording and "append to the advertised
tool set"; both are retired. Pointer corrected 2026-09-14; no code changed.

These touch **shared auth infra** — review deliberately before wiring:

1. **JWT issuance (`oauth/token_issuer.rb` + rack_app `issue_token_response`)** — the gem's token carries
   `role` only and **no `scope` claim at all**; the `scope` string in the OAuth token *response* is
   derived (role→`mcp:read/write/admin`) and never enters the JWT. Add an explicit space-delimited
   `scope` claim. Do **not** restate the grant rule here: it is owned by `McpApi::AtomspaceGrants`
   (deck repo, POLICY REV4). REV4 in brief — `mcp:atomspace:read` is granted by an explicit
   `ATOMSPACE_READ_GRANTS` ENV allowlist entry, **or** automatically to an authenticated human
   admin / `Raw Data Analyst` principal. API-key principals are auto-granted nothing (allowlist
   only). `mcp:admin` is a **separate** scope, never implied by read scope.

2. **Tool-list visibility (rack_app `create_user_tools` / tools-list path)** — the eight tools form
   a **dedicated** toolset: registered **only** in the dedicated AtomSpace MCP toolset and **never**
   in the public Hyperon Wiki MCP tool list (Card 17184, decision 2026-06-08 — an acceptance
   criterion). Do **not** append them to the public advertised set, filtered or otherwise. The
   Space-global aggregates (`space_stats`, `atom_count_by_type`, `atom_types`) must not be surfaced
   through the public wiki MCP tools. Use `Registry.visible_for(token_scopes)` to build the
   *dedicated* list — the "hide" half of the hide + invoke-gate predicate. Step 3 is the other half
   and is not optional.

3. **Invocation enforcement (dispatch)** — call `Registry.gate!(tool, token_scopes)` before
   `tool.call(...)`. Visibility filtering alone is not enforcement.

4. **MagiTools (`Hyperon::Wiki::Mcp::Tools`)** — add 8 thin HTTP wrappers
   (`atomspace_query_atoms`, `atomspace_get_card_atom`, …) that POST to the deck endpoints
   `/api/mcp/atomspace_mirror/*` and return parsed JSON.

5. **Base rescue taxonomy** — extend `Atomspace::Base::TRANSPORT_ERRORS` with the gem's real
   `Client` transport error classes; keep it NARROW (no `rescue StandardError`).

Deck side (hyperon-wiki, separate branch): `Api::Mcp::AtomspaceMirrorController` + routes
`namespace :atomspace_mirror`, `Atomspace::ReadConsistencyPort` (L7 injection),
`Atomspace::ReadClient`/`SidecarReadClient` (read-IPC verb TODO).
