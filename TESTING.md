# Testing Guide

## Client Library Tests

### Prerequisites

**Required:**
- Ruby 3.2+
- Bundler
- Git

**Platform Notes:**
- **Linux/macOS**: Full test suite works out of the box
- **Windows**: Native extension issues (psych/libyaml) may cause failures in some gems
  - Core functionality tests will still pass
  - For 100% pass rate, test on Linux or WSL2

### Running Tests

```bash
# Install dependencies
bundle install

# Run full test suite
bundle exec rspec

# Run with documentation format
bundle exec rspec --format documentation

# Run specific test file
bundle exec rspec spec/magi/archive/mcp/tools_spec.rb

# Run specific test
bundle exec rspec spec/magi/archive/mcp/tools_spec.rb:42
```

### Expected Results

**Total:** 162 examples
**Expected Pass Rate:** 162/162 (100%)

**Test Breakdown:**
- **Integration/Contract Tests** (7 examples): API response shape validation
- **Unit Tests** (155 examples):
  - Config: 17 examples
  - Auth: 18 examples
  - Client: 18 examples
  - Tools: 102 examples (including weekly summary, validation, relationships, etc.)

### Test Environment Setup

Tests use WebMock to stub HTTP requests. No live API access required.

**Required ENV vars** (automatically set in specs):
- `MCP_API_KEY` or (`MCP_USERNAME` + `MCP_PASSWORD`)
- `MCP_ROLE` (user, gm, or admin)
- `DECKO_API_BASE_URL`

These are set in `before` blocks in each spec file, so no manual setup needed.

## Server API Tests

### Prerequisites

**Required:**
- Ruby 3.2+
- Rails 7.2+
- Decko/Card gems
- PostgreSQL (for full Rails environment)

**Platform Notes:**
- Tests require full Rails environment with Decko
- Windows native extension issues (psych, nokogiri) - recommend Linux/WSL2

### Running Server Tests

```bash
cd /path/to/magi-archive

# Install dependencies
bundle install

# Run MCP API test suite only
bundle exec rspec spec/mcp_api

# Run with documentation format
bundle exec rspec spec/mcp_api --format documentation

# Run specific controller tests
bundle exec rspec spec/mcp_api/controllers/auth_controller_spec.rb
bundle exec rspec spec/mcp_api/controllers/cards_controller_relationships_spec.rb
```

### Expected Results

**MCP API Tests:**
- Auth controller: JWT token generation, username/password auth, API key auth
- Cards controller: CRUD operations, relationships (referers, nests, links), batch operations
- Validation controller: Tag validation, structure recommendations
- Admin controller: Database backups
- Integration: Full authentication → query → response flow

**Critical Tests to Verify:**
1. JWT token generation (RS256 with JWKS)
2. Username/password authentication
3. Relationship fallback regex (no false positives)
4. Batch operations (transactional mode)
5. Role-based access control (user/gm/admin filtering)

## Linux Test Verification

For final pre-merge verification, run on a clean Linux environment:

### Client Library

```bash
# On Linux/Ubuntu server
git clone https://github.com/Magi-AGI/magi-archive-mcp.git
cd magi-archive-mcp
git checkout feature/mcp-specifications

# Install Ruby 3.2+ if needed
# rbenv install 3.2.0
# rbenv global 3.2.0

bundle install
bundle exec rspec

# Expected: 162 examples, 0 failures
```

### Server API

```bash
# On Linux deployment server (ubuntu@54.219.9.17 or similar)
cd /path/to/magi-archive
git pull origin feature/mcp-api-phase2

bundle install
bundle exec rspec spec/mcp_api

# Expected: All MCP API tests pass
```

### SSH Access for Server Testing

```bash
# Production/staging server
ssh -i ~/.ssh/magi-archive-key.pem ubuntu@54.219.9.17

# Navigate to Rails app
cd /path/to/magi-archive

# Run tests
RAILS_ENV=test bundle exec rspec spec/mcp_api
```

## Continuous Integration

Future work: GitHub Actions workflow to automate testing on Linux.

See `#5 - Integration Testing` in hardening improvements (deferred).

## Known Issues

### Windows Native Extensions

**Symptoms:**
- `psych` gem fails to compile (yaml.h not found)
- `nokogiri` compilation errors
- Some specs fail with "Could not find psych/nokogiri"

**Workaround:**
- Use WSL2 (Windows Subsystem for Linux)
- Or test on Linux/macOS
- Or accept partial test failures (core tests still pass)

**Why:**
Ruby native extensions require C compiler and development libraries. Windows lacks these by default.

### Test Database Setup

Server tests require a test database. Ensure `database.yml` is configured:

```yaml
test:
  adapter: postgresql
  database: magi_archive_test
  host: localhost
  username: postgres
  password: <%= ENV['DATABASE_PASSWORD'] %>
```

## Test Coverage

### What's Covered

**Client Library:**
- ✅ Configuration validation
- ✅ JWT authentication (RS256, JWKS)
- ✅ Username/password authentication
- ✅ HTTP client (retry logic, token refresh)
- ✅ All 16 MCP tools
- ✅ Pagination handling
- ✅ Error handling
- ✅ Batch operations
- ✅ Weekly summary generation
- ✅ Tag validation
- ✅ Relationship queries

**Server API:**
- ✅ JWT service (token generation, verification)
- ✅ Auth controller (both auth methods)
- ✅ Cards CRUD operations
- ✅ Relationship endpoints (referers, nests, links)
- ✅ Validation endpoints
- ✅ Admin endpoints (backups)
- ✅ Role-based filtering (user/gm/admin)
- ✅ Error handling

### What's Not Covered

- End-to-end integration (client → live server)
- Performance/load testing
- Security penetration testing
- Browser-based MCP clients (Claude Desktop, Codex)

## Pre-Merge Checklist

Before merging `feature/mcp-specifications` and `feature/mcp-api-phase2`:

- [ ] Client tests: 162/162 passing on Linux
- [ ] Server tests: All MCP API specs passing on Linux
- [ ] Manual smoke test: `magi-archive-mcp get "Main Page"`
- [ ] Manual smoke test: Create card via API
- [ ] Code review complete
- [ ] Documentation updated
- [ ] CHANGELOG updated

## Troubleshooting

### "Config requires MCP_API_KEY or MCP_USERNAME"

Tests should auto-set these in `before` blocks. If not:

```bash
export MCP_API_KEY="test-key-123"
export MCP_ROLE="user"
bundle exec rspec
```

### "Could not find Card/Decko"

Server tests require full Rails environment:

```bash
cd /path/to/magi-archive
bundle install
bundle exec rails db:test:prepare
bundle exec rspec spec/mcp_api
```

### "WebMock not stubbing request"

Check that test is stubbing correct URL pattern:

```ruby
stub_request(:get, "#{base_url}/api/mcp/cards")
  .with(headers: { "Authorization" => "Bearer #{token}" })
  .to_return(status: 200, body: {}.to_json)
```

## Contact

Questions about tests? Check:
- [CLAUDE.md](CLAUDE.md) - Development guide
- [MCP-SPEC.md](MCP-SPEC.md) - API specification
- GitHub Issues for test-related questions
