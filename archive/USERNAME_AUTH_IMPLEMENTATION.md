# Username/Password Authentication Implementation

## ✅ Complete - Username/Password Authentication

Username/password authentication has been successfully implemented as the **primary authentication method** for human users, with API keys remaining available for service accounts and automation.

## Overview

### What Changed

**Before (API Key Only):**
```
User → Contact Admin → Get API Key → Configure Client → Use API
```

**After (Username/Password):**
```
User → Use Existing Credentials → Auto-detect Role → Use API
```

### Benefits

✅ **No Admin Intervention** - Users don't need to contact admin for API keys
✅ **Automatic Role Detection** - System determines role from Decko permissions
✅ **Better UX** - Use existing wiki credentials
✅ **Better Security** - Actions tied to actual user accounts
✅ **Unified Auth** - Same as web login
✅ **Easier Password Reset** - Change password in one place

## Implementation Details

### Server Side (Decko)

#### 1. User Authenticator (`lib/mcp/user_authenticator.rb`)

Complete authentication and authorization module:

**Key Methods:**
- `authenticate(username, password)` - Verifies credentials against Decko
- `determine_role(user_card)` - Auto-detects role from permissions
- `admin?(user_card)` - Checks if user has admin permissions
- `gm?(user_card)` - Checks if user is in Game Master role

**Role Detection Logic:**
```ruby
# Admin check
- Is in "Administrator" or "Admin" role
- Has admin? flag on user card
- Has roles subcard with "Administrator"

# GM check
- Is in "Game Master" or "GM" role
- Has roles subcard with "Game Master" or "GM"

# Default
- Regular "user" role
```

#### 2. Updated Auth Controller (`app/controllers/api/mcp/auth_controller.rb`)

Supports **three authentication flows:**

**Flow 1: Username Only (Auto Role)**
```json
POST /api/mcp/auth
{
  "username": "john_doe",
  "password": "secret"
}

Response:
{
  "token": "...",
  "role": "user",  // Auto-detected
  "username": "john_doe",
  "auth_method": "username"
}
```

**Flow 2: Username + Role Override**
```json
POST /api/mcp/auth
{
  "username": "admin_user",
  "password": "secret",
  "role": "user"  // Override to test with lower permissions
}

Response:
{
  "token": "...",
  "role": "user",  // Overridden (validated against permissions)
  "username": "admin_user"
}
```

**Flow 3: API Key (Service Accounts)**
```json
POST /api/mcp/auth
{
  "api_key": "64-char-key",
  "role": "user"  // Required
}

Response:
{
  "token": "...",
  "role": "user",
  "auth_method": "api_key"
}
```

**Token Payload (Username Auth):**
```ruby
{
  role: "user",
  username: "john_doe",
  email: "john@example.com",  // If available
  auth_method: "username",
  iat: 1234567890,
  exp: 1234571490
}
```

### Client Side (Ruby Gem)

#### 1. Updated Config (`lib/magi/archive/mcp/config.rb`)

Supports both authentication methods:

**Environment Variables:**
```bash
# Method 1: Username/Password
MCP_USERNAME=john_doe
MCP_PASSWORD=secret
# MCP_ROLE is optional (auto-detected)

# Method 2: API Key
MCP_API_KEY=64-char-key
MCP_ROLE=user  # Required with API key
```

**Auto-detection:**
```ruby
# Determines auth method based on what's provided
if username && password
  @auth_method = :username
elsif api_key
  @auth_method = :api_key
else
  raise ConfigurationError
end
```

**Auth Payload Generation:**
```ruby
case auth_method
when :username
  {
    username: username,
    password: password,
    role: role  # Optional
  }
when :api_key
  {
    api_key: api_key,
    role: role  # Required
  }
end
```

## Usage Examples

### For End Users

#### Simple Setup (Recommended)

```bash
# .env
MCP_USERNAME=john_doe
MCP_PASSWORD=my_password
```

```bash
# Test it
magi-archive-mcp search --query "test"
# Role auto-detected from your account!
```

#### With Role Override

```bash
# .env
MCP_USERNAME=admin_user
MCP_PASSWORD=admin_pass
MCP_ROLE=user  # Test with user permissions
```

### For Service Accounts

```bash
# .env
MCP_API_KEY=generated-64-char-key
MCP_ROLE=user
```

## Authentication Flow

### Username/Password Flow

```
1. Client sends username + password to /api/mcp/auth
2. Server calls Mcp::UserAuthenticator.authenticate()
3. Authenticator verifies credentials against Decko user system
4. Authenticator determines role from user permissions:
   - Checks admin? → admin role
   - Checks gm? → gm role
   - Default → user role
5. Server validates requested role (if provided) against detected role
6. Server generates token with username and role
7. Client stores token and uses for subsequent requests
```

### Role Hierarchy

```
admin (level 3) > gm (level 2) > user (level 1)
```

**Validation Rules:**
- Admin can request: admin, gm, or user
- GM can request: gm or user
- User can request: user only

**Examples:**
- Admin requests `user` role: ✅ Allowed (downgrade)
- User requests `admin` role: ❌ Denied (no permission)
- GM requests `gm` role: ✅ Allowed (exact match)

## Integration with Decko

### User Storage

Decko stores users as **Cards** of type "User":
- Username: Card name
- Password: `Username+*password` subcard (BCrypt encrypted)
- Roles: `Username+*roles` subcard (pointer to role cards)

### Authentication

Uses Decko's built-in authentication:
- `Card::Auth.authenticate(username, password)` if available
- Falls back to BCrypt password comparison
- Supports case-insensitive username lookup

### Permission Checking

Checks multiple permission indicators:
1. Role membership (`+roles` subcard)
2. Built-in flags (`admin?` method)
3. Role card pointers ("Administrator", "Game Master")

## Testing

### Server Testing

```bash
# Test username auth (auto role)
curl -X POST http://localhost:3000/api/mcp/auth \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"testpass"}'

# Test username auth (with role override)
curl -X POST http://localhost:3000/api/mcp/auth \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"adminpass","role":"user"}'

# Test API key (still works)
curl -X POST http://localhost:3000/api/mcp/auth \
  -H "Content-Type: application/json" \
  -d '{"api_key":"64-char-key","role":"user"}'
```

### Client Testing

```ruby
# Test username auth
ENV["MCP_USERNAME"] = "testuser"
ENV["MCP_PASSWORD"] = "testpass"

tools = Magi::Archive::Mcp::Tools.new
card = tools.get_card("Main Page")
# Role auto-detected!

# Test API key
ENV.delete("MCP_USERNAME")
ENV.delete("MCP_PASSWORD")
ENV["MCP_API_KEY"] = "test-key"
ENV["MCP_ROLE"] = "user"

tools = Magi::Archive::Mcp::Tools.new
card = tools.get_card("Main Page")
```

## Files Modified/Created

### Server Side

1. **Created:** `lib/mcp/user_authenticator.rb` (180 lines)
   - User authentication against Decko
   - Role detection from permissions

2. **Updated:** `app/controllers/api/mcp/auth_controller.rb` (225 lines)
   - Three authentication flows
   - Role validation and override
   - Token generation for both methods

### Client Side

3. **Updated:** `lib/magi/archive/mcp/config.rb` (181 lines)
   - Support for username/password
   - Auth method auto-detection
   - Flexible auth payload generation

4. **Updated:** `.env.test.template`
   - Two authentication methods
   - Clear examples for each

5. **Created:** `QUICK_START_USERNAME_AUTH.md`
   - User guide for username/password auth

6. **Updated:** `README.md`
   - Prominent documentation of both auth methods

## Migration Path

### Current Users (API Keys)

✅ **No changes required** - API key authentication still works exactly as before

### New Users

🎉 **Just use your Decko credentials** - No need to contact admin

### Transition Recommendation

**For Human Users:** Migrate to username/password
**For Service Accounts:** Keep using API keys

## Security Considerations

### Passwords

- ✅ Only sent over HTTPS
- ✅ Never stored by client
- ✅ Used once to get token
- ✅ Token expires after 1 hour
- ✅ Auto-refresh before expiry

### Tokens

- ✅ Include username for audit trail
- ✅ Include auth method
- ✅ Short-lived (1 hour default)
- ✅ MessageVerifier signed

### Role Escalation Prevention

- ✅ Server validates requested role against user permissions
- ✅ Cannot request higher role than you have
- ✅ Can request lower role (for testing)

## Backwards Compatibility

✅ **100% Backwards Compatible**

- API key authentication unchanged
- Existing Phase 1 env key still works
- Existing Phase 2 database keys still work
- All existing clients continue working
- Username/password is additive, not breaking

## Advantages Over API Key Only

| Aspect | API Key | Username/Password |
|--------|---------|-------------------|
| Setup | Contact admin | Use existing credentials |
| Role Detection | Manual specification | Automatic from permissions |
| Audit Trail | API key prefix | Actual username |
| Password Reset | Request new key | Change in one place |
| Multiple Roles | Need multiple keys | Override with one account |
| User Experience | Extra step | Seamless |

## When to Use Each Method

### Username/Password (Recommended For)

- 👤 Human users doing interactive work
- 🎮 Game Masters managing content
- 🔧 Admins performing maintenance
- 🧪 Testing with different permission levels

### API Keys (Recommended For)

- 🤖 Automated scripts and bots
- 🔄 CI/CD pipelines
- ⚙️ Service accounts
- 🔌 System integrations
- 📊 Long-running processes

## Next Steps

### For Deployment

1. **Deploy server changes** to wiki.magi-agi.org
2. **Update client gem** and redistribute
3. **Update documentation** for end users
4. **Announce** the new authentication method

### For Users

1. **Update gem**: `gem update magi-archive-mcp`
2. **Update `.env`**: Add MCP_USERNAME and MCP_PASSWORD
3. **Remove** MCP_API_KEY (if switching from API key)
4. **Test**: Run `magi-archive-mcp search --query "test"`

## Support

- **Server Code**: `magi-archive/deck/mod/mcp_api/`
- **Client Gem**: `magi-archive-mcp/`
- **User Guide**: `QUICK_START_USERNAME_AUTH.md`
- **API Key Guide**: `QUICK_START_FOR_TEST_USER.md` (for service accounts)

---

**Implementation Date:** 2025-12-03
**Status:** ✅ Complete and Production Ready
**Version:** Phase 2 + Username Auth
**Maintained by:** Magi AGI Team
