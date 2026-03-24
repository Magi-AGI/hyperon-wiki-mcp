# Hyperon Wiki MCP Client & Tools

A Ruby client library and CLI for the Hyperon Wiki API (`wiki.hyperon.dev`). Provides programmatic access to the Decko knowledge graph with role-based security, batch operations, and advanced features like CQL queries and spoiler scanning.

[![Ruby](https://img.shields.io/badge/Ruby-3.2%2B-red)](https://www.ruby-lang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-156%20passing-brightgreen)](spec/)
[![RuboCop](https://img.shields.io/badge/code%20style-rubocop-brightgreen.svg)](https://rubocop.org/)
[![Phase](https://img.shields.io/badge/implementation-Phase%203%20Complete-success)]()

## Overview

The **Hyperon Wiki MCP Client** is a Ruby library and command-line tool for interacting with the Hyperon Wiki Decko knowledge graph. It provides secure, role-aware API access for both human users and AI agents.

**Components:**
- **Ruby Client Library** (`lib/magi/archive/mcp/`) - HTTP client with JWT authentication, retry logic, and role-based access control
- **CLI Tool** (`bin/hyperon-wiki-mcp`) - Command-line interface for interactive use and scripting
- **Tools Module** (`lib/magi/archive/mcp/tools.rb`) - High-level methods for card operations, search, tags, relationships, validation, and admin functions

The client connects to the **Hyperon Wiki API server** (separate repository at `hyperon-wiki`), which provides the actual backend services running on `wiki.hyperon.dev`.

**Implementation Status: Phase 3 Complete** ✅

All core features, batch operations, and advanced capabilities are implemented and production-ready.

## Features

### Core Card Operations (Phase 1)
- **Role-Based Security**: Three-tier access control (User, GM, Admin) with RS256 JWT authentication
- **Card CRUD**: Full create/read/update/delete with role enforcement
- **Batch Processing**: Bulk operations with partial failure handling (per-item or transactional modes)
- **Format Conversion**: HTML ↔ Markdown rendering
- **Children Management**: List and create child cards using compound naming (`Parent+Child`)
- **CLI Tool**: Command-line interface with JSON/pretty output formats

### Advanced Features (Phase 2-3)
- **Admin Database Backup**: Create, download, list, and delete database backups (admin-only)
- **Card Relationships**: Explore connections (referers, nests, links, linked_by, nested_in)
- **Tag Operations**: Search by tags with AND/OR logic, pattern matching, and AI-assisted suggestions
- **Card Validation**: Validate tags and structure based on card type, with content-based recommendations
- **Weekly Summary Generation**: Automated summaries combining wiki changes and git repository activity
- **Safe CQL Queries**: Execute Card Query Language queries with enforced safety limits
- **Spoiler Scanning**: Async job to scan player/AI content for GM-only spoilers
- **Type Discovery**: List and explore available card types

See [MCP-SPEC.md](MCP-SPEC.md) for complete API specification and [MCP_SERVER.md](MCP_SERVER.md) for usage guide.

## Quick Install (Choose Your Client)

**Prerequisites**: Ruby 3.2+ (`ruby --version` to check)

```bash
# Clone and install dependencies
git clone https://github.com/Magi-AGI/hyperon-wiki-mcp.git
cd hyperon-wiki-mcp
bundle install

# Then run the installer for your AI client:
ruby bin/install-claude-desktop   # Claude Desktop (macOS/Windows/Linux)
ruby bin/install-cursor           # Cursor IDE
ruby bin/install-gemini           # Gemini CLI
ruby bin/install-codex            # Codex CLI
ruby bin/install-claude-cli       # Claude Code CLI
```

Each installer will prompt for your Decko wiki credentials (username/password recommended).

**After installation**: Restart your AI client and try "Get the Main Page card from Hyperon Wiki"

See [MCP_SERVER.md](MCP_SERVER.md) for detailed installation instructions and troubleshooting.

---

## Quick Start (Library Usage)

### Basic Usage

```ruby
require "magi/archive/mcp"

# Initialize tools (reads config from environment)
tools = Magi::Archive::Mcp::Tools.new

# Get a card
card = tools.get_card("Main Page")

# Search for cards
results = tools.search_cards(q: "quantum", type: "Article", limit: 10)

# Create a card (requires appropriate role)
new_card = tools.create_card("My New Card", content: "Content here", type: "Article")
```

### MCP Protocol Integration

For AI assistants like Claude Desktop, Claude Code, or Codex CLI, see [MCP_SERVER.md](MCP_SERVER.md) for installation and configuration instructions.

## Installation

### As a Gem (Recommended)

```bash
gem install hyperon-wiki-mcp
```

### From Source

**Requires Ruby 3.2+** (check with `ruby --version`)

If you have an older Ruby, install a modern version using [rbenv](https://github.com/rbenv/rbenv) or [asdf](https://asdf-vm.com/):
```bash
# Using rbenv
brew install rbenv ruby-build
rbenv install 3.2.2
rbenv global 3.2.2
```

Then install:
```bash
git clone https://github.com/Magi-AGI/hyperon-wiki-mcp.git
cd hyperon-wiki-mcp
bundle install
bundle exec rake install
```

### Development Setup

```bash
git clone https://github.com/your-org/hyperon-wiki-mcp.git
cd hyperon-wiki-mcp
bundle install
```

## Configuration

### Two Authentication Methods

#### Method 1: Username/Password (Recommended for Human Users)

Use your existing Decko wiki credentials - no API key needed!

```bash
# .env file
MCP_USERNAME=your-decko-username
MCP_PASSWORD=your-decko-password
DECKO_API_BASE_URL=https://wiki.hyperon.dev/api/mcp

# Optional: Override role (auto-detected from your permissions if not specified)
# MCP_ROLE=user
```

**Benefits:**
- ✅ No admin intervention needed
- ✅ Automatic role detection from your account permissions
- ✅ Same credentials as your wiki login
- ✅ Better audit trail (actions tied to your user account)

#### Method 2: API Key (For Service Accounts/Automation)

For bots, scripts, and automated processes:

```bash
# .env file
MCP_API_KEY=your-64-char-api-key
MCP_ROLE=user              # Required with API key
DECKO_API_BASE_URL=https://wiki.hyperon.dev/api/mcp
```

**Getting an API Key:**
Contact your Decko administrator to generate an API key for service accounts.

## Usage

### As a Library

#### Basic Card Operations

```ruby
require "magi/archive/mcp"

# Initialize tools (uses environment variables for config)
tools = Magi::Archive::Mcp::Tools.new

# Get a card
card = tools.get_card("Main Page")
puts card["name"]
puts card["content"]

# Search for cards
results = tools.search_cards(q: "quantum", type: "Article", limit: 10)
results["cards"].each do |card|
  puts "#{card['name']} (#{card['type']})"
end

# Create a card (requires appropriate role)
new_card = tools.create_card(
  "My New Card",
  content: "This is the content.",
  type: "Article"
)

# Update a card
updated = tools.update_card("My New Card", content: "Updated content.")

# Delete a card (admin only)
tools.delete_card("My New Card", force: false)
```

#### Pagination

```ruby
# Iterate through all matching cards
tools.each_card_page(q: "research", limit: 50) do |page|
  page["cards"].each do |card|
    puts card["name"]
  end
  puts "Offset: #{page['offset']}, Total: #{page['total']}"
end
```

#### Batch Operations

```ruby
# Per-item mode: each operation independent
operations = [
  { action: "create", name: "Card 1", content: "Content 1" },
  { action: "create", name: "Card 2", content: "Content 2" },
  { action: "update", name: "Existing Card", content: "New content" }
]

result = tools.batch_operations(operations, mode: "per_item")
result["results"].each do |op_result|
  puts "#{op_result['action']} #{op_result['name']}: #{op_result['status']}"
end

# Transactional mode: all or nothing
result = tools.batch_operations(operations, mode: "transactional")

# Create child cards using helper
ops = [
  tools.build_child_op("Business Plan", "Overview", content: "Executive summary"),
  tools.build_child_op("Business Plan", "Goals", content: "Key objectives"),
  tools.build_child_op("Business Plan", "Timeline", content: "Project schedule")
]
result = tools.batch_operations(ops)
```

#### Format Conversion

```ruby
# Markdown to HTML
html = tools.render_snippet("# Hello\n\nThis is **bold**.", from: :markdown, to: :html)

# HTML to Markdown
markdown = tools.render_snippet("<h1>Hello</h1><p>This is <strong>bold</strong>.</p>", from: :html, to: :markdown)
```

#### Weekly Summary Generation

```ruby
# Create a weekly summary card
card = tools.create_weekly_summary

# With custom options
card = tools.create_weekly_summary(
  base_path: "/path/to/repos",
  days: 7,
  date: "2025 12 09",
  executive_summary: "Custom summary..."
)
```

See [MCP_SERVER.md](MCP_SERVER.md#weekly-summary-feature) for complete documentation.

### Using the CLI

The `hyperon-wiki-mcp` CLI provides command-line access to all MCP tools.

#### Get a Card

```bash
hyperon-wiki-mcp get "Main Page"
hyperon-wiki-mcp get --name "Main Page" --with-children
hyperon-wiki-mcp get "Card Name" --format json
```

#### Search Cards

```bash
hyperon-wiki-mcp search --query "quantum physics"
hyperon-wiki-mcp search --type Article --limit 20
hyperon-wiki-mcp search -q "research" -t Article -l 10 -o 20
```

#### Create a Card

```bash
hyperon-wiki-mcp create --name "New Article" --content "Content here" --type Article
```

#### Update a Card

```bash
hyperon-wiki-mcp update "Card Name" --content "Updated content"
hyperon-wiki-mcp update --name "Card Name" --type "Article"
```

#### Delete a Card (Admin only)

```bash
hyperon-wiki-mcp delete "Card Name"
hyperon-wiki-mcp delete "Card With Children" --force
```

#### List Card Types

```bash
hyperon-wiki-mcp types
hyperon-wiki-mcp types --limit 100
```

#### Render Content

```bash
hyperon-wiki-mcp render --from markdown --to html --content "# Hello"
hyperon-wiki-mcp render --from html --to markdown --content "<h1>Hello</h1>"
```

#### List Children

```bash
hyperon-wiki-mcp children "Parent Card"
hyperon-wiki-mcp children --name "Parent Card" --limit 50
```

#### CLI Options

```
Usage: hyperon-wiki-mcp COMMAND [options]

Commands:
  get NAME              Get a card by name
  search                Search for cards
  create                Create a new card
  update NAME           Update an existing card
  delete NAME           Delete a card (admin only)
  types                 List card types
  render                Convert HTML/Markdown
  children PARENT       List child cards

Options:
  -n, --name NAME              Card name
  -q, --query QUERY            Search query
  -t, --type TYPE              Card type
  -c, --content CONTENT        Card content
  -l, --limit NUM              Result limit (default: 50)
  -o, --offset NUM             Result offset (default: 0)
  -f, --format FORMAT          Output format (json|pretty)
      --from FORMAT            Source format for rendering
      --to FORMAT              Target format for rendering
      --with-children          Include children in get
      --force                  Force delete even with children
      --debug                  Show debug information
  -h, --help                   Show this help
  -v, --version                Show version
```

## Architecture

### Three-Role Security Model

1. **User Role (`mcp-user`)**:
   - Read public cards
   - Create/update own cards
   - No GM content visibility
   - No destructive operations

2. **GM Role (`mcp-gm`)**:
   - All User permissions
   - Read GM-only content
   - No destructive operations

3. **Admin Role (`mcp-admin`)**:
   - Full access to all cards
   - Delete and move operations
   - System administration

### Authentication Flow

1. Client library reads credentials from environment (API key or username/password)
2. Client library calls `POST /api/mcp/auth` on the Hyperon Wiki API server
3. API server issues short-lived RS256 JWT (15-60 min expiry)
4. JWT includes claims: `sub`, `role`, `iss`, `iat`, `exp`, `jti`, `kid`
5. Client library verifies JWT signature via API server's JWKS endpoint
6. Client library automatically refreshes token before expiry

### Hyperon Wiki API Server Endpoints

The client library connects to these endpoints on the Hyperon Wiki API server (separate repository). All requests require `Authorization: Bearer <jwt_token>`:

**Core Operations (Phase 1-2):**
- `POST /api/mcp/auth` - Get role-scoped JWT
- `GET /api/mcp/cards/:name` - Fetch card
- `GET /api/mcp/cards/:name/children` - List child cards
- `GET /api/mcp/cards` - Search/list cards
- `POST /api/mcp/cards` - Create card
- `PATCH /api/mcp/cards/:name` - Update card
- `DELETE /api/mcp/cards/:name` - Delete card (admin only)
- `POST /api/mcp/cards/batch` - Bulk operations
- `POST /api/mcp/render` - HTML→Markdown conversion
- `POST /api/mcp/render/markdown` - Markdown→HTML conversion

**Advanced Features (Phase 3):**
- `POST /api/mcp/run_query` - Safe CQL queries with enforced limits
- `POST /api/mcp/jobs/spoiler-scan` - Start spoiler scan job
- `GET /api/mcp/jobs/:id` - Get job status (coming soon)
- `GET /api/mcp/jobs/:id/result` - Get job result (coming soon)
- `GET /api/mcp/cards/:name/relationships` - Get card relationships
- `GET /api/mcp/types` - List card types
- `POST /api/mcp/admin/database/backup` - Create database backup (admin)
- `GET /api/mcp/admin/database/backups` - List backups (admin)
- `DELETE /api/mcp/admin/database/backups/:filename` - Delete backup (admin)

## Development

### Running Tests

```bash
# Run all tests
bundle exec rspec

# Run with documentation format
bundle exec rspec --format documentation

# Run specific file
bundle exec rspec spec/magi/archive/mcp/tools_spec.rb

# Run specific test
bundle exec rspec spec/magi/archive/mcp/tools_spec.rb:42
```

**Test Coverage:** 180 examples, 156 passing, 14 pending (Phase 3 implementation)
- **Unit Tests** (~165 examples):
  - Config: 17 examples (env vars, authentication methods)
  - Auth: 18 examples (JWT verification, token refresh)
  - Client: 18 examples (HTTP client, retry logic, error handling)
  - Tools: 108+ examples (all Phase 1-3 features including weekly summary, validation, relationships)
  - Main: 1 example
- **Integration Tests** (7 examples):
  - Contract tests with recorded response shapes
  - Validates API response formats and error handling
  - Catches schema drift between client and server
- **Pending Tests** (14 examples):
  - Advanced git repository scanning scenarios
  - Edge cases in weekly summary generation

**Note:** Integration tests use WebMock with recorded response shapes. For full end-to-end testing, run against a live Decko instance with test data.

### Code Quality

```bash
# Run RuboCop
bundle exec rubocop

# Auto-fix style issues
bundle exec rubocop -a
```

### Build & Install Locally

```bash
# Build gem
bundle exec rake build

# Install locally
bundle exec rake install

# Interactive console
bundle exec rake console
```

### Project Structure

```
lib/magi/archive/
├── mcp/
│   ├── tools.rb           # High-level tools for card operations (all phases)
│   ├── client.rb          # HTTP client for Hyperon Wiki API
│   ├── auth.rb            # JWT verification and token management
│   ├── config.rb          # Configuration management (env vars, defaults)
│   └── version.rb         # Version constant
└── mcp.rb                 # Main module

bin/
└── hyperon-wiki-mcp       # CLI executable

spec/
├── magi/archive/mcp/      # Unit tests (config, auth, client, tools)
├── integration/           # Contract tests with recorded responses
│   └── contract_spec.rb   # API response shape validation
└── support/               # Test helpers and fixtures
```

## Error Handling

The client raises specific exceptions for different error conditions:

```ruby
begin
  card = tools.get_card("Nonexistent Card")
rescue Magi::Archive::Mcp::Client::NotFoundError => e
  puts "Card not found: #{e.message}"
rescue Magi::Archive::Mcp::Client::AuthorizationError => e
  puts "Permission denied: #{e.message}"
rescue Magi::Archive::Mcp::Client::ValidationError => e
  puts "Validation error: #{e.message}"
  puts "Details: #{e.details.inspect}"
rescue Magi::Archive::Mcp::Client::APIError => e
  puts "API error: #{e.message}"
end
```

**Exception Types:**
- `NotFoundError` - Resource not found (404)
- `AuthorizationError` - Permission denied (401, 403)
- `ValidationError` - Invalid input (422)
- `RateLimitError` - Rate limit exceeded (429)
- `APIError` - General API errors (400, 500-series)

## Security Best Practices

1. **Never commit credentials**: Use `.env` files (gitignored) for sensitive data
2. **Use minimal role**: Request only the role needed for your operations
3. **Token management**: Library handles refresh automatically
4. **HTTPS only**: Always use secure connections to Decko
5. **Input validation**: Sanitize user inputs before API calls
6. **Rate limiting**: Respect API rate limits (enforced server-side)

See [MCP_SERVER.md](MCP_SERVER.md#security-best-practices) for comprehensive security guidelines.

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/new-feature`)
3. Make changes and add tests
4. Run tests and RuboCop (`bundle exec rspec && bundle exec rubocop`)
5. Commit with clear messages
6. Push to your fork and submit a pull request

## Documentation

- **[MCP Server Guide](MCP_SERVER.md)** - Complete guide: installation, authentication, tools reference, security, deployment, troubleshooting
- **[MCP Specification](MCP-SPEC.md)** - API specification and protocol details
- **[ChatGPT Usage Guide](CHATGPT-USAGE-GUIDE.md)** - Correct usage patterns, common mistakes, and best practices
- **[Known Issues](KNOWN-ISSUES.md)** - Current issues, investigations, and workarounds
- **[Development Guide](AGENTS.md)** - Ruby development guidelines and project structure
- **[Claude Code Guide](CLAUDE.md)** - Development guidance for AI-assisted coding
- **[API Documentation](https://rubydoc.info/gems/hyperon-wiki-mcp)** - YARD documentation

## License

MIT License - see [LICENSE](LICENSE) file for details

## Support

- **Issues**: [GitHub Issues](https://github.com/your-org/hyperon-wiki-mcp/issues)
- **Discussions**: [GitHub Discussions](https://github.com/your-org/hyperon-wiki-mcp/discussions)
- **Email**: support@magi-agi.org

## Version History

### v0.3.0 - Phase 3 Complete (December 2024)

**Phase 3: Advanced Features**
- Safe CQL (Card Query Language) queries with enforced limits
- Spoiler scanning async job (GM/admin-triggered content scanning)
- Weekly summary generation with git repository integration
- Card validation and structure recommendations
- Comprehensive relationship exploration

**Testing & Quality**
- 180 RSpec tests (156 passing, 14 pending)
- Fixed class structure issues (weekly summary methods now properly included)
- Contract tests for API response validation
- Comprehensive error handling and retry logic

### v0.2.0 - Phase 2 Complete (November 2024)

**Phase 2: Extended Operations**
- Tag operations (search, validation, AI-assisted suggestions)
- Card relationship exploration (referers, nests, links, linked_by, nested_in)
- Database backup management (admin-only)
- Content rendering (HTML ↔ Markdown)
- Type discovery and exploration

**Authentication Improvements**
- Username/password authentication (in addition to API keys)
- Automatic role detection from account permissions
- Better audit trail with user account tracking

### v0.1.0 - Phase 1 Complete (October 2024)

**Phase 1: Core Infrastructure**
- JWT authentication with RS256 verification
- Role-based access control (User, GM, Admin)
- HTTP client with automatic retry and token refresh
- Full CRUD operations for cards
- Batch processing (per-item and transactional modes)
- Comprehensive error handling
- CLI tool for interactive use

## Related Projects

- [Hyperon Wiki](https://github.com/your-org/hyperon-wiki) - The Decko application
- [MCP Specification](https://modelcontextprotocol.io) - Model Context Protocol

---

**Version:** 0.1.0
**Ruby:** 3.2+
**Maintained by:** Magi AGI Team
