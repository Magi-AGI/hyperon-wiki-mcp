# Security Guide

This guide outlines security best practices, threat models, and secure configuration for the Magi Archive MCP Server.

## Table of Contents

- [Security Model](#security-model)
- [Threat Model](#threat-model)
- [Best Practices](#best-practices)
- [Credential Management](#credential-management)
- [Network Security](#network-security)
- [Access Control](#access-control)
- [Audit Logging](#audit-logging)
- [Incident Response](#incident-response)
- [Security Checklist](#security-checklist)

## Security Model

### Defense in Depth

Magi Archive MCP implements multiple layers of security:

```
┌─────────────────────────────────────────────────┐
│ Layer 1: Transport Security (HTTPS/TLS)        │
├─────────────────────────────────────────────────┤
│ Layer 2: API Key Authentication                │
├─────────────────────────────────────────────────┤
│ Layer 3: JWT Token Verification (RS256)        │
├─────────────────────────────────────────────────┤
│ Layer 4: Role-Based Access Control (RBAC)      │
├─────────────────────────────────────────────────┤
│ Layer 5: Input Validation & Sanitization       │
├─────────────────────────────────────────────────┤
│ Layer 6: Rate Limiting & Abuse Prevention      │
└─────────────────────────────────────────────────┘
```

### Trust Boundaries

1. **Client ↔ MCP Server**: Application code using the library
2. **MCP Server ↔ Decko API**: Network boundary over HTTPS
3. **Decko API ↔ Database**: Internal Decko application layer

## Threat Model

### Assets to Protect

1. **API Keys**: Long-lived credentials for authentication
2. **JWT Tokens**: Short-lived session tokens
3. **Card Content**: User and GM data stored in Decko
4. **System Access**: Prevent unauthorized administrative actions

### Threats

| Threat | Risk Level | Mitigation |
|--------|-----------|------------|
| API Key Exposure | High | Environment variables, never commit to VCS |
| Man-in-the-Middle | High | HTTPS enforcement, certificate validation |
| Privilege Escalation | High | Role verification on every request |
| Token Theft | Medium | Short token lifetime (15-60min), HTTPS only |
| Rate Limit Abuse | Medium | Server-side rate limiting, exponential backoff |
| Injection Attacks | Medium | Input validation, parameterized queries |
| Replay Attacks | Low | JWT `jti` (unique ID per token) |

## Best Practices

### 1. Credential Management

#### Never Commit Secrets

**Bad:**
```ruby
# config.rb - NEVER DO THIS
API_KEY = "abc123def456"  # ❌ Hardcoded credential
```

**Good:**
```ruby
# config.rb
API_KEY = ENV.fetch("MCP_API_KEY")  # ✅ From environment

# .env (gitignored)
MCP_API_KEY=abc123def456
```

#### Use Environment Variables

```bash
# .env file (add to .gitignore)
MCP_API_KEY=your-secret-key
MCP_ROLE=user
DECKO_API_BASE_URL=https://wiki.magi-agi.org/api/mcp
```

#### Separate Keys per Environment

```bash
# .env.development
MCP_API_KEY=dev-key-with-limited-access
MCP_ROLE=user

# .env.production (never commit)
MCP_API_KEY=prod-key-full-access
MCP_ROLE=admin
```

### 2. Principle of Least Privilege

Always use the minimum role required:

**Bad:**
```ruby
# Always using admin for convenience
ENV["MCP_ROLE"] = "admin"  # ❌ Excessive privilege
tools = Magi::Archive::Mcp::Tools.new

# Only need to read cards
card = tools.get_card("Main Page")
```

**Good:**
```ruby
# Use minimal role for the task
ENV["MCP_ROLE"] = "user"  # ✅ Least privilege
tools = Magi::Archive::Mcp::Tools.new

card = tools.get_card("Main Page")
```

### 3. Input Validation

Always validate user input before passing to the API:

**Bad:**
```ruby
# Directly using user input
user_input = gets.chomp
card = tools.get_card(user_input)  # ❌ No validation
```

**Good:**
```ruby
# Validate before use
user_input = gets.chomp

# Validate card name format
unless user_input.match?(/\A[A-Za-z0-9 _-]+\z/)
  raise ArgumentError, "Invalid card name format"
end

# Limit length
if user_input.length > 255
  raise ArgumentError, "Card name too long"
end

card = tools.get_card(user_input)  # ✅ Validated
```

### 4. Error Handling

Don't expose sensitive information in errors:

**Bad:**
```ruby
begin
  card = tools.get_card(name)
rescue => e
  # ❌ Exposes internal details
  puts "Error: #{e.message}"
  puts e.backtrace
end
```

**Good:**
```ruby
begin
  card = tools.get_card(name)
rescue Magi::Archive::Mcp::Client::NotFoundError
  # ✅ User-friendly, no details leaked
  puts "Card not found"
rescue Magi::Archive::Mcp::Client::AuthorizationError
  puts "Permission denied"
rescue Magi::Archive::Mcp::Client::APIError => e
  # Log details internally, show generic message to user
  logger.error("API error: #{e.message}")
  puts "An error occurred. Please try again."
end
```

### 5. Secure Configuration

#### File Permissions

Protect configuration files:

```bash
# Restrict .env file permissions (owner read/write only)
chmod 600 .env

# Verify
ls -la .env
# -rw------- 1 user group 123 Dec 2 .env
```

#### Configuration Validation

```ruby
# Validate configuration at startup
config = Magi::Archive::Mcp::Config.new

# Ensure HTTPS
unless config.base_url.start_with?("https://")
  raise SecurityError, "HTTPS required for API base URL"
end

# Validate API key format
unless config.api_key.match?(/\A[a-zA-Z0-9]{32,}\z/)
  raise SecurityError, "Invalid API key format"
end
```

## Credential Management

### API Key Lifecycle

```
┌─────────┐    ┌──────────┐    ┌─────────┐    ┌─────────┐
│ Request │───▶│  Issue   │───▶│   Use   │───▶│ Rotate  │
└─────────┘    └──────────┘    └─────────┘    └─────────┘
                                                    │
                                                    ▼
                                               ┌─────────┐
                                               │ Revoke  │
                                               └─────────┘
```

### Key Rotation

Rotate API keys regularly:

```ruby
# rotation_script.rb
require "magi/archive/mcp"

# 1. Request new key from admin
new_key = request_new_api_key_from_admin

# 2. Test new key
test_config = Magi::Archive::Mcp::Config.new(api_key: new_key, role: "user")
test_tools = Magi::Archive::Mcp::Tools.new(test_config)

begin
  test_tools.get_card("Main Page")
  puts "✓ New key works"
rescue => e
  puts "✗ New key failed: #{e.message}"
  exit 1
end

# 3. Update environment
File.write(".env", "MCP_API_KEY=#{new_key}\nMCP_ROLE=user\n")
puts "✓ Updated .env with new key"

# 4. Notify admin to revoke old key
notify_admin_to_revoke_old_key

puts "✓ Key rotation complete"
```

### Key Storage

**Good Options:**
- Environment variables (development)
- AWS Secrets Manager (production)
- HashiCorp Vault (production)
- Azure Key Vault (production)
- Encrypted configuration files

**Bad Options:**
- ❌ Hardcoded in source files
- ❌ Committed to version control
- ❌ Stored in plain text files (except .env with proper permissions)
- ❌ Passed as command-line arguments (visible in process list)

### Secrets Management Example

```ruby
# Using AWS Secrets Manager
require "aws-sdk-secretsmanager"

def get_api_key
  client = Aws::SecretsManager::Client.new(region: "us-west-2")

  secret = client.get_secret_value(secret_id: "magi-archive/api-key")
  JSON.parse(secret.secret_string)["api_key"]
end

config = Magi::Archive::Mcp::Config.new(
  api_key: get_api_key,
  role: "user"
)
```

## Network Security

### HTTPS Enforcement

The library enforces HTTPS:

```ruby
# This will raise an error
config = Magi::Archive::Mcp::Config.new(
  api_key: "key",
  role: "user",
  base_url: "http://insecure.com/api"  # ❌ HTTP not allowed
)
# Raises: SecurityError: HTTPS required
```

### Certificate Validation

Never disable certificate validation:

**Bad:**
```ruby
# ❌ NEVER DO THIS
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE
```

**Good:**
```ruby
# ✅ Use system CA certificates (default)
# Library uses Net::HTTP with default SSL verification
```

### Network Isolation

In production, consider network segmentation:

```
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│ Application  │────────▶│   Firewall   │────────▶│  Decko API   │
│   (Private)  │         │  (Outbound   │         │   (Public)   │
│              │         │   Only)      │         │              │
└──────────────┘         └──────────────┘         └──────────────┘
       │
       ▼
   No Inbound
   Connections
```

## Access Control

### Role-Based Access Control (RBAC)

```ruby
# Define role capabilities
ROLE_CAPABILITIES = {
  "user" => [:read_public, :create, :update_own],
  "gm" => [:read_public, :read_gm, :create, :update_own, :spoiler_scan],
  "admin" => [:read_all, :create, :update_all, :delete, :admin]
}.freeze

# Check before operations
def authorize_operation(role, operation)
  capabilities = ROLE_CAPABILITIES[role] || []

  unless capabilities.include?(operation)
    raise Magi::Archive::Mcp::Client::AuthorizationError,
          "Role '#{role}' cannot perform '#{operation}'"
  end
end

# Use before sensitive operations
authorize_operation(ENV["MCP_ROLE"], :delete)
tools.delete_card("Sensitive Card")
```

### Separation of Duties

Use different keys for different purposes:

```ruby
# Read-only bot (user role)
reader_config = Magi::Archive::Mcp::Config.new(
  api_key: ENV["READER_API_KEY"],
  role: "user"
)

# Admin maintenance script (admin role)
admin_config = Magi::Archive::Mcp::Config.new(
  api_key: ENV["ADMIN_API_KEY"],
  role: "admin"
)
```

## Audit Logging

### Logging Recommendations

Log all security-relevant events:

```ruby
require "logger"

class SecureTools < Magi::Archive::Mcp::Tools
  def initialize(config = nil, logger: Logger.new(STDOUT))
    super(config)
    @logger = logger
  end

  def get_card(name, **options)
    @logger.info("AUDIT: get_card name=#{name} role=#{client.auth.role}")

    result = super

    @logger.info("AUDIT: get_card success name=#{name}")
    result
  rescue => e
    @logger.error("AUDIT: get_card failed name=#{name} error=#{e.class}")
    raise
  end

  def delete_card(name, **options)
    @logger.warn("AUDIT: delete_card name=#{name} role=#{client.auth.role}")

    result = super

    @logger.warn("AUDIT: delete_card success name=#{name}")
    result
  rescue => e
    @logger.error("AUDIT: delete_card failed name=#{name} error=#{e.class}")
    raise
  end
end

# Use secure tools
tools = SecureTools.new(logger: Logger.new("audit.log"))
```

### What to Log

**Always Log:**
- Authentication attempts (success and failure)
- Authorization failures
- Destructive operations (delete, bulk updates)
- Admin operations
- Rate limit violations
- Configuration changes

**Never Log:**
- API keys or tokens
- Full card content (may contain sensitive data)
- Passwords or secrets

### Log Format

```ruby
# Structured logging
logger.info(
  event: "card_access",
  action: "get",
  card_name: name,
  role: role,
  user_id: user_id,
  timestamp: Time.now.iso8601,
  success: true
)
```

## Incident Response

### Compromised API Key

If an API key is compromised:

1. **Immediately notify admin** to revoke the key
2. **Generate new key** with different value
3. **Review audit logs** for unauthorized access
4. **Assess impact**: What data was accessed?
5. **Update systems** with new key
6. **Post-mortem**: How was key exposed?

### Response Script

```ruby
#!/usr/bin/env ruby
# incident_response.rb

require "magi/archive/mcp"

puts "=== INCIDENT RESPONSE: Compromised API Key ==="

# 1. Revoke old key (contact admin manually)
puts "\n1. Contact admin to revoke key: #{ENV['COMPROMISED_KEY_ID']}"
puts "   Admin contact: security@magi-agi.org"

# 2. Test if key still works
puts "\n2. Testing if old key still works..."
begin
  config = Magi::Archive::Mcp::Config.new(
    api_key: ENV["OLD_API_KEY"],
    role: "user"
  )
  tools = Magi::Archive::Mcp::Tools.new(config)
  tools.get_card("Main Page")
  puts "   ⚠️  Old key still active! Contact admin urgently!"
rescue Magi::Archive::Mcp::Client::AuthorizationError
  puts "   ✓ Old key revoked"
end

# 3. Install new key
puts "\n3. Installing new key..."
ENV["MCP_API_KEY"] = ENV.fetch("NEW_API_KEY")

# 4. Test new key
puts "\n4. Testing new key..."
tools = Magi::Archive::Mcp::Tools.new
tools.get_card("Main Page")
puts "   ✓ New key works"

# 5. Request audit logs
puts "\n5. Request audit logs from admin for period:"
puts "   From: #{ENV['COMPROMISE_START_TIME']}"
puts "   To: #{Time.now}"

puts "\n=== Incident response complete ==="
```

## Security Checklist

### Development

- [ ] API keys stored in environment variables, not code
- [ ] `.env` file added to `.gitignore`
- [ ] Using HTTPS for all API calls
- [ ] Input validation on all user inputs
- [ ] Error handling doesn't expose sensitive details
- [ ] Using minimal required role for operations
- [ ] Secrets never logged

### Production

- [ ] API keys rotated regularly (every 90 days)
- [ ] Keys stored in secrets management system
- [ ] Audit logging enabled
- [ ] Rate limiting configured
- [ ] Network access restricted (firewall rules)
- [ ] Certificate validation enabled
- [ ] Monitoring and alerting configured
- [ ] Incident response plan documented
- [ ] Regular security audits scheduled

### Operations

- [ ] API key access reviewed quarterly
- [ ] Unused keys revoked
- [ ] Audit logs reviewed weekly
- [ ] Failed authentication attempts monitored
- [ ] Anomalous access patterns investigated
- [ ] Dependencies updated regularly (`bundle update`)
- [ ] Security patches applied promptly

## Reporting Security Issues

If you discover a security vulnerability:

1. **Do NOT** open a public GitHub issue
2. Email security@magi-agi.org with:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)
3. Allow 48 hours for initial response
4. Coordinate disclosure timeline with maintainers

## Security Resources

- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [JWT Best Practices](https://tools.ietf.org/html/rfc8725)
- [Ruby Security Guide](https://guides.rubyonrails.org/security.html)
- [Decko Security Documentation](https://wiki.magi-agi.org/Security)

## Compliance

This library is designed to support:
- SOC 2 compliance (audit logging, access control)
- GDPR compliance (data access, deletion)
- HIPAA compliance (when properly configured)

Consult your compliance team for specific requirements.
