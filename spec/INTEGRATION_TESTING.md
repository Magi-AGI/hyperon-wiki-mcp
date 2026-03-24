# MCP Client Integration Testing Guide

This document explains how to run integration tests for the Magi Archive MCP client.

## Test Types

### 1. Unit Tests
**Location**: `spec/magi/archive/mcp/`
**Purpose**: Test individual classes with mocked HTTP requests
**Run**: `bundle exec rspec spec/magi/`

### 2. Integration Tests ⭐ NEW
**Location**: `spec/integration/`
**Purpose**: Test against actual running server
**Catches**: Real HTTP errors, authentication issues, API contract violations

## Running Integration Tests

### Prerequisites

1. **Start the MCP server**:
```bash
cd ../magi-archive
bundle exec rails server -p 3000
```

2. **Create test user** (in Rails console):
```ruby
# In magi-archive directory
bundle exec rails console

# Create test user
user = Card.create!(
  name: "test@example.com",
  type_id: Card.fetch_id("User")
)

# Set password
password_card = user.fetch(trait: :password, new: {})
password_card.content = BCrypt::Password.create("password123")
password_card.save!
```

### Run Integration Tests

```bash
# Enable integration tests and run
INTEGRATION_TEST=true bundle exec rspec spec/integration/

# Or with custom server URL
TEST_API_URL=https://wiki.magi-agi.org/api/mcp \
TEST_USERNAME=your_email@example.com \
TEST_PASSWORD=your_password \
INTEGRATION_TEST=true \
bundle exec rspec spec/integration/
```

### Run Integration Tests Against Production

```bash
TEST_API_URL=https://wiki.magi-agi.org/api/mcp \
TEST_USERNAME=your_email@example.com \
TEST_PASSWORD=your_password \
INTEGRATION_TEST=true \
bundle exec rspec spec/integration/
```

## What Integration Tests Catch

| Error Type | Unit Tests | Integration Tests |
|------------|------------|-------------------|
| Logic bugs | ✅ | ✅ |
| Mocked behavior mismatch | ❌ | ✅ |
| Real API errors | ❌ | ✅ |
| Authentication flow issues | ⚠️ | ✅ |
| Network/timeout issues | ❌ | ✅ |
| Actual server errors | ❌ | ✅ |
| API contract violations | ❌ | ✅ |
| Real database constraints | ❌ | ✅ |

## Integration Test Examples

### Full CRUD Flow
```ruby
it "creates, reads, updates, and deletes a card" do
  tools = Magi::Archive::Mcp::Tools.new

  # Create
  result = tools.create_card("TestCard", content: "Test", type: "Basic")
  expect(result["name"]).to eq("TestCard")

  # Read
  card = tools.get_card("TestCard")
  expect(card["content"]).to include("Test")

  # Update
  updated = tools.update_card("TestCard", content: "Updated")
  expect(updated["content"]).to include("Updated")

  # Delete
  tools.delete_card("TestCard")
  expect { tools.get_card("TestCard") }.to raise_error(NotFoundError)
end
```

### Batch Operations
```ruby
it "creates multiple cards in one request" do
  operations = [
    { action: "create", name: "Card1", content: "Test", type: "Basic" },
    { action: "create", name: "Card2", content: "Test", type: "Basic" }
  ]

  result = tools.batch_operations(operations)
  expect(result["results"].size).to eq(2)
end
```

## Environment Variables

### Required for Integration Tests
- `INTEGRATION_TEST=true` - Enable integration tests
- `TEST_API_URL` - Server URL (default: `http://localhost:3000/api/mcp`)
- `TEST_USERNAME` - Test user email
- `TEST_PASSWORD` - Test user password

### Optional
- `TEST_TIMEOUT` - Request timeout in seconds (default: 30)
- `MCP_ROLE` - Role to authenticate as (default: "user")

## CI/CD Integration

For automated testing in CI/CD:

```bash
#!/bin/bash
set -e

# Start test server in background
cd ../magi-archive
bundle exec rails server -e test -p 3001 &
SERVER_PID=$!

# Wait for server to be ready
sleep 10

# Run integration tests
cd ../magi-archive-mcp
TEST_API_URL=http://localhost:3001/api/mcp \
TEST_USERNAME=test@example.com \
TEST_PASSWORD=password123 \
INTEGRATION_TEST=true \
bundle exec rspec spec/integration/

# Stop server
kill $SERVER_PID
```

## Troubleshooting

### "Integration tests disabled"
**Cause**: `INTEGRATION_TEST` environment variable not set
**Fix**: Run with `INTEGRATION_TEST=true`

### "Server not ready" timeout
**Cause**: MCP server not running or not accessible
**Fix**: Start server first: `cd ../magi-archive && bundle exec rails s`

### Authentication failures
**Cause**: Test user doesn't exist or wrong credentials
**Fix**: Create test user (see Prerequisites section)

### "Connection refused"
**Cause**: Wrong `TEST_API_URL`
**Fix**: Check server is running on correct port

## Pre-Deployment Checklist

Before releasing a new client version:

```bash
# 1. Run unit tests
bundle exec rspec spec/magi/

# 2. Run integration tests against local server
INTEGRATION_TEST=true bundle exec rspec spec/integration/

# 3. Run integration tests against staging
TEST_API_URL=https://staging.wiki.magi-agi.org/api/mcp \
INTEGRATION_TEST=true \
bundle exec rspec spec/integration/

# 4. Run integration tests against production (read-only)
TEST_API_URL=https://wiki.magi-agi.org/api/mcp \
INTEGRATION_TEST=true \
bundle exec rspec spec/integration/ --tag readonly
```

## Best Practices

1. **Always cleanup**: Integration tests should delete created cards in `after` blocks
2. **Use unique names**: Append timestamps to avoid conflicts: `"TestCard#{Time.now.to_i}"`
3. **Test both success and failure**: Include tests for error conditions
4. **Don't run by default**: Integration tests should be opt-in (`INTEGRATION_TEST=true`)
5. **Tag destructive tests**: Use `--tag readonly` for CI against production

## Example Full Integration Test

```ruby
RSpec.describe "Full API Integration", :integration do
  let(:tools) { Magi::Archive::Mcp::Tools.new }
  let(:card_name) { "IntegrationTest#{Time.now.to_i}" }

  after do
    tools.delete_card(card_name) rescue nil
  end

  it "performs complete workflow" do
    # Create
    result = tools.create_card(
      card_name,
      content: "Initial content",
      type: "Basic"
    )
    expect(result["name"]).to eq(card_name)

    # Read
    card = tools.get_card(card_name)
    expect(card["content"]).to include("Initial")

    # Update
    updated = tools.update_card(card_name, content: "Updated content")
    expect(updated["content"]).to include("Updated")

    # List children
    children = tools.list_children(card_name)
    expect(children["children"]).to be_an(Array)

    # Delete
    deleted = tools.delete_card(card_name)
    expect(deleted["name"]).to eq(card_name)

    # Verify deletion
    expect {
      tools.get_card(card_name)
    }.to raise_error(Magi::Archive::Mcp::Client::NotFoundError)
  end
end
```
