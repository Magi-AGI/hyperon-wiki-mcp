# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2024-12-02

### Added

#### Core Infrastructure (Phase 1)
- Initial gem structure with proper Ruby namespacing
- JWT authentication with RS256 signature verification
- JWKS endpoint integration for public key fetching
- HTTP client for Decko API with automatic retry logic
- Environment-based configuration system (`.env` support)
- Role-based access control (User, GM, Admin roles)
- Comprehensive error handling with custom exception types
- Configuration validation and defaults

#### Basic MCP Tools (Phase 2)
- `get_card(name, with_children:)` - Fetch card by name
- `search_cards(q:, type:, limit:, offset:)` - Search cards with filters
- `create_card(name, content:, type:)` - Create new cards
- `update_card(name, content:, type:)` - Update existing cards
- `delete_card(name, force:)` - Delete cards (admin only)
- `list_children(parent, limit:, offset:)` - List child cards
- `list_types(limit:, offset:)` - List available card types
- `render_snippet(content, from:, to:)` - Convert HTML ↔ Markdown
- `each_card_page(q:, type:, limit:, &block)` - Pagination iterator

#### CLI Tool (Phase 2.5)
- Command-line interface with 8 commands
- `get` - Get card by name with optional children
- `search` - Search cards with query and filters
- `create` - Create new cards
- `update` - Update existing cards
- `delete` - Delete cards with force option
- `types` - List card types
- `render` - Convert between HTML and Markdown
- `children` - List child cards
- JSON and pretty-print output formats
- Comprehensive error handling for all client exceptions
- Help and version flags

#### Advanced Features (Phase 3)
- `batch_operations(operations, mode:)` - Bulk operations with per-item or transactional modes
- `run_query(cql, limit:)` - Execute safe CQL queries with enforced limits
- `start_spoiler_scan(**options)` - Start async spoiler scan jobs (GM/Admin)
- `get_job_status(job_id)` - Poll job status
- `get_job_result(job_id)` - Retrieve job results
- HTTP 207 Multi-Status support for batch operations
- Partial failure handling in batch mode

#### Testing
- 107 RSpec tests covering all components
- Config tests (17 examples)
- Auth tests (18 examples)
- Client tests (18 examples)
- Tools tests (53 examples)
- Main module tests (1 example)
- WebMock integration for HTTP stubbing
- Comprehensive error scenario coverage

#### Documentation
- `README.md` - Comprehensive project documentation
- `QUICKSTART.md` - Quick start guide with examples
- `AUTHENTICATION.md` - Role-based auth guide with examples for all roles
- `SECURITY.md` - Security best practices and threat model
- `MCP-SPEC.md` - Complete MCP protocol specification
- `AGENTS.md` - Development guidelines and commands
- `CHANGELOG.md` - Version history

#### Development Tools
- RuboCop configuration with justified style exceptions
- Gemfile with all dependencies
- Rakefile with build/install/console tasks
- `.rspec` configuration for test runner
- `.gitignore` for Ruby projects

### Security
- RS256 JWT verification with JWKS
- Role-based access control enforcement
- HTTPS-only API communication
- Automatic token refresh before expiry
- Input validation and sanitization
- No credentials in logs or error messages

### Changed
- N/A (initial release)

### Deprecated
- N/A (initial release)

### Removed
- N/A (initial release)

### Fixed
- N/A (initial release)

## Release Notes

### v0.1.0 - Initial Release

This is the initial release of the Magi Archive MCP Server, a Ruby implementation of the Model Context Protocol for secure, role-aware API access to the Magi Archive Decko application.

**Key Features:**
- Complete MCP tool implementation with all basic and advanced features
- Three-tier role-based access control (User, GM, Admin)
- Command-line interface for interactive use
- Comprehensive test coverage (107 tests, 0 failures)
- Full documentation suite
- Production-ready security features

**What's Included:**
- Ruby gem installable via `gem install magi-archive-mcp`
- CLI tool: `magi-archive-mcp`
- Library: `require "magi/archive/mcp"`
- Complete documentation in Markdown format

**Requirements:**
- Ruby 3.2 or higher
- Active Magi Archive API key
- Network access to wiki.magi-agi.org

**Migration from Legacy Scripts:**
This release replaces ad-hoc SSH Ruby scripts from the `magi-archive` repository with a structured, secure MCP protocol implementation. Legacy script users should:
1. Obtain an MCP API key from the Decko administrator
2. Install the gem: `gem install magi-archive-mcp`
3. Configure environment: `MCP_API_KEY` and `MCP_ROLE`
4. Update scripts to use the new library or CLI

**Known Limitations:**
- Token refresh is automatic but requires network connectivity
- Batch operations limited to ~100 operations per request
- Rate limits enforced server-side (per API key)

**Next Release Plans:**
- Enhanced query builder for complex CQL queries
- Streaming support for large result sets
- Additional job types (import/export, validation)
- Performance optimizations for pagination
- Extended YARD API documentation

---

[Unreleased]: https://github.com/your-org/magi-archive-mcp/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/your-org/magi-archive-mcp/releases/tag/v0.1.0
