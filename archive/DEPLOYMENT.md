# Deployment Guide for Testing

This guide walks you through deploying the Magi Archive MCP gem for testing against the live Decko server at `wiki.magi-agi.org`.

## Prerequisites

1. **Ruby 3.2+** installed
2. **API Key** from Decko administrator
3. **Network access** to wiki.magi-agi.org

## Quick Start

### 1. Build and Install the Gem

The gem has already been built. To install it:

#### On WSL/Linux:
```bash
cd /mnt/e/GitLab/the-smithy1/magi/Magi-AGI/magi-archive-mcp

# Option A: Install for current user
gem install --user-install pkg/magi-archive-mcp-0.1.0.gem

# Add to PATH (add this to your ~/.bashrc):
export PATH="$HOME/.local/share/gem/ruby/3.2.0/bin:$PATH"
```

#### On Windows (PowerShell):
```powershell
cd E:\GitLab\the-smithy1\magi\Magi-AGI\magi-archive-mcp

# Install the gem
gem install pkg/magi-archive-mcp-0.1.0.gem
```

### 2. Get Your API Key

Contact the Decko administrator to obtain an API key. Keys are scoped to specific roles:
- **user**: Basic read/write access to your own cards
- **gm**: Access to GM-only content
- **admin**: Full administrative access

**Important:** For initial testing, request a `user` role key.

### 3. Configure Environment

Copy the template and fill in your credentials:

```bash
cp .env.test.template .env
```

Edit `.env`:
```bash
MCP_API_KEY=your-actual-api-key-here
MCP_ROLE=user
DECKO_API_BASE_URL=https://wiki.magi-agi.org/api/mcp
```

**Security Note:** Never commit your `.env` file to git! It's already in `.gitignore`.

### 4. Run Installation Test

Test that everything is configured correctly:

```bash
# From the project directory
ruby test_installation.rb
```

Expected output:
```
================================================================================
Magi Archive MCP Installation Test
================================================================================

✓ Gem Version: 0.1.0

✓ Configuration loaded successfully
  - API Base URL: https://wiki.magi-agi.org/api/mcp
  - Requested Role: user
  - API Key: your-key-prefix... (32 chars)

Testing authentication...
✓ Authentication successful
  - Token received: eyJhbGciOiJSUzI1NiIsInR5cCI...

Testing card retrieval...
✓ Successfully retrieved card: Main Page
  - Type: Basic
  - Content preview: Welcome to the Magi Archive...

Testing card search...
✓ Search completed successfully
  - Found 42 total matches
  - Returned 5 cards in this page

Testing type listing...
✓ Type listing completed
  - Found 25 total types
  - Sample types: Basic, Article, User

================================================================================
Installation test complete!
================================================================================
```

## Testing the CLI

Once installed, the `magi-archive-mcp` command should be available.

### Basic Commands

#### Get a card:
```bash
magi-archive-mcp get "Main Page"
```

#### Search cards:
```bash
magi-archive-mcp search --query "quantum physics"
magi-archive-mcp search --type Article --limit 10
```

#### List card types:
```bash
magi-archive-mcp types
```

#### List children of a card:
```bash
magi-archive-mcp children "Parent Card Name"
```

#### Create a card (requires write permission):
```bash
magi-archive-mcp create --name "Test Card" --content "Test content" --type Basic
```

#### Render HTML to Markdown:
```bash
magi-archive-mcp render --from html --to markdown --content "<h1>Hello</h1>"
```

### CLI Options

All commands support:
- `--format json` - Output raw JSON instead of pretty formatting
- `--debug` - Show detailed debug information
- `--help` - Show command-specific help

## Testing as a Library

Create a test script (`test_script.rb`):

```ruby
#!/usr/bin/env ruby
require "dotenv/load"
require "magi/archive/mcp"

# Initialize tools
tools = Magi::Archive::Mcp::Tools.new

# Get a card
begin
  card = tools.get_card("Main Page")
  puts "Card: #{card['name']}"
  puts "Content: #{card['content'][0..100]}..."
rescue Magi::Archive::Mcp::Client::NotFoundError
  puts "Card not found"
end

# Search for cards
results = tools.search_cards(q: "test", limit: 10)
puts "\nFound #{results['total']} cards"
results['cards'].each do |card|
  puts "  - #{card['name']}"
end

# List types
types = tools.list_types
puts "\nAvailable card types:"
types['types'].each do |type|
  puts "  - #{type['name']}"
end

# Create a test card (if you have write permission)
begin
  new_card = tools.create_card(
    "MCP Test Card #{Time.now.to_i}",
    content: "Created via MCP gem at #{Time.now}",
    type: "Basic"
  )
  puts "\nCreated card: #{new_card['name']}"
  puts "URL: #{new_card['url']}"
rescue Magi::Archive::Mcp::Client::AuthorizationError => e
  puts "\nNo write permission (expected for user role)"
end
```

Run it:
```bash
ruby test_script.rb
```

## Common Issues

### 1. Command Not Found: magi-archive-mcp

**Problem:** Shell can't find the executable.

**Solution (WSL/Linux):**
```bash
export PATH="$HOME/.local/share/gem/ruby/3.2.0/bin:$PATH"
```

**Solution (Windows):**
The gem bin should be automatically added to PATH by RubyGems.

### 2. Configuration Error: MCP_API_KEY is required

**Problem:** No `.env` file or missing API key.

**Solution:**
1. Copy `.env.test.template` to `.env`
2. Fill in your actual API key
3. Make sure you're running from the project directory (where `.env` is)

### 3. Authentication Failed: 401 Unauthorized

**Problem:** Invalid API key or role mismatch.

**Solution:**
1. Verify your API key is correct
2. Check that the role matches what your key is authorized for
3. Contact the Decko administrator if issues persist

### 4. Card Not Found: 404

**Problem:** Trying to access a card that doesn't exist or you don't have permission to view.

**Solution:**
1. Verify the card name is correct (case-sensitive!)
2. Check that your role has permission to view the card
3. Try searching for the card first: `magi-archive-mcp search --query "partial name"`

### 5. Permission Denied: 403 Forbidden

**Problem:** Your role doesn't have permission for the operation.

**Solution:**
1. User role can only read public cards and write own cards
2. GM role can read GM content but not delete
3. Admin role required for delete/move operations
4. Request appropriate role if needed

## Testing Different Scenarios

### Read-Only Testing (User Role)

```bash
# Safe operations for user role
magi-archive-mcp get "Main Page"
magi-archive-mcp search --query "test"
magi-archive-mcp types
magi-archive-mcp children "Parent Card"
```

### Write Testing (User/GM Role)

```bash
# Create a test card
magi-archive-mcp create \
  --name "MCP Test $(date +%s)" \
  --content "Testing MCP gem" \
  --type Basic

# Update it
magi-archive-mcp update "MCP Test 1234567890" \
  --content "Updated content"
```

### Batch Operations

Create `batch_test.rb`:
```ruby
require "dotenv/load"
require "magi/archive/mcp"

tools = Magi::Archive::Mcp::Tools.new

# Create multiple cards in one request
ops = [
  { action: "create", name: "Test 1", content: "Content 1" },
  { action: "create", name: "Test 2", content: "Content 2" },
  { action: "create", name: "Test 3", content: "Content 3" }
]

result = tools.batch_operations(ops, mode: "per_item")
puts "Succeeded: #{result['succeeded']}"
puts "Failed: #{result['failed']}"
```

### Child Card Creation

```ruby
require "dotenv/load"
require "magi/archive/mcp"

tools = Magi::Archive::Mcp::Tools.new

# Create child cards using helper
ops = [
  tools.build_child_op("Parent", "Child 1", content: "First child"),
  tools.build_child_op("Parent", "Child 2", content: "Second child"),
  tools.build_child_op("Parent", "Child 3", content: "Third child")
]

result = tools.batch_operations(ops)
```

## Next Steps

### For Development

If you want to continue developing:

```bash
# Don't install gem, use bundler instead
cd /path/to/magi-archive-mcp
bundle install

# Run from source
bundle exec bin/magi-archive-mcp get "Main Page"

# Or load in IRB
bundle exec irb -r ./lib/magi/archive/mcp.rb
```

### For Production Deployment

When ready to deploy to production:

1. **Tag the release:**
   ```bash
   git tag -a v0.1.0 -m "Release version 0.1.0"
   git push origin v0.1.0
   ```

2. **Publish to RubyGems** (if desired):
   ```bash
   gem push pkg/magi-archive-mcp-0.1.0.gem
   ```

3. **Document production setup:**
   - Create systemd service for continuous operation
   - Set up log rotation
   - Configure monitoring/alerting
   - Document backup procedures

## Monitoring and Logs

When using the gem in production:

```ruby
# Enable debug logging
ENV['DEBUG'] = 'true'

# Log all API calls
tools = Magi::Archive::Mcp::Tools.new
tools.client.logger = Logger.new(STDOUT)
```

## Support

- **Issues:** Report bugs at the GitLab repository
- **Documentation:** See README.md for full API documentation
- **MCP Spec:** See MCP-SPEC.md for protocol details
- **Decko Admin:** Contact for API keys and permissions

## Security Checklist

Before production deployment:

- [ ] API keys stored in environment variables (never in code)
- [ ] `.env` file is in `.gitignore`
- [ ] Using HTTPS for all API calls
- [ ] Rate limiting configured
- [ ] Error messages don't leak sensitive data
- [ ] Logs don't contain API keys or tokens
- [ ] Using minimal required role (principle of least privilege)
- [ ] Token refresh is working correctly
- [ ] JWKS cache is configured appropriately

---

**Version:** 0.1.0
**Last Updated:** 2025-12-03
**Maintained by:** Magi AGI Team
