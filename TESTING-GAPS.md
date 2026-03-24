# Integration Test Coverage Gaps

This document tracks which MCP tool methods have integration tests against the production server.

## Why Integration Tests Matter

- **Contract tests** (with WebMock) verify the client handles response formats correctly
- **Integration tests** verify the server actually implements endpoints correctly
- **Bug found**: `list_children` had passing contract tests but server threw `NoMethodError`

## Coverage Status

### ✅ Core Card Operations (Tested)
- [x] `get_card` - Full CRUD test
- [x] `create_card` - Full CRUD test
- [x] `update_card` - Full CRUD test
- [x] `delete_card` - Full CRUD test
- [x] `batch_operations` (per_item mode) - Batch operations test
- [ ] `batch_operations` (transactional mode) - Test exists, mode not implemented server-side
- [x] `spoiler_scan` - Spoiler scan test

### ⚠️ Known Server Bugs
- [ ] `list_children` - **SERVER BUG**: Returns `NoMethodError` (test skipped until fixed)

### ❌ Search & Query Operations (Not Tested)
- [ ] `search_cards` - No integration test
- [ ] `list_types` - No integration test

### ❌ Rendering Operations (Not Tested)
- [ ] `render_snippet` (HTML→Markdown) - No integration test
- [ ] `render_snippet` (Markdown→HTML) - No integration test

### ❌ Tag Operations (Not Tested)
- [ ] `search_by_tag` - No integration test
- [ ] `search_by_tags` - No integration test
- [ ] `get_all_tags` - No integration test
- [ ] `get_card_tags` - No integration test
- [ ] `search_by_tag_pattern` - No integration test
- [ ] `search_by_tags_any` - No integration test

### ❌ Relationship Operations (Not Tested)
- [ ] `get_referers` - No integration test
- [ ] `get_nested_in` - No integration test
- [ ] `get_nests` - No integration test
- [ ] `get_links` - No integration test
- [ ] `get_linked_by` - No integration test

### ❌ Validation Operations (Not Tested)
- [ ] `validate_card_tags` - No integration test
- [ ] `validate_card_structure` - No integration test
- [ ] `get_type_requirements` - No integration test
- [ ] `create_card_with_validation` - No integration test

### ❌ Admin Operations (Not Tested)
- [ ] `list_database_backups` - No integration test
- [ ] `delete_database_backup` - No integration test

### ❌ Weekly Summary Operations (Not Tested)
- [ ] `create_weekly_summary` - No integration test
- [ ] `get_recent_changes` - No integration test

## Priority for Adding Tests

### High Priority (Core API endpoints)
1. `search_cards` - Fundamental search operation
2. `render_snippet` - Content transformation
3. `list_types` - Type discovery
4. Tag operations - Content organization
5. Relationship operations - Graph navigation

### Medium Priority (Advanced features)
1. Validation operations - Data integrity
2. Weekly summary operations - Automated reporting

### Low Priority (Admin only)
1. Admin backup operations - Admin-only features

## How to Add Integration Tests

1. Add test to `spec/integration/full_api_integration_spec.rb`
2. Use `INTEGRATION_TEST=true` environment variable
3. Create and clean up temporary test cards
4. Test against actual production server response formats
5. If server bug found, skip test with clear description

## Example Test Pattern

```ruby
describe "Feature name" do
  let(:tools) { Magi::Archive::Mcp::Tools.new }

  it "tests the feature" do
    # Create test data
    test_card = tools.create_card("Test#{Time.now.to_i}", content: "Test", type: "RichText")

    # Test the endpoint
    result = tools.some_operation(test_card['name'])

    # Verify response
    expect(result).to have_key("expected_key")
    expect(result["status"]).to eq("success")

    # Cleanup
    tools.delete_card(test_card['name'])
  end
end
```

## Test Metrics

- **Total tools**: ~40 methods
- **Integration tests**: 8 (20%)
- **Known bugs**: 1 (list_children)
- **Target**: 100% coverage

## Related Files

- `spec/integration/full_api_integration_spec.rb` - Main integration test suite
- `spec/integration/contract_spec.rb` - Contract tests (mocked responses)
- `spec/support/integration_helpers.rb` - Test helpers

## Last Updated

2025-12-08 - Initial coverage audit after discovering `list_children` server bug
