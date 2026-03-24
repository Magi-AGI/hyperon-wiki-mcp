# MCP Service Specification

## Purpose & Scope
- Build a Model Context Protocol (MCP) service that gives Claude, Gemini, and Codex CLIs efficient, role-aware access to `wiki.magi-agi.org` (Decko).
- Replace ad-hoc SSH workflows with API-driven calls that minimize token use and centralize auth.
- Serve three roles: `user` (player view), `gm` (game-master-only content), `admin` (destructive actions like delete/move).

## High-Level Architecture
- **Decko App (magi-archive repo)**: Add a JSON API layer mounted under `/api/mcp` inside the Rails app.
  - Controllers reuse Decko card models; enforce role-based visibility before rendering.
  - Responses are compact JSON (no HTML) to reduce token/verbosity.
  - Authentication via RS256 JWTs issued by Decko and verified by the MCP server without round-trips.
  - Dependencies: add `jwt` (or equivalent) to Gemfile; expose JWKS for verification.
- Naming semantics: card names use `+` separators (parent+child+grandchild); preserve Decko wiki links (`[[Card+Name|Label]]`); endpoints must accept unencoded `+` and percent-encoded spaces. Preferred URL form: encode spaces, keep `+` literal (`Games+Butterfly%20Galaxii+Player`); accept fully encoded `+` (`%2B`) as well.
  - Wiki links: keep Decko `[[...]]` syntax literal in `content`/`markdown_content`; do not auto-convert to Markdown links.
- **MCP Server (magi-archive-mcp repo)**: Implements MCP protocol, forwards tool calls to the Decko API, and normalizes output for the three CLIs.
  - Tools exposed: `get_card`, `search_cards`, `create_card`, `update_card`, `delete_card` (admin only), `list_children`, `run_query` (limited CQL/filters), `upload_attachment` (role-checked), `render_snippet` (HTML→markdown-safe).
  - Enforces rate limits and payload size caps; truncates large responses with continuation tokens.
- **Auth Flow**: API key per agent/dev team (env `MCP_API_KEY`) + requested role (`user`/`gm`/`admin`). The Decko API issues a short-lived signed token bound to both the API key and the Decko account for that role.

## Authentication & Roles
- Store secrets in Decko `.env.production` (`MCP_API_KEY`, role account credentials or service tokens). Never ship keys in repos.
- Decko accounts:
  - `mcp-user` (player permissions; no GM-only visibility; no delete).
  - `mcp-gm` (can read GM content; no destructive ops).
  - `mcp-admin` (can delete/move; used sparingly).
- Role separation rules:
  - Only admin role can call `delete_card` or bulk ops.
  - GM-only cards are filtered out for `user` role; server hard-blocks cross-role escalation per request.

## API Surface (Decko side)
- `POST /api/mcp/auth` → returns short-lived RS256 JWT scoped to role and key. (MVP note: could ship with Rails signed bearer tokens first, then upgrade to JWT; keep claims/rotation plan ready.)
- `GET /api/mcp/cards/:name` → fetch card metadata/content with role-based filters.
- `GET /api/mcp/cards` → list/search with query params: `q` (name contains), `type`, `updated_since`, `limit/offset`. Phase 3: add `search_in` param (`name`|`content`|`both`) for content search.
- `POST /api/mcp/cards` → create; body: `name`, `type`, `content` (raw HTML) or `markdown_content` (server-converted), optional `fields`.
- `PATCH /api/mcp/cards/:name` → update content/fields; accepts `content` or `markdown_content`.
- `DELETE /api/mcp/cards/:name` → admin only.
- `GET /api/mcp/cards/:name/children` → list children/structure.
- `POST /api/mcp/render` → convert stored HTML to markdown-safe snippet (for chat display).
- `POST /api/mcp/render/markdown` → convert markdown to Decko-safe HTML for RichText cards; optional inline sanitization modes.
- `POST /api/mcp/cards/batch` → bulk create/update (atomic per card with partial failure reporting); no server-side templating—clients send explicit ops; type accepted by name (e.g., "RichText", "Pointer").
- `POST /api/mcp/jobs/spoiler-scan` → admin/GM-triggered job that scans for spoiler terms and writes results to a target card (replaces SSH spoiler-check script).
- `POST /api/mcp/run_query` → limited CQL search with enforced filters/limits; read-only.
- `GET /api/mcp/types` → list card types (name ↔ id); `GET /api/mcp/types/:name` → resolve type id by name for create/update convenience.
- All endpoints require `Authorization: Bearer <token>`; tokens expire (e.g., 15–60 minutes); refresh via auth endpoint using the API key.
  - Phase note: render endpoints can ship in Phase 2 if not needed for MVP; Phase 1 can focus on core CRUD/types/search/list/batch with inline `markdown_content` conversion on create/update/batch.

## MCP Server Behavior
- Implements MCP tool schema for the above endpoints; retries idempotent reads; surfaces concise errors.
- Streams large responses in chunks to reduce tokens; optionally returns summaries with `full=true` flag for follow-up fetches.
- Provides canned prompts/examples for each CLI client.

## Auth (RS256 JWT)
- Claims: `sub` (Decko account id), `role` (`user`/`gm`/`admin`), `iss` (`magi-archive`), `iat`, `exp` (15–60m), `jti` (nonce), `kid` (key id).
- Keys: server-side RSA key pair; expose JWKS or `/api/mcp/.well-known/jwks.json` for MCP verification; rotate keys with overlapping validity windows.
- Refresh: `POST /api/mcp/auth` with `MCP_API_KEY` + requested role issues new JWT; deny cross-role escalation.
- Validation: MCP server verifies signature, `exp`, `iss`, and `role`; Decko enforces permissions again per request.
- MVP option: start with Rails signed bearer tokens (MessageVerifier) if RS256 setup overhead delays delivery; design claims to match the JWT shape for drop-in upgrade. Example (MVP): `token = Rails.application.message_verifier(:mcp_auth).generate(role: "gm", api_key: "key_abc123", exp: 1.hour.from_now.to_i)`.

## run_query (CQL-limited)
- Allowed filters: `name` contains, `prefix` (e.g., `Games+Butterfly Galaxii+Player`), `not_name` (glob/regex like `*+GM*`), `type` equals, `updated_since`/`updated_before`, `tag` includes, `limit`/`offset`.
- Disallow/ignore: destructive views, raw SQL, pointer deref, and any content mutation.
- Caps: `limit` max 100; enforce timeouts; always return `total` and `next_offset` for pagination.
- Response: `{ items: [ { name, type, id, updated_at, summary? } ], total, next_offset }`.
- Optional: add named query templates (e.g., `/api/mcp/queries/faction_cards`) for common patterns to avoid exposing even limited CQL; can follow after MVP.

## cards/batch Payload & Errors
- Payload: `{ ops: [ { action: "create"|"update", name, type?: "RichText"|..., content?: "<p>..</p>", markdown_content?: "...", fields?: { "*type+*default": "..." }, children?: [{ name, type, content|markdown_content }], fetch_or_initialize?: true, patch?: {...} } ], mode?: "transactional"|"per_item" }`
- Behaviors:
  - `markdown_content` runs `render/markdown` server-side before save; `content` passes through (allow styled HTML when needed, e.g., spoiler highlights).
  - `children` optionally creates/updates known child cards (TOC, tags, AI/GM inclusions).
  - `fetch_or_initialize` mirrors `Card.fetch(name, new: {})` semantics; enables upsert-style flows without a separate fetch. If card exists: update with provided fields/content; if missing: create.
  - `mode` controls failure handling: `transactional` (all-or-nothing) vs `per_item` (partial success with per-op errors).
- Error model: per op `{ status: "ok"|"error", message?, validation_errors? }` plus overall HTTP 207 for mixed results.

## Update Helpers (section/regex)
- MVP safe helper: `{ patch: { mode: "replace_between", start_marker: "<h2>Associated Cultures</h2>", end_marker: "<h2>", replacement_html: "<h2>Associated Cultures</h2><p>...</p>", end_inclusive?: false } }`.
- Future (Phase 2): regex mode with guardrails (max pattern length, max_matches, optional dry_run preview).
- Preserve wiki links (`[[...]]`) and plus-card naming; avoid automatic link rewrites.
  - `end_inclusive`: false (default) replaces up to but not including `end_marker`; true replaces through the `end_marker`.

## jobs/spoiler-scan
- Input: `{ terms_card: "Games+...+spoiler terms", results_card: "Games+...+results", scope: "player|ai", limit?: 500 }`.
- Role: `gm` or `admin` only; respects GM visibility when writing results.
- Output: `{ status: "queued"|"completed", matches: n, results_card: name }`; job writes formatted HTML to `results_card`.

## Legacy SSH Use Cases → API Coverage
- Fetch/read cards and lengths (e.g., `fetch-*.rb`, `check-*.rb`, `list-major-factions.rb`): covered by `get_card`, `search_cards`, `list_children`.
- Massive create/update of lore cards (subcultures, bridges, TOCs, tags) across factions (`create-*`, `update-*`, `restructure-*`, `trim-*`): covered by `cards/batch` with markdown→HTML conversion; ensure type selection and child inclusions are parameters.
- GM visibility filters/tests (`test-gm-filter.rb`, spoiler checks): enforced server-side by role; `jobs/spoiler-scan` updates a results card without exposing GM content to `user` role.
- TOC/tag maintenance (`toc-verification`, `fix-*-tocs`, tag updates): include helpers in `cards/batch` to append/replace TOC HTML and pointer/tag content; add `list_children` with ordering metadata.
- Backups/imports (`magi_archive_backup_*.dump`): avoid arbitrary Ruby; optional admin endpoint to trigger read-only DB export/download link if needed (guarded and rate-limited).
- Content conversion (HTML/markdown artifacts in tmp): use `render/markdown` to prepare RichText-safe HTML; MCP can upload final content without server-side script uploads.
- Queries/searches (`spoiler-check.sh`, `check-*` scans): `search_cards` with filters (`q`, `type`, `updated_since`) and optional `case_sensitive`/`match_mode`; add `run_query` only for safe CQL fragments if required.
- Plus-card structure: all endpoints must accept and preserve Decko naming with `+` hierarchy; children/listing should reflect that structure.

## Operational & Safety Guards
- Limits: default `limit` 50 (max 100); batch `ops` max (e.g., 100) and max content size per item; rate-limit per API key.
- Pagination: `offset`/`next_offset` consistently across list/search/query endpoints.
- Idempotency: support `Idempotency-Key` on writes; prefer `If-Match`/ETag for updates to prevent clobbering.
- Errors: structured errors with codes (`validation_error`, `permission_denied`, `rate_limited`, `conflict`, `not_found`); HTTP 207 for mixed batch results.
- Sanitization: `render/markdown` sanitizes by default; allow a trusted mode for admins if needed. Preserve raw HTML when supplied via `content`. Decko-safe conversion preserves `[[...]]` links, escapes script/style tags, normalizes headers/paragraphs, and avoids auto-rewriting wiki links.
- Logging/Audit: log `role`, `card`, `action`, result, and duration; avoid logging content unless debug/admin mode is explicitly enabled.
- Env/config: document required env vars (`MCP_API_KEY`, JWT keys, base URL), staging/prod endpoints, JWKS cache TTL, key-rotation overlap, and clock-skew tolerance.

## Roles & Permissions Mapping
- Map MCP roles to Decko accounts: `mcp-user` (player), `mcp-gm` (GM read), `mcp-admin` (admin). Avoid `Card::Auth.as_bot` in API runtime; rely on per-role accounts and Decko permission checks.
- GM-only content must be filtered for `user` role; destructive actions (delete/move) restricted to `admin`.
- Decko account setup (pre-deploy):
  - Create service accounts `mcp-user`, `mcp-gm`, `mcp-admin`.
  - Grant permissions: `mcp-user` can read player-visible cards; cannot see +GM/+AI; cannot delete. `mcp-gm` can read GM; cannot delete/change permissions. `mcp-admin` full access (delete/move) with audit + rate limits.
  - Verify via: `Card::Auth.as("mcp-user") { Card.fetch("...+GM") }` should deny; `mcp-gm` should pass for GM; `mcp-admin` full access.

## Error Response Format (examples)
- Permission:
```json
{ "error": { "code": "permission_denied", "message": "Role 'user' cannot access GM content", "details": { "card": "Games+...+GM", "required_role": "gm" } } }
```
- Validation:
```json
{ "error": { "code": "validation_error", "message": "Card name contains invalid characters", "validation_errors": [ { "field": "name", "error": "cannot contain '/'" } ] } }
```
- Mixed batch (HTTP 207): `{ "results": [ { "status": "ok", "name": "Card1" }, { "status": "error", "name": "Card2", "message": "permission_denied" } ] }`

## list_children Behavior
- `GET /api/mcp/cards/{name}/children` returns `{ parent: name, children: [ { name, type, id? } ], depth?: int, child_count?: int }`, preserving `+` hierarchy order where applicable.

## Token Refresh Flow
- Standard: if token is near expiry, client pre-refreshes; if expired, API returns `401` with `WWW-Authenticate: Bearer error="expired"`; client re-requests `/api/mcp/auth` with API key and retries once.
- Optional headers: `X-Token-Expires-In` to hint refresh threshold (non-blocking).

## Phase Breakdown
- Phase 1 (MVP):
  - Auth: Rails signed tokens (MessageVerifier), short TTL; refresh-on-401.
  - Endpoints: `get_card`, `create_card`, `update_card` (simple replace or replace_between), `search_cards`, `list_children`, `types`.
  - Batch: simple array of ops (no regex, optional `fetch_or_initialize`, no children nesting if not needed).
  - Pagination and limits enforced; error formats as above.
- Phase 2:
  - Auth: RS256 JWT + JWKS; same claims.
  - Batch: children support, `fetch_or_initialize`, and safe `replace_between` helper; named query templates.
  - render/markdown; cards/batch with children; run_query (limited filters).
- Phase 3:
  - ✅ **Content search**: Enhance `search_cards` to search card content (not just names). Server-side: add `search_in` parameter (`name`, `content`, `both`); optional full-text indexing. Client-side: expose parameter in MCP tool with clear documentation of performance implications. **IMPLEMENTED**
  - ✅ **Health check endpoint**: Lightweight monitoring endpoints (`/health` and `/health/ping`) for checking wiki availability without authentication. **IMPLEMENTED**
  - ✅ **Tag suggestions tool**: AI-assisted tag suggestions based on content analysis and existing wiki tags. Promotes tag consistency and discovery. **IMPLEMENTED**
  - Regex patch mode with guardrails/dry-run.
  - jobs/spoiler-scan and other server-side jobs.
  - Advanced named queries; optional backups/export endpoint.

## cards/batch Examples
- Simple bulk create:
```json
{ "ops": [
  { "action": "create", "name": "Card1", "type": "RichText", "content": "<p>One</p>" },
  { "action": "create", "name": "Card2", "type": "RichText", "content": "<p>Two</p>" }
] }
```
- Upsert (fetch_or_initialize):
```json
{ "ops": [
  { "action": "create", "name": "Card+That+Might+Exist", "fetch_or_initialize": true, "content": "<p>Updated content</p>" }
] }
```
- Compound card with children (+* fields):
```json
{ "ops": [
  { "action": "create",
    "name": "verification_email",
    "type": "EmailTemplate",
    "children": [
      { "name": "*from", "type": "Phrase", "content": "noreply@wiki.magi-agi.org" },
      { "name": "*subject", "type": "Phrase", "content": "Verify your account" },
      { "name": "*html message", "type": "RichText", "content": "<p>Click {{_|verify_url}}</p>" }
    ]
  }
] }
```
- Section replacement (MVP helper):
```json
{ "ops": [
  { "action": "update",
    "name": "Existing+Card",
    "patch": {
      "mode": "replace_between",
      "start_marker": "<h2>Associated Cultures</h2>",
      "end_marker": "<h2>",
      "replacement_html": "<h2>Associated Cultures</h2><p>Updated...</p>"
    }
  }
] }
```

## Compound Cards & Fields
- Plus-cards for fields (`*from`, `*subject`, `+AI`, `+GM`) are created as children; `children` array in `cards/batch` or separate create calls.
- Children naming: when `children` names begin with `*` (e.g., `"*from"`), API prepends the parent (`verification_email+*from`). Clients may provide full names for non-child relationships.
- Preserve `[[...]]` links inside child content; no automatic rewrites.

## Type Endpoint Responses
- `GET /api/mcp/types/RichText`:
```json
{ "name": "RichText", "id": 32, "codename": "rich_text", "description": "Rich HTML content with wiki links", "common": true }
```
- `GET /api/mcp/types`:
```json
{ "types": [
  { "name": "RichText", "id": 32, "common": true },
  { "name": "Phrase", "id": 23, "common": true },
  { "name": "EmailTemplate", "id": 45, "common": false }
] }
```

## Pagination Example
- `GET /api/mcp/cards?q=Eclipser&limit=50&offset=0`:
```json
{ "cards": [ ...50 items... ], "total": 127, "next_offset": 50, "limit": 50 }
```
- Next page: `GET /api/mcp/cards?q=Eclipser&limit=50&offset=50`
- Search/list filters: `q` (contains), `prefix`, `not_name`, `type`, `updated_since`, `updated_before`, `limit`, `offset`.

## Open Questions
- Attachment handling: defer to Phase 2/3 or add upload endpoint?
- Bulk delete: add admin-only batch delete?
- ~~Card revision history: expose Decko versions via API?~~ → **Planned for Phase 4** (see Future Enhancements)
- Recursive children listing: keep flat for MVP; add recursive option later if needed.

## Future Enhancements (Phase 3+)

### Content Search
**Status**: ✅ **IMPLEMENTED** (Phase 3)

**Problem**: Current `search_cards` only searches card names (substring match), not content. This limits discoverability when users search for keywords that appear in card content but not in names.

**Proposed Solution**:
- **Server-side (Decko API)**:
  - Add `search_in` parameter to `GET /api/mcp/cards`: accepts `name` (default), `content`, or `both`
  - Implement content search using SQL `LIKE` or full-text indexing (PostgreSQL `tsvector`/`tsquery` for better performance)
  - Consider performance implications: content search may be slower, especially without indexing
  - Add optional `match_mode` parameter: `substring` (default), `whole_word`, `phrase`
  - Maintain role-based filtering (GM-only content not searchable by user role)

- **Client-side (MCP Server)**:
  - Expose `search_in` parameter in `search_cards` tool
  - Update tool description to clearly explain:
    - Default behavior (name-only search, fast)
    - Content search option (may be slower, more results)
    - Performance implications for large wikis
  - Add example usage in tool documentation

**Implementation Notes**:
- Consider adding `highlight` option to return matching snippets
- May need pagination adjustments (content search could return many more results)
- Security: ensure HTML tags in content don't cause issues with search queries
- Performance: consider caching or rate-limiting content searches

**Dependencies**: None (server-side change with client update)

**Estimated Effort**: Medium (2-3 days server + 1 day client)

**Implementation** (Completed Dec 2025):
- **Client**: magi-archive-mcp commit f79393d
  - Added `search_in` parameter to `Tools.search_cards` method
  - Exposed parameter in MCP `search_cards` tool with enum validation
  - Defaults to "name" for backward compatibility

- **Server**: magi-archive commit 0991d80
  - Modified `build_search_query` in `cards_controller.rb`
  - Supports `query[:content]` and `query[:or]` for Decko search
  - Role-based filtering maintained for all search modes

**Usage Example**:
```ruby
# Search card names only (default, fastest)
tools.search_cards(q: "species")

# Search card content only
tools.search_cards(q: "neural lace", search_in: "content")

# Search both names and content
tools.search_cards(q: "technology", search_in: "both")
```

###Health Check Endpoints
**Status**: ✅ **IMPLEMENTED** (Phase 3)

**Problem**: No way to monitor wiki availability or detect outages without making authenticated requests.

**Proposed Solution**:
- **Server-side (Decko API)**:
  - Add `GET /api/mcp/health` endpoint (full health check)
  - Add `GET /api/mcp/health/ping` endpoint (minimal check)
  - No authentication required for monitoring purposes
  - Check database connectivity and basic card access
  - Return structured health status with component checks

- **Client-side (MCP Server)**:
  - Add `health_check()` and `ping()` methods to Client class
  - Create health_check MCP tool for proactive monitoring
  - Support detailed vs quick health checks

**Implementation** (Completed Dec 2025):
- **Server**: magi-archive commit 29a3d59
  - Created HealthController with index and ping actions
  - Routes: GET /api/mcp/health and /api/mcp/health/ping
  - No authentication required
  - Returns status, timestamp, version, and component checks

- **Client**: magi-archive-mcp commit 18dcc52
  - Added health_check() and ping() to Client class
  - Created HealthCheck MCP tool
  - Supports detailed (full check) and quick (ping) modes

**Usage Example**:
```ruby
# Full health check
client.health_check
# => { "status" => "healthy", "timestamp" => "...", "checks" => {...} }

# Quick ping
client.ping
# => { "status" => "ok", "timestamp" => "..." }
```

### Tag Suggestions
**Status**: ✅ **IMPLEMENTED** (Phase 3)

**Problem**: Manual tag selection is tedious and leads to inconsistent tagging across the wiki.

**Proposed Solution**:
- Analyze card content, name, and type to suggest relevant tags
- Match keywords against existing wiki tags (not hard-coded)
- Promote tag reuse and consistency
- Show existing tags vs new suggestions

**Implementation** (Completed Dec 2025):
- **Client**: magi-archive-mcp commits 18dcc52, 361e434, ddc72da
  - Created SuggestTags MCP tool
  - Fetches all existing tags from wiki (up to 500)
  - Extracts keywords from content
  - Matches keywords to existing tags (fuzzy matching)
  - Considers card name hierarchy and type
  - Returns only tags that exist in the wiki

**Algorithm**:
1. Extract capitalized words from content (keywords)
2. Fetch all existing tags from wiki via get_all_tags
3. Fuzzy match keywords to existing tag names
4. Match card name parts (from + hierarchy) to existing tags
5. Match card type to existing tags
6. Return top N matched tags

**Usage Example**:
```ruby
# Suggest tags for existing card
suggest_tags(card_name: "Games+Butterfly Galaxii+Tech")

# Suggest tags for new content
suggest_tags(content: "<p>Advanced neural interface technology...</p>", type: "Technology")
```

### Card History & Restore (Phase 4)
**Status**: 🔄 **PARTIAL** (MCP client implemented, awaiting Decko API)

**Problem**: Deleted cards or overwritten content cannot be recovered via the API. AI agents occasionally delete virtual/junction cards by mistake, and there's no programmatic way to undo these actions. Currently, recovery requires manual intervention via the wiki's History tab.

**Background**: Decko maintains full revision history internally:
- `Card#acts` - All changes (create, update, delete) to a card
- `Card#actions` - Individual field-level changes within each act
- Cards are never truly deleted; they're moved to "trash" and can be restored
- Each revision stores the complete content state

**Proposed Solution**:

#### Server-side (Decko API)

**New Endpoints**:

1. `GET /api/mcp/cards/:name/history` - List card revisions
   ```json
   {
     "card": "Games+Butterfly Galaxii",
     "revisions": [
       {
         "act_id": 12345,
         "action": "update",
         "actor": "Nemquae",
         "acted_at": "2025-12-24T10:30:00Z",
         "changes": ["content"],
         "comment": null
       },
       {
         "act_id": 12340,
         "action": "create",
         "actor": "Nemquae",
         "acted_at": "2025-12-20T15:00:00Z",
         "changes": ["name", "type", "content"],
         "comment": "Initial creation"
       }
     ],
     "total": 2,
     "in_trash": false
   }
   ```

2. `GET /api/mcp/cards/:name/history/:act_id` - Get specific revision content
   ```json
   {
     "card": "Games+Butterfly Galaxii",
     "act_id": 12340,
     "acted_at": "2025-12-20T15:00:00Z",
     "actor": "Nemquae",
     "snapshot": {
       "name": "Games+Butterfly Galaxii",
       "type": "RichText",
       "content": "<p>Original content...</p>"
     }
   }
   ```

3. `POST /api/mcp/cards/:name/restore` - Restore card to a previous state
   - **Role**: `admin` only
   - **Body**: `{ "act_id": 12340 }` or `{ "from_trash": true }`
   ```json
   {
     "success": true,
     "card": "Games+Butterfly Galaxii",
     "restored_from": {
       "act_id": 12340,
       "acted_at": "2025-12-20T15:00:00Z"
     },
     "message": "Card restored to revision from 2025-12-20"
   }
   ```

4. `GET /api/mcp/trash` - List deleted cards (admin only)
   ```json
   {
     "cards": [
       {
         "name": "Test Card",
         "type": "Basic",
         "deleted_at": "2025-12-24T09:00:00Z",
         "deleted_by": "mcp-admin"
       }
     ],
     "total": 1
   }
   ```

#### Client-side (MCP Server)

**New Tools**:

1. `get_card_history` - View revision history for a card
   ```ruby
   tools.get_card_history("Games+Butterfly Galaxii")
   tools.get_card_history("Games+Butterfly Galaxii", limit: 10)
   ```

2. `get_revision` - Get content from a specific revision
   ```ruby
   tools.get_revision("Games+Butterfly Galaxii", act_id: 12340)
   ```

3. `restore_card` - Restore card to previous state (admin only)
   ```ruby
   # Restore to specific revision
   tools.restore_card("Games+Butterfly Galaxii", act_id: 12340)

   # Restore from trash (undelete)
   tools.restore_card("Accidentally Deleted Card", from_trash: true)
   ```

4. `list_trash` - List deleted cards (admin only)
   ```ruby
   tools.list_trash(limit: 50)
   ```

**MCP Tool Definitions**:

```ruby
# get_card_history
input_schema(
  properties: {
    name: { type: "string", description: "Card name" },
    limit: { type: "integer", default: 20, maximum: 100 }
  },
  required: ["name"]
)

# restore_card
input_schema(
  properties: {
    name: { type: "string", description: "Card name to restore" },
    act_id: { type: "integer", description: "Revision ID to restore to" },
    from_trash: { type: "boolean", description: "Restore deleted card from trash" }
  },
  required: ["name"]
)
```

**Implementation Notes**:

- **Decko internals**: Use `Card#acts`, `Card#actions`, and `Act#card_actions` for history
- **Trash recovery**: Use `Card.where(trash: true)` and `card.update!(trash: false)` to restore
- **Revision restore**: Create new act that copies content from historical action
- **Performance**: History queries should be indexed on `card_id` and `acted_at`
- **Security**: History is role-aware; GM-only cards' history is hidden from user role
- **Audit**: All restore operations logged with actor, source revision, and timestamp

**Use Cases**:

1. **Accidental deletion recovery**: AI agent mistakenly deletes a virtual card; admin uses `restore_card(name, from_trash: true)` to recover
2. **Content rollback**: Bad edit overwrites important content; use `get_card_history` to find good revision, then `restore_card(name, act_id: X)`
3. **Audit trail**: Review who changed a card and when using `get_card_history`
4. **Trash cleanup**: Admin reviews `list_trash` to permanently delete or restore old cards

**Dependencies**:
- Decko's built-in versioning system (acts/actions tables)
- Admin role for restore operations

**Estimated Effort**:
- Server-side: 3-4 days (controllers, serializers, tests)
- Client-side: 2 days (tools, MCP definitions, tests)

**Priority**: High - Prevents data loss from AI agent mistakes

**Implementation Status** (Dec 2025):
- **MCP Client** (magi-archive-mcp): ✅ Implemented
  - `Tools#get_card_history(name, limit:)` - Get revision history
  - `Tools#get_revision(name, act_id:)` - Get specific revision content
  - `Tools#restore_card(name, act_id: nil, from_trash: false)` - Restore card
  - `Tools#list_trash(limit:, offset:)` - List deleted cards
  - MCP tools: `get_card_history`, `get_revision`, `restore_card`, `list_trash`
  - Unit tests and integration tests added
- **Decko API** (magi-archive): ⏳ Pending implementation
  - Requires new controllers for history endpoints
  - Must expose Card#acts and Card#actions data
  - Trash restoration needs Card.where(trash: true) access

### Virtual Card Detection (Phase 4)
**Status**: 🔄 **PARTIAL** (client-side detection implemented, API enhancement pending)

**Problem**: AI agents sometimes delete virtual/junction cards (empty compound cards like `Games+Butterfly Galaxii`) mistaking them for orphaned content. These cards are essential structural elements in the wiki hierarchy.

**Current Solution** (Client-side, implemented Dec 2025):
- MCP `get_card` tool detects virtual cards by checking:
  1. Card name contains `+` (compound/junction card)
  2. Card content is empty or whitespace only
- Displays prominent `**Virtual Card:** ⚠️ YES` warning in response
- Adds detailed explanation advising not to delete

**Proposed Enhancement** (Server-side):
- Add `virtual_card: true|false` field to card responses from Decko API
- Decko can detect more accurately using:
  ```ruby
  card.virtual? || (card.compound? && card.content.blank? && card.children.any?)
  ```
- More reliable than client-side heuristics

**API Changes**:
```json
// GET /api/mcp/cards/:name response
{
  "name": "Games+Butterfly Galaxii",
  "type": "Basic",
  "content": "",
  "virtual_card": true,  // NEW FIELD
  "child_count": 15      // Optional: helps determine if card is structural
}
```

**Dependencies**: Decko API update

**Estimated Effort**: 1 day (server-side addition)

## Security & Auditing
- HTTPS only; lock API to known IPs/SGs if possible.
- Log role, card name, verb, and outcome; redact content in logs by default (toggleable for admin debug).
- Rate-limit per API key; cap pagination (e.g., max 100 items).
- CSRF not required (API-token based), but include replay protection via exp/nonce in tokens.

## Migration Steps (two repos)
- **magi-archive**: Add `/api/mcp` controllers/serializers, auth middleware, service accounts, env keys, and tests; wire to Decko permission checks.
- **magi-archive-mcp**: Implement MCP server with configurable API base URL/key, tool definitions, pagination handling, and integration tests against staging.
- Document onboarding: how to request an API key, select role, and run sample CLI calls.
