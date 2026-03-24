# MCP Implementation Plan

## Goals
- Deliver Phase 1 (MVP) API for Decko-backed MCP: auth, types, core CRUD, search/list, and basic batch to replace SSH/Ruby scripts.
- Keep Decko naming/link semantics intact (`+` separators, `[[...]]` links).
- Enforce role-based access without `Card::Auth.as_bot` in runtime; use service accounts.

## High-Level Approach
1) **Module location**: Create `mod/mcp_api/` in `magi-archive` with controllers, serializers, and routes mounted under `/api/mcp`. Keep logic thin; reuse Decko models.
2) **Auth (Phase 1)**: Rails `MessageVerifier` bearer tokens, short TTL (15–60m), `role` + `api_key` claims; refresh on 401. Prepare JWT/JWKS upgrade for Phase 2.
3) **Service accounts**: Create `mcp-user`, `mcp-gm`, `mcp-admin` Decko accounts with scoped permissions; verify with `Card::Auth.as("...")` tests (runtime uses service account sessions; never `as_bot`).
4) **Core endpoints (Phase 1)**:
   - `POST /api/mcp/auth` — issue signed tokens (role + exp + api_key).
   - `GET /api/mcp/types` and `GET /api/mcp/types/:name` — type lookup.
   - `GET /api/mcp/cards/:name` — get metadata/content (role-filtered).
   - `POST /api/mcp/cards` — create (type by name; accepts `content` or `markdown_content` inline conversion).
   - `PATCH /api/mcp/cards/:name` — update; supports `replace_between` patch helper and simple replace; accepts `content` or `markdown_content`.
   - `DELETE /api/mcp/cards/:name` — admin-only delete (single-card) in Phase 1; batch delete deferred.
   - `GET /api/mcp/cards` — search with `q/prefix/not_name/type/updated_since/updated_before/limit/offset`.
   - `GET /api/mcp/cards/:name/children` — flat children listing with counts.
   - `POST /api/mcp/cards/batch` — simple per-item or transactional mode; supports `fetch_or_initialize`; optional children; no regex.
5) **Phase 2/3 staging**: Keep hooks for run_query (named templates), render endpoints, regex patch with guardrails, jobs (spoiler-scan), JWT/JWKS, optional attachments/export, batch dry-run/diff, higher admin batch limits/continuations, recursive children, related-card fetch, long-lived tokens, admin impersonation.

## Open Questions + Proposed Answers
- **Attachments**: Defer to Phase 2; add `POST /api/mcp/attachments` (admin/gm) with size/MIME caps and pointer to card. Not needed for initial script migrations.
- **Bulk delete**: Add admin-only `POST /api/mcp/cards/batch_delete` in Phase 2; Phase 1 omits destructive batch.
- **Card revision history**: Phase 2+: `GET /api/mcp/cards/:name/history` exposing Decko versions (id, editor, timestamps); not required for MVP.
- **Recursive children**: Keep flat in MVP; Phase 2 can add `recursive=true` with depth cap.
- **Batch limits**: MVP cap 100 ops; admin-only higher caps (e.g., 500) + continuation tokens in Phase 2.
- **Safety modes**: Add batch `dry_run`/`return_diff` and validation-only mode in Phase 2; `replace_between` gains `if_not_found: "error"|"skip"|"append"`.

## Work Breakdown (Phase 1)
- **Auth & Accounts**
  - Add `jwt` gem for future use; implement `MessageVerifier` tokens now.
  - Seed service accounts (idempotent rake task, e.g., `rake mcp:setup_roles`) and permissions; add smoke tests (fail for user on +GM; pass for gm/admin).
- **Routing & Controllers**
  - Mount `/api/mcp` routes; add controllers for auth, types, cards, batch, children, search.
  - Serialization: compact JSON with fields `{name,id?,type,codename?,content?,updated_at}`.
- **Types**
  - Service to map type name?id (cached); expose `common` flag for frequent types; document cache TTL/invalidation.
- **Cards**
  - Create/read/update with type-by-name resolution; support `content` passthrough and `markdown_content` conversion (Markdown?Decko-safe HTML: preserve `[[...]]`, escape script/style, normalize basic tags); keep `[[...]]` literal.
  - Patch helper `replace_between` with `end_inclusive` default false; reject regex in Phase 1.
- **Search/List**
  - Implement filters: `q` (contains), `prefix`, `not_name` (glob), `type`, `updated_since/before`, `limit/offset`; return `total` and `next_offset`.
  - Children: flat listing, preserving `+` hierarchy; include `child_count`/`depth`.
- **Batch**
  - Accept ops array; modes `transactional`|`per_item`; supports `fetch_or_initialize`; children allowed with short names prepended to parent; enforce caps (ops count, content length).
- **Safety/diagnostics (Phase 1/2 bridge)**
  - Plan for Phase 2: batch `dry_run` with optional `return_diff`, validation-only mode, admin higher caps and continuation tokens; `replace_between` `if_not_found` behavior toggle.
- **Error & Rate Limits**
  - Standard error envelope; 207 for mixed batch; rate-limit per API key/role; add Idempotency-Key support for writes; document rollback path (revert deploy or disable routes) if Phase 1 rollout issues occur.
- **Tests**
  - Controller/request specs for each endpoint; permission matrix (user/gm/admin); batch success/partial failure; patch helper; pagination.

## Implementation Sequence (Phase 1)
1) Accounts & permissions seeding task; smoke tests for role gates.
2) Auth endpoint with MessageVerifier tokens; middleware to resolve role/account.
3) Types endpoints with caching.
4) get_card/create/update + replace_between helper + DELETE.
5) search_cards and list_children.
6) batch (simple, no regex).
7) Pagination/rate limits/error envelope polish.
8) Integration tests (end-to-end) and staging deploy.

## Notes for Phase 2/3
- Swap auth to RS256 JWT + JWKS; keep claims identical.
- Add render endpoints, named queries (`/queries/...`), recursive children option, batch delete (admin), attachments, history endpoint, jobs (spoiler-scan), regex patch with guardrails/dry-run, batch dry-run/diff/validation-only, higher admin caps + continuation tokens, related-card fetch, admin impersonation, long-lived tokens option, health check, optional git/log/config read-only endpoints (if approved).
