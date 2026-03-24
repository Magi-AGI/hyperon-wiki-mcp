# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Magi Archive MCP Server** is a Model Context Protocol (MCP) implementation in Ruby that provides secure, role-aware API access to the `wiki.magi-agi.org` Decko application. It enables AI agents (Claude, Gemini, Codex CLIs) to interact with the Magi Archive, replacing legacy SSH scripts with a structured JSON API.

**Current Status**: Phase 3 complete - All core features, basic tools, and advanced features are fully implemented and operational.

## Core Architecture

### System Role
- **Type**: MCP Server (middleware/client)
- **Upstream**: Magi Archive Decko App (Rails/Decko)
- **Protocol**: Model Context Protocol → Decko JSON API
- **Auth**: RS256 JWT with role-based access control

### Three-Role Security Model
1. **User Role** (`mcp-user`): Player permissions, no GM content visibility, no destructive operations
2. **GM Role** (`mcp-gm`): Read GM-only content, no destructive operations
3. **Admin Role** (`mcp-admin`): Full access including delete/move operations

### Key MCP Tools (Implemented)
- `get_card`, `search_cards`, `list_children` - Card retrieval
- `create_card`, `update_card`, `delete_card` - Card mutation (role-gated)
- `get_tags`, `search_by_tags`, `suggest_tags` - Tag operations and AI-assisted suggestions
- `get_relationships` - Card relationship queries (referers, links, nests)
- `validate_card`, `get_recommendations` - Card validation and structure recommendations
- `get_types`, `render_content` - Type discovery and HTML↔Markdown conversion
- `batch_cards` - Bulk operations with partial failure handling
- `run_query` - Safe CQL queries with enforced limits
- `spoiler_scan` - GM/admin-triggered content scanning
- `health_check` - Wiki availability monitoring (no auth required)
- `admin_backup` - Database backup management (admin-only)
- `create_weekly_summary` - Automated weekly summaries with git integration

## Development Commands

### Setup
```bash
bundle install                    # Install Ruby dependencies
```

### Testing
```bash
bundle exec rspec                 # Run full test suite
bundle exec rspec --format documentation  # Verbose test output
bundle exec rspec spec/path/to/file_spec.rb  # Run single test file
bundle exec rspec spec/path/to/file_spec.rb:42  # Run specific test line
```

### Quality & Build
```bash
bundle exec rubocop               # Lint and style check
bundle exec rubocop -a            # Auto-fix style issues
bundle exec rake build            # Build gem to pkg/
bundle exec rake install          # Install gem locally
bundle exec rake console          # IRB console with project loaded
```

## Project Structure (Target)

```
lib/magi/archive/          # Namespaced modules
├── mcp/                   # MCP protocol implementation
│   ├── server.rb          # Main MCP server
│   ├── tools/             # Individual tool implementations
│   └── auth.rb            # JWT verification logic
├── client.rb              # Decko API client
└── version.rb             # Version constant

bin/                       # CLI entrypoints (thin wrappers)
spec/                      # RSpec tests (mirrors lib/ structure)
├── magi/archive/          # Unit tests
├── integration/           # Integration tests
└── support/               # Fixtures and helpers
pkg/                       # Build artifacts (gitignored)
tmp/                       # Temporary files (gitignored)
```

## Coding Conventions

### Ruby Style
- **Indentation**: 2 spaces
- **Methods/Variables**: `snake_case`
- **Classes/Modules**: `CamelCase`
- **Modules**: Explicit `Magi::Archive::ClassName` nesting
- **Requires**: Explicit at top of each file
- **Constants**: Frozen when possible

### Example Module Structure
```ruby
# lib/magi/archive/client.rb
module Magi
  module Archive
    class Client
      # Implementation
    end
  end
end
```

### Testing Requirements
- Every feature/bugfix requires corresponding `_spec.rb`
- Use `describe`/`context` blocks for organization
- Stub external I/O (Decko API calls)
- Prefer deterministic test data
- Tag slow/integration tests appropriately

## API Integration Details

### Decko API Endpoints (Upstream)
All endpoints require `Authorization: Bearer <jwt_token>`:
- `POST /api/mcp/auth` - Get role-scoped JWT
- `GET /api/mcp/cards/:name` - Fetch card with role filters
- `GET /api/mcp/cards` - Search/list (params: `q`, `type`, `limit`, `offset`)
- `POST /api/mcp/cards` - Create card
- `PATCH /api/mcp/cards/:name` - Update card
- `DELETE /api/mcp/cards/:name` - Admin-only deletion
- `POST /api/mcp/cards/batch` - Bulk operations
- `POST /api/mcp/render` - HTML→Markdown conversion
- `POST /api/mcp/render/markdown` - Markdown→HTML conversion
- `POST /api/mcp/run_query` - Safe CQL queries

### Authentication Flow
1. Environment provides `MCP_API_KEY` and requested role
2. MCP server calls `POST /api/mcp/auth` with key + role
3. Decko issues short-lived RS256 JWT (15-60min expiry)
4. JWT claims: `sub`, `role`, `iss`, `iat`, `exp`, `jti`, `kid`
5. MCP server verifies signature via JWKS, enforces role per request
6. Refresh token before expiry using same auth endpoint

### Response Patterns
- **Pagination**: `offset`/`next_offset` + `total` count
- **Errors**: Structured with codes (`validation_error`, `permission_denied`, etc.)
- **Batch**: HTTP 207 for mixed results with per-op status
- **Rate Limits**: Per API key limits enforced upstream
- **Size Caps**: Default limit 50, max 100; batch max ~100 ops

## Implementation Priorities

### Phase 1: Core Infrastructure ✅ COMPLETE
1. ✅ Scaffold Ruby gem structure (`bundle gem magi-archive-mcp`)
2. ✅ Set up RSpec and RuboCop configuration
3. ✅ Implement JWT verification against Decko JWKS
4. ✅ Create base HTTP client for Decko API calls
5. ✅ Add environment configuration (`.env` support)

### Phase 2: Basic MCP Tools ✅ COMPLETE
1. ✅ Implement `get_card` and `search_cards`
2. ✅ Add `create_card` and `update_card`
3. ✅ Implement role enforcement layer
4. ✅ Add pagination handling
5. ✅ Create MCP tool schema definitions

### Phase 3: Advanced Features ✅ COMPLETE
1. ✅ Implement `cards/batch` with partial failure handling
2. ✅ Add `render_content` HTML/Markdown conversion
3. ✅ Implement `run_query` with CQL safety filters
4. ✅ Add `jobs/spoiler-scan` for GM workflows
5. ✅ Implement rate limiting and retry logic

## Security Considerations

- **Never commit secrets**: Use `.env` files (gitignored) for `MCP_API_KEY`, JWT keys
- **Role escalation prevention**: Hard-block cross-role token usage
- **Token expiry**: Implement refresh before expiry, handle 401s gracefully
- **Input validation**: Sanitize all user inputs before API calls
- **HTTPS only**: Enforce secure connections to Decko
- **Audit logging**: Log role, action, card name (not content by default)

## Legacy Migration Context

This MCP server replaces ad-hoc SSH Ruby scripts from the `magi-archive` repo that performed:
- Card fetching/length checks (`fetch-*.rb`, `check-*.rb`)
- Bulk card creation/updates (`create-*`, `update-*`, `restructure-*`)
- GM visibility filtering (`test-gm-filter.rb`)
- Spoiler scanning across player/AI content
- TOC/tag maintenance and verification

The MCP approach provides structured API access, role enforcement, and token-efficient responses suitable for AI agent consumption.

## Configuration Files

### Required Environment Variables
```bash
MCP_API_KEY=your-api-key           # Issued by Decko admin
MCP_ROLE=user|gm|admin             # Requested role scope
DECKO_API_BASE_URL=https://wiki.magi-agi.org/api/mcp
JWKS_CACHE_TTL=3600                # JWKS cache duration (seconds)
```

### Key Files to Create
- `Gemfile` - Dependency declarations (jwt, http, dotenv, rspec, rubocop)
- `.rubocop.yml` - Style enforcement config (minimal, justified cops only)
- `.rspec` - RSpec configuration
- `Rakefile` - Build/console tasks
- `magi-archive-mcp.gemspec` - Gem specification

## Specifications Reference

Comprehensive technical specifications are maintained in:
- **MCP-SPEC.md** (`MCP-SPEC.md:1`): Full API spec, auth flow, tool definitions, security model
- **AGENTS.md** (`AGENTS.md:1`): Development guidelines, project structure, standard commands
- **GEMINI.md** (`GEMINI.md:1`): Project overview and current status

Always consult these specs before implementing new features to ensure compliance with the architectural design.
