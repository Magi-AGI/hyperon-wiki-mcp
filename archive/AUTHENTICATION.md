# Authentication Guide

This guide explains the authentication system and provides detailed examples for each role level.

## Table of Contents

- [Overview](#overview)
- [Authentication Flow](#authentication-flow)
- [Role Levels](#role-levels)
- [Configuration](#configuration)
- [Role Examples](#role-examples)
  - [User Role](#user-role-examples)
  - [GM Role](#gm-role-examples)
  - [Admin Role](#admin-role-examples)
- [Token Management](#token-management)
- [Troubleshooting](#troubleshooting)

## Overview

Magi Archive MCP uses a **three-tier role-based access control** system with JWT (JSON Web Token) authentication:

1. **User Role**: Player permissions - read public content, create/update own cards
2. **GM Role**: Game Master permissions - includes User permissions plus GM-only content access
3. **Admin Role**: Administrator permissions - full system access including destructive operations

## Authentication Flow

```
┌─────────────┐                ┌──────────────┐                ┌─────────────┐
│  MCP Client │                │  Decko API   │                │   JWKS      │
└──────┬──────┘                └──────┬───────┘                └──────┬──────┘
       │                              │                               │
       │ 1. POST /api/mcp/auth        │                               │
       │    (api_key + role)          │                               │
       ├─────────────────────────────>│                               │
       │                              │                               │
       │                              │ 2. Validate key & role        │
       │                              │                               │
       │ 3. Return JWT                │                               │
       │    (RS256 signed)            │                               │
       │<─────────────────────────────┤                               │
       │                              │                               │
       │ 4. GET /api/mcp/cards/Foo    │                               │
       │    Authorization: Bearer JWT │                               │
       ├─────────────────────────────>│                               │
       │                              │                               │
       │                              │ 5. Fetch JWKS (if needed)     │
       │                              ├──────────────────────────────>│
       │                              │                               │
       │                              │ 6. Return public keys         │
       │                              │<──────────────────────────────┤
       │                              │                               │
       │                              │ 7. Verify JWT signature       │
       │                              │    Check role permissions     │
       │                              │                               │
       │ 8. Return card data          │                               │
       │<─────────────────────────────┤                               │
       │                              │                               │
```

## Role Levels

### User Role (`mcp-user`)

**Permissions:**
- ✅ Read public cards
- ✅ Search public cards
- ✅ Create new cards (as owner)
- ✅ Update own cards
- ✅ List card types
- ✅ Convert formats (HTML ↔ Markdown)
- ❌ No access to GM-only content
- ❌ No delete operations
- ❌ No admin operations

**Use Cases:**
- Player character management
- Personal note-taking
- Public article creation
- Research and reading

### GM Role (`mcp-gm`)

**Permissions:**
- ✅ All User role permissions
- ✅ Read GM-only content (hidden from players)
- ✅ Run spoiler scans
- ✅ Execute privileged queries
- ❌ No delete operations
- ❌ No system administration

**Use Cases:**
- Game master content management
- Spoiler checking (ensure player content doesn't reveal secrets)
- Campaign planning
- NPC and plot management

### Admin Role (`mcp-admin`)

**Permissions:**
- ✅ All GM role permissions
- ✅ Delete cards
- ✅ Force delete cards with children
- ✅ Move/rename cards
- ✅ System administration
- ✅ User management

**Use Cases:**
- System maintenance
- Content moderation
- Database cleanup
- User support

## Configuration

### Environment Variables

```bash
# Required
MCP_API_KEY=your-api-key-from-admin
MCP_ROLE=user  # or 'gm' or 'admin'

# Optional
DECKO_API_BASE_URL=https://wiki.magi-agi.org/api/mcp
JWKS_CACHE_TTL=3600  # Cache duration in seconds
```

### Using .env File

Create a `.env` file in your project root:

```bash
# .env
MCP_API_KEY=abc123def456ghi789
MCP_ROLE=user
```

The library automatically loads `.env` files using the `dotenv` gem.

### Programmatic Configuration

```ruby
require "magi/archive/mcp"

# Custom configuration
config = Magi::Archive::Mcp::Config.new(
  api_key: "your-api-key",
  role: "user",
  base_url: "https://wiki.magi-agi.org/api/mcp"
)

# Use custom config
tools = Magi::Archive::Mcp::Tools.new(config)
```

## Role Examples

### User Role Examples

#### Basic Read Operations

```ruby
# Set environment
ENV["MCP_API_KEY"] = "user-api-key"
ENV["MCP_ROLE"] = "user"

require "magi/archive/mcp"

tools = Magi::Archive::Mcp::Tools.new

# Read public cards
main_page = tools.get_card("Main Page")
puts "Welcome: #{main_page['content']}"

# Search public content
results = tools.search_cards(q: "tutorial", type: "Article")
results["cards"].each do |card|
  puts "#{card['name']}: #{card['content'][0..100]}..."
end
```

#### Create Personal Content

```ruby
# Create a player character card
character = tools.create_card(
  "My Character Name",
  type: "Character",
  content: <<~CONTENT
    # Character Background

    **Name:** Aria Stormwind
    **Class:** Wizard
    **Level:** 5

    ## Backstory
    Aria grew up in the coastal city of Wavecrest...
  CONTENT
)

puts "Created character: #{character['name']}"
puts "URL: #{character['url']}"
```

#### Update Own Cards

```ruby
# Update character progression
updated = tools.update_card(
  "My Character Name",
  content: tools.get_card("My Character Name")["content"] + "\n\n## Level 6 Update\nLearned Fireball spell!"
)

puts "Updated to level 6!"
```

#### Attempt GM Content (Fails)

```ruby
begin
  # This will fail - users can't see GM content
  gm_secret = tools.get_card("GM Secret Plot Notes")
rescue Magi::Archive::Mcp::Client::NotFoundError => e
  puts "GM content is hidden from users (appears as not found)"
end
```

### GM Role Examples

#### Access GM Content

```ruby
# Set GM environment
ENV["MCP_API_KEY"] = "gm-api-key"
ENV["MCP_ROLE"] = "gm"

require "magi/archive/mcp"

tools = Magi::Archive::Mcp::Tools.new

# Read GM-only cards
plot = tools.get_card("Secret Plot Twist")
puts "GM Notes: #{plot['content']}"

# Search GM content
gm_npcs = tools.search_cards(q: "NPC", type: "GM Note")
puts "Found #{gm_npcs['total']} GM NPCs"
```

#### Run Spoiler Scans

```ruby
# Check if player content accidentally reveals secrets
job = tools.start_spoiler_scan(
  card_names: ["Player Character Aria", "Player Journal Entry 5"]
)

puts "Spoiler scan started: #{job['job_id']}"

# Poll for completion
loop do
  status = tools.get_job_status(job["job_id"])
  puts "Status: #{status['status']}"

  break if status["status"] == "completed"

  sleep 2
end

# Get results
result = tools.get_job_result(job["job_id"])
if result["spoilers"].any?
  puts "WARNING: Found #{result['spoilers'].length} spoilers!"
  result["spoilers"].each do |spoiler|
    puts "  - #{spoiler['card']}: #{spoiler['text']}"
  end
else
  puts "No spoilers found - player content is safe!"
end
```

#### Create GM Content

```ruby
# Create hidden GM notes
gm_note = tools.create_card(
  "Session 12 GM Notes",
  type: "GM Note",
  content: <<~CONTENT
    # Session 12 Plan

    ## Secret Encounter
    When the party reaches the old tower, they'll encounter...

    ## NPC Motivations
    Lord Blackwood is actually working for the BBEG...

    ## Treasure
    +2 Longsword hidden in the vault
  CONTENT
)

puts "GM note created (hidden from players)"
```

#### Update GM Planning

```ruby
# Update campaign timeline
timeline = tools.get_card("Campaign Timeline")
updated_timeline = timeline["content"] + "\n\n## Session 12\n- Party discovers the conspiracy"

tools.update_card("Campaign Timeline", content: updated_timeline)
```

#### Batch Create NPCs

```ruby
operations = [
  {
    action: "create",
    name: "NPC: Innkeeper Marla",
    type: "GM Note",
    content: "Friendly innkeeper, knows local gossip"
  },
  {
    action: "create",
    name: "NPC: Guard Captain Rex",
    type: "GM Note",
    content: "Suspicious of outsiders, can be bribed"
  },
  {
    action: "create",
    name: "NPC: Mysterious Stranger",
    type: "GM Note",
    content: "Actually the BBEG in disguise"
  }
]

result = tools.batch_operations(operations, mode: "per_item")
puts "Created #{result['results'].count { |r| r['status'] == 'success' }} NPCs"
```

### Admin Role Examples

#### Full System Access

```ruby
# Set admin environment
ENV["MCP_API_KEY"] = "admin-api-key"
ENV["MCP_ROLE"] = "admin"

require "magi/archive/mcp"

tools = Magi::Archive::Mcp::Tools.new

# Read any card (public, user, GM, admin)
any_card = tools.get_card("Any Card Name")

# Search all content
all_results = tools.search_cards(q: "anything")
```

#### Delete Operations

```ruby
# Delete a card (admin only)
begin
  tools.delete_card("Obsolete Card")
  puts "Deleted successfully"
rescue Magi::Archive::Mcp::Client::ValidationError => e
  if e.message.include?("has children")
    puts "Card has children - use force delete"

    # Force delete (removes card and all children)
    tools.delete_card("Obsolete Card", force: true)
    puts "Force deleted with children"
  end
end
```

#### Bulk Cleanup

```ruby
# Delete multiple obsolete cards
obsolete_cards = ["Old Test 1", "Old Test 2", "Duplicate Entry"]

operations = obsolete_cards.map do |name|
  { action: "delete", name: name }
end

result = tools.batch_operations(operations, mode: "per_item")

result["results"].each do |op|
  if op["status"] == "success"
    puts "✓ Deleted #{op['name']}"
  else
    puts "✗ Failed to delete #{op['name']}: #{op['error']}"
  end
end
```

#### Content Moderation

```ruby
# Find and update inappropriate content
flagged = tools.search_cards(q: "inappropriate_term")

flagged["cards"].each do |card|
  # Review card
  puts "Reviewing: #{card['name']}"

  # Update or delete as appropriate
  if should_delete?(card)
    tools.delete_card(card["name"])
    puts "  Deleted"
  elsif should_redact?(card)
    redacted = redact_content(card["content"])
    tools.update_card(card["name"], content: redacted)
    puts "  Redacted"
  end
end
```

## Token Management

### Automatic Token Refresh

The library automatically handles token refresh:

```ruby
tools = Magi::Archive::Mcp::Tools.new

# Token is fetched on first request
card1 = tools.get_card("Card 1")  # Authenticates, gets token

# Token is reused for subsequent requests
card2 = tools.get_card("Card 2")  # Uses cached token
card3 = tools.get_card("Card 3")  # Uses cached token

# After 45 minutes (token expires in 60 min)
card4 = tools.get_card("Card 4")  # Automatically refreshes token
```

### Manual Token Management

```ruby
# Access the underlying client
client = Magi::Archive::Mcp::Client.new

# Force token refresh
client.auth.refresh_token!

# Check token expiry
if client.auth.token_expired?
  puts "Token has expired"
end

# Get current token info
puts "Role: #{client.auth.role}"
puts "Expires: #{client.auth.token_expiry}"
```

### Token Caching

Tokens are cached in memory per client instance:

```ruby
# Each instance has its own token
tools1 = Magi::Archive::Mcp::Tools.new
tools2 = Magi::Archive::Mcp::Tools.new

# These will each fetch their own token
tools1.get_card("Card 1")  # Fetch token 1
tools2.get_card("Card 2")  # Fetch token 2 (separate instance)
```

## Troubleshooting

### "Authentication failed: Invalid API key"

- Check your `MCP_API_KEY` is correct
- Verify the key is active (contact admin)
- Ensure no extra whitespace in the key

```bash
# Wrong (has trailing space)
MCP_API_KEY="abc123 "

# Correct
MCP_API_KEY="abc123"
```

### "Permission denied: Insufficient role"

You're trying an operation your role doesn't permit:

```ruby
# User trying to delete (requires admin)
ENV["MCP_ROLE"] = "user"
tools = Magi::Archive::Mcp::Tools.new

begin
  tools.delete_card("Some Card")
rescue Magi::Archive::Mcp::Client::AuthorizationError => e
  puts "Error: #{e.message}"
  puts "Deletion requires admin role"
end
```

**Solution**: Request appropriate role from administrator or use a different operation.

### "Token expired"

This should never happen (automatic refresh), but if it does:

```ruby
# The library handles this automatically, but you can force refresh:
client = Magi::Archive::Mcp::Client.new
client.auth.refresh_token!
```

### "Role mismatch"

Your API key may be restricted to specific roles:

```bash
# If your key is user-only, this will fail:
MCP_API_KEY=user-only-key
MCP_ROLE=admin  # Error: key not authorized for admin role
```

**Solution**: Use a role your key supports, or request a multi-role key from admin.

## Security Best Practices

1. **Use minimal role**: Only request the role level you need
2. **Protect API keys**: Never commit keys to version control
3. **Rotate keys regularly**: Request new keys periodically
4. **Use .env files**: Keep credentials separate from code
5. **Monitor access**: Review logs for unexpected activity

See [SECURITY.md](SECURITY.md) for comprehensive security guidelines.

## API Key Management

### Requesting an API Key

Contact your Decko administrator:

1. Specify required role level (user, gm, admin)
2. Describe use case
3. Specify if programmatic or CLI use
4. Provide expected request volume

### Key Restrictions

API keys may have:
- **Role restrictions**: Limited to specific roles
- **Rate limits**: Requests per minute/hour
- **IP restrictions**: Only work from specific IPs
- **Time limits**: Expire after a certain period

### Revoking Keys

If a key is compromised:
1. Contact administrator immediately
2. Request key revocation
3. Request new key with different value
4. Update all systems using old key

## Multi-Role Applications

Some applications need different roles for different operations:

```ruby
# Create separate clients for each role
user_config = Magi::Archive::Mcp::Config.new(
  api_key: ENV["USER_API_KEY"],
  role: "user"
)

gm_config = Magi::Archive::Mcp::Config.new(
  api_key: ENV["GM_API_KEY"],
  role: "gm"
)

user_tools = Magi::Archive::Mcp::Tools.new(user_config)
gm_tools = Magi::Archive::Mcp::Tools.new(gm_config)

# Use appropriate client for operation
player_card = user_tools.get_card("Player Character")  # User role
gm_notes = gm_tools.get_card("GM Secret Plot")         # GM role
```

## Next Steps

- Review [SECURITY.md](SECURITY.md) for security best practices
- Read the [MCP Specification](MCP-SPEC.md) for technical details
- Explore [examples/](examples/) for code samples
