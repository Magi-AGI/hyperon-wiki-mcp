# Changelog

All notable changes to the Magi Archive MCP Server project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed - 2025-12-11

#### Production Environment Loading Fix
- **Critical Fix**: Fixed `.env` file loading in production HTTP server (`bin/mcp-server-rack-direct`)
- Changed from `File.join(__dir__, '..', '.env')` to `File.expand_path('../.env', __dir__)` to ensure absolute path resolution
- Resolves issue where environment variables weren't loading when script invoked via nohup with full path
- **Impact**: ChatGPT MCP integration now properly authenticates with admin role
- **Commits**: b89d748, 1c14953, 3b2c30a, 43a3d94

#### Validation Feature Removal
- **Philosophy Change**: Removed hardcoded validation and recommendation features to align with Decko's *cardtype+*default pattern
- Encourages AI agents to reference example cards and apply judgment rather than follow rigid rules
- **Removed**:
  - 6 validation/recommendation methods from `tools.rb` (215 lines)
  - 2 MCP tool files: `validate_card.rb`, `get_recommendations.rb`
  - Integration test file: `spec/integration/validation_operations_spec.rb`
  - Tool registrations from both `bin/mcp-server` and `bin/mcp-server-rack-direct`
- **Impact**: Cleaner API, better alignment with wiki philosophy, 13 integration tests passing that were previously failing
- **Commit**: 1a7438b

### Added - 2025-12-09

#### Card Renaming with Reference Updates
- Added `rename_card` method to `Tools` class with reference updating support
- New MCP tool: `RenameCard` (admin-only)
- Parameters:
  - `name`: Current card name
  - `new_name`: New name for the card
  - `update_referers`: Boolean to control whether references are updated (default: true)
- Leverages Decko's built-in reference tracking to update all links to renamed cards
- **Commit**: 965ee8a (estimated)

## [0.1.0] - 2025-12-08

### Summary
Initial release of the Magi Archive MCP Server with comprehensive card management, authentication, and integration capabilities.

### Added

#### Core Features
- **Authentication System**
  - JWT-based authentication with RS256 signature verification
  - JWKS endpoint for public key distribution
  - Support for username/password and API key authentication
  - Role-based access control (user, gm, admin)
  - Automatic token refresh before expiry
  - Token caching with configurable TTL

#### Card Operations
- **Basic CRUD**:
  - `get_card` - Fetch single card with children support
  - `search_cards` - Query cards by name, content, type, tags, date ranges
  - `create_card` - Create new cards with type and content
  - `update_card` - Modify existing cards
  - `delete_card` - Remove cards (admin-only)
  - `list_children` - Get child cards of a parent

- **Advanced Operations**:
  - `batch_cards` - Bulk create/update with transactional and per-item modes
  - `run_query` - Safe CQL queries with enforced limits
  - `spoiler_scan` - Scan for spoiler term leakage (GM/admin)

#### Tag Operations
- `get_tags` - Retrieve all system tags or tags for specific card
- `search_by_tags` - Find cards by tags with AND/OR logic
- `suggest_tags` - AI-assisted tag suggestions based on existing wiki tags

#### Relationship Queries
- `get_referers` - Find cards that reference a target card
- `get_linked_by` - Find cards that link to a target
- `get_links` - Find cards this card links to
- `get_nests` - Find cards this card nests
- `get_nested_in` - Find cards where this card is nested

#### Content Rendering
- `render_content` - Convert between HTML and Markdown (GFM)
- `render_snippet` - Truncate and preview content

#### Utility Features
- `get_types` - Discover available card types
- `health_check` - Verify wiki availability (no auth required)
- `ping` - Ultra-lightweight server check
- `get_site_context` - Comprehensive wiki context for AI agents
- `admin_backup` - Database backup management (admin-only)
- `create_weekly_summary` - Automated summaries with git integration

#### Special Card Handling
- Virtual card detection with helpful warnings
- Pointer card identification with `list_children` suggestions
- Search card detection with query behavior explanations
- Trash filtering (excludes deleted cards from results)
- Compound card name support with proper encoding

#### Developer Experience
- Comprehensive integration test suite (132+ examples)
- Contract tests for API response shape verification
- Retry logic with exponential backoff for rate limits and server errors
- Pagination utilities with automatic page fetching
- Clear error messages with specific error classes
- Detailed documentation in MCP_SERVER.md

### Fixed

#### Server-Side Bugs Resolved
- **Bug #1**: `/cards/:name/children` endpoint 500 NoMethodError - Fixed in magi-archive commit 55685de
- **Bug #2**: `/cards/batch` missing mode field in response - Workaround implemented
- **Bug #3**: `/render` and `/render/markdown` 404 errors - Fixed in magi-archive commit 55685de

### Security

#### Access Control
- Enforced role-based permissions on all destructive operations
- Admin-only operations: delete, rename, backup management
- GM access to GM-visible content
- User role limited to safe read/write operations

#### SSL/TLS
- Configurable SSL verification (strict by default)
- Support for development environments with `SSL_VERIFY_MODE=none`

#### Input Validation
- Card name encoding for special characters
- Query parameter sanitization
- Type validation for create/update operations
- Rate limit handling with automatic retry

### Documentation

#### User Guides
- **MCP_SERVER.md** - Comprehensive guide (3,347 lines)
  - Installation and setup
  - Authentication configuration
  - All available tools with examples
  - Security best practices
  - Deployment instructions
  - Troubleshooting guide

#### Developer Guides
- **MCP-SPEC.md** - Complete API specification
- **AGENTS.md** - Development guidelines for AI
- **GEMINI.md** - Project context for AI
- **CLAUDE.md** - Claude Code guidance
- **README.md** - Quick start and overview

#### Testing Documentation
- **SERVER-BUGS.md** - Known issues and resolution status
- Integration test suite with detailed examples
- Contract test patterns for API verification

### Performance

#### Response Times (Production)
- Health check: ~50-100ms
- Simple card fetch: ~100-300ms
- Complex queries: ~500-800ms
- Batch operations: ~1-3s (depends on size)

#### Optimizations
- JWKS caching (configurable TTL, default 1 hour)
- Token reuse until near expiry (5-minute buffer)
- HTTP connection reuse
- Efficient pagination with offset/limit

---

## Version History Summary

- **v0.1.0** (2025-12-08): Initial release with full MCP implementation
- **Unreleased** (2025-12-11): Production fixes, validation removal, card renaming

---

## Links

- **Repository**: https://github.com/Magi-AGI/magi-archive-mcp
- **Wiki**: https://wiki.magi-agi.org
- **Issues**: https://github.com/Magi-AGI/magi-archive-mcp/issues
