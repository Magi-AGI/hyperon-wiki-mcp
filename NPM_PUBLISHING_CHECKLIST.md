# npm Publishing Checklist - Step-by-Step Guide

Follow these steps in order to publish the Magi Archive MCP Server to npm for ChatGPT Desktop integration.

## Prerequisites Checklist

- [ ] npm account created at https://www.npmjs.com
- [ ] 2FA enabled on npm account (WebAuthn/passkey or authenticator app)
- [ ] Node.js 16+ installed (`node --version`)
- [ ] npm CLI installed (`npm --version`)
- [ ] Git repository up to date (all changes committed)

## Step 1: Set Up npm Account (One-Time Setup)

### 1.1 Create npm Account
```bash
# If you don't have an account yet
# Visit: https://www.npmjs.com/signup
```

### 1.2 Enable 2FA (Required for Publishing)
1. Go to https://www.npmjs.com/settings/[username]/twofa/auth-and-writes
2. Click "Enable 2FA for authorization and publishing"
3. Choose authentication method:
   - **Recommended**: WebAuthn/Security Key (most secure)
   - **Alternative**: Authenticator app (Google Authenticator, Authy, etc.)
4. Follow prompts to complete setup
5. Save recovery codes in a secure location

### 1.3 Login to npm from CLI
```bash
npm login
```

You'll be prompted for:
- Username
- Password
- Email
- 2FA code (from authenticator app or security key)

This creates a **granular access token** automatically (no manual token creation needed).

**Important**: This login creates a token that expires after 7 days by default. You'll need to login again before publishing after that period.

## Step 2: Prepare the Package

### 2.1 Verify Package Files Exist
```bash
cd E:/GitLab/the-smithy1/magi/Magi-AGI/magi-archive-mcp

# Check all required files exist
ls -l package.json
ls -l bin/mcp-server-npm.js
ls -l scripts/check-ruby.js
ls -l .npmignore
ls -l README.md
```

### 2.2 Test Package Locally
```bash
# Install dependencies
bundle install

# Create local npm link for testing
npm link

# Test the command works
magi-archive-mcp --help

# If it works, unlink
npm unlink -g @magi-archive/mcp-server
```

### 2.3 Run Quality Checks
```bash
# Check for security vulnerabilities
npm audit

# Validate package.json
npm pkg fix

# Preview what will be published (don't actually publish yet)
npm pack --dry-run
```

## Step 3: Version the Package

### 3.1 Choose Version Bump Type

Semantic versioning (current: 0.1.0):
- **Patch** (0.1.0 → 0.1.1): Bug fixes only
- **Minor** (0.1.0 → 0.2.0): New features, backward compatible
- **Major** (0.1.0 → 1.0.0): Breaking changes

### 3.2 Update Version
```bash
# For initial release (already at 0.1.0)
# No change needed

# For future updates, use one of:
npm version patch -m "Bump to %s - bug fixes"
npm version minor -m "Bump to %s - new features"
npm version major -m "Bump to %s - breaking changes"
```

This automatically:
- Updates package.json
- Creates git commit
- Creates git tag

## Step 4: Publish to npm

### 4.1 Final Pre-Publishing Checks
```bash
# Ensure you're logged in (check if token expired)
npm whoami

# If that fails, login again:
npm login

# Verify package name is available/correct
npm view @magi-archive/mcp-server
# Should return 404 for first publish, or show existing versions
```

### 4.2 Publish Package
```bash
# For scoped packages (@magi-archive/...), must use --access public
npm publish --access public
```

**Expected Output:**
```
npm notice
npm notice package: @magi-archive/mcp-server@0.1.0
npm notice === Tarball Contents ===
npm notice [file list]
npm notice === Tarball Details ===
npm notice name:          @magi-archive/mcp-server
npm notice version:       0.1.0
npm notice package size:  XX.X kB
npm notice unpacked size: XX.X kB
npm notice total files:   XX
npm notice
+ @magi-archive/mcp-server@0.1.0
```

### 4.3 Verify Publication
```bash
# Check package page exists
npm view @magi-archive/mcp-server

# Test installation
npm install -g @magi-archive/mcp-server

# Verify it works
magi-archive-mcp --version
```

### 4.4 Push Git Changes
```bash
# Push the version commit and tag to GitHub
git push
git push --tags
```

## Step 5: Register on mcp.run

### 5.1 Create mcp.run Account
1. Visit https://mcp.run
2. Click "Sign up"
3. Sign up with GitHub account
4. Verify email address

### 5.2 Register MCP Server
1. Go to https://mcp.run/servers/new
2. Fill in the registration form:

**Basic Information:**
- **Name**: `magi-archive`
- **Display Name**: `Magi Archive MCP Server`
- **Description**: Access the Magi Archive wiki - search, create, and manage cards with role-based permissions. Provides 16+ tools for card operations, batch updates, weekly summaries, and more.

**Package Details:**
- **npm Package**: `@magi-archive/mcp-server`
- **Category**: Knowledge & Documentation
- **Repository URL**: `https://github.com/your-org/magi-archive-mcp`
- **Homepage URL**: `https://wiki.magi-agi.org`

**Authentication:**
- **Type**: Environment Variables
- **Required Variables**:
  - `MCP_USERNAME` - Decko wiki username
  - `MCP_PASSWORD` - Decko wiki password
- **Optional Variables**:
  - `DECKO_API_BASE_URL` - API endpoint (defaults to https://wiki.magi-agi.org/api/mcp)

**Additional Information:**
- **Tags**: `wiki`, `knowledge-base`, `magi-archive`, `decko`, `documentation`, `mcp-server`
- **Installation Instructions**: See npm package README

3. Click "Submit for Review"
4. Wait for mcp.run team approval (usually 1-3 days)

### 5.3 Post-Registration
Once approved:
- Server will appear in ChatGPT Desktop's MCP server list
- Users can install with `npm install -g @magi-archive/mcp-server`
- Server auto-discovered after setting environment variables

## Step 6: Announce and Document

### 6.1 Update Documentation
- [ ] Add npm package badge to README.md
- [ ] Update installation instructions
- [ ] Create release notes on GitHub

### 6.2 Create GitHub Release
```bash
# Tag should already exist from npm version
# Go to: https://github.com/your-org/magi-archive-mcp/releases/new
# Select the tag (e.g., v0.1.0)
# Add release notes
```

### 6.3 Announce
- [ ] Post to project Discord/Slack
- [ ] Update wiki.magi-agi.org with installation instructions
- [ ] Share on social media (if applicable)

## Troubleshooting

### "You must sign in to publish packages"
```bash
npm login
# Enter credentials and 2FA code
```

### "E402: 402 Payment Required"
Your account needs to enable publishing. Visit npm account settings.

### "E403: Forbidden"
- Check package name isn't taken by someone else
- Ensure you have publish rights to the `@magi-archive` scope
- Verify 2FA is enabled on your account

### "npm ERR! code ENEEDAUTH"
Your login token expired (granular tokens expire after 7 days).
```bash
npm login
```

### "Package name too similar to existing package"
npm prevents name-squatting. Choose a different name if needed.

### "2FA code required but not provided"
Ensure 2FA is set up correctly on your npm account.

### Package published but not appearing in ChatGPT Desktop
1. Verify package exists: `npm view @magi-archive/mcp-server`
2. Check mcp.run listing is approved
3. Ensure ChatGPT Desktop is updated to latest version
4. Try manually searching for "magi-archive" in ChatGPT settings

## Token Maintenance

### Checking Token Status
```bash
# Check if you're logged in
npm whoami

# If this fails, your token expired - login again
npm login
```

### Token Expiration
- Granular tokens expire after **7 days** by default
- You'll need to run `npm login` again before publishing
- npm will email you when tokens are about to expire

### CI/CD Publishing (Future)
For automated publishing, consider switching to **Trusted Publishing** (OIDC):
- No tokens needed
- More secure
- Automatic rotation
- See: https://docs.npmjs.com/generating-provenance-statements

## Quick Reference Commands

```bash
# Check npm login status
npm whoami

# Login to npm
npm login

# Test package locally
npm link

# Validate package
npm pkg fix
npm audit

# Publish (first time)
npm publish --access public

# Update version and publish
npm version patch -m "Bump to %s"
npm publish --access public

# Push to git
git push && git push --tags
```

## Support

- **npm Issues**: https://www.npmjs.com/support
- **mcp.run Issues**: https://mcp.run/support
- **Package Issues**: https://github.com/your-org/magi-archive-mcp/issues

---

**Last Updated**: December 2024
**Package**: @magi-archive/mcp-server
**Current Version**: 0.1.0
**Status**: Ready for initial publication
