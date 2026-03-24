# Publishing Magi Archive MCP Server to npm/mcp.run

This guide covers publishing the Magi Archive MCP Server to npm and registering it on mcp.run for ChatGPT Desktop integration.

## Prerequisites

1. **npm Account**: Create account at https://www.npmjs.com
2. **npm CLI**: Ensure npm is installed (Node.js 16+ recommended)
3. **Two-Factor Authentication**: Enable 2FA on your npm account (required for publishing)
4. **mcp.run Account**: Create account at https://mcp.run
5. **Repository Access**: Push access to the GitHub repository

## Important: npm Security Updates (2025)

**Classic npm tokens are deprecated and will be revoked.** You must use one of these authentication methods:

### For Manual Publishing (Recommended)
Use `npm login` which creates secure granular access tokens:
```bash
npm login
# Follow interactive prompts - uses WebAuthn or authenticator app
```

### For CI/CD (Recommended)
Use **Trusted Publishing** (OIDC) which provides temporary, job-specific credentials without long-lived tokens:
- GitHub Actions: Configure OIDC trust relationship
- No token storage required
- Automatic rotation and better audit trails
- See: https://docs.npmjs.com/generating-provenance-statements

### For Automation (Legacy)
If you must use tokens, create **granular access tokens** (not classic tokens):
- Default expiration: 7 days
- Maximum expiration: 90 days
- Scope to specific packages and operations
- See: https://docs.npmjs.com/about-access-tokens

**Important:** Never use classic tokens - they are being sunset and will stop working.

## Quick Reference

```bash
# Login to npm (first time only) - creates granular tokens automatically
npm login

# Publish to npm
npm publish --access public

# Update version
npm version patch  # or minor, or major
npm publish --access public
```

## Step 1: Prepare for Publishing

### 1.1 Verify Package Configuration

The `package.json` should already be configured with:

```json
{
  "name": "@magi-archive/mcp-server",
  "version": "0.1.0",
  "description": "MCP server for Magi Archive wiki",
  "bin": {
    "magi-archive-mcp": "./bin/mcp-server-npm.js"
  },
  "mcp": {
    "server": {
      "name": "magi-archive",
      "description": "Access the Magi Archive wiki",
      "capabilities": {
        "tools": true
      }
    }
  }
}
```

### 1.2 Test Locally

Before publishing, test the package locally:

```bash
# Install dependencies
bundle install

# Link package globally for testing
npm link

# Test the command
magi-archive-mcp --help

# Unlink when done testing
npm unlink -g @magi-archive/mcp-server
```

### 1.3 Create .npmignore

Create `.npmignore` to exclude unnecessary files:

```
# Test files
spec/
tmp/
.rspec
.rubocop.yml

# Development files
.env
.env.*
*.swp
*.swo
*~

# Documentation (keep README.md)
CLAUDE.md
AGENTS.md
MCP-SPEC.md
PUBLISHING.md

# Git
.git/
.gitignore

# Build artifacts
pkg/
coverage/
```

**Important:** Unlike `.gitignore`, npm includes files by default, so `.npmignore` specifies what to **exclude**.

## Step 2: Publish to npm

### 2.1 Login to npm

```bash
npm login
```

Enter your npm credentials when prompted.

### 2.2 Publish Package

For scoped packages (like `@magi-archive/mcp-server`), use `--access public`:

```bash
npm publish --access public
```

### 2.3 Verify Publication

```bash
# Check package page
open https://www.npmjs.com/package/@magi-archive/mcp-server

# Test installation
npm install -g @magi-archive/mcp-server
```

## Step 3: Register on mcp.run

### 3.1 Create mcp.run Account

1. Visit https://mcp.run
2. Sign up with GitHub account
3. Verify email

### 3.2 Register MCP Server

1. Go to https://mcp.run/servers/new
2. Fill in server details:
   - **Name**: `magi-archive`
   - **Description**: Access the Magi Archive wiki - search, create, and manage cards with role-based permissions
   - **npm Package**: `@magi-archive/mcp-server`
   - **Category**: Knowledge & Documentation
   - **Repository**: `https://github.com/your-org/magi-archive-mcp`
   - **Homepage**: `https://wiki.magi-agi.org`

3. Add authentication requirements:
   - Type: API Key
   - Environment Variables:
     - `MCP_USERNAME` (required)
     - `MCP_PASSWORD` (required)
     - `DECKO_API_BASE_URL` (optional, defaults to https://wiki.magi-agi.org/api/mcp)

4. Add tags:
   - `wiki`
   - `knowledge-base`
   - `magi-archive`
   - `decko`
   - `documentation`

5. Submit for review

### 3.3 Verification

mcp.run will verify:
- Package exists on npm
- Package has valid `mcp` field in package.json
- Server starts correctly
- Basic functionality works

## Step 4: Update for New Versions

### 4.1 Semantic Versioning

Follow semantic versioning (semver):
- **Patch** (0.1.0 → 0.1.1): Bug fixes, minor changes
- **Minor** (0.1.0 → 0.2.0): New features, backward compatible
- **Major** (0.1.0 → 1.0.0): Breaking changes

### 4.2 Release Process

```bash
# Update version in package.json
npm version patch  # or minor, or major

# This creates a git tag automatically
# Push changes and tags
git push
git push --tags

# Publish to npm
npm publish --access public
```

### 4.3 Update mcp.run Listing

mcp.run automatically detects new npm versions. You may need to:
1. Update server description if features changed
2. Add release notes on the server page
3. Update screenshots/documentation

## Step 5: Maintenance

### 5.1 Responding to Issues

Monitor:
- npm package downloads and issues
- mcp.run server reviews and ratings
- GitHub issues related to npm installation

### 5.2 Deprecating Old Versions

If a version has critical bugs:

```bash
npm deprecate @magi-archive/mcp-server@0.1.0 "Critical bug, please upgrade to 0.1.1"
```

### 5.3 Unpublishing (Rarely Used)

**Warning:** npm has strict unpublish policies. You can only unpublish:
- Within 72 hours of publishing
- If no one has installed it

```bash
# Only in emergencies
npm unpublish @magi-archive/mcp-server@0.1.0
```

## Troubleshooting

### Package Name Already Taken

If `@magi-archive/mcp-server` is taken:
1. Choose alternative name (e.g., `@magi-agi/archive-mcp`)
2. Update `package.json` name field
3. Update all documentation

### mcp.run Verification Failed

Common issues:
- **Server doesn't start**: Check `bin/mcp-server-npm.js` paths
- **Missing mcp field**: Verify `package.json` has `mcp` object
- **Authentication fails**: Ensure clear env var documentation

### Users Can't Find Server in ChatGPT

1. Verify package is published: `npm view @magi-archive/mcp-server`
2. Check mcp.run listing is approved
3. Ensure ChatGPT Desktop is updated
4. Users may need to manually search for "magi-archive" in ChatGPT settings

## Security Considerations

### npm Authentication Security (Critical)

1. **Use Granular Tokens Only**: Classic tokens are deprecated and will be revoked
   - Manual publishing: Use `npm login` (creates granular tokens automatically)
   - CI/CD: Use Trusted Publishing (OIDC) - no tokens needed
   - Automation: Create granular access tokens (7-90 day expiration)
   - See: https://github.blog/changelog/2025-09-29-strengthening-npm-security-important-changes-to-authentication-and-token-management/

2. **Token Lifetime Management**:
   - Granular tokens expire after 7 days by default (90 days maximum)
   - Plan to refresh tokens before expiration
   - Monitor npm for expiration warnings
   - Consider switching to Trusted Publishing to avoid token management

3. **Migrate from Classic Tokens**: If you're using classic tokens:
   - Generate new granular access tokens immediately
   - Update all automation/CI/CD configurations
   - Revoke old classic tokens
   - Classic tokens will stop working after mid-November 2025

### Package Security

1. **Never commit secrets**: Exclude `.env` files
2. **Review dependencies**: Run `npm audit` before publishing
3. **Sign releases**: Use npm provenance (automatic with Trusted Publishing)
4. **Enable 2FA**: Required for npm publishing (use WebAuthn/passkeys, not TOTP)

### mcp.run Security

1. **API Key Management**: Document secure credential storage
2. **Rate Limiting**: Ensure server respects API rate limits
3. **Error Messages**: Don't expose sensitive info in errors
4. **Audit Logging**: Server-side logs user actions

## Resources

- **npm Documentation**: https://docs.npmjs.com/
- **npm Security Updates (2025)**: https://github.blog/changelog/2025-09-29-strengthening-npm-security-important-changes-to-authentication-and-token-management/
- **npm Granular Access Tokens**: https://docs.npmjs.com/about-access-tokens
- **npm Trusted Publishing**: https://docs.npmjs.com/generating-provenance-statements
- **mcp.run Docs**: https://docs.mcp.run
- **MCP Specification**: https://modelcontextprotocol.io
- **Semantic Versioning**: https://semver.org/

## Support

For publishing issues:
- npm support: https://www.npmjs.com/support
- mcp.run support: https://mcp.run/support
- Package issues: GitHub Issues

---

**Last Updated:** December 2024
**Package:** @magi-archive/mcp-server
**Registry:** npm (public)
**Platform:** mcp.run
