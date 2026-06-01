# Server-Side Bugs Found During Integration Testing

This document tracks bugs discovered in the `magi-archive` server (wiki.magi-agi.org) during MCP client integration testing.

## Summary Status

- **Bug #1**: `/cards/:name/children` 500 error - ✅ FIXED
- **Bug #2**: `/cards/batch` missing mode field - ✅ WORKAROUND (behavior correct)
- **Bug #3**: `/render` endpoints 404 error - ✅ FIXED
- **Bug #4**: `create_card` spurious "already exists" after successful create - ⚠️ OPEN (filed 2026-04-25)
- **Bug #5**: `restore_card` cannot find `+tag` Pointer subcards in trash - ⚠️ OPEN (filed 2026-04-25)

**Integration Test Results (as of 2025-12-11):**
- 132 examples passing ✅
- 0 failures
- 3 pending (expected - documented limitations)
- All MCP endpoints operational

Bugs #4 and #5 surface only in cluster-pilot wiki-edit workflows (heavy create_card / restore_card usage on `+tag` Pointer subcards) and have client-side workarounds documented below.

## Bug #1: `/cards/:name/children` Endpoint Returns NoMethodError ✅ FIXED

**Severity**: HIGH
**Impact**: `list_children` API completely unusable
**Status**: ✅ FIXED in commit 55685de - Now uses left_id foreign key queries

### Description

The `/cards/:name/children` endpoint returns HTTP 500 with `NoMethodError` exception for all requests, regardless of card name format.

### Reproduction

```bash
# Using integration tests
INTEGRATION_TEST=true bundle exec rspec spec/integration/debug_list_children_spec.rb
```

### Test Results

All card name formats fail:
- ❌ Simple names: `Home` → NoMethodError
- ❌ Names with spaces: `Main Page` → 404 Not Found (expected) or NoMethodError
- ❌ Compound names: `Games+Butterfly Galaxii` → NoMethodError
- ❌ Newly created cards: `DebugParent1234567` → NoMethodError

### Expected Behavior

The endpoint should return:
```json
{
  "parent": "CardName",
  "children": [
    {
      "name": "CardName+Child1",
      "content": "...",
      "type": "RichText",
      "id": 123
    }
  ],
  "child_count": 1,
  "depth": 1,
  "limit": 50,
  "offset": 0
}
```

### Actual Behavior

```json
{
  "code": "internal_error",
  "message": "An unexpected error occurred",
  "details": {
    "exception": "NoMethodError"
  }
}
```

### Server Logs Needed

Please check Rails logs for the actual NoMethodError message and stack trace.

### Client-Side Workaround

None available. The MCP client integration test for `list_children` is skipped until this is fixed:

```ruby
it "lists children of a parent card", skip: "Server returns NoMethodError - needs server-side fix" do
  # Test implementation
end
```

### Related Files

- **Client test**: `spec/integration/full_api_integration_spec.rb:158`
- **Debug test**: `spec/integration/debug_list_children_spec.rb`
- **Contract test** (passes with mocked response): `spec/integration/contract_spec.rb:76`

### Suggested Fix

The endpoint is likely missing implementation or has a typo in the controller. Check:

1. **Routing**: Is `/api/mcp/cards/:name/children` properly routed?
2. **Controller**: Does the controller action exist and is it calling the correct method?
3. **Decko Card API**: Is there a method name mismatch (e.g., `children` vs `kids` vs `child_cards`)?

### Priority

**HIGH** - This is a documented MCP endpoint that should be functional. The contract test shows the expected format is correct; the server implementation is broken.

---

## Bug #2: `/cards/batch` Missing `mode` Field in Response

**Severity**: LOW
**Impact**: Response doesn't include requested mode, but behavior is correct
**Status**: Workaround implemented

### Description

When calling `/cards/batch` with `mode: "transactional"`, the server correctly implements transactional behavior (rollback on failure) but doesn't include the `mode` field in the response.

### Reproduction

```ruby
result = tools.batch_operations(operations, mode: "transactional")
# result["mode"] is nil, not "transactional"
```

### Expected Behavior

```json
{
  "results": [...],
  "mode": "transactional",
  "total": 2,
  "succeeded": 0,
  "failed": 2
}
```

### Actual Behavior

```json
{
  "results": [...],
  "total": 2,
  "succeeded": 0,
  "failed": 2
}
```

Note: The `mode` field is missing, but transactional rollback DOES work correctly.

### Workaround

The client test verifies transactional behavior by checking that rolled-back cards don't exist:

```ruby
# Don't check mode field, verify behavior instead
expect {
  tools.get_card("#{batch_prefix}_good")
}.to raise_error(Magi::Archive::Mcp::Client::NotFoundError)
```

### Priority

**LOW** - Behavior is correct, just missing response field. Not blocking.

---

## Testing Process

### Integration Test Coverage

As of 2025-12-08:
- **12/12 functional tests passing** (100%)
- **2 pending tests** (documented above)
- **6 retry logic unit tests** added (all passing)

### How Bugs Were Found

1. **Contract tests** (mocked responses) passed ✅
2. **Integration tests** (real server) failed ❌
3. **Lesson**: Contract tests verify client correctness, integration tests verify server correctness

### Recommendation

Add server-side integration tests for the MCP API endpoints to catch these issues before client testing.

---

## Contact

For questions about these bugs, see:
- **Client implementation**: `magi-archive-mcp` repository
- **Server implementation**: `magi-archive` repository
- **MCP Specification**: `MCP-SPEC.md`

## Bug #3: `/render` and `/render/markdown` Endpoints Return 404 ✅ FIXED

**Severity**: HIGH
**Impact**: Content transformation completely unavailable
**Status**: ✅ FIXED in commit 55685de

### Description

The `/render` and `/render/markdown` endpoints return HTTP 404 (Not Found), indicating these endpoints are not implemented on the server despite being documented in the MCP specification.

### Reproduction

```ruby
# All render operations return 404
tools.render_snippet(html_content, from: :html, to: :markdown) # 404
tools.render_snippet(markdown_content, from: :markdown, to: :html) # 404
```

### Expected Behavior

**POST /render** (HTML→Markdown):
```json
{
  "markdown": "# Hello\n\nThis is **bold**.",
  "format": "gfm"
}
```

**POST /render/markdown** (Markdown→HTML):
```json
{
  "html": "<h1>Hello</h1><p>This is <strong>bold</strong>.</p>",
  "format": "html"
}
```

### Actual Behavior

```
HTTP 404 Not Found
```

### Client-Side Impact

- Content transformation unavailable
- MCP tools cannot convert between HTML and Markdown
- Contract tests pass (mocked responses), but integration tests fail
- 3 integration tests failing due to this bug

### Server Action Required

Implement the `/api/mcp/render` and `/api/mcp/render/markdown` endpoints as specified in MCP-SPEC.md.

### Priority

**HIGH** - This is a documented MCP endpoint that should be functional. Content transformation is a core feature.

---

## Bug #4: `create_card` Returns Spurious "already exists" After Successful Create ⚠️ OPEN

**Severity**: MEDIUM
**Impact**: Forces every `create_card` caller to follow up with `get_card` to determine real state.
**Status**: ⚠️ OPEN — filed via `submit_feedback` 2026-04-25 during the Hyperon Wiki PLN cluster pilot.

### Description

`create_card` can return a validation error along the lines of "card already exists" *after* the card has actually been written successfully. The card is present in the wiki when looked up immediately afterward, with the expected content and ID.

### Reproduction context

Encountered repeatedly while creating new RawData parents and `+tag` Pointer subcards during the PLN, ECAN, OpenPsi, and AtomSpace Backend Integration cluster pilots (2026-04-08 through 2026-04-29). Not consistently reproducible from a clean state — appears to be a race or post-write validation pass that fires after the underlying create has already committed.

### Workaround

Treat the error as advisory rather than authoritative: always verify with `get_card` before retrying or aborting. If `get_card` returns the expected content, the create succeeded and the error can be ignored.

---

## Bug #5: `restore_card` Cannot Find `+tag` Pointer Subcards in Trash ⚠️ OPEN

**Severity**: MEDIUM
**Impact**: `restore_card` workflow is broken for tag pointers; callers must fall back to `create_card`.
**Status**: ⚠️ OPEN — filed via `submit_feedback` 2026-04-25 during the Hyperon Wiki PLN cluster pilot.

### Description

`restore_card` returns "not found" for `+tag` Pointer subcards even though `list_trash` shows them present. Other cardtypes restore from trash without issue under the same caller; only the Pointer-cardtype `+tag` children are affected.

### Reproduction context

Encountered while attempting to undo accidental deletes of `+tag` subcards on Draft `+AI` proposal parents during cluster-pilot wiki edits.

### Workaround

Use `create_card` to recreate the `+tag` subcard with the original content (typically a single `ai_generated` line). The `create_card` succeeds despite Bug #4's spurious error — verify with `get_card` afterward.

---

## Operational conventions discovered during cluster-pilot edits

The following are **not bugs** but are non-obvious server behaviors that future MCP clients (and orchestrating agents) should know about. Captured here so they live next to the MCP server code rather than only in the wiki repo's CLAUDE.md.

### `+tag` plural-alias normalization

The wiki normalizes trailing-`s` plurals on tag subcards: `<parent>+tag` and `<parent>+tags` resolve to the same card. The canonical form is singular `+tag`. The Pointer cardtype expects plain newline-separated tag strings (e.g., `ai_generated`), not JSON arrays.

### Draft parents auto-generate empty `+tag` subcards

When a Draft cardtype parent is created, the wiki creates an empty `+tag` Pointer subcard automatically. Callers that need to populate tags should use `update_card` on the existing `+tag` rather than `create_card` (which would race the auto-generation).

### Published vs Draft edit semantics

- Draft cardtype: edit directly via `update_card`.
- Published cardtype: requires a `+AI` Draft child carrying the proposed diff — direct `update_card` against the Published parent is rejected by the server.

### Concurrent-write protocol (orchestrator-side, not server-side)

Cluster-pilot wiki edits are run with these client-side rules to keep the audit trail clean:

- **One writer only**: the orchestrating model executes `create_card` / `update_card` / `delete_card`. Advisory models do not write wiki state, even when invited to.
- **Sequential calls, no parallel batches** for wiki writes.
- **Verify after every write**: `get_card` immediately after `create_card` / `update_card` to confirm the change landed (and to disambiguate Bug #4's spurious "already exists").
- **Maintain an audit trail**: name, cardtype, returned result, verified ID, timestamp for each write.

These conventions originated in the `hyperon-wiki` repo's cluster-pilot orchestration; they are MCP-client-side discipline, not server enforcement.

---

## Recent Changes

**2026-04-29** - Added Bugs #4 and #5 plus operational-conventions section from cluster-pilot wiki edits (PLN/ECAN/OpenPsi/AtomSpace pilots, 2026-04-08 through 2026-04-29)
**2025-12-11** - Updated summary: All bugs resolved, integration tests passing
**2025-12-08** - Added render endpoints bug after integration testing
**2025-12-08** - Documented initial server bugs found during integration testing
