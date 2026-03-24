# Quick Start: Giving Test Access to Another User

## For the Admin (You)

### Step 1: Get Your Server's API Key

SSH into your Decko server:

```bash
ssh ubuntu@wiki.magi-agi.org
cd /path/to/decko
cat .env.production | grep MCP_API_KEY
```

If you don't have an API key yet, generate one:

```bash
# Generate a secure 64-character key
ruby -r securerandom -e "puts SecureRandom.hex(32)"
```

Add it to your server's `.env.production`:

```bash
echo "MCP_API_KEY=your-generated-key-here" >> .env.production
decko restart
```

### Step 2: Share with Test User

Send them (via secure channel):

**API Key:** `your-generated-key-here`
**Role:** `user` (or `gm` or `admin` depending on what access they need)
**Server URL:** `https://wiki.magi-agi.org/api/mcp`

Also send them:
- Link to the gem file: `magi-archive-mcp/pkg/magi-archive-mcp-0.1.0.gem`
- Or installation instructions from `DEPLOYMENT.md`

---

## For the Test User (Them)

### Step 1: Install the Gem

Save the gem file you received, then:

```bash
# Install the gem
gem install --user-install path/to/magi-archive-mcp-0.1.0.gem

# Add to PATH (Linux/Mac)
export PATH="$HOME/.local/share/gem/ruby/3.2.0/bin:$PATH"
```

### Step 2: Configure

Create a `.env` file in your working directory:

```bash
MCP_API_KEY=the-key-admin-gave-you
MCP_ROLE=user
DECKO_API_BASE_URL=https://wiki.magi-agi.org/api/mcp
```

### Step 3: Test

Run the test script:

```bash
ruby test_installation.rb
```

Or test the CLI directly:

```bash
# Get a card
magi-archive-mcp get "Main Page"

# Search
magi-archive-mcp search --query "test"

# List types
magi-archive-mcp types
```

---

## Troubleshooting

### "Invalid API key" error

**Problem:** The API key doesn't match what's on the server.

**Solution:** Admin should double-check the key from `.env.production` on the server.

### "Permission denied for role" error

**Problem:** The API key might not allow that role (future Phase 2 feature).

**Solution:** For now, all roles should work. Check server logs for details.

### Connection refused

**Problem:** Server might be down or firewall blocking.

**Solution:**
```bash
# Test if server is reachable
curl https://wiki.magi-agi.org/api/mcp/auth

# Should return a 4xx error (expected without valid auth)
```

---

## Role Permissions Reference

### `user` Role (Recommended for testing)
- ✓ Read public cards
- ✓ Create/update own cards
- ✗ Cannot see GM/AI cards
- ✗ Cannot delete cards

### `gm` Role
- ✓ Read all cards (including GM/AI)
- ✓ Create/update cards
- ✗ Cannot delete cards

### `admin` Role
- ✓ Full access
- ✓ Delete cards
- ⚠️ Use with caution!

---

## Security Notes

⚠️ **Current Phase 1 Limitation:**
- Everyone shares the same API key
- Anyone with the key can request any role
- Only share with trusted users!

🔒 **For Production:**
See `SERVER_API_KEY_MANAGEMENT.md` for implementing per-user API keys (Phase 2).

---

## Quick Reference Card

**Admin gives user:**
```
API Key: 3f9a8b2c1d4e5f6a7b8c9d0e1f2a3b4c
Role: user
Server: https://wiki.magi-agi.org/api/mcp
```

**User creates `.env`:**
```bash
MCP_API_KEY=3f9a8b2c1d4e5f6a7b8c9d0e1f2a3b4c
MCP_ROLE=user
DECKO_API_BASE_URL=https://wiki.magi-agi.org/api/mcp
```

**User tests:**
```bash
magi-archive-mcp --version
magi-archive-mcp search --query "test"
```

**Success!** 🎉
