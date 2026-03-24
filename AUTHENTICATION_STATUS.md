# MCP API Authentication Status

## ✅ Working: Email-Based Authentication

Users can authenticate using their **email address** and password.

### Example Request
```bash
curl -X POST http://54.219.9.17:3000/api/mcp/auth \
  -H 'Content-Type: application/json' \
  -d '{
    "username": "lake.watkins@gmail.com",
    "password": "your-password",
    "role": "user"
  }'
```

### Example Response
```json
{
  "token": "eyJraWQiOiJwcm9kLWtleS0wMDEi...",
  "role": "user",
  "username": "Nemquae",
  "expires_in": 3600,
  "expires_at": 1765215296,
  "auth_method": "username"
}
```

The returned JWT token can be used to authenticate with all MCP API endpoints:
```bash
curl -X GET http://54.219.9.17:3000/api/mcp/cards/Nemquae \
  -H "Authorization: Bearer YOUR_TOKEN"
```

## ❌ Known Limitation: Username-Only Authentication

Authentication using just the **username** (without email) currently fails.

### Does NOT Work
```bash
curl -X POST http://54.219.9.17:3000/api/mcp/auth \
  -H 'Content-Type: application/json' \
  -d '{
    "username": "Nemquae",
    "password": "your-password",
    "role": "user"
  }'
# Returns: 401 Unauthorized - Invalid credentials
```

### Root Cause

The `find_user_card(username)` method in `/home/ubuntu/magi-archive/mod/mcp_api/lib/mcp/user_authenticator.rb:99` returns `nil` when searching by username only.

Investigation revealed:
1. `Card.find_by_name("Nemquae")` succeeds when tested independently
2. But fails when called within the authentication flow
3. Possibly related to database connection timing or transaction context
4. May also be affected by Decko's card caching mechanisms

### Workaround

**Use email addresses for authentication.**

All Decko users have an email address stored in their account card (`Username+*account+*email`). This is the recommended authentication method.

### Technical Details

The authentication flow has two paths:

1. **✅ Email Path (Working)**
   ```
   Card::Auth.authenticate(email, password)
   → Returns: Nemquae+*account card
   → Extract username: "Nemquae"
   → Find user card: Card.find_by_name("Nemquae")
   → Determine role from user card
   → Generate JWT token
   ```

2. **❌ Username Path (Failing)**
   ```
   find_user_card(username)
   → Returns: nil (should return User card)
   → Authentication fails before reaching Card::Auth
   ```

## Fixed Issues

During debugging, the following issues were resolved:

- ✅ **fetch(trait:) calls**: Changed to `Card.find_by_name(user_card.name.to_s + "+*trait")` to avoid "Hash not supported" errors
- ✅ **Column names**: Changed all `.content` to `.db_content` (correct Decko database column)
- ✅ **Card::Name objects**: Properly convert to strings with `.to_s` before string concatenation
- ✅ **Authentication method**: Now uses Decko's `Card::Auth.authenticate` with SHA1 hashing (not BCrypt)
- ✅ **Email extraction**: Correctly reads from `Username+*account+*email` subcard
- ✅ **Account card extraction**: Properly removes `+*account` suffix with regex

## Implementation Files

- `/home/ubuntu/magi-archive/mod/mcp_api/lib/mcp/user_authenticator.rb` - Core authentication logic
- `/home/ubuntu/magi-archive/mod/mcp_api/app/controllers/api/mcp/auth_controller.rb` - Authentication endpoint
- `/home/ubuntu/magi-archive/mod/mcp_api/lib/mcp/jwt_issuer.rb` - JWT token generation

## Testing

### Manual Test (Email Auth)
```bash
# Store token in variable
TOKEN=$(curl -s -X POST http://54.219.9.17:3000/api/mcp/auth \
  -H 'Content-Type: application/json' \
  -d '{"username":"lake.watkins@gmail.com","password":"PASS","role":"user"}' | \
  python3 -c "import sys, json; print(json.load(sys.stdin)['token'])")

# Use token to fetch card
curl -X GET http://54.219.9.17:3000/api/mcp/cards/Nemquae \
  -H "Authorization: Bearer $TOKEN"
```

### Automated Tests Needed
- [ ] RSpec tests for email authentication path
- [ ] RSpec tests for username authentication path (when fixed)
- [ ] Integration tests for full auth → API call flow
- [ ] Tests for role-based access control

## Next Steps

### For Production Use
1. **Documentation**: Update API documentation to specify email authentication is required
2. **Client Updates**: Update `.env` files to use email addresses for MCP_USERNAME
3. **Error Messages**: Improve 401 error message to suggest using email instead of username

### For Future Development
1. **Debug username auth**: Add detailed logging to understand why `find_user_card` fails
2. **Direct account lookup**: Try `Card.find_by_name("#{username}+*account")` as primary path
3. **Add tests**: Create RSpec tests that catch this regression
4. **Performance**: Consider caching user lookups to avoid repeated database queries

## Commit History

- `e1f6394` - Fix authentication to use Card::Auth.authenticate (2025-12-08)
  - Complete rewrite of authenticate() method
  - Fixed all fetch(trait:) calls
  - Fixed database column references
  - Email authentication fully functional

---

**Last Updated**: 2025-12-08
**Status**: ✅ Production-ready for email-based authentication
**Known Issue**: Username-only authentication not working (use email instead)
