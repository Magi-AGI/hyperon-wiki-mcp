# Magi Archive MCP Server Guide

A comprehensive guide to installing, configuring, and using the Magi Archive MCP Server with Claude Desktop, Claude Code, Codex, ChatGPT, and other MCP-compatible clients.

---

## Table of Contents

1. [Overview](#1-overview)
   - [What is MCP?](#what-is-mcp)
   - [Why Use the MCP Server?](#why-use-the-mcp-server)
   - [Available Tools](#available-tools)
2. [Installation](#2-installation)
   - [Prerequisites](#prerequisites)
   - [Auto-Installation](#auto-installation)
   - [Manual Installation](#manual-installation)
   - [Platform-Specific Instructions](#platform-specific-instructions)
3. [Authentication](#3-authentication)
   - [Username/Password Method](#method-1-usernamepassword-recommended)
   - [API Key Method](#method-2-api-key)
   - [Role Detection](#role-detection)
   - [Example Configurations](#example-configurations)
4. [Available Tools](#4-available-tools)
   - [Core Card Operations](#core-card-operations)
   - [Tag Operations](#tag-operations)
   - [Relationships](#relationships)
   - [Validation & Recommendations](#validation--recommendations)
   - [Types & Rendering](#types--rendering)
   - [Admin Operations](#admin-operations)
   - [Utility Operations](#utility-operations)
5. [Weekly Summary Feature](#5-weekly-summary-feature)
   - [Overview](#overview-1)
   - [Usage Examples](#usage-examples)
   - [Configuration Options](#configuration-options)
6. [Security Best Practices](#6-security-best-practices)
   - [Credential Management](#credential-management)
   - [Role-Based Access](#role-based-access-control-rbac)
   - [Token Handling](#token-management)
   - [Common Security Pitfalls](#common-pitfalls)
7. [Deployment](#7-deployment)
   - [Production Deployment](#production-deployment)
   - [Configuration Management](#configuration-management)
   - [Monitoring and Logging](#monitoring-and-logs)
   - [Testing](#testing-the-installation)
8. [Troubleshooting](#8-troubleshooting)
   - [Common Issues](#common-issues)
   - [Debug Mode](#debug-mode)
   - [Getting Help](#getting-help)

---

## 1. Overview

### What is MCP?

The [Model Context Protocol](https://modelcontextprotocol.io) (MCP) is an open standard created by Anthropic for connecting AI assistants to external data sources and tools. It uses JSON-RPC 2.0 over stdio for communication, enabling seamless integration between AI clients like Claude Desktop and external services.

**Key Features:**
- Standardized protocol for AI tool integration
- JSON-RPC 2.0 communication over stdio
- Secure, role-based access control
- Support for multiple client applications

### Why Use the MCP Server?

The Magi Archive MCP Server enables AI assistants to directly interact with the Magi Archive wiki (wiki.magi-agi.org) through a standardized protocol, providing:

- **Direct Wiki Access**: Read, search, create, and manage wiki cards
- **Automated Workflows**: Generate weekly summaries, validate content, scan for issues
- **Structured Data**: Access wiki data in a format optimized for AI consumption
- **Role-Based Security**: User, GM, and Admin role enforcement
- **Git Integration**: Combine wiki changes with repository activity

**Use Cases:**
- Content creation and management via Claude Desktop
- Automated weekly reporting
- Content validation and structure recommendations
- Game master tools (spoiler detection, GM content management)
- Administrative tasks (backups, bulk operations)

### Available Tools

The MCP server provides **16 tools** across multiple categories:

**Core Card Operations (6 tools):**
- get_card, search_cards, create_card, update_card, delete_card, list_children

**Tag Operations (2 tools):**
- get_tags, search_by_tags

**Relationships (1 tool):**
- get_relationships

**Validation & Recommendations (2 tools):**
- validate_card, get_recommendations

**Types & Rendering (2 tools):**
- get_types, render_content

**Admin Operations (1 tool):**
- admin_backup

**Utility Operations (1 tool):**
- create_weekly_summary

**By Permission Level:**
- User accessible: 14 tools
- Admin only: 2 tools (delete_card, admin_backup)

---

## 2. Installation

### Prerequisites

Before installing the MCP server, ensure you have:

1. **Ruby 3.2+** installed on your system
2. **Bundler** for dependency management
3. **One of the following MCP clients:**
   - Claude Desktop
   - Claude Code
   - Codex CLI
   - ChatGPT Desktop (when available)
   - Any MCP-compatible client
4. **API credentials** from the Decko administrator
5. **Network access** to wiki.magi-agi.org

**Verify Ruby Version:**
```bash
ruby --version
# Should show 3.2.0 or higher
```

**Install Bundler:**
```bash
gem install bundler
```

### Auto-Installation

The fastest way to get started is using the auto-installation scripts.

#### Option 1: Ruby Installation (Recommended)

```bash
# Clone the repository
git clone https://github.com/your-org/magi-archive-mcp.git
cd magi-archive-mcp

# Install dependencies
bundle install

# Install for Claude Desktop
ruby bin/install-claude-desktop

# OR install for Codex
ruby bin/install-codex

# OR install for Cursor IDE
ruby bin/install-cursor

# OR install for Gemini CLI
ruby bin/install-gemini
```

**What the installer does:**
1. Prompts for authentication method (username/password or API key)
2. Asks for your working directory (for git repo scanning)
3. Creates or updates the appropriate config file
4. Makes the server executable
5. Validates the configuration
6. Provides next steps

**Interactive Prompts:**
```
=== Magi Archive MCP Server - Claude Desktop Installation ===

Authentication Method:
1. Username/Password (recommended)
2. API Key

Choose method (1 or 2): 1

Enter your Decko username: your-username
Enter your Decko password: ********

Working Directory (for git scanning):
Default: /current/directory
Enter path (or press Enter for default): /path/to/your/projects

✓ Configuration saved to:
  ~/Library/Application Support/Claude/claude_desktop_config.json

✓ Installation complete!

Next steps:
1. Restart Claude Desktop
2. Try: "Get the Main Page card from Magi Archive"
```

#### Option 2: NPM Installation

For Node.js users, an NPM wrapper is available:

```bash
# Install via npm
npm install -g magi-archive-mcp

# Install for Claude Desktop
magi-archive-install-claude

# OR install for Codex
magi-archive-install-codex
```

The NPM installer provides the same interactive experience as the Ruby installer.

### Manual Installation

If you prefer to configure manually or need custom setup:

#### For Claude Desktop

**macOS:**
Edit `~/Library/Application Support/Claude/claude_desktop_config.json`

**Windows:**
Edit `%APPDATA%\Claude\claude_desktop_config.json`

**Linux:**
Edit `~/.config/Claude/claude_desktop_config.json`

**Configuration:**
```json
{
  "mcpServers": {
    "magi-archive": {
      "command": "ruby",
      "args": [
        "/absolute/path/to/magi-archive-mcp/bin/mcp-server",
        "/absolute/path/to/working/directory"
      ],
      "env": {
        "MCP_USERNAME": "your-decko-username",
        "MCP_PASSWORD": "your-decko-password",
        "DECKO_API_BASE_URL": "https://wiki.magi-agi.org/api/mcp"
      }
    }
  }
}
```

#### For Claude Code

Claude Code uses a similar configuration file.

**Location:**
- macOS/Linux: `~/.config/claude-code/mcp_config.json`
- Windows: `%APPDATA%\claude-code\mcp_config.json`

**Configuration format is identical to Claude Desktop.**

#### For Codex

**Location:**
- macOS/Linux: `~/.config/codex/mcp_config.json`
- Windows: `%APPDATA%\codex\mcp_config.json`

**Configuration:**
```json
{
  "mcpServers": {
    "magi-archive": {
      "command": "ruby",
      "args": [
        "/absolute/path/to/magi-archive-mcp/bin/mcp-server",
        "/absolute/path/to/working/directory"
      ],
      "env": {
        "MCP_USERNAME": "your-username",
        "MCP_PASSWORD": "your-password",
        "DECKO_API_BASE_URL": "https://wiki.magi-agi.org/api/mcp"
      }
    }
  }
}
```

#### For Cursor IDE

**Location (all platforms):**
`~/.cursor/mcp.json`

**Configuration:**
```json
{
  "mcpServers": {
    "magi-archive": {
      "command": "ruby",
      "args": [
        "/absolute/path/to/magi-archive-mcp/bin/mcp-server",
        "/absolute/path/to/working/directory"
      ],
      "env": {
        "MCP_USERNAME": "your-username",
        "MCP_PASSWORD": "your-password",
        "DECKO_API_BASE_URL": "https://wiki.magi-agi.org/api/mcp"
      }
    }
  }
}
```

#### For Gemini CLI

**Location (all platforms):**
`~/.gemini/settings.json`

**Configuration:**
```json
{
  "mcpServers": {
    "magi-archive": {
      "command": "ruby",
      "args": [
        "/absolute/path/to/magi-archive-mcp/bin/mcp-server",
        "/absolute/path/to/working/directory"
      ],
      "env": {
        "MCP_USERNAME": "your-username",
        "MCP_PASSWORD": "your-password",
        "DECKO_API_BASE_URL": "https://wiki.magi-agi.org/api/mcp"
      }
    }
  }
}
```

#### For ChatGPT Desktop/Web

ChatGPT uses the mcp.run platform for MCP server integration, which requires hosting the server publicly. For local testing, consider using Claude Desktop or Cursor instead. See `CHATGPT-USAGE-GUIDE.md` for details and known limitations.

### Platform-Specific Instructions

#### macOS

1. **Install Ruby via Homebrew:**
   ```bash
   brew install ruby
   ```

2. **Add to PATH** (add to `~/.zshrc` or `~/.bash_profile`):
   ```bash
   export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
   ```

3. **Follow auto-installation steps above**

4. **Config file location:**
   - Claude Desktop: `~/Library/Application Support/Claude/claude_desktop_config.json`
   - Codex: `~/.config/codex/mcp_config.json`

#### Windows

1. **Install Ruby via RubyInstaller:**
   - Download from https://rubyinstaller.org
   - Use Ruby+Devkit 3.2.x or higher
   - Run installer with default options

2. **Open PowerShell or Command Prompt**

3. **Follow auto-installation steps above**

4. **Config file locations:**
   - Claude Desktop: `%APPDATA%\Claude\claude_desktop_config.json`
   - Codex: `%APPDATA%\codex\mcp_config.json`

**Windows Path Note:** Use forward slashes or double backslashes in JSON:
```json
"args": [
  "E:/GitLab/magi-archive-mcp/bin/mcp-server",
  "E:/GitLab/my-projects"
]
```

Or:
```json
"args": [
  "E:\\GitLab\\magi-archive-mcp\\bin\\mcp-server",
  "E:\\GitLab\\my-projects"
]
```

#### Linux (WSL included)

1. **Install Ruby:**
   ```bash
   # Ubuntu/Debian
   sudo apt install ruby-full

   # Fedora
   sudo dnf install ruby

   # Arch
   sudo pacman -S ruby
   ```

2. **Install bundler:**
   ```bash
   gem install bundler
   ```

3. **Follow auto-installation steps above**

4. **WSL users:** Can access Windows config files:
   ```bash
   # Claude Desktop config in Windows
   /mnt/c/Users/YourName/AppData/Roaming/Claude/claude_desktop_config.json
   ```

5. **Config file locations:**
   - Claude Desktop: `~/.config/Claude/claude_desktop_config.json`
   - Codex: `~/.config/codex/mcp_config.json`

---

## 3. Authentication

Magi Archive MCP uses a **three-tier role-based access control** system with JWT (JSON Web Token) authentication.

### Authentication Flow

```
┌─────────────┐                ┌──────────────┐                ┌─────────────┐
│  MCP Client │                │  Decko API   │                │   JWKS      │
└──────┬──────┘                └──────┬───────┘                └──────┬──────┘
       │                              │                               │
       │ 1. POST /api/mcp/auth        │                               │
       │    (credentials + role)      │                               │
       ├─────────────────────────────>│                               │
       │                              │                               │
       │                              │ 2. Validate credentials       │
       │                              │                               │
       │ 3. Return JWT                │                               │
       │    (RS256 signed)            │                               │
       │<─────────────────────────────┤                               │
       │                              │                               │
       │ 4. GET /api/mcp/cards/Foo    │                               │
       │    Authorization: Bearer JWT │                               │
       ├─────────────────────────────>│                               │
       │                              │                               │
       │                              │ 5. Fetch JWKS (if needed)     │
       │                              ├──────────────────────────────>│
       │                              │                               │
       │                              │ 6. Return public keys         │
       │                              │<──────────────────────────────┤
       │                              │                               │
       │                              │ 7. Verify JWT signature       │
       │                              │    Check role permissions     │
       │                              │                               │
       │ 8. Return card data          │                               │
       │<─────────────────────────────┤                               │
       │                              │                               │
```

### Method 1: Username/Password (Recommended)

The simplest and most secure method for individual users.

**Configuration:**
```json
{
  "env": {
    "MCP_USERNAME": "your-decko-username",
    "MCP_PASSWORD": "your-decko-password",
    "DECKO_API_BASE_URL": "https://wiki.magi-agi.org/api/mcp"
  }
}
```

**How it works:**
1. Server authenticates with Decko using username/password
2. Decko returns a JWT token with appropriate role
3. Role is automatically detected based on user permissions
4. Token is cached and automatically refreshed

**Advantages:**
- No need to manage API keys
- Role automatically determined by user account
- Familiar authentication method
- Easy credential rotation

**Example:**
```json
{
  "mcpServers": {
    "magi-archive": {
      "command": "ruby",
      "args": ["/path/to/mcp-server", "/path/to/workdir"],
      "env": {
        "MCP_USERNAME": "alice",
        "MCP_PASSWORD": "secure-password-123",
        "DECKO_API_BASE_URL": "https://wiki.magi-agi.org/api/mcp"
      }
    }
  }
}
```

### Method 2: API Key

For programmatic access, automation, or when username/password authentication is not preferred.

**Configuration:**
```json
{
  "env": {
    "MCP_API_KEY": "your-64-character-api-key-here",
    "MCP_ROLE": "user",
    "DECKO_API_BASE_URL": "https://wiki.magi-agi.org/api/mcp"
  }
}
```

**How it works:**
1. Server authenticates with Decko using API key + requested role
2. Decko validates key has permission for requested role
3. Decko returns a JWT token scoped to that role
4. Token is cached and automatically refreshed

**Advantages:**
- Can be scoped to specific roles
- Can be rotated without changing user password
- Can be restricted by IP, rate limit, or expiry
- Better for automation and CI/CD

**Requesting an API Key:**
Contact your Decko administrator with:
1. Required role level (user, gm, admin)
2. Use case description
3. Expected request volume
4. Whether for individual or programmatic use

**Example:**
```json
{
  "mcpServers": {
    "magi-archive": {
      "command": "ruby",
      "args": ["/path/to/mcp-server", "/path/to/workdir"],
      "env": {
        "MCP_API_KEY": "abc123def456...xyz789",
        "MCP_ROLE": "gm",
        "DECKO_API_BASE_URL": "https://wiki.magi-agi.org/api/mcp"
      }
    }
  }
}
```

### Role Detection

The MCP server supports three role levels:

#### User Role (`mcp-user`)

**Permissions:**
- ✅ Read public cards
- ✅ Search public cards
- ✅ Create new cards (as owner)
- ✅ Update own cards
- ✅ List card types
- ✅ Convert formats (HTML ↔ Markdown)
- ❌ No access to GM-only content
- ❌ No delete operations
- ❌ No admin operations

**Use Cases:**
- Player character management
- Personal note-taking
- Public article creation
- Research and reading

**Automatic Detection:**
When using username/password, user role is granted if:
- User has basic wiki account
- No GM or admin privileges

#### GM Role (`mcp-gm`)

**Permissions:**
- ✅ All User role permissions
- ✅ Read GM-only content (hidden from players)
- ✅ Run spoiler scans
- ✅ Execute privileged queries
- ❌ No delete operations
- ❌ No system administration

**Use Cases:**
- Game master content management
- Spoiler checking (ensure player content doesn't reveal secrets)
- Campaign planning
- NPC and plot management

**Automatic Detection:**
When using username/password, GM role is granted if:
- User has GM flag set in Decko
- User is member of GM group

#### Admin Role (`mcp-admin`)

**Permissions:**
- ✅ All GM role permissions
- ✅ Delete cards
- ✅ Force delete cards with children
- ✅ Move/rename cards
- ✅ System administration
- ✅ User management
- ✅ Database backups

**Use Cases:**
- System maintenance
- Content moderation
- Database cleanup
- User support

**Automatic Detection:**
When using username/password, admin role is granted if:
- User has admin flag set in Decko
- User is system administrator

### Example Configurations

#### Example 1: User Role with Username/Password

```json
{
  "mcpServers": {
    "magi-archive": {
      "command": "ruby",
      "args": [
        "/Users/alice/magi-archive-mcp/bin/mcp-server",
        "/Users/alice/projects"
      ],
      "env": {
        "MCP_USERNAME": "alice",
        "MCP_PASSWORD": "player-password",
        "DECKO_API_BASE_URL": "https://wiki.magi-agi.org/api/mcp"
      }
    }
  }
}
```

**Result:** Alice gets User role, can read/create public content, manage her character cards.

#### Example 2: GM Role with API Key

```json
{
  "mcpServers": {
    "magi-archive": {
      "command": "ruby",
      "args": [
        "/Users/bob/magi-archive-mcp/bin/mcp-server",
        "/Users/bob/campaigns"
      ],
      "env": {
        "MCP_API_KEY": "gm-key-abc123def456...",
        "MCP_ROLE": "gm",
        "DECKO_API_BASE_URL": "https://wiki.magi-agi.org/api/mcp"
      }
    }
  }
}
```

**Result:** Bob gets GM role, can read GM content, run spoiler scans, manage campaign.

#### Example 3: Admin Role for Maintenance

```json
{
  "mcpServers": {
    "magi-archive": {
      "command": "ruby",
      "args": [
        "E:/magi-archive-mcp/bin/mcp-server",
        "E:/wikis"
      ],
      "env": {
        "MCP_API_KEY": "admin-key-xyz789...",
        "MCP_ROLE": "admin",
        "DECKO_API_BASE_URL": "https://wiki.magi-agi.org/api/mcp"
      }
    }
  }
}
```

**Result:** Admin role, full access for maintenance, backups, bulk operations.

#### Example 4: Multiple Configurations

You can configure multiple instances with different roles:

```json
{
  "mcpServers": {
    "magi-archive-user": {
      "command": "ruby",
      "args": ["/path/to/mcp-server", "/path/to/workdir"],
      "env": {
        "MCP_USERNAME": "alice",
        "MCP_PASSWORD": "password",
        "DECKO_API_BASE_URL": "https://wiki.magi-agi.org/api/mcp"
      }
    },
    "magi-archive-admin": {
      "command": "ruby",
      "args": ["/path/to/mcp-server", "/path/to/workdir"],
      "env": {
        "MCP_API_KEY": "admin-key...",
        "MCP_ROLE": "admin",
        "DECKO_API_BASE_URL": "https://wiki.magi-agi.org/api/mcp"
      }
    }
  }
}
```

**Result:** Two separate MCP connections with different permission levels.

---

## 4. Available Tools

Complete reference for all 16 MCP tools with parameters, examples, and return values.

### Core Card Operations

#### 1. get_card

Fetch a single card by name from the wiki.

**Parameters:**
- `name` (string, required): Card name (case-sensitive)
- `with_children` (boolean, optional): Include child cards in response

**Examples:**
```
"Get the card named 'Main Page' from Magi Archive"
"Fetch 'Business Plan+Executive Summary' with its children"
"Show me the Home card"
```

**Returns:**
```
Card: Main Page
Type: Basic
URL: https://wiki.magi-agi.org/Main_Page

Content:
Welcome to the Magi Archive...

[If with_children=true:]
Children:
- Main Page+About
- Main Page+Getting Started
```

**Error Cases:**
- Card not found (404)
- Permission denied (403)
- Invalid card name format

#### 2. search_cards

Search for cards by query, type, or filters with pagination.

**Parameters:**
- `query` (string, optional): Search query (searches card names and content)
- `type` (string, optional): Filter by card type (e.g., "Article", "Character")
- `limit` (integer, optional): Max results (default: 50, max: 100)
- `offset` (integer, optional): Pagination offset (default: 0)

**Examples:**
```
"Search Magi Archive for cards about 'Butterfly Galaxii'"
"Find all Article type cards"
"Search for cards matching 'quantum physics' with type RichText"
"Get the next 50 results after offset 100"
```

**Returns:**
```
Search Results: 42 total matches
Showing 5 results:

1. Butterfly Galaxii+Overview (Article)
   Content preview: The Butterfly Galaxii setting...
   URL: https://wiki.magi-agi.org/...

2. Butterfly Galaxii+Species (Basic)
   Content preview: Major species in the setting...
   URL: https://wiki.magi-agi.org/...

[Pagination info:]
Next offset: 5 (for next page)
```

**Performance:**
- Basic searches: ~200-400ms
- Complex queries: ~500-800ms
- Results automatically paginated

#### 3. create_card

Create a new card on the wiki.

**Parameters:**
- `name` (string, required): Card name
- `content` (string, optional): Card content (Markdown or HTML)
- `type` (string, optional): Card type (default: "Basic")

**Examples:**
```
"Create a card called 'New Species Document'"
"Add a new Article card about quantum physics with this content: ..."
"Create a character card named 'Aria Stormwind'"
```

**Returns:**
```
✓ Card created successfully

Name: New Species Document
Type: Basic
URL: https://wiki.magi-agi.org/New_Species_Document

You can now edit this card in Claude or on the wiki.
```

**Requirements:**
- User or higher role
- Valid card name (no special characters except spaces, +, -)
- Name must be unique

#### 4. update_card

Update an existing card's content or type.

**Parameters:**
- `name` (string, required): Card name
- `content` (string, optional): New content
- `type` (string, optional): New type

**Examples:**
```
"Update 'Main Page' with new content"
"Change the type of 'My Card' to Article"
"Update 'Character+Aria' with her new backstory"
```

**Returns:**
```
✓ Card updated successfully

Name: Main Page
Type: Basic
URL: https://wiki.magi-agi.org/Main_Page

Updated fields:
- content (modified)
```

**Requirements:**
- User role: Can update own cards only
- GM/Admin: Can update any card
- Card must exist

#### 5. delete_card

Delete a card from the wiki (admin only).

**Parameters:**
- `name` (string, required): Card name
- `force` (boolean, optional): Force delete even with children (default: false)

**Examples:**
```
"Delete the card 'Old Draft'"
"Force delete 'Test Parent' and all children"
```

**Returns:**
```
⚠️  Card deleted

Name: Old Draft
URL: https://wiki.magi-agi.org/Old_Draft (no longer accessible)

WARNING: This operation cannot be undone!
[If force=true:]
Also deleted 3 child cards:
- Old Draft+Section 1
- Old Draft+Section 2
- Old Draft+Notes
```

**Requirements:**
- Admin role required
- Card must exist
- If card has children, must use `force=true`

**Security:**
- Requires confirmation in some clients
- Audit logged
- Cannot be undone

#### 6. list_children

List all child cards of a parent card.

**Parameters:**
- `parent_name` (string, required): Parent card name
- `limit` (integer, optional): Max children (default: 50, max: 100)

**Examples:**
```
"List children of 'Business Plan'"
"Show all subcards of 'Butterfly Galaxii+Species'"
"Get child cards for 'Main Page'"
```

**Returns:**
```
Children of 'Business Plan': 5 total

1. Business Plan+Executive Summary (Basic)
   Updated: 2025-12-01
   URL: https://wiki.magi-agi.org/...

2. Business Plan+Vision (Article)
   Updated: 2025-11-28
   URL: https://wiki.magi-agi.org/...

3. Business Plan+Market Analysis (RichText)
   Updated: 2025-11-25
   URL: https://wiki.magi-agi.org/...

[And 2 more...]
```

**Notes:**
- Results ordered by name
- Includes metadata (type, update date)
- Pagination available for many children

### Tag Operations

#### 7. get_tags

Get all tags in the system or tags for a specific card.

**Parameters:**
- `card_name` (string, optional): Card name (omit for all tags)
- `limit` (integer, optional): Max tags for all-tags mode (default: 100, max: 500)

**Examples:**
```
"Get all tags in Magi Archive"
"Show tags for 'Main Page'"
"List available tags"
"What tags are used in the wiki?"
```

**Returns (all tags):**
```
All Tags: 42 total

- Species (used by 15 cards)
- Game (used by 23 cards)
- GM (used by 8 cards)
- Draft (used by 12 cards)
- Article (used by 34 cards)
[And 37 more...]
```

**Returns (specific card):**
```
Tags for 'Butterfly Galaxii+Species': 3 tags

- Species
- Game
- Reference
```

**Performance:**
- All tags cached for 5 minutes
- Specific card tags: ~100-200ms

#### 8. search_by_tags

Search for cards by tags with AND or OR logic.

**Parameters:**
- `tags` (array of strings, required): Tags to search for
- `match_mode` (string, optional): "all" (AND) or "any" (OR), default: "all"
- `limit` (integer, optional): Max results (default: 50, max: 100)

**Examples:**
```
"Find cards tagged with both 'Species' AND 'Alien'"
"Search for cards with 'Game' OR 'Draft' tags"
"Show all cards tagged 'GM'"
"Find cards with tags ['Reference', 'Technical'] using AND logic"
```

**Returns:**
```
Cards matching tags ['Species', 'Alien'] (AND): 8 total

1. Vulcans (Species)
   Tags: Species, Alien, Star Trek
   URL: https://wiki.magi-agi.org/...

2. Klingons (Species)
   Tags: Species, Alien, Star Trek, Warrior
   URL: https://wiki.magi-agi.org/...

[And 6 more...]
```

**Match Modes:**
- `all` (AND): Card must have ALL specified tags
- `any` (OR): Card must have AT LEAST ONE specified tag

### Relationships

#### 9. get_relationships

Get relationship information for a card.

**Parameters:**
- `card_name` (string, required): Card name
- `relationship_type` (string, required): One of:
  - `referers`: Cards that reference this card
  - `linked_by`: Cards that link to this card
  - `nested_in`: Cards that nest this card
  - `nests`: Cards that this card nests
  - `links`: Cards that this card links to

**Examples:**
```
"Show me what cards reference 'Main Page'"
"Find cards that link to 'Business Plan'"
"Get nesting relationships for 'Template Card'"
"What does 'Article Template' link to?"
```

**Returns:**
```
Cards referencing 'Main Page': 12 total

1. Getting Started Guide (Article)
   URL: https://wiki.magi-agi.org/...

2. Welcome Message (Basic)
   URL: https://wiki.magi-agi.org/...

[And 10 more...]
```

**Use Cases:**
- Find broken links
- Understand card connections
- Navigate wiki structure
- Identify orphaned cards

### Validation & Recommendations

#### 10. validate_card

Validate a card's tags and structure based on its type.

**Parameters:**
- `type` (string, required): Card type
- `tags` (array, optional): Tags to validate
- `name` (string, optional): Card name for naming validation
- `content` (string, optional): Content for content-based suggestions
- `children` (array, optional): Child card names for structure validation

**Examples:**
```
"Validate tags for a Species type card with tags ['Game', 'Alien']"
"Check if 'New Article' has correct structure"
"Validate this card: type=Character, tags=['Player', 'Active']"
```

**Returns:**
```
Validation Results for Species card

✓ Valid
  - Tag 'Game' is appropriate for Species
  - Tag 'Alien' is appropriate for Species

⚠️  Warnings
  - Consider adding tag 'Reference' for Species cards
  - Recommended child cards: +Description, +Abilities, +Culture

❌ Errors
  None
```

**Validation Checks:**
- Tag appropriateness for type
- Required vs optional tags
- Recommended structure
- Naming conventions
- Content completeness

#### 11. get_recommendations

Get structure recommendations and improvement suggestions.

**Parameters:**
- `operation` (string, required): One of:
  - `requirements`: Get type requirements
  - `recommend_structure`: Get structure recommendation for new card
  - `suggest_improvements`: Analyze existing card
- `type` (string): Card type (for requirements/recommend_structure)
- `name` (string): Card name (for recommend_structure/suggest_improvements)
- `tags` (array, optional): Current tags
- `content` (string, optional): Card content

**Examples:**
```
"What are the requirements for a Species card?"
"Recommend structure for a new 'Vulcans' Species card"
"Suggest improvements for 'Main Page'"
```

**Returns (requirements):**
```
Requirements for Species cards

Required Tags:
- Game or Setting

Recommended Tags:
- Reference (if detailed documentation)
- Draft (if work in progress)

Required Structure:
- +Description: Overview and appearance
- +Abilities: Special traits and powers
- +Culture: Society and customs

Optional Structure:
- +History: Background and origins
- +Notable Examples: Famous individuals
```

**Returns (recommend_structure):**
```
Recommended Structure for 'Vulcans' (Species)

Suggested child cards:
1. Vulcans+Description
   Purpose: Physical appearance, lifespan, biology

2. Vulcans+Abilities
   Purpose: Telepathy, superior strength, logic

3. Vulcans+Culture
   Purpose: IDIC philosophy, Pon Farr, Kolinahr

Suggested tags:
- Species
- Star Trek
- Reference
```

**Returns (suggest_improvements):**
```
Improvement Suggestions for 'Main Page'

✓ Strengths
  - Well structured with child cards
  - Comprehensive content
  - Appropriate tags

💡 Suggestions
  - Add +FAQ child card for common questions
  - Consider tag 'Welcome' for landing pages
  - Content could benefit from more internal links
```

### Types & Rendering

#### 12. get_types

List all card types available in the system.

**Parameters:**
- `limit` (integer, optional): Max types (default: 100, max: 500)

**Examples:**
```
"List all card types in Magi Archive"
"Show available card types"
"What types of cards can I create?"
```

**Returns:**
```
Available Card Types: 25 total

- Basic (default type)
- Article (formatted articles)
- RichText (rich content with media)
- Character (character profiles)
- Species (species documentation)
- Location (place descriptions)
- GM Note (hidden from players)
- Template (reusable templates)
- User (user profiles)
[And 16 more...]
```

**Use Cases:**
- Discover available types
- Validate type names before creation
- Understand wiki structure

#### 13. render_content

Convert content between HTML and Markdown formats.

**Parameters:**
- `content` (string, required): Content to convert
- `from_format` (string, required): "html" or "markdown"
- `to_format` (string, required): "html" or "markdown"

**Examples:**
```
"Convert this HTML to Markdown: <h1>Hello</h1><p>World</p>"
"Render this Markdown as HTML: # Hello\n\nWorld"
"Transform <strong>bold</strong> to Markdown"
```

**Returns:**
```
Original (HTML):
<h1>Hello</h1><p>World</p>

Converted (Markdown):
# Hello

World
```

**Supported Conversions:**
- HTML → Markdown
- Markdown → HTML

**Use Cases:**
- Prepare content for wiki
- Extract readable text from HTML
- Format content for display

### Admin Operations

#### 14. admin_backup

Manage database backups (admin only).

**Parameters:**
- `operation` (string, required): One of:
  - `download`: Create and download new backup
  - `list`: Show available backups
  - `delete`: Remove a backup file
- `filename` (string): Backup filename (for delete operation)
- `save_path` (string, optional): Local path to save (for download)

**Examples:**
```
"Download a database backup"
"List all available backups"
"Delete backup 'magi_archive_backup_20251203_120000.sql'"
```

**Returns (download):**
```
✓ Backup created and downloaded

Filename: magi_archive_backup_20251203_143022.sql
Size: 45.2 MB
Saved to: /path/to/backups/magi_archive_backup_20251203_143022.sql

Backup includes:
- All card data
- User accounts
- Tags and relationships
- File attachments (metadata)

Database snapshot as of: 2025-12-03 14:30:22 UTC
```

**Returns (list):**
```
Available Backups: 5 total

1. magi_archive_backup_20251203_120000.sql (44.8 MB)
   Created: 2025-12-03 12:00:00 UTC

2. magi_archive_backup_20251202_120000.sql (44.5 MB)
   Created: 2025-12-02 12:00:00 UTC

[And 3 more...]
```

**Returns (delete):**
```
✓ Backup deleted

Filename: magi_archive_backup_20251201_120000.sql
This backup is no longer available.
```

**Requirements:**
- Admin role required
- Adequate disk space for download
- Backup retention policy compliance

**Security:**
- Audit logged
- Backups encrypted at rest
- Download requires secure connection

### Utility Operations

#### 15. create_weekly_summary

Generate automated weekly summary combining wiki changes and git activity.

**Parameters:**
- `base_path` (string, optional): Root directory for git repos (default: working directory)
- `days` (integer, optional): Days to look back (default: 7, max: 365)
- `date` (string, optional): Date for card name in 'YYYY MM DD' format (default: today)
- `executive_summary` (string, optional): Custom summary text
- `create_card` (boolean, optional): Whether to create card or preview (default: true)

**Examples:**
```
"Generate a weekly summary for Magi Archive"
"Create a weekly summary for the last 14 days"
"Preview weekly summary without creating the card"
"Generate summary with executive: 'Focused on MCP Phase 2.1 completion'"
```

**Returns (create_card=true):**
```
✓ Weekly summary created

Name: Weekly Work Summary 2025 12 09
Type: Basic
URL: https://wiki.magi-agi.org/Weekly_Work_Summary_2025_12_09

Summary includes:
- 15 wiki card updates
- 42 commits across 3 repositories
- Executive summary
- Next steps section

Preview:
# Weekly Work Summary 2025 12 09

## Executive Summary
This week saw 15 card updates across the wiki and 42 commits across 3 repositories...
[truncated]
```

**Returns (create_card=false):**
```
[Full markdown preview of the summary content]

# Weekly Work Summary 2025 12 09

## Executive Summary
This week saw 15 card updates across the wiki and 42 commits across 3 repositories.
Focus areas included MCP Phase 2.1 features, comprehensive testing, and documentation.

## Wiki Card Updates

### Business Plan
- Business Plan+Executive Summary (2025-12-03)
- Business Plan+Vision (2025-12-02)

[... full content ...]
```

**See [Section 5: Weekly Summary Feature](#5-weekly-summary-feature) for detailed documentation.**

### Tool Categories Summary

**By Function:**
- Card Management: 6 tools (get, search, create, update, delete, list_children)
- Tags: 2 tools (get_tags, search_by_tags)
- Relationships: 1 tool (get_relationships)
- Validation: 2 tools (validate_card, get_recommendations)
- Types & Rendering: 2 tools (get_types, render_content)
- Admin: 1 tool (admin_backup)
- Utilities: 1 tool (create_weekly_summary)

**By Permission Level:**
- User accessible: 14 tools
- Admin only: 2 tools (delete_card, admin_backup)

**Total: 16 tools**

### Usage Tips

**1. Chaining Operations**

Combine tools in conversation:
```
User: "Search for Species cards, then get tags for the first result"
Claude: [Uses search_cards, then get_tags]
```

**2. Validation Before Creation**

Always validate before creating important cards:
```
User: "Validate my Species card with tags ['Game', 'Alien'] then create it"
Claude: [Uses validate_card, reviews results, then create_card]
```

**3. Weekly Workflow**

Typical weekly summary workflow:
```
User: "Generate this week's summary for the Magi AGI project"
Claude: [Uses create_weekly_summary with git repo scanning]
```

**4. Relationship Exploration**

Explore wiki structure:
```
User: "Show me the structure: children of 'Business Plan', what links to it, and what it references"
Claude: [Uses list_children, get_relationships (linked_by), get_relationships (links)]
```

### Error Handling

All tools return clear error messages:

**Common Errors:**
- **Not Found (404)**: Card doesn't exist
- **Authorization (403)**: Insufficient permissions (need admin/gm role)
- **Validation Error**: Card data doesn't meet requirements
- **Network Error**: Connection issues with wiki
- **Rate Limit**: Too many requests per minute

**Example Error Response:**
```
❌ Error: Card not found

The card 'Nonexistent Card' does not exist on the wiki.

Suggestions:
- Check the card name spelling (case-sensitive)
- Search for similar cards: "Search for 'Nonexistent'"
- Verify you have permission to view this card
```

### Performance Notes

**Response Times:**
- Card fetch: ~100-500ms
- Search: ~200-800ms (depends on result size)
- Weekly summary: ~2-5s (scans git repos)
- Validation: ~300-600ms (fetches type requirements)
- Backup download: ~10-60s (depends on database size)

**Rate Limiting:**
The Decko API enforces rate limits:
- Default: 50 requests per minute per API key
- Automatic retry with exponential backoff
- Tool calls count toward this limit

**Optimization:**
- Search results are paginated (50-100 per page)
- Tag data cached for 5 minutes
- JWT tokens cached until expiry
- Batch operations reduce request count

---

## 5. Weekly Summary Feature

### Overview

The Weekly Summary feature provides automated tools for generating comprehensive weekly work summaries that combine wiki card changes and repository activity. This feature follows the format established by the existing "Weekly Work Summary" cards on the wiki.

**Key Capabilities:**
- Retrieve all cards updated within a time period
- Scan git repositories for commits
- Format summary in standardized markdown
- Create summary card on wiki or preview locally
- Combine wiki activity with code changes
- Support for custom executive summaries

**Generated Summary Includes:**
- Executive summary (auto-generated or custom)
- Wiki card updates (grouped by parent)
- Repository changes (commits grouped by repo)
- Next steps placeholder

### Usage Examples

#### Example 1: Basic Weekly Summary

Create a standard weekly summary for the current week:

**Command:**
```
"Generate a weekly summary for Magi Archive"
```

**What happens:**
1. Scans wiki for cards updated in last 7 days
2. Scans git repositories in working directory for commits
3. Formats content following standard template
4. Creates "Weekly Work Summary [today's date]" card
5. Returns card URL and preview

**Result:**
```
✓ Weekly summary created

Name: Weekly Work Summary 2025 12 09
URL: https://wiki.magi-agi.org/Weekly_Work_Summary_2025_12_09

Summary:
- 15 wiki card updates
- 42 commits across 3 repositories
```

#### Example 2: Custom Date Range

Create a summary for a specific two-week period:

**Command:**
```
"Create a weekly summary for the last 14 days with date 2025 12 09"
```

**Parameters:**
- `days: 14` (look back 14 days)
- `date: "2025 12 09"` (use this date in card name)

**Result:** Summary covering the past two weeks, titled "Weekly Work Summary 2025 12 09"

#### Example 3: Preview Before Creating

Generate and review the summary content before creating the card:

**Command:**
```
"Preview a weekly summary without creating the card"
```

**Parameters:**
- `create_card: false`

**Result:** Returns full markdown content for review, no card created

**Workflow:**
```
User: "Preview weekly summary"
Claude: [Shows full markdown preview]

User: "Looks good, create it"
Claude: [Uses create_weekly_summary with create_card=true]
```

#### Example 4: Custom Executive Summary

Create summary with custom executive summary text:

**Command:**
```
"Generate weekly summary with executive summary: 'This week focused on completing MCP Phase 2.1, implementing comprehensive testing, and updating all documentation.'"
```

**Parameters:**
- `executive_summary: "This week focused on..."`

**Result:** Summary with your custom executive summary instead of auto-generated one

#### Example 5: Specific Repository Path

Scan a specific project directory:

**Command:**
```
"Create weekly summary scanning repos in /home/user/projects/magi"
```

**Parameters:**
- `base_path: "/home/user/projects/magi"`

**Result:** Scans only repositories under the specified path

### Configuration Options

#### Time Range Options

**`days` (integer, default: 7)**
- Number of days to look back
- Maximum: 365
- Example: `days: 14` for two weeks

**`since` (string, optional)**
- Specific start date in ISO format
- Overrides `days` parameter
- Example: `since: "2025-11-25"`

**`before` (string, optional)**
- Specific end date in ISO format
- Default: current time
- Example: `before: "2025-12-02"`

**Date Range Examples:**
```ruby
# Last 7 days (default)
create_weekly_summary

# Last 14 days
create_weekly_summary(days: 14)

# Specific date range
create_weekly_summary(
  since: "2025-11-25",
  before: "2025-12-02"
)
```

#### Repository Scanning Options

**`base_path` (string, optional)**
- Root directory to scan for git repos
- Default: working directory from MCP config
- Scans up to 2 levels deep
- Automatically finds `.git` directories

**Scanning Behavior:**
- Recursively scans subdirectories (2 levels max)
- Skips non-git directories
- Includes only repos with commits in time period
- Gracefully handles inaccessible repos

**Example Structures:**
```
base_path: /home/user/projects
├── magi-archive/          ← Found
│   └── .git/
├── magi-archive-mcp/      ← Found
│   └── .git/
├── docs/                  ← Skipped (no .git)
└── other-project/         ← Found
    └── .git/
```

#### Card Creation Options

**`date` (string, optional)**
- Date string for card name
- Format: "YYYY MM DD"
- Default: today's date
- Example: `date: "2025 12 09"`

**`executive_summary` (string, optional)**
- Custom executive summary text
- Replaces auto-generated summary
- Can be multiple sentences
- Markdown formatting supported

**`parent` (string, optional)**
- Parent card name
- Default: "Home"
- Creates as child card: "Parent+Weekly Work Summary..."

**`create_card` (boolean, optional)**
- Whether to create card or just return content
- Default: `true`
- `false` for preview mode

**Full Example:**
```
"Create weekly summary with these options:
- Last 14 days
- Date: 2025 12 09
- Executive summary: 'Major milestone week completing Phase 2.1'
- Base path: /home/user/projects
- Parent: Project Summaries"
```

### Output Format

The generated weekly summary follows this structure:

```markdown
# Weekly Work Summary 2025 12 09

## Executive Summary

This week saw 15 card updates across the wiki and 42 commits across 3 repositories.
Major focus areas included MCP API Phase 2.1 completion, comprehensive testing,
and documentation updates.

## Wiki Card Updates

### Business Plan

- `Business Plan+Executive Summary` (2025-12-03)
- `Business Plan+Vision` (2025-12-02)

### Technical Documentation

- `Technical Documentation+API Reference` (2025-12-01)
- `Technical Documentation+Security Guide` (2025-11-30)

### Game Content

- `Butterfly Galaxii+Species+Vulcans` (2025-12-02)
- `Butterfly Galaxii+Locations+Earth` (2025-11-29)

## Repository & Code Changes

### magi-archive

**12 commits**

- `abc123d` Add Phase 2.1 features (Developer, 2025-12-03)
- `def456e` Update validation controller (Developer, 2025-12-02)
- `789abcd` Implement tag caching (Developer, 2025-12-02)
- `012efgh` Fix relationship queries (Developer, 2025-12-01)
- `345ijkl` Add comprehensive tests (Developer, 2025-12-01)
... and 7 more commits

### magi-archive-mcp

**30 commits**

- `xyz789a` Implement weekly summary feature (Developer, 2025-12-03)
- `bcd012e` Add MCP server tools (Developer, 2025-12-03)
- `fgh345i` Create auto-installers (Developer, 2025-12-02)
- `jkl678m` Update authentication (Developer, 2025-12-02)
- `nop901q` Add NPM wrapper (Developer, 2025-12-01)
... and 25 more commits

## Next Steps

- [Add your next steps here]
-
-
```

**Format Details:**

**Executive Summary:**
- Auto-generated: Counts cards and commits
- Custom: Your provided text
- Highlights major focus areas

**Wiki Card Updates:**
- Grouped by top-level parent card
- Shows full card path
- Includes update date in YYYY-MM-DD format
- Sorted by parent, then by date (newest first)

**Repository & Code Changes:**
- Grouped by repository name
- Shows total commit count
- Lists up to 10 commits per repo
- Format: `hash` Subject (Author, Date)
- Overflow indicated: "... and N more commits"

**Next Steps:**
- Placeholder section for manual completion
- Typically filled in after review

### API Reference

#### Get Recent Card Changes

```ruby
tools.get_recent_changes(days: 7)
tools.get_recent_changes(since: "2025-11-25", before: "2025-12-02")
```

**Returns:** Array of card hashes with metadata

#### Scan Git Repositories

```ruby
tools.scan_git_repos(base_path: "/path/to/repos", days: 7)
tools.scan_git_repos(since: "2025-11-25")
```

**Returns:** Hash of repository changes grouped by repo name

#### Format Weekly Summary

```ruby
tools.format_weekly_summary(
  card_changes,
  repo_changes,
  title: "Custom Title",
  executive_summary: "Custom summary..."
)
```

**Returns:** Formatted markdown string

#### Create Weekly Summary

```ruby
tools.create_weekly_summary
tools.create_weekly_summary(days: 14, date: "2025 12 09")
tools.create_weekly_summary(create_card: false)  # Preview mode
```

**Returns:** Card hash (if created) or markdown string (if preview)

### Limitations and Considerations

**Repository Scanning:**
- Scans up to 2 directory levels deep
- Requires git to be installed and in PATH
- Only includes repos with commits in time period
- Limited to 10 commits per repo in output (overflow counted)
- Private repos require local access
- Submodules not automatically included

**Card Changes:**
- Uses wiki's `updated_at` timestamps
- Automatically handles pagination
- Filters based on user role (respects GM/AI content restrictions)
- Groups by top-level parent only
- Large result sets may take longer

**Performance:**
- Large repos with many commits: slower scanning
- Very large card result sets: automatic pagination
- Consider specific date ranges for better performance
- Git scanning: ~1-3s per repo

**Error Handling:**
- Gracefully handles inaccessible repositories
- Continues if some repos fail to scan
- Returns empty arrays for inaccessible repos
- Logs errors but doesn't fail entire operation

### Troubleshooting

**Issue: No repositories found**

**Cause:** Git repos not in expected location or not within scan depth

**Solution:**
```
"Create weekly summary with base path /absolute/path/to/repos"
```

**Issue: Missing commits**

**Cause:** Date range too narrow or commits not yet pushed

**Solution:**
- Verify date range: "Preview summary for last 14 days"
- Check local commits: `git log --since="7 days ago"`
- Ensure commits are in local repo (pushed or not)

**Issue: Card creation fails**

**Cause:** Authentication or permission issues

**Solution:**
- Verify credentials in MCP config
- Check user role (need create permission)
- Try preview mode first: `create_card: false`

**Issue: Empty card changes**

**Cause:** No cards updated in specified time period

**Solution:**
- Adjust date range: "Summary for last 14 days"
- Verify wiki activity with search
- Check role permissions (user can't see GM cards)

**Issue: Git not found**

**Cause:** Git not installed or not in PATH

**Solution:**
- Install git: https://git-scm.com
- Verify: `git --version`
- Add to PATH if needed

---

## 6. Security Best Practices

This section outlines security best practices, threat models, and secure configuration for the Magi Archive MCP Server.

### Security Model

#### Defense in Depth

Magi Archive MCP implements multiple layers of security:

```
┌─────────────────────────────────────────────────┐
│ Layer 1: Transport Security (HTTPS/TLS)        │
├─────────────────────────────────────────────────┤
│ Layer 2: API Key/Password Authentication       │
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

**Trust Boundaries:**
1. **Client ↔ MCP Server**: Application code using the library
2. **MCP Server ↔ Decko API**: Network boundary over HTTPS
3. **Decko API ↔ Database**: Internal Decko application layer

#### Threat Model

**Assets to Protect:**
1. API Keys and passwords
2. JWT Tokens
3. Card Content (user and GM data)
4. System Access

**Threats and Mitigations:**

| Threat | Risk Level | Mitigation |
|--------|-----------|------------|
| API Key Exposure | High | Environment variables, never commit to VCS |
| Man-in-the-Middle | High | HTTPS enforcement, certificate validation |
| Privilege Escalation | High | Role verification on every request |
| Token Theft | Medium | Short token lifetime (15-60min), HTTPS only |
| Rate Limit Abuse | Medium | Server-side rate limiting, exponential backoff |
| Injection Attacks | Medium | Input validation, parameterized queries |
| Replay Attacks | Low | JWT `jti` (unique ID per token) |

### Credential Management

#### Never Commit Secrets

**Bad:**
```json
{
  "env": {
    "MCP_PASSWORD": "my-password-123"
  }
}
```
❌ Hardcoded credential in config file committed to git

**Good:**
```bash
# .env file (in .gitignore)
MCP_PASSWORD=my-password-123
```

```json
{
  "env": {
    "MCP_PASSWORD": "${MCP_PASSWORD}"
  }
}
```
✅ Reference to environment variable, actual value in gitignored file

#### Use Environment Variables

**Best Practices:**
1. **Store credentials in `.env` files**
   ```bash
   # .env (add to .gitignore)
   MCP_USERNAME=alice
   MCP_PASSWORD=secure-password-here
   MCP_API_KEY=fallback-key-if-needed
   ```

2. **Add `.env` to `.gitignore`**
   ```gitignore
   # .gitignore
   .env
   .env.*
   !.env.example
   ```

3. **Provide `.env.example` template**
   ```bash
   # .env.example (committed to git)
   MCP_USERNAME=your-username-here
   MCP_PASSWORD=your-password-here
   DECKO_API_BASE_URL=https://wiki.magi-agi.org/api/mcp
   ```

4. **Use different keys per environment**
   ```bash
   # .env.development
   MCP_API_KEY=dev-key-with-limited-access
   MCP_ROLE=user

   # .env.production (never commit)
   MCP_API_KEY=prod-key-full-access
   MCP_ROLE=admin
   ```

#### File Permissions

Protect configuration files:

```bash
# Restrict .env file permissions (owner read/write only)
chmod 600 .env

# Verify
ls -la .env
# Expected: -rw------- 1 user group 123 Dec 2 .env
```

**Windows:** Use file properties to restrict access to your user account only.

### Principle of Least Privilege

Always use the minimum role required for the task.

**Bad:**
```json
{
  "env": {
    "MCP_ROLE": "admin"
  }
}
```
❌ Always using admin for convenience (excessive privilege)

**Good:**
```json
{
  "env": {
    "MCP_ROLE": "user"
  }
}
```
✅ Using minimal role for the task (least privilege)

**Role Selection Guide:**
- **User role**: For reading and creating your own content
- **GM role**: Only when you need GM content access
- **Admin role**: Only for administrative tasks (backups, deletions)

**Multiple Configurations:**
Set up separate MCP servers for different roles:

```json
{
  "mcpServers": {
    "magi-archive-user": {
      "env": {
        "MCP_USERNAME": "alice",
        "MCP_PASSWORD": "...",
        "MCP_ROLE": "user"
      }
    },
    "magi-archive-admin": {
      "env": {
        "MCP_API_KEY": "admin-key...",
        "MCP_ROLE": "admin"
      }
    }
  }
}
```

### Input Validation

Always validate user input before passing to the API.

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
unless user_input.match?(/\A[A-Za-z0-9 _+-]+\z/)
  raise ArgumentError, "Invalid card name format"
end

# Limit length
if user_input.length > 255
  raise ArgumentError, "Card name too long"
end

card = tools.get_card(user_input)  # ✅ Validated
```

**Validation Checklist:**
- ✅ Check format (allowed characters)
- ✅ Limit length
- ✅ Sanitize special characters
- ✅ Reject suspicious patterns
- ✅ Use allowlists, not denylists

### Error Handling

Don't expose sensitive information in errors.

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

### Token Management

**Automatic Token Refresh:**
The library automatically handles token refresh. Tokens are:
- Cached in memory per client instance
- Automatically refreshed before expiry
- Short-lived (15-60 minutes)
- RS256 signed and verified

**Manual Token Management (Advanced):**
```ruby
# Access the underlying client
client = tools.client

# Force token refresh
client.auth.refresh_token!

# Check token expiry
if client.auth.token_expired?
  puts "Token has expired"
end

# Get current token info
puts "Role: #{client.auth.role}"
puts "Expires: #{client.auth.token_expiry}"
```

**Token Security:**
- ✅ Tokens transmitted over HTTPS only
- ✅ Tokens contain role claim
- ✅ Tokens verified on every request
- ✅ Tokens include unique ID (jti) to prevent replay
- ❌ Never log tokens
- ❌ Never commit tokens to version control
- ❌ Never send tokens to third parties

### Role-Based Access Control (RBAC)

**Authorization Enforcement:**
Every request validates:
1. JWT signature (valid token?)
2. Token expiry (not expired?)
3. Role claim (has required role?)
4. Operation permission (role allows operation?)

**Example Authorization Check:**
```ruby
# The library handles this automatically, but conceptually:
def authorize_operation(role, operation)
  capabilities = {
    "user" => [:read_public, :create, :update_own],
    "gm" => [:read_public, :read_gm, :create, :update_own, :spoiler_scan],
    "admin" => [:read_all, :create, :update_all, :delete, :admin]
  }.freeze

  unless capabilities[role]&.include?(operation)
    raise AuthorizationError, "Role '#{role}' cannot perform '#{operation}'"
  end
end
```

**Separation of Duties:**
Use different credentials for different purposes:

```json
{
  "mcpServers": {
    "magi-reader": {
      "env": {
        "MCP_USERNAME": "reader-bot",
        "MCP_PASSWORD": "...",
        "MCP_ROLE": "user"
      }
    },
    "magi-admin": {
      "env": {
        "MCP_API_KEY": "admin-key...",
        "MCP_ROLE": "admin"
      }
    }
  }
}
```

### Common Pitfalls

**1. Logging Sensitive Data**

❌ **Bad:**
```ruby
logger.info("Authenticating with key: #{api_key}")
logger.info("Token received: #{token}")
```

✅ **Good:**
```ruby
logger.info("Authenticating with key: #{api_key[0..8]}...")
logger.info("Token received: [REDACTED]")
```

**2. Hardcoding URLs without HTTPS**

❌ **Bad:**
```json
{
  "env": {
    "DECKO_API_BASE_URL": "http://wiki.magi-agi.org/api/mcp"
  }
}
```

✅ **Good:**
```json
{
  "env": {
    "DECKO_API_BASE_URL": "https://wiki.magi-agi.org/api/mcp"
  }
}
```

**3. Disabling Certificate Validation**

❌ **Bad:**
```ruby
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE
```

✅ **Good:**
```ruby
# Use default SSL verification (don't disable it!)
```

**4. Using Same Credentials Everywhere**

❌ **Bad:** Same admin key for development, staging, production

✅ **Good:** Separate keys per environment with appropriate roles

**5. Not Rotating Credentials**

❌ **Bad:** Never changing API keys or passwords

✅ **Good:** Rotate credentials every 90 days (or per policy)

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

**Key Rotation Process:**
1. Request new key from admin
2. Test new key in development
3. Update production configuration
4. Verify production works with new key
5. Notify admin to revoke old key

**Rotation Script Example:**
```ruby
# 1. Request new key from admin
new_key = request_new_api_key_from_admin

# 2. Test new key
test_config = Magi::Archive::Mcp::Config.new(
  api_key: new_key,
  role: "user"
)
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

### Security Checklist

#### Development

- [ ] API keys stored in environment variables, not code
- [ ] `.env` file added to `.gitignore`
- [ ] Using HTTPS for all API calls
- [ ] Input validation on all user inputs
- [ ] Error handling doesn't expose sensitive details
- [ ] Using minimal required role for operations
- [ ] Secrets never logged

#### Production

- [ ] API keys rotated regularly (every 90 days)
- [ ] Keys stored in secrets management system (AWS Secrets Manager, Vault, etc.)
- [ ] Audit logging enabled
- [ ] Rate limiting configured
- [ ] Network access restricted (firewall rules)
- [ ] Certificate validation enabled
- [ ] Monitoring and alerting configured
- [ ] Incident response plan documented
- [ ] Regular security audits scheduled

#### Operations

- [ ] API key access reviewed quarterly
- [ ] Unused keys revoked
- [ ] Audit logs reviewed weekly
- [ ] Failed authentication attempts monitored
- [ ] Anomalous access patterns investigated
- [ ] Dependencies updated regularly (`bundle update`)
- [ ] Security patches applied promptly

### Incident Response

#### Compromised API Key

If an API key is compromised:

1. **Immediately notify admin** to revoke the key
2. **Generate new key** with different value
3. **Review audit logs** for unauthorized access
4. **Assess impact**: What data was accessed?
5. **Update systems** with new key
6. **Post-mortem**: How was key exposed?

**Response Script:**
```ruby
#!/usr/bin/env ruby
# incident_response.rb

puts "=== INCIDENT RESPONSE: Compromised API Key ==="

# 1. Contact admin to revoke key
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

### Reporting Security Issues

If you discover a security vulnerability:

1. **Do NOT** open a public GitHub issue
2. Email **security@magi-agi.org** with:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)
3. Allow 48 hours for initial response
4. Coordinate disclosure timeline with maintainers

### Compliance

This library is designed to support:
- **SOC 2 compliance** (audit logging, access control)
- **GDPR compliance** (data access, deletion)
- **HIPAA compliance** (when properly configured)

Consult your compliance team for specific requirements.

---

## 7. Deployment

### Production Deployment

#### Build and Install the Gem

**On Production Server:**

```bash
# Clone repository
git clone https://github.com/your-org/magi-archive-mcp.git
cd magi-archive-mcp

# Install dependencies
bundle install

# Build gem
bundle exec rake build
# Creates pkg/magi-archive-mcp-0.1.0.gem

# Install gem
gem install pkg/magi-archive-mcp-0.1.0.gem
```

#### Production Environment Setup

**1. Create production environment file:**

```bash
# /etc/magi-archive-mcp/.env.production
MCP_API_KEY=production-key-here
MCP_ROLE=user
DECKO_API_BASE_URL=https://wiki.magi-agi.org/api/mcp
JWKS_CACHE_TTL=3600
```

**2. Set restrictive permissions:**

```bash
chmod 600 /etc/magi-archive-mcp/.env.production
chown mcp-user:mcp-group /etc/magi-archive-mcp/.env.production
```

**3. Configure MCP client:**

For Claude Desktop on production server:
```json
{
  "mcpServers": {
    "magi-archive": {
      "command": "ruby",
      "args": [
        "/usr/local/bin/magi-archive-mcp",
        "/var/www/projects"
      ],
      "env": {
        "MCP_API_KEY": "${MCP_API_KEY}",
        "MCP_ROLE": "${MCP_ROLE}",
        "DECKO_API_BASE_URL": "${DECKO_API_BASE_URL}"
      }
    }
  }
}
```

### Configuration Management

#### Using Secrets Management Systems

**AWS Secrets Manager:**

```ruby
require 'aws-sdk-secretsmanager'

def get_api_key
  client = Aws::SecretsManager::Client.new(region: 'us-west-2')
  secret = client.get_secret_value(secret_id: 'magi-archive/api-key')
  JSON.parse(secret.secret_string)['api_key']
end

# Use in configuration
ENV['MCP_API_KEY'] = get_api_key
```

**HashiCorp Vault:**

```ruby
require 'vault'

Vault.configure do |config|
  config.address = 'https://vault.example.com'
  config.token = ENV['VAULT_TOKEN']
end

# Fetch secret
secret = Vault.logical.read('secret/magi-archive/mcp')
ENV['MCP_API_KEY'] = secret.data[:api_key]
```

**Azure Key Vault:**

```ruby
require 'azure/key_vault'

client = Azure::KeyVault::Client.new(
  credentials: Azure::KeyVault::Authentication.new
)

secret = client.get_secret(
  'https://your-vault.vault.azure.net',
  'magi-archive-api-key'
)

ENV['MCP_API_KEY'] = secret.value
```

#### Environment-Specific Configuration

**Development:**
```bash
# .env.development
MCP_USERNAME=dev-user
MCP_PASSWORD=dev-password
DECKO_API_BASE_URL=https://dev.wiki.magi-agi.org/api/mcp
DEBUG=true
```

**Staging:**
```bash
# .env.staging
MCP_API_KEY=staging-key
MCP_ROLE=gm
DECKO_API_BASE_URL=https://staging.wiki.magi-agi.org/api/mcp
DEBUG=false
```

**Production:**
```bash
# .env.production
MCP_API_KEY=production-key
MCP_ROLE=user
DECKO_API_BASE_URL=https://wiki.magi-agi.org/api/mcp
DEBUG=false
LOG_LEVEL=info
```

### Testing the Installation

#### Installation Test Script

The repository includes a test script: `test_installation.rb`

```bash
# From project directory
ruby test_installation.rb
```

**Expected Output:**
```
================================================================================
Magi Archive MCP Installation Test
================================================================================

✓ Gem Version: 0.1.0

✓ Configuration loaded successfully
  - API Base URL: https://wiki.magi-agi.org/api/mcp
  - Requested Role: user
  - API Key: abc123... (32 chars)

Testing authentication...
✓ Authentication successful
  - Token received: eyJhbGciOiJSUzI1NiIsInR5cCI...

Testing card retrieval...
✓ Successfully retrieved card: Main Page
  - Type: Basic
  - Content preview: Welcome to the Magi Archive...

Testing card search...
✓ Search completed successfully
  - Found 42 total matches
  - Returned 5 cards in this page

Testing type listing...
✓ Type listing completed
  - Found 25 total types
  - Sample types: Basic, Article, User

================================================================================
Installation test complete!
================================================================================
```

#### Testing Individual Components

**Test authentication:**
```ruby
require 'magi/archive/mcp'

tools = Magi::Archive::Mcp::Tools.new
puts "Authenticated as role: #{tools.client.auth.role}"
```

**Test card retrieval:**
```ruby
card = tools.get_card('Main Page')
puts "Card: #{card['name']}"
puts "Type: #{card['type']}"
```

**Test search:**
```ruby
results = tools.search_cards(q: 'test', limit: 5)
puts "Found #{results['total']} results"
```

### Monitoring and Logs

#### Enable Debug Logging

**For development:**
```bash
export DEBUG=true
ruby bin/mcp-server
```

**For production (Ruby Logger):**
```ruby
require 'logger'

logger = Logger.new(STDOUT)
logger.level = Logger::INFO

# Or log to file
logger = Logger.new('/var/log/magi-archive-mcp/server.log')
logger.level = Logger::WARN
```

#### Audit Logging

**Log all operations:**
```ruby
require 'logger'

class AuditedTools < Magi::Archive::Mcp::Tools
  def initialize(config = nil, logger: Logger.new('/var/log/magi-mcp-audit.log'))
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
end
```

**What to log:**
- ✅ Authentication attempts (success/failure)
- ✅ Authorization failures
- ✅ Destructive operations (delete, bulk updates)
- ✅ Admin operations
- ✅ Rate limit violations
- ✅ Configuration changes

**What NOT to log:**
- ❌ API keys or tokens
- ❌ Full card content (may contain sensitive data)
- ❌ Passwords or secrets

#### Performance Monitoring

**Track response times:**
```ruby
require 'benchmark'

result = Benchmark.measure do
  tools.search_cards(q: 'query')
end

logger.info("Search took #{result.real}s")
```

**Monitor rate limits:**
```ruby
# The client automatically retries with backoff
# Monitor for repeated 429 errors in logs
```

### Common Issues

#### 1. Command Not Found: magi-archive-mcp

**Problem:** Shell can't find the executable

**Solution (Linux/macOS):**
```bash
export PATH="$HOME/.local/share/gem/ruby/3.2.0/bin:$PATH"
# Add to ~/.bashrc or ~/.zshrc
```

**Solution (Windows):**
The gem bin should be automatically added to PATH by RubyGems.

#### 2. Configuration Error: MCP_API_KEY is required

**Problem:** No `.env` file or missing API key

**Solution:**
1. Copy `.env.test.template` to `.env`
2. Fill in your actual API key
3. Make sure you're running from the project directory (where `.env` is)

#### 3. Authentication Failed: 401 Unauthorized

**Problem:** Invalid API key or role mismatch

**Solution:**
1. Verify your API key is correct
2. Check that the role matches what your key is authorized for
3. Contact the Decko administrator if issues persist

#### 4. Card Not Found: 404

**Problem:** Trying to access a card that doesn't exist or you don't have permission to view

**Solution:**
1. Verify the card name is correct (case-sensitive!)
2. Check that your role has permission to view the card
3. Try searching for the card first

#### 5. Permission Denied: 403 Forbidden

**Problem:** Your role doesn't have permission for the operation

**Solution:**
1. User role can only read public cards and write own cards
2. GM role can read GM content but not delete
3. Admin role required for delete/move operations
4. Request appropriate role if needed

### Security Checklist

Before production deployment:

- [ ] API keys stored in environment variables (never in code)
- [ ] `.env` file is in `.gitignore`
- [ ] Using HTTPS for all API calls
- [ ] Rate limiting configured
- [ ] Error messages don't leak sensitive data
- [ ] Logs don't contain API keys or tokens
- [ ] Using minimal required role (principle of least privilege)
- [ ] Token refresh is working correctly
- [ ] JWKS cache is configured appropriately
- [ ] File permissions set correctly (600 for .env)
- [ ] Secrets management system in use (Vault, AWS Secrets Manager, etc.)
- [ ] Audit logging enabled
- [ ] Monitoring and alerting configured

---

## 8. Troubleshooting

### Common Issues

#### Server Won't Start

**Symptom:** MCP server fails to start, tools not available in Claude Desktop

**Diagnosis:**

1. **Check Ruby version:**
   ```bash
   ruby --version
   # Should be 3.2.0 or higher
   ```

2. **Check dependencies:**
   ```bash
   cd magi-archive-mcp
   bundle install
   ```

3. **Check authentication:**
   Ensure your `.env` file or config has valid credentials

4. **Check file permissions:**
   ```bash
   chmod +x bin/mcp-server
   ```

5. **Test server directly:**
   ```bash
   ruby bin/mcp-server /path/to/workdir
   ```

**Common Causes:**
- Ruby version too old (< 3.2)
- Missing dependencies (run `bundle install`)
- Invalid credentials
- File not executable
- Path issues in config

#### Tools Not Appearing in Claude Desktop

**Symptom:** Claude Desktop runs but Magi Archive tools don't appear

**Diagnosis:**

1. **Restart Claude Desktop completely**
   - Quit application (not just close window)
   - Relaunch

2. **Check config file syntax**
   ```bash
   # macOS
   cat ~/Library/Application\ Support/Claude/claude_desktop_config.json | jq

   # Windows
   type %APPDATA%\Claude\claude_desktop_config.json | jq
   ```
   Must be valid JSON (no trailing commas, proper quotes)

3. **Check server logs**
   - Open Claude Desktop
   - Help → Developer Tools
   - Check Console for errors

4. **Verify file paths are absolute**
   ```json
   {
     "args": [
       "/absolute/path/to/mcp-server",  ← Must be absolute
       "/absolute/path/to/workdir"      ← Must be absolute
     ]
   }
   ```

5. **Test MCP protocol directly:**
   ```bash
   echo '{"jsonrpc":"2.0","id":"1","method":"tools/list"}' | ruby bin/mcp-server
   ```
   Should return JSON with tool list

**Common Causes:**
- Config file syntax errors (invalid JSON)
- Relative paths instead of absolute
- Server crashes on startup
- Missing environment variables
- File permissions

#### Authentication Failures

**Symptom:** "Authentication failed: Invalid API key" or similar

**Diagnosis:**

1. **Check credentials format:**
   ```bash
   # No extra whitespace
   MCP_API_KEY="abc123def456..."  # ✓ Correct
   MCP_API_KEY="abc123 "          # ✗ Wrong (trailing space)
   ```

2. **Verify credentials are active:**
   Contact admin to verify key is not revoked

3. **Check role permissions:**
   ```bash
   # Your key may not support the requested role
   MCP_API_KEY=user-only-key
   MCP_ROLE=admin  # ✗ Error: key not authorized for admin role
   ```

4. **Test authentication directly:**
   ```ruby
   require 'magi/archive/mcp'

   config = Magi::Archive::Mcp::Config.new(
     api_key: ENV['MCP_API_KEY'],
     role: ENV['MCP_ROLE']
   )

   tools = Magi::Archive::Mcp::Tools.new(config)

   begin
     tools.get_card('Main Page')
     puts "✓ Authentication successful"
   rescue => e
     puts "✗ Authentication failed: #{e.message}"
   end
   ```

**Common Causes:**
- Typo in API key
- Extra whitespace in credentials
- Key revoked or expired
- Role mismatch (key doesn't support requested role)
- Network issues reaching Decko API

#### Permission Denied Errors

**Symptom:** "Permission denied: Insufficient role" when trying operations

**Root Cause:** Your role doesn't have permission for the operation

**Solutions:**

**For delete operations:**
```
User trying to delete → Need admin role
```
**Solution:** Request admin API key or use admin credentials

**For GM content:**
```
User trying to read GM card → Need gm or admin role
```
**Solution:** Request GM role if you're a game master

**For card updates:**
```
User trying to update another user's card → Need gm or admin role
```
**Solution:** User role can only update own cards

**Role Permission Matrix:**

| Operation | User | GM | Admin |
|-----------|------|-----|-------|
| Read public cards | ✅ | ✅ | ✅ |
| Read GM cards | ❌ | ✅ | ✅ |
| Create cards | ✅ | ✅ | ✅ |
| Update own cards | ✅ | ✅ | ✅ |
| Update any cards | ❌ | ❌ | ✅ |
| Delete cards | ❌ | ❌ | ✅ |
| Admin operations | ❌ | ❌ | ✅ |

#### Token Expired Errors

**Symptom:** "Token expired" error during operation

**This should never happen** (automatic refresh), but if it does:

**Diagnosis:**
```ruby
client = tools.client

# Check token status
puts "Expired? #{client.auth.token_expired?}"
puts "Expiry: #{client.auth.token_expiry}"

# Force refresh
client.auth.refresh_token!
```

**Common Causes:**
- System clock incorrect (time sync issue)
- Network interruption during refresh
- Decko API temporarily unavailable

**Solution:**
1. Check system time: `date`
2. Sync time if needed: `ntpdate` or equivalent
3. Retry operation (automatic refresh should work)

#### Network Issues

**Symptom:** Connection errors, timeouts, or intermittent failures

**Diagnosis:**

1. **Check network connectivity:**
   ```bash
   curl https://wiki.magi-agi.org/api/mcp
   ```

2. **Check DNS resolution:**
   ```bash
   nslookup wiki.magi-agi.org
   ```

3. **Check firewall:**
   - Ensure outbound HTTPS (443) allowed
   - Ensure Ruby process not blocked

4. **Check proxy settings:**
   ```bash
   # If behind corporate proxy
   export HTTP_PROXY=http://proxy.example.com:8080
   export HTTPS_PROXY=http://proxy.example.com:8080
   ```

5. **Test with verbose output:**
   ```bash
   export DEBUG=true
   ruby bin/mcp-server
   ```

**Common Causes:**
- Network down or unstable
- Firewall blocking outbound connections
- DNS issues
- Corporate proxy not configured
- Decko API temporarily unavailable

#### Rate Limiting

**Symptom:** "Rate limit exceeded" or 429 errors

**Cause:** Too many requests per minute (default: 50 requests/minute)

**Solutions:**

1. **Reduce request frequency:**
   - Batch operations where possible
   - Add delays between requests
   - Cache results locally

2. **Use batch operations:**
   ```ruby
   # Instead of multiple create_card calls
   operations = [
     { action: 'create', name: 'Card 1', content: '...' },
     { action: 'create', name: 'Card 2', content: '...' }
   ]
   tools.batch_operations(operations)
   ```

3. **Request higher rate limit:**
   - Contact Decko administrator
   - Explain use case
   - May receive dedicated API key with higher limit

**The client automatically retries with exponential backoff**, so most rate limit issues resolve themselves.

### Debug Mode

#### Enable Debug Output

**Environment variable:**
```bash
export DEBUG=true
ruby bin/mcp-server
```

**In Ruby code:**
```ruby
ENV['DEBUG'] = 'true'
require 'magi/archive/mcp'
```

**Debug output includes:**
- HTTP requests and responses
- Authentication flow
- Token refresh events
- API call details
- Error stack traces

**Example debug output:**
```
[DEBUG] Authenticating with Decko API...
[DEBUG] POST https://wiki.magi-agi.org/api/mcp/auth
[DEBUG] Request body: { "role": "user" }
[DEBUG] Response: 200 OK
[DEBUG] Token received, expires: 2025-12-03 15:30:00 UTC
[DEBUG] GET https://wiki.magi-agi.org/api/mcp/cards/Main%20Page
[DEBUG] Authorization: Bearer eyJhbGci...
[DEBUG] Response: 200 OK
```

#### Verbose Logging

**Logger configuration:**
```ruby
require 'logger'

logger = Logger.new(STDOUT)
logger.level = Logger::DEBUG

# Pass to tools
tools = Magi::Archive::Mcp::Tools.new
tools.client.logger = logger
```

**Log levels:**
- `DEBUG`: Verbose output (all requests/responses)
- `INFO`: Normal operations
- `WARN`: Warnings and retries
- `ERROR`: Errors and failures

#### Testing MCP Protocol Directly

**Test tools/list:**
```bash
echo '{"jsonrpc":"2.0","id":"1","method":"tools/list"}' | \
  ruby bin/mcp-server
```

**Expected response:**
```json
{
  "jsonrpc": "2.0",
  "id": "1",
  "result": {
    "tools": [
      {
        "name": "get_card",
        "description": "Get a single card by name...",
        "inputSchema": { ... }
      },
      ...
    ]
  }
}
```

**Test tools/call:**
```bash
echo '{"jsonrpc":"2.0","id":"2","method":"tools/call","params":{"name":"get_card","arguments":{"name":"Main Page"}}}' | \
  ruby bin/mcp-server
```

### Getting Help

#### Documentation Resources

- **This Guide**: Comprehensive MCP server documentation
- **README.md**: Quick start and basic usage
- **MCP-SPEC.md**: Technical specification
- **AUTHENTICATION.md**: Authentication details (archived)
- **SECURITY.md**: Security best practices (archived)

#### Support Channels

**GitHub Issues:**
- Bug reports: https://github.com/your-org/magi-archive-mcp/issues
- Feature requests: Label as "enhancement"
- Questions: Label as "question"

**Email Support:**
- General support: support@magi-agi.org
- Security issues: security@magi-agi.org (private)

**Wiki Documentation:**
- Main wiki: https://wiki.magi-agi.org
- MCP documentation: https://wiki.magi-agi.org/MCP

#### Reporting Bugs

**Include in bug reports:**
1. Ruby version (`ruby --version`)
2. Gem version (`gem list magi-archive-mcp`)
3. Operating system and version
4. MCP client (Claude Desktop, Codex, etc.)
5. Steps to reproduce
6. Expected vs actual behavior
7. Error messages (redact sensitive info)
8. Relevant config (redact credentials)

**Example bug report:**
```
Ruby: 3.2.2
Gem: magi-archive-mcp 0.1.0
OS: macOS 14.1
Client: Claude Desktop 1.2.3

Steps to reproduce:
1. Configure MCP server with user role
2. Try to create card "Test Card"
3. Receive error: "Permission denied"

Expected: Card created successfully
Actual: Permission denied error

Error message:
  Permission denied: Insufficient role

Config (credentials redacted):
  {
    "env": {
      "MCP_ROLE": "user",
      "DECKO_API_BASE_URL": "https://wiki.magi-agi.org/api/mcp"
    }
  }
```

#### Feature Requests

**Good feature requests include:**
1. Clear description of desired feature
2. Use case / why it's needed
3. Example of how it would be used
4. Alternative approaches considered
5. Willingness to contribute (optional)

**Example feature request:**
```
Feature: Batch card creation with validation

Use case:
Creating multiple related cards at once (e.g., species + subcards)
would be faster with validation before creation.

Proposed usage:
  "Create these 5 cards with validation: ..."

Would combine validate_card + batch_operations

Willing to contribute: Yes, can submit PR if design approved
```

---

## Appendix

### Version History

**Version 1.0.0 (2025-12-03)**

Initial MCP Server Implementation:
- ✅ 16 MCP tools (card operations, tags, relationships, validation, rendering, admin, utilities)
- ✅ Auto-installers for Claude Desktop, Claude Code, and Codex
- ✅ NPM wrapper for Node.js users
- ✅ Username/password and API key authentication
- ✅ Three-tier role-based access (user, gm, admin)
- ✅ Weekly summary feature with git integration
- ✅ Comprehensive documentation
- ✅ JSON-RPC 2.0 over stdio (MCP spec 2025-03-26 compliant)
- ✅ Automatic token refresh and management
- ✅ Rate limiting and retry logic
- ✅ Input validation and security features

### Glossary

**MCP**: Model Context Protocol - Open standard for connecting AI assistants to external tools and data

**Decko**: Wiki software powering wiki.magi-agi.org

**JWT**: JSON Web Token - Secure token format for authentication

**JWKS**: JSON Web Key Set - Public keys for JWT verification

**RS256**: RSA signature with SHA-256 - Asymmetric signing algorithm

**RBAC**: Role-Based Access Control - Permission system based on user roles

**JSON-RPC**: Remote Procedure Call protocol using JSON

**stdio**: Standard input/output - Communication channel used by MCP

**API Key**: Long-lived credential for programmatic access

**Token**: Short-lived session credential (JWT)

**Card**: Wiki page in Decko

**Child Card**: Subpage using "Parent+Child" naming

**Tag**: Label/category applied to cards

**Type**: Card template/schema (Basic, Article, etc.)

### External Resources

**MCP Protocol:**
- Specification: https://spec.modelcontextprotocol.io
- Ruby SDK: https://github.com/modelcontextprotocol/ruby-sdk
- Documentation: https://modelcontextprotocol.io

**Magi Archive:**
- Wiki: https://wiki.magi-agi.org
- API Documentation: https://wiki.magi-agi.org/API
- Security: https://wiki.magi-agi.org/Security

**Ruby:**
- Ruby Language: https://www.ruby-lang.org
- RubyGems: https://rubygems.org
- Bundler: https://bundler.io

**JWT:**
- JWT.io: https://jwt.io
- RFC 7519: https://tools.ietf.org/html/rfc7519
- Best Practices: https://tools.ietf.org/html/rfc8725

**Security:**
- OWASP Top 10: https://owasp.org/www-project-top-ten/
- Ruby Security: https://guides.rubyonrails.org/security.html

### License

MIT License - See LICENSE file for details

### Contributing

Contributions welcome! To contribute:

1. Fork the repository
2. Create feature branch
3. Make changes with tests
4. Submit pull request
5. Ensure CI passes

See CONTRIBUTING.md for detailed guidelines.

### Support

For issues, questions, or feature requests:
- **GitHub Issues**: https://github.com/your-org/magi-archive-mcp/issues
- **Email**: support@magi-agi.org
- **Security**: security@magi-agi.org
- **Wiki**: https://wiki.magi-agi.org/MCP

---

**Document Version**: 1.0.0
**Last Updated**: 2025-12-03
**Maintained by**: Magi AGI Team
