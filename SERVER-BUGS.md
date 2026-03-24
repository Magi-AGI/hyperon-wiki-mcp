# Server-Side Bugs Found During Integration Testing

This document tracks bugs discovered in the `magi-archive` server (wiki.magi-agi.org) during MCP client integration testing.

## Summary Status

**All reported bugs have been resolved! ✅**

- **Bug #1**: `/cards/:name/children` 500 error - ✅ FIXED
- **Bug #2**: `/cards/batch` missing mode field - ✅ WORKAROUND (behavior correct)
- **Bug #3**: `/render` endpoints 404 error - ✅ FIXED

**Integration Test Results (as of 2025-12-11):**
- 132 examples passing ✅
- 0 failures
- 3 pending (expected - documented limitations)
- All MCP endpoints operational

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

## Recent Changes

**2025-12-11** - Updated summary: All bugs resolved, integration tests passing
**2025-12-08** - Added render endpoints bug after integration testing
**2025-12-08** - Documented initial server bugs found during integration testing
