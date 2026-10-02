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

   **LANDED** as `Server::AtomspaceEntrypoint` (`server/atomspace_entrypoint.rb`): a dedicated
   JSON-RPC `tools/list` + `tools/call` path whose whole tool table is `Registry::TOOLS`, so a
   public Deck tool is not reachable through it at all. It prefers the **context-taking** seams
   (`visible_for_context` / `gate_for_context!`) over the array-taking pair named above, because a
   bare scope list cannot say whether the grant behind it is still fresh. Not yet mounted on an
   HTTP path or stdio transport — see step 6.

3. **Invocation enforcement (dispatch)** — call `Registry.gate!(tool, token_scopes)` before
   `tool.call(...)`. Visibility filtering alone is not enforcement.

   **LANDED** in the same entrypoint via `gate_for_context!`, which resolves the requirement from
   the **registered tool object** rather than the request's tool name, and runs before the deck is
   touched — so a denied call performs no read.

   **Denial surface (local contract).** An authenticated caller whose grant does not authorize the
   scope gets a JSON-RPC error, **not** HTTP 401: the transport exchange succeeded and the
   credential is valid, so "authenticate and retry" would be a lie and would loop the client over a
   decision that will not change. rack_app keeps 401 for the genuinely unauthenticated case.
   `AtomspaceEntrypoint::AUTHORIZATION_DENIED = -32002` is a local application code in the
   JSON-RPC implementation-defined server-error range (-32000..-32099), chosen rather than reused
   because rack_app already spends `-32001` on "Authentication required" / "Session not found".
   `tools/list` filters to an **empty list** instead of erroring (it is built for every caller);
   `tools/call` **denies**. Unknown-tool and method-not-found keep the gem's own codes, because
   those are routing facts and not authorization facts.

4. **MagiTools (`Hyperon::Wiki::Mcp::Tools`)** — add 8 thin HTTP wrappers
   (`atomspace_query_atoms`, `atomspace_get_card_atom`, …) that POST to the deck endpoints
   `/api/mcp/atomspace_mirror/*` and return parsed JSON.

5. **Base rescue taxonomy** — extend `Atomspace::Base::TRANSPORT_ERRORS` with the gem's real
   `Client` transport error classes; keep it NARROW (no `rescue StandardError`).

6. **Mounting the dedicated entrypoint (OPEN)** — `AtomspaceEntrypoint.handle` answers one parsed
   request object and is reached by no HTTP path or stdio transport yet. Mounting owns the concerns
   it deliberately does not: which host/path the dedicated toolset is served on, batched requests,
   notification suppression for an id-less request, session handling, and HTTP status mapping (the
   authorization denial is a 200-with-JSON-RPC-error, not a 403). Public Deck tools stay
   **scope-free** — none declares a `required_scope`, and nothing here invents one for them.

Deck side (hyperon-wiki, separate branch): `Api::Mcp::AtomspaceMirrorController` + routes
`namespace :atomspace_mirror`, `Atomspace::ReadConsistencyPort` (L7 injection),
`Atomspace::ReadClient`/`SidecarReadClient` (read-IPC verb TODO).
