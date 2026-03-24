# MCP Registry Submission Guide

This guide covers submitting the Magi Archive MCP Server to the official Model Context Protocol registry.

## Repository

**Your Fork**: https://github.com/Magi-AGI/mcp-registry
**Upstream**: https://github.com/modelcontextprotocol/registry

## Submission Steps

### 1. Prepare Server Entry File

Create a JSON file describing your MCP server. The file should be named using the npm package name format.

**File**: `src/magi-agi/mcp-server.json`

```json
{
  "name": "@magi-agi/mcp-server",
  "version": "0.1.0",
  "description": "MCP server for Magi Archive wiki - provides AI agents secure access to the Magi Archive knowledge base",
  "homepage": "https://wiki.magi-agi.org",
  "repository": {
    "type": "git",
    "url": "https://github.com/your-org/magi-archive-mcp"
  },
  "license": "MIT",
  "author": "Magi AGI Project",
  "categories": [
    "knowledge-management",
    "documentation",
    "wiki"
  ],
  "installation": {
    "npm": "@magi-agi/mcp-server"
  },
  "configuration": {
    "required": {
      "env": {
        "MCP_USERNAME": {
          "description": "Decko wiki username",
          "type": "string"
        },
        "MCP_PASSWORD": {
          "description": "Decko wiki password",
          "type": "string",
          "secret": true
        }
      }
    },
    "optional": {
      "env": {
        "DECKO_API_BASE_URL": {
          "description": "API endpoint URL",
          "type": "string",
          "default": "https://wiki.magi-agi.org/api/mcp"
        }
      }
    }
  },
  "capabilities": {
    "tools": true,
    "resources": false,
    "prompts": false
  },
  "tools": [
    {
      "name": "get_card",
      "description": "Fetch a card by name from the wiki"
    },
    {
      "name": "search_cards",
      "description": "Search for cards by query, type, or filters"
    },
    {
      "name": "create_card",
      "description": "Create a new card in the wiki"
    },
    {
      "name": "update_card",
      "description": "Update an existing card"
    },
    {
      "name": "delete_card",
      "description": "Delete a card (admin only)"
    },
    {
      "name": "list_children",
      "description": "List all child cards of a parent card"
    },
    {
      "name": "get_tags",
      "description": "Get all tags or tags for a specific card"
    },
    {
      "name": "search_by_tags",
      "description": "Search for cards by tags with AND or OR logic"
    },
    {
      "name": "get_relationships",
      "description": "Get relationship information for a card"
    },
    {
      "name": "validate_card",
      "description": "Validate a card's tags and structure"
    },
    {
      "name": "get_recommendations",
      "description": "Get structure recommendations for cards"
    },
    {
      "name": "get_types",
      "description": "List all card types available"
    },
    {
      "name": "render_content",
      "description": "Convert content between HTML and Markdown"
    },
    {
      "name": "admin_backup",
      "description": "Manage database backups (admin only)"
    },
    {
      "name": "create_weekly_summary",
      "description": "Generate weekly summary card combining wiki and repo activity"
    }
  ]
}
```

### 2. Fork and Clone the Registry

```bash
# Already done - you forked to: https://github.com/Magi-AGI/mcp-registry

# Clone your fork
git clone https://github.com/Magi-AGI/mcp-registry.git
cd mcp-registry

# Add upstream remote
git remote add upstream https://github.com/modelcontextprotocol/registry.git
```

### 3. Create Feature Branch

```bash
# Update from upstream
git fetch upstream
git checkout main
git merge upstream/main

# Create feature branch
git checkout -b add-magi-archive-mcp-server
```

### 4. Add Server Entry

```bash
# Create directory structure if needed
mkdir -p src/magi-agi

# Copy the JSON file you created
# Place it at: src/magi-agi/mcp-server.json
```

### 5. Validate Your Entry

Check the registry documentation for validation requirements:
- JSON must be valid
- All required fields present
- npm package exists and is accessible
- Categories are valid
- Tool descriptions are clear

### 6. Commit and Push

```bash
# Add your file
git add src/magi-agi/mcp-server.json

# Commit with descriptive message
git commit -m "Add Magi Archive MCP Server

MCP server providing secure access to the Magi Archive wiki.

Features:
- 15+ tools for card operations, search, and management
- Role-based access control (User, GM, Admin)
- Batch operations and weekly summaries
- HTML/Markdown content rendering

Package: @magi-agi/mcp-server
Homepage: https://wiki.magi-agi.org
"

# Push to your fork
git push origin add-magi-archive-mcp-server
```

### 7. Create Pull Request

1. Go to https://github.com/Magi-AGI/mcp-registry
2. Click "Pull Request" or "Compare & pull request"
3. Select:
   - **Base repository**: `modelcontextprotocol/registry`
   - **Base branch**: `main`
   - **Head repository**: `Magi-AGI/mcp-registry`
   - **Compare branch**: `add-magi-archive-mcp-server`
4. Fill in PR details:
   - **Title**: "Add Magi Archive MCP Server"
   - **Description**:
     ```markdown
     # Add Magi Archive MCP Server

     ## Summary
     Adds MCP server for the Magi Archive wiki, providing AI agents secure access
     to a knowledge base with 15+ tools for card operations and management.

     ## Package Details
     - **npm**: @magi-agi/mcp-server
     - **Version**: 0.1.0
     - **Homepage**: https://wiki.magi-agi.org
     - **Repository**: https://github.com/your-org/magi-archive-mcp

     ## Features
     - Card CRUD operations
     - Advanced search and filtering
     - Tag-based organization
     - Relationship tracking
     - Weekly summaries with git integration
     - Role-based access control

     ## Installation
     ```bash
     npm install -g @magi-agi/mcp-server
     ```

     ## Checklist
     - [x] npm package published and accessible
     - [x] JSON schema valid
     - [x] All required fields present
     - [x] Tools documented
     - [x] Configuration explained
     ```
5. Click "Create Pull Request"

### 8. Wait for Review

- Registry maintainers will review your submission
- They may request changes or clarifications
- Respond to feedback promptly
- Once approved, your server will be merged

### 9. After Merge

Once your PR is merged:
- Your MCP server will be available in the official registry
- ChatGPT Desktop and other MCP clients can discover it
- Users can install and use it directly
- Keep your npm package updated

## Maintenance

### Updating Your Entry

When you publish new versions:

```bash
# Update the JSON file with new version number
# Update tool descriptions if changed
# Commit and create new PR

git checkout main
git pull upstream main
git checkout -b update-magi-archive-mcp-v0.2.0
# Make changes to src/magi-agi/mcp-server.json
git add src/magi-agi/mcp-server.json
git commit -m "Update Magi Archive MCP Server to v0.2.0"
git push origin update-magi-archive-mcp-v0.2.0
# Create PR
```

## Registry Schema Reference

Key fields in the JSON schema:

```json
{
  "name": "string (npm package name)",
  "version": "string (semver)",
  "description": "string (brief description)",
  "homepage": "string (URL)",
  "repository": {
    "type": "git",
    "url": "string (git URL)"
  },
  "license": "string (SPDX identifier)",
  "categories": ["array", "of", "strings"],
  "installation": {
    "npm": "string (package name)"
  },
  "configuration": {
    "required": { "env": {} },
    "optional": { "env": {} }
  },
  "capabilities": {
    "tools": boolean,
    "resources": boolean,
    "prompts": boolean
  },
  "tools": [
    {
      "name": "string",
      "description": "string"
    }
  ]
}
```

## Resources

- **MCP Registry**: https://github.com/modelcontextprotocol/registry
- **Your Fork**: https://github.com/Magi-AGI/mcp-registry
- **MCP Specification**: https://modelcontextprotocol.io
- **npm Package**: https://www.npmjs.com/package/@magi-agi/mcp-server

---

**Status**: Ready for submission
**Package**: @magi-agi/mcp-server v0.1.0
**Last Updated**: December 2024
