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

   **LANDED (issuance half).** `TokenIssuer#issue` now takes `scope:` and signs an explicit
   space-delimited `scope` claim; `issue_token_response` computes the role-derived scope **once**,
   via `RackApp#scope_for_role`, and passes the same string to both the signature and the response
   body, so the two can no longer disagree. The claim is **taken, not derived** inside the issuer:
   mapping role→scope behind a signing key would hide an authorization decision from both the deck
   and a reader of rack_app. Nothing usable supplied ⇒ the claim is **omitted** rather than signed
   empty — an empty claim asserts "granted nothing", absence states "nothing was decided", and both
   fail closed for a reader (`Auth#scopes` answers `[]` either way). A client's *requested* scope is
   still ignored; the server's role-derived answer wins. The role→scope mapping itself is unchanged.

   **WHICH TOKEN FAMILY THIS IS, because the gem has two.** `OAuth::TokenIssuer` signs the gem's own
   **inbound** access tokens (the Bearer credential an MCP client presents; verified by rack_app's
   `verify_access_token`). `Auth#token` is a **different** credential fetched from the deck's `/auth`
   endpoint and verified against the deck's JWKS — and `Auth#scopes` / `Auth#read_grant` read *that*
   token's `scope` claim. So this change does **not** make `mcp:atomspace:read` reachable: that scope
   is signed deck-side under POLICY REV4, and neither the issuer nor `scope_for_role` may mint it
   (asserted in both new specs). `rack_app`'s `read_grant(required_scope: nil)` is unchanged.


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

   **LANDED** before this branch, in `64208ce` ("Lane C / L9: AtomSpace mirror agent tools (gem)"),
   as `tools.rb:63-105`. All eight exist and each `.compact`s its nil params away before the call.
   One correction to the wording above, which described an intent the code did not keep: they are
   `client.get` calls with query params, **not** POSTs. This step was stale, not open.

5. **Base rescue taxonomy** — extend `Atomspace::Base::TRANSPORT_ERRORS` with the gem's real
   `Client` transport error classes; keep it NARROW (no `rescue StandardError`).

   **LANDED.** The list this step asked to extend was not merely incomplete, it was **unreachable**:
   it named `Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, SocketError`, while `Client`
   is built on the `http` gem and both `Client#request` (`client.rb:296`) and `#get_raw`
   (`client.rb:209`) `rescue HTTP::Error => e` and re-raise `APIError, "HTTP request failed: …"`.
   No listed class could reach `rescue *TRANSPORT_ERRORS`; a dead mirror arrived at
   `rescue Client::APIError` with a **nil** `error_code`, missed `KNOWN_READ_ERRORS`, and was
   re-raised out of the tool. `HttpTimeouts::BudgetExhaustedError` (an `HTTP::TimeoutError`
   subclass, so wrapped identically) took the same path, which made the dispatch deadline's
   deliberate local refusal surface as an unhandled error.

   The taxonomy is now stated against what the client actually raises — `HTTP::ConnectionError`
   and `HTTP::TimeoutError`, which cover the socket and timeout subclasses plus
   `BudgetExhaustedError` by inheritance — and the `APIError` branch additionally matches on
   `Exception#cause` (`transport_wrapped?`), because the wrapper carries no status and no error
   code of its own. Matching the cause rather than the `"HTTP request failed"` string is
   deliberate: rewording that message must not silently un-handle every transport fault.

   **Still narrow, and the width is the whole point.** `HTTP::Error` itself is NOT rescued —
   `HTTP::RequestError` (unsupported scheme/method) and `HTTP::ResponseError` (state errors,
   redirect loops) are bugs in our own code, and widening to the parent would dress each one as
   "retry shortly". A JSON-parse-wrapped `APIError`, an unexpected-status `APIError`, and a 5xx
   without a Lane C code all still re-raise. `rescue StandardError` is still absent.

   **One message for two causes, on purpose.** A failing mirror and a spent dispatch budget are
   different events, but the agent's move is identical (retry; the next dispatch arrives with a
   fresh budget), so both answer `AtomSpace mirror service unavailable; retry shortly.` — worded
   as unavailability rather than remote fault, since a budget refusal never touches the network.

6. **Mounting the dedicated entrypoint (OPEN — blocked on product decisions, not on code)** —
   `AtomspaceEntrypoint.handle` answers one parsed request object and is reached by no HTTP path or
   stdio transport yet. Mounting owns the concerns it deliberately does not: which host/path the
   dedicated toolset is served on, batched requests, notification suppression for an id-less request,
   session handling, and HTTP status mapping (the authorization denial is a
   200-with-JSON-RPC-error, not a 403). Public Deck tools stay **scope-free** — none declares a
   `required_scope`, and nothing here invents one for them.

   **WHY THIS IS NOT YET IMPLEMENTABLE WITHOUT GUESSING.** Every existing transport pattern in this
   repo answers "serve the ONE public tool table", and none of them generalizes to a second,
   separately-authorized table:

   - **No host/path is specified anywhere.** `RackApp#call` dispatches on an exhaustive
     `[method, path]` `case`, and `HostAuthorization::ALLOWED_HOSTS` is a fixed six-entry allowlist
     (`127.0.0.1[:3002]`, `localhost[:3002]`, `mcp.hyperon.dev`, `dev-mcp.hyperon.dev`). The
     dedicated toolset needs either a new path on the existing host or a new host, and the choice is
     externally visible: `README-OPS.md` documents nginx proxying `mcp.hyperon.dev` → `127.0.0.1:3002`
     with the Host header rewritten, and `handle_root`'s advertised `endpoints` map plus
     `/.well-known/*` `scopes_supported` would both have to change. No ENV var, service file, nginx
     config, or doc in this repo names a second port, host, or path for AtomSpace.
   - **A path-mount would put a registry seam reference in `rack_app.rb`,** which is exactly the
     review trigger `spec/server/tools/atomspace/wiring_spec.rb` records ("a seam reference appearing
     in a THIRD file … most importantly in a public dispatch path, which is how the dedicated toolset
     would quietly become a filter on the public one"). That is a deliberate stop, not an obstacle to
     route around.
   - **Session, batch, and notification semantics cannot be inherited mechanically.** `RackApp`
     delegates all three to `MCP::Server#handle` → `JsonRpcHandler.handle`, which owns array/batch
     handling, hoists a single-element batch out of its array, drops id-less notifications by
     returning `nil`, and validates ids against `DEFAULT_ALLOWED_ID_CHARACTERS`.
     `AtomspaceEntrypoint.handle` answers one Hash and implements none of it. Reusing
     `JsonRpcHandler` directly, building a second `MCP::Server` whose tool table is `Registry::TOOLS`,
     or hand-rolling the batch/notification rules are three different designs with different
     blast radii — and a second `MCP::Server` reintroduces the shared-mutable-`server_context`
     problem `DISPATCH_LOCK` exists to solve, for a second server with its own lock.
   - **stdio has no authenticated principal at all.** `bin/mcp-server` builds one
     `StdioTransport` over the default identity with no Bearer token, no session, and no
     `read_grant`; a stdio AtomSpace entrypoint would have no `RequestContext` to pass and would
     either deny everything or need a new local-trust story.

   **DECISION NEEDED before this can land:** (a) host and path (new path on `mcp.hyperon.dev`, or a
   separate host/port that `ALLOWED_HOSTS` and nginx must learn); (b) whether the dedicated path is
   served by a second `MCP::Server` instance, by `JsonRpcHandler` over `AtomspaceEntrypoint`, or by
   the entrypoint growing its own batch/notification handling; (c) whether stdio is in scope at all,
   and if so what principal it runs as; (d) whether `/.well-known` discovery and `handle_root`
   advertise the dedicated endpoint publicly.


Deck side (hyperon-wiki, separate branch): `Api::Mcp::AtomspaceMirrorController` + routes
`namespace :atomspace_mirror`, `Atomspace::ReadConsistencyPort` (L7 injection),
`Atomspace::ReadClient`/`SidecarReadClient` (read-IPC verb TODO).
