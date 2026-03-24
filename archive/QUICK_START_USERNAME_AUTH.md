# Quick Start: Username/Password Authentication

## For Users - The Simple Way!

No API keys needed! Just use your existing Decko wiki credentials.

### Step 1: Install the Gem

```bash
# If you received the gem file
gem install --user-install path/to/magi-archive-mcp-0.1.0.gem

# Add to PATH (Linux/Mac)
export PATH="$HOME/.local/share/gem/ruby/3.2.0/bin:$PATH"
```

### Step 2: Configure with Your Credentials

Create a `.env` file in your working directory:

```bash
# Use your regular Decko wiki username and password
MCP_USERNAME=your_username
MCP_PASSWORD=your_password
DECKO_API_BASE_URL=https://wiki.magi-agi.org/api/mcp
```

That's it! No need to contact admin for an API key.

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

## How It Works

### Automatic Role Detection

Your role is **automatically determined** from your Decko account permissions:

- **Admin** - If you have administrator permissions in Decko
- **GM** - If you're in the "Game Master" role
- **User** - Regular user permissions

No need to specify a role - the system knows who you are!

### Role Override (Optional)

If you have multiple roles (e.g., you're an admin but want to test as a user), you can override:

```bash
# In your .env file
MCP_USERNAME=your_username
MCP_PASSWORD=your_password
MCP_ROLE=user  # Override to user role even if you're an admin
```

## Examples

### Example 1: Regular User

```bash
# .env
MCP_USERNAME=john_doe
MCP_PASSWORD=secret123
```

**Result:** Authenticated as `user` role (auto-detected from your account)

### Example 2: Game Master

```bash
# .env
MCP_USERNAME=gm_alice
MCP_PASSWORD=gm_secret
```

**Result:** Authenticated as `gm` role (auto-detected because you're in GM group)

### Example 3: Administrator

```bash
# .env
MCP_USERNAME=admin
MCP_PASSWORD=admin_pass
```

**Result:** Authenticated as `admin` role (auto-detected from your admin permissions)

### Example 4: Admin Testing as User

```bash
# .env
MCP_USERNAME=admin
MCP_PASSWORD=admin_pass
MCP_ROLE=user  # Override to test with limited permissions
```

**Result:** Authenticated as `user` role (even though you're an admin)

## Using in Code

### Basic Usage

```ruby
require "magi/archive/mcp"

# Initialize tools (uses MCP_USERNAME and MCP_PASSWORD from .env)
tools = Magi::Archive::Mcp::Tools.new

# Get a card
card = tools.get_card("Main Page")
puts "Card: #{card['name']}"
puts "Role: #{card['role']}"  # Shows your auto-detected role
```

### Check Your Role

```ruby
require "magi/archive/mcp"

tools = Magi::Archive::Mcp::Tools.new
token_info = tools.client.auth.token

# The token contains your username and role
puts "Authenticated as: #{token_info[:username]}"
puts "Role: #{token_info[:role]}"
```

## Troubleshooting

### "Authentication failed: User not found"

**Problem:** Username doesn't exist in Decko.

**Solution:** Check your spelling. Usernames are case-sensitive. Try logging into wiki.magi-agi.org to verify.

### "Authentication failed: Invalid password"

**Problem:** Password is incorrect.

**Solution:** Reset your password on wiki.magi-agi.org if needed.

### "Permission denied for role 'admin'"

**Problem:** You requested admin role but don't have admin permissions.

**Solution:** Remove `MCP_ROLE=admin` from your `.env` to use auto-detection, or use a role you have permission for.

## Advantages Over API Keys

✅ **No admin intervention** - Use your existing credentials
✅ **Automatic role detection** - System knows your permissions
✅ **Easier to remember** - Same as your wiki login
✅ **Easier to change** - Just change your Decko password
✅ **Better audit trail** - Actions tied to your actual user account
✅ **Unified authentication** - Same system as web login

## When to Use API Keys Instead

API keys are still useful for:
- **Service accounts** - Automated scripts, bots
- **Shared environments** - Multiple users on same machine
- **CI/CD pipelines** - Automated testing
- **Long-running processes** - Where password changes would break things

For human users doing interactive work, **username/password is recommended**.

## Security Notes

⚠️ **Keep your `.env` file secure**
- Never commit `.env` to git (it's in `.gitignore`)
- Don't share your password
- Use a strong password

🔒 **Password storage**
- Passwords are only sent over HTTPS
- Never stored by the client
- Only used to get a temporary token (1 hour)
- Token refreshes automatically

## Quick Reference Card

**Create `.env` file:**
```bash
MCP_USERNAME=your_username
MCP_PASSWORD=your_password
DECKO_API_BASE_URL=https://wiki.magi-agi.org/api/mcp
```

**Test it:**
```bash
magi-archive-mcp search --query "test"
```

**Success!** 🎉

Your role is automatically detected from your Decko account - no need to specify it!

---

**Still want to use API keys?** See `QUICK_START_FOR_TEST_USER.md` for the API key method (recommended for service accounts only).
