# Server-Side API Key Management Guide

This guide explains how to manage API keys on the **Decko server** at `wiki.magi-agi.org` to grant MCP client access.

## Current Implementation (Phase 1/MVP)

### How It Works

The current server implementation (in `magi-archive/deck/mod/mcp_api`) uses a **single shared API key**:

1. Server has one `MCP_API_KEY` environment variable
2. All clients use this same key
3. Clients request different roles (user/gm/admin) at auth time
4. Server issues role-scoped tokens

**Source:** `app/controllers/api/mcp/auth_controller.rb:45-53`

### Giving Access to Test Users (Current Method)

#### Step 1: Find Your Server's API Key

On the Decko server (wiki.magi-agi.org), check the current API key:

```bash
# SSH into the server
ssh ubuntu@wiki.magi-agi.org

# Check the environment variable
echo $MCP_API_KEY

# Or check the .env file
cat /path/to/decko/.env.production | grep MCP_API_KEY
```

If no key exists, generate one:

```bash
# Generate a secure 32-character API key
ruby -r securerandom -e "puts SecureRandom.hex(16)"
# Example output: 3f9a8b2c1d4e5f6a7b8c9d0e1f2a3b4c

# Add to .env.production
echo "MCP_API_KEY=3f9a8b2c1d4e5f6a7b8c9d0e1f2a3b4c" >> /path/to/decko/.env.production

# Restart the server
decko restart
```

#### Step 2: Share Key with Test User

Provide the test user with:

1. **API Key:** The `MCP_API_KEY` value
2. **Role:** Which role they should request (`user`, `gm`, or `admin`)
3. **Server URL:** `https://wiki.magi-agi.org/api/mcp`

**Security Note:** Since everyone shares the same key, only share with trusted users!

#### Step 3: Test User Configuration

The test user creates their `.env` file:

```bash
MCP_API_KEY=3f9a8b2c1d4e5f6a7b8c9d0e1f2a3b4c
MCP_ROLE=user
DECKO_API_BASE_URL=https://wiki.magi-agi.org/api/mcp
```

### Limitations of Current Approach

❌ **Security Issues:**
- Single key for all users (no individual revocation)
- Anyone with the key can request any role
- No audit trail of which user performed actions
- Key rotation requires updating all clients

❌ **Access Control Issues:**
- Can't limit specific users to specific roles
- Can't set per-user rate limits
- Can't expire individual access

## Phase 2: Multi-Key Management (Recommended for Production)

### Overview

Implement database-backed API keys with per-key permissions, rate limits, and audit trails.

### Database Schema

Create a migration to add API key storage:

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_mcp_api_keys.rb
class CreateMcpApiKeys < ActiveRecord::Migration[7.0]
  def change
    create_table :mcp_api_keys do |t|
      t.string :key_hash, null: false, index: { unique: true }
      t.string :key_prefix, null: false  # First 8 chars for display
      t.string :name, null: false        # Human-readable name
      t.string :allowed_roles, array: true, default: ["user"]
      t.integer :rate_limit_per_hour, default: 1000
      t.datetime :last_used_at
      t.datetime :expires_at
      t.boolean :active, default: true
      t.string :created_by              # Admin who created it
      t.string :notes                   # Purpose, contact info
      t.timestamps
    end

    add_index :mcp_api_keys, :active
    add_index :mcp_api_keys, :expires_at
  end
end
```

### Model Implementation

```ruby
# app/models/mcp_api_key.rb
class McpApiKey < ApplicationRecord
  # Validations
  validates :key_hash, presence: true, uniqueness: true
  validates :name, presence: true
  validates :allowed_roles, presence: true
  validate :roles_must_be_valid

  # Scopes
  scope :active, -> { where(active: true).where("expires_at IS NULL OR expires_at > ?", Time.now) }

  # Class methods
  def self.generate(name:, roles: ["user"], rate_limit: 1000, expires_in: nil, created_by: nil, notes: nil)
    # Generate secure random key
    api_key = SecureRandom.hex(32)  # 64 character key
    key_hash = Digest::SHA256.hexdigest(api_key)
    key_prefix = api_key[0..7]

    # Create record
    record = create!(
      key_hash: key_hash,
      key_prefix: key_prefix,
      name: name,
      allowed_roles: roles,
      rate_limit_per_hour: rate_limit,
      expires_at: expires_in ? Time.now + expires_in : nil,
      created_by: created_by,
      notes: notes,
      active: true
    )

    # Return the plaintext key ONCE (never stored in DB)
    { record: record, api_key: api_key }
  end

  def self.find_by_key(api_key)
    key_hash = Digest::SHA256.hexdigest(api_key)
    active.find_by(key_hash: key_hash)
  end

  # Instance methods
  def role_allowed?(role)
    allowed_roles.include?(role.to_s)
  end

  def touch_last_used!
    update_column(:last_used_at, Time.now)
  end

  def deactivate!
    update!(active: false)
  end

  def expired?
    expires_at && expires_at < Time.now
  end

  private

  def roles_must_be_valid
    invalid_roles = allowed_roles - %w[user gm admin]
    if invalid_roles.any?
      errors.add(:allowed_roles, "contains invalid roles: #{invalid_roles.join(', ')}")
    end
  end
end
```

### Update Auth Controller

```ruby
# app/controllers/api/mcp/auth_controller.rb
def valid_api_key?(api_key)
  # Phase 2: Database-backed keys
  @api_key_record = McpApiKey.find_by_key(api_key)

  if @api_key_record
    @api_key_record.touch_last_used!
    true
  else
    false
  end
end

def allowed_role_for_key?(api_key, role)
  # Phase 2: Check per-key role permissions
  return false unless @api_key_record
  @api_key_record.role_allowed?(role)
end
```

### Rake Tasks for Key Management

```ruby
# lib/tasks/mcp_keys.rake
namespace :mcp do
  namespace :keys do
    desc "Generate a new MCP API key"
    task :generate, [:name, :roles, :created_by] => :environment do |t, args|
      name = args[:name] || "Unnamed Key #{Time.now.to_i}"
      roles = (args[:roles] || "user").split(",").map(&:strip)
      created_by = args[:created_by] || "rake"

      result = McpApiKey.generate(
        name: name,
        roles: roles,
        created_by: created_by
      )

      puts "=" * 80
      puts "API Key Generated Successfully"
      puts "=" * 80
      puts "Name: #{result[:record].name}"
      puts "Key: #{result[:api_key]}"
      puts "Roles: #{result[:record].allowed_roles.join(', ')}"
      puts "Rate Limit: #{result[:record].rate_limit_per_hour} req/hour"
      puts "Created: #{result[:record].created_at}"
      puts
      puts "⚠️  IMPORTANT: Copy this key now - it will never be shown again!"
      puts "=" * 80
    end

    desc "List all API keys"
    task :list => :environment do
      keys = McpApiKey.order(created_at: :desc)

      puts "=" * 80
      puts "MCP API Keys"
      puts "=" * 80

      keys.each do |key|
        status = key.active ? "✓ Active" : "✗ Inactive"
        status += " (expired)" if key.expired?

        puts "#{key.id}. #{key.name}"
        puts "   Prefix: #{key.key_prefix}..."
        puts "   Roles: #{key.allowed_roles.join(', ')}"
        puts "   Status: #{status}"
        puts "   Last used: #{key.last_used_at || 'Never'}"
        puts "   Created: #{key.created_at} by #{key.created_by}"
        puts
      end
    end

    desc "Deactivate an API key by ID"
    task :deactivate, [:id] => :environment do |t, args|
      key = McpApiKey.find(args[:id])
      key.deactivate!
      puts "✓ Deactivated key: #{key.name} (#{key.key_prefix}...)"
    end

    desc "Reactivate an API key by ID"
    task :activate, [:id] => :environment do |t, args|
      key = McpApiKey.find(args[:id])
      key.update!(active: true)
      puts "✓ Activated key: #{key.name} (#{key.key_prefix}...)"
    end

    desc "Delete an API key by ID (WARNING: Cannot be undone)"
    task :delete, [:id] => :environment do |t, args|
      key = McpApiKey.find(args[:id])
      name = key.name
      prefix = key.key_prefix
      key.destroy!
      puts "✗ Deleted key: #{name} (#{prefix}...)"
    end
  end
end
```

### Using the Rake Tasks

#### Generate a user-level key:
```bash
cd /path/to/decko
bundle exec rake mcp:keys:generate["Test User Key","user","admin@example.com"]
```

Output:
```
================================================================================
API Key Generated Successfully
================================================================================
Name: Test User Key
Key: 3f9a8b2c1d4e5f6a7b8c9d0e1f2a3b4c5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1
Roles: user
Rate Limit: 1000 req/hour
Created: 2025-12-03 15:30:00 UTC

⚠️  IMPORTANT: Copy this key now - it will never be shown again!
================================================================================
```

#### Generate a GM key with multiple roles:
```bash
bundle exec rake mcp:keys:generate["GM Key","user,gm","admin@example.com"]
```

#### List all keys:
```bash
bundle exec rake mcp:keys:list
```

#### Deactivate a key:
```bash
bundle exec rake mcp:keys:deactivate[5]
```

#### Delete a key:
```bash
bundle exec rake mcp:keys:delete[5]
```

### Admin Web Interface (Optional)

Create a simple admin interface in Decko:

```ruby
# app/controllers/admin/mcp_keys_controller.rb
module Admin
  class McpKeysController < AdminController
    def index
      @keys = McpApiKey.order(created_at: :desc).page(params[:page])
    end

    def new
      @key = McpApiKey.new
    end

    def create
      result = McpApiKey.generate(
        name: params[:name],
        roles: params[:roles]&.split(','),
        rate_limit: params[:rate_limit]&.to_i || 1000,
        created_by: current_user.name,
        notes: params[:notes]
      )

      flash[:api_key] = result[:api_key]
      redirect_to admin_mcp_keys_path
    end

    def destroy
      @key = McpApiKey.find(params[:id])
      @key.deactivate!
      redirect_to admin_mcp_keys_path, notice: "Key deactivated"
    end
  end
end
```

## Best Practices

### Key Generation

✅ **Do:**
- Use at least 32 bytes (64 hex chars) for keys
- Generate with `SecureRandom.hex(32)`
- Hash keys before storing (SHA256)
- Show plaintext key ONCE on creation
- Include key prefix for identification

❌ **Don't:**
- Store plaintext keys in database
- Use predictable key patterns
- Reuse keys across environments

### Key Distribution

✅ **Do:**
- Share keys via secure channel (encrypted email, password manager)
- Document who has each key
- Set expiration dates for test keys
- Use descriptive names ("Production Client", "Test User - Jane")

❌ **Don't:**
- Put keys in git repositories
- Share keys in Slack/Discord
- Email keys in plaintext
- Use same key for dev/staging/production

### Key Rotation

✅ **Do:**
- Rotate keys every 90 days
- Rotate immediately if compromised
- Provide grace period with both old and new keys active
- Notify users before deactivating old keys

### Monitoring

✅ **Do:**
- Log all API key usage
- Alert on unusual patterns
- Track last_used_at
- Monitor rate limits

## Migration Path

### Moving from Phase 1 to Phase 2

1. **Run Migration:**
   ```bash
   bundle exec rake db:migrate
   ```

2. **Create Initial Keys:**
   ```bash
   # Create keys for existing users
   bundle exec rake mcp:keys:generate["Production Client","user,gm,admin","admin"]
   ```

3. **Update Auth Controller:**
   - Uncomment Phase 2 code
   - Keep Phase 1 code temporarily for backwards compatibility

4. **Test New Keys:**
   ```bash
   curl -X POST https://wiki.magi-agi.org/api/mcp/auth \
     -H "Content-Type: application/json" \
     -d '{"api_key":"NEW_KEY_HERE","role":"user"}'
   ```

5. **Notify Existing Users:**
   - Send new keys via secure channel
   - Set deadline for transition
   - Keep old `MCP_API_KEY` active during grace period

6. **Remove Phase 1 Code:**
   - After all users migrated
   - Remove `ENV["MCP_API_KEY"]` fallback
   - Remove from `.env.production`

## Quick Reference

### Current (Phase 1) - Giving Access

```bash
# On server
echo $MCP_API_KEY
# Share this key with user

# User's .env
MCP_API_KEY=<shared-key>
MCP_ROLE=user
```

### Future (Phase 2) - Giving Access

```bash
# On server - generate unique key
bundle exec rake mcp:keys:generate["User Name","user","admin@example.com"]
# Copy the generated key

# Send key to user (secure channel)

# User's .env
MCP_API_KEY=<their-unique-key>
MCP_ROLE=user
```

## Security Checklist

- [ ] API keys are at least 32 bytes (64 hex chars)
- [ ] Keys are hashed before storage (never plaintext in DB)
- [ ] Keys use cryptographically secure random generation
- [ ] Per-key role restrictions enforced
- [ ] Rate limiting implemented
- [ ] Audit logging enabled
- [ ] Key expiration supported
- [ ] Key rotation process documented
- [ ] Secure key distribution method established
- [ ] Monitoring and alerting configured

## Support

- **Server Code:** `magi-archive/deck/mod/mcp_api/`
- **Auth Controller:** `app/controllers/api/mcp/auth_controller.rb`
- **Client Gem:** `magi-archive-mcp/`
- **Issues:** Report to Decko admin or GitLab repository

---

**Current Status:** Phase 1 (Single Shared Key)
**Recommended:** Upgrade to Phase 2 for production use
**Last Updated:** 2025-12-03
