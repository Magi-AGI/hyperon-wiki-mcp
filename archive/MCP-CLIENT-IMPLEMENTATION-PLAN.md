# MCP Client Implementation Plan

**Project**: Magi Archive MCP Client (Ruby Gem)
**Repository**: `magi-archive-mcp/`
**Target**: Ruby gem that provides MCP tools for AI agents to interact with wiki.magi-agi.org
**Status**: Planning Phase

---

## Prerequisites

### Development Environment

**⚠️ WSL Required**: Ruby gem development and testing will be done in WSL due to better Ruby tooling support.

```bash
# In WSL
ruby --version    # Should be 3.2.3 (via rbenv or system)
bundler --version # Should be 2.x
git --version     # For version control
```

### API Access Verified

- ✅ MCP API deployed at https://wiki.magi-agi.org/api/mcp
- ✅ JWT authentication operational
- ✅ Service accounts configured (mcp-user, mcp-gm, mcp-admin)
- ✅ Security model: User role = API key only; GM/Admin = username + password required

### Credentials Available

Stored in `/home/ubuntu/magi-archive/.env.production` on server:
- `MCP_API_KEY` - For user role authentication
- `MCP_GM_PASSWORD` - For GM authentication (username: mcp-gm)
- `MCP_ADMIN_PASSWORD` - For admin authentication (username: mcp-admin)

---

## Phase 1: Core Infrastructure Setup

### 1.1 Scaffold Ruby Gem Structure

**Location**: WSL, `magi-archive-mcp/` directory

**Tasks**:
- [ ] Run `bundle gem magi-archive-mcp --test=rspec --linter=rubocop --ci=github`
- [ ] Review generated structure (lib/, spec/, bin/, Gemfile, gemspec)
- [ ] Update `.gitignore` to exclude `.env`, `pkg/`, `tmp/`
- [ ] Commit initial scaffold

**Expected Structure**:
```
magi-archive-mcp/
├── lib/
│   ├── magi/
│   │   └── archive/
│   │       ├── mcp.rb              # Main entry point
│   │       ├── version.rb          # Gem version
│   │       ├── client.rb           # HTTP client for Decko API
│   │       ├── auth.rb             # JWT handling
│   │       └── tools/              # MCP tool implementations
│   └── magi-archive-mcp.rb         # Gem loader
├── spec/
│   ├── spec_helper.rb
│   ├── magi/archive/
│   └── integration/
├── bin/
│   └── magi-archive-mcp            # CLI entry point
├── Gemfile
├── magi-archive-mcp.gemspec
├── .rubocop.yml
├── .rspec
└── README.md
```

**Validation**:
```bash
bundle install
bundle exec rake -T  # Should show available tasks
```

---

### 1.2 Configure Dependencies

**File**: `magi-archive-mcp.gemspec`

**Tasks**:
- [ ] Add required gem dependencies:
  - `jwt` (~> 2.7) - JWT token handling
  - `http` (~> 5.0) or `faraday` (~> 2.0) - HTTP client
  - `dotenv` (~> 2.8) - Environment variable management
- [ ] Add development dependencies:
  - `rspec` (~> 3.12)
  - `rubocop` (~> 1.50)
  - `vcr` (~> 6.0) - HTTP interaction recording for tests
  - `webmock` (~> 3.18) - HTTP request stubbing
- [ ] Set gem metadata (homepage, source code URL, description)
- [ ] Run `bundle install` to verify dependencies

**Validation**:
```bash
bundle install
bundle exec rspec --version
bundle exec rubocop --version
```

---

### 1.3 Environment Configuration

**File**: `lib/magi/archive/mcp/config.rb`

**Tasks**:
- [ ] Create configuration class that loads from ENV
- [ ] Required variables:
  - `DECKO_API_BASE_URL` (default: https://wiki.magi-agi.org/api/mcp)
  - `MCP_API_KEY` (required)
  - `MCP_USERNAME` (optional, for GM/admin)
  - `MCP_PASSWORD` (optional, for GM/admin)
  - `MCP_ROLE` (default: user)
  - `JWKS_CACHE_TTL` (default: 3600)
- [ ] Support loading from `.env` file via dotenv
- [ ] Add validation for required variables
- [ ] Add `.env.example` template file

**Example `.env.example`**:
```bash
# Magi Archive MCP Client Configuration

# API Base URL (default: https://wiki.magi-agi.org/api/mcp)
DECKO_API_BASE_URL=http://localhost:3000/api/mcp

# API Key (required for user role)
MCP_API_KEY=your-api-key-here

# Role (user, gm, or admin)
MCP_ROLE=user

# Credentials (required for gm/admin roles)
# MCP_USERNAME=mcp-gm
# MCP_PASSWORD=your-password

# JWKS cache duration in seconds
JWKS_CACHE_TTL=3600
```

**Validation**:
- [ ] Create `.env` from template
- [ ] Test configuration loading
- [ ] Test validation errors for missing required vars

---

### 1.4 JWT Authentication Implementation

**File**: `lib/magi/archive/mcp/auth.rb`

**Tasks**:
- [ ] Implement JWKS fetching from `/.well-known/jwks.json`
- [ ] Cache JWKS with configurable TTL
- [ ] Implement JWT token verification using public key
- [ ] Handle token expiry and refresh logic
- [ ] Store current token and expiry time
- [ ] Provide method to get valid token (refresh if needed)

**Key Methods**:
```ruby
class Magi::Archive::MCP::Auth
  def initialize(config)
  def authenticate(role: "user", username: nil, password: nil)
  def token # Returns valid token, refreshes if expired
  def refresh_token!
  private
  def fetch_jwks
  def verify_token(token)
end
```

**Authentication Logic**:
```ruby
# User role
auth.authenticate(role: "user")

# GM role (requires credentials)
auth.authenticate(role: "gm", username: "mcp-gm", password: "...")

# Admin role (requires credentials)
auth.authenticate(role: "admin", username: "mcp-admin", password: "...")
```

**Validation**:
- [ ] Unit tests for JWKS fetching
- [ ] Unit tests for token verification
- [ ] Unit tests for token refresh
- [ ] Integration test with live API

---

### 1.5 HTTP Client Implementation

**File**: `lib/magi/archive/mcp/client.rb`

**Tasks**:
- [ ] Create base HTTP client wrapper
- [ ] Automatic authentication header injection
- [ ] Handle common HTTP errors (401, 403, 404, 500)
- [ ] Implement retry logic with exponential backoff
- [ ] Parse JSON responses
- [ ] Handle Decko error format (error.code, error.message, error.details)

**Key Methods**:
```ruby
class Magi::Archive::MCP::Client
  def initialize(config, auth)
  def get(path, params: {})
  def post(path, body: {})
  def patch(path, body: {})
  def delete(path)
  private
  def request(method, path, params: {}, body: {})
  def handle_response(response)
  def handle_error(error)
end
```

**Error Handling**:
```ruby
# Decko error format
{
  "error": {
    "code": "validation_error",
    "message": "Card validation failed",
    "details": {"errors": ["Name can't be blank"]}
  }
}
```

**Validation**:
- [ ] Unit tests for HTTP methods
- [ ] Unit tests for error handling
- [ ] Unit tests for retry logic
- [ ] Integration test with live API

---

### 1.6 Testing Infrastructure

**Files**: `spec/spec_helper.rb`, `spec/support/*`

**Tasks**:
- [ ] Configure RSpec with proper helpers
- [ ] Set up VCR for recording HTTP interactions
- [ ] Set up WebMock for stubbing API calls
- [ ] Create test fixtures for common API responses
- [ ] Add helper methods for authentication
- [ ] Configure separate test environment

**RSpec Configuration**:
```ruby
# spec/spec_helper.rb
require 'vcr'
require 'webmock/rspec'

VCR.configure do |config|
  config.cassette_library_dir = "spec/fixtures/vcr_cassettes"
  config.hook_into :webmock
  config.filter_sensitive_data('<API_KEY>') { ENV['MCP_API_KEY'] }
  config.filter_sensitive_data('<PASSWORD>') { ENV['MCP_PASSWORD'] }
end
```

**Test Categories**:
- Unit tests: Mock all HTTP calls
- Integration tests: Use VCR cassettes
- Live tests: Optional, require credentials

**Validation**:
- [ ] Run `bundle exec rspec` - should pass
- [ ] Check code coverage report

---

### 1.7 RuboCop Configuration

**File**: `.rubocop.yml`

**Tasks**:
- [ ] Configure RuboCop for project style
- [ ] Disable overly strict cops (e.g., line length for specs)
- [ ] Enable security cops
- [ ] Set target Ruby version to 3.2

**Minimal Configuration**:
```yaml
AllCops:
  TargetRubyVersion: 3.2
  NewCops: enable
  Exclude:
    - 'vendor/**/*'
    - 'tmp/**/*'

Metrics/BlockLength:
  Exclude:
    - 'spec/**/*'

Layout/LineLength:
  Max: 120
```

**Validation**:
```bash
bundle exec rubocop
bundle exec rubocop -a  # Auto-fix safe issues
```

---

## Phase 2: Basic MCP Tools

### 2.1 Card Retrieval Tools

**Files**: `lib/magi/archive/mcp/tools/card_tools.rb`

**Tasks**:
- [ ] Implement `get_card(name)`
- [ ] Implement `search_cards(query, limit:, offset:)`
- [ ] Implement `list_children(parent_name)`
- [ ] Handle pagination properly
- [ ] Parse and validate responses

**API Endpoints Used**:
- `GET /cards/:name` - Single card
- `GET /cards?q=...&limit=...&offset=...` - Search
- `GET /cards/:name/children` - Children

**Method Signatures**:
```ruby
def get_card(name)
  # Returns: {name, id, type, content, codename, updated_at, created_at}
end

def search_cards(query: nil, type: nil, prefix: nil, limit: 50, offset: 0)
  # Returns: {cards: [...], total, limit, offset, next_offset}
end

def list_children(parent_name)
  # Returns: {parent, children: [...], child_count}
end
```

**Validation**:
- [ ] Unit tests with mocked responses
- [ ] Integration tests with VCR
- [ ] Test pagination handling
- [ ] Test error cases (404, permission denied)

---

### 2.2 Card Mutation Tools

**Files**: `lib/magi/archive/mcp/tools/card_tools.rb`

**Tasks**:
- [ ] Implement `create_card(name:, type:, content:, markdown_content:)`
- [ ] Implement `update_card(name, content:, markdown_content:, patch:)`
- [ ] Implement `delete_card(name)` (admin only)
- [ ] Handle validation errors
- [ ] Support markdown content conversion

**API Endpoints Used**:
- `POST /cards` - Create
- `PATCH /cards/:name` - Update
- `DELETE /cards/:name` - Delete

**Method Signatures**:
```ruby
def create_card(name:, type:, content: nil, markdown_content: nil)
  # Returns: {name, id, type, content, updated_at, created_at}
end

def update_card(name, content: nil, markdown_content: nil, patch: nil)
  # Returns: {name, id, type, content, updated_at, created_at}
end

def delete_card(name)
  # Requires admin role
  # Returns: {status: "deleted", name}
end
```

**Validation**:
- [ ] Unit tests for each method
- [ ] Test role enforcement (user can't delete)
- [ ] Test validation error handling
- [ ] Integration tests with VCR

---

### 2.3 Type Management Tools

**Files**: `lib/magi/archive/mcp/tools/type_tools.rb`

**Tasks**:
- [ ] Implement `list_types(common_only:, limit:, offset:)`
- [ ] Parse type information
- [ ] Handle pagination

**API Endpoints Used**:
- `GET /types`

**Method Signatures**:
```ruby
def list_types(common_only: false, limit: 50, offset: 0)
  # Returns: {types: [{name, id, codename, common}], total, limit, offset}
end
```

**Validation**:
- [ ] Unit tests with mocked responses
- [ ] Test common_only filtering
- [ ] Test pagination

---

### 2.4 Rendering Tools

**Files**: `lib/magi/archive/mcp/tools/render_tools.rb`

**Tasks**:
- [ ] Implement `html_to_markdown(html)`
- [ ] Implement `markdown_to_html(markdown)`
- [ ] Handle rendering errors

**API Endpoints Used**:
- `POST /render/html_to_markdown`
- `POST /render/markdown_to_html`

**Method Signatures**:
```ruby
def html_to_markdown(html)
  # Returns: {markdown, preserved_wiki_links: [...]}
end

def markdown_to_html(markdown)
  # Returns: {html}
end
```

**Validation**:
- [ ] Test wiki link preservation
- [ ] Test markdown features (headers, lists, links)
- [ ] Test HTML sanitization

---

### 2.5 CLI Tool

**File**: `bin/magi-archive-mcp`

**Tasks**:
- [ ] Create CLI interface using OptionParser or Thor
- [ ] Support common operations: get, search, create, update
- [ ] Output JSON or pretty-printed format
- [ ] Handle authentication via env vars

**Example Usage**:
```bash
# Get a card
magi-archive-mcp get "Card Name"

# Search cards
magi-archive-mcp search --query "test" --type "Phrase"

# Create a card (requires auth)
magi-archive-mcp create --name "Test Card" --type "Phrase" --content "Test"

# List types
magi-archive-mcp types --common
```

**Validation**:
- [ ] Test all CLI commands
- [ ] Test error handling
- [ ] Test output formatting

---

## Phase 3: Advanced Features

### 3.1 Batch Operations

**Files**: `lib/magi/archive/mcp/tools/batch_tools.rb`

**Tasks**:
- [ ] Implement `batch_operations(ops, mode:)`
- [ ] Handle partial failures (HTTP 207)
- [ ] Support transactional mode

**API Endpoints Used**:
- `POST /cards/batch`

**Method Signatures**:
```ruby
def batch_operations(ops, mode: "per_item")
  # mode: "per_item" or "transactional"
  # Returns: {results: [{status, name, id, message}]}
end
```

**Validation**:
- [ ] Test successful batch
- [ ] Test partial failures
- [ ] Test transactional rollback

---

### 3.2 Query Tools

**Files**: `lib/magi/archive/mcp/tools/query_tools.rb`

**Tasks**:
- [ ] Implement `run_query(cql_query, limit:)`
- [ ] Validate CQL for safety
- [ ] Handle query errors

**API Endpoints Used**:
- `POST /run_query`

**Validation**:
- [ ] Test safe queries
- [ ] Test query limits
- [ ] Test error handling

---

### 3.3 Job Tools

**Files**: `lib/magi/archive/mcp/tools/job_tools.rb`

**Tasks**:
- [ ] Implement `start_spoiler_scan(options)`
- [ ] Poll job status
- [ ] Retrieve job results

**API Endpoints Used**:
- `POST /jobs/spoiler-scan`
- `GET /jobs/:id`

**Validation**:
- [ ] Test job creation (GM/admin only)
- [ ] Test job status polling
- [ ] Test result retrieval

---

## Testing Strategy

### Unit Tests
**Location**: `spec/magi/archive/mcp/`

- Mock all HTTP calls with WebMock
- Test error handling
- Test edge cases
- Target 90%+ code coverage

### Integration Tests
**Location**: `spec/integration/`

- Use VCR to record real API interactions
- Test full authentication flow
- Test end-to-end tool usage
- Use test account credentials

### Live Tests (Optional)
**Location**: `spec/live/` (excluded by default)

- Require real credentials
- Test against live API
- Use for manual verification only
- Never run in CI

---

## Documentation Requirements

### README.md
- [ ] Installation instructions
- [ ] Quick start guide
- [ ] Authentication examples (user, GM, admin)
- [ ] Common usage examples
- [ ] Configuration reference

### API Documentation
- [ ] YARD documentation for all public methods
- [ ] Generate HTML docs: `bundle exec yard doc`
- [ ] Include code examples in docs

### Security Guide
- [ ] How to store credentials securely
- [ ] Role-based access explanation
- [ ] Token refresh behavior
- [ ] Rate limiting considerations

---

## Deployment Checklist

### Gem Publishing (when ready)
- [ ] Update version in `lib/magi/archive/mcp/version.rb`
- [ ] Update CHANGELOG.md
- [ ] Tag release in git
- [ ] Build gem: `bundle exec rake build`
- [ ] Publish to RubyGems: `gem push pkg/magi-archive-mcp-*.gem`

### Internal Usage
- [ ] Install gem locally: `bundle exec rake install`
- [ ] Test with real credentials
- [ ] Create example scripts for AI agents
- [ ] Document usage patterns

---

## Success Criteria

### Phase 1 Complete When:
- ✅ Gem scaffold created
- ✅ Dependencies installed
- ✅ JWT authentication working
- ✅ HTTP client functional
- ✅ Tests passing
- ✅ RuboCop clean

### Phase 2 Complete When:
- ✅ All basic tools implemented
- ✅ User role functionality verified
- ✅ GM/Admin role functionality verified
- ✅ CLI tool functional
- ✅ Documentation complete

### Phase 3 Complete When:
- ✅ Batch operations working
- ✅ Query tools functional
- ✅ Job tools functional
- ✅ Ready for production use

---

## Risk Mitigation

### Authentication Complexity
- **Risk**: JWT token handling is complex
- **Mitigation**: Use well-tested jwt gem, comprehensive tests
- **Fallback**: Manual token management if needed

### API Changes
- **Risk**: Decko API might change
- **Mitigation**: Version lock, integration tests will catch breaking changes
- **Fallback**: Pin to specific API version

### Security Vulnerabilities
- **Risk**: Credential leakage in tests/logs
- **Mitigation**: VCR filtering, .env in gitignore, no credentials in code
- **Fallback**: Credential rotation if leak detected

---

## Timeline Estimate

**Phase 1**: 2-3 days (scaffolding + core infrastructure)
**Phase 2**: 3-4 days (basic tools + CLI)
**Phase 3**: 2-3 days (advanced features)
**Testing/Documentation**: 2 days
**Total**: ~7-12 days

---

## WSL Setup Notes

### Initial WSL Setup
```bash
# Check Ruby version
ruby --version  # Should be 3.2.3

# If not installed, use rbenv
git clone https://github.com/rbenv/rbenv.git ~/.rbenv
echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
echo 'eval "$(rbenv init -)"' >> ~/.bashrc
exec bash

# Install ruby-build
git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build

# Install Ruby 3.2.3
rbenv install 3.2.3
rbenv global 3.2.3

# Install bundler
gem install bundler
```

### Access Windows Files from WSL
```bash
# Windows files are mounted at /mnt/
cd /mnt/e/GitLab/the-smithy1/magi/Magi-AGI/magi-archive-mcp
```

### Git Configuration in WSL
```bash
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

---

## Next Steps

1. ✅ Review this implementation plan
2. ⏭️ Set up WSL Ruby environment (if needed)
3. ⏭️ Navigate to magi-archive-mcp directory in WSL
4. ⏭️ Begin Phase 1.1: Scaffold Ruby gem
