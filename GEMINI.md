# Project: Magi Archive MCP Server

## Overview
This project is the **Magi Archive MCP Server**, a Model Context Protocol (MCP) implementation designed to interface with the `wiki.magi-agi.org` Decko application. It enables AI agents (via CLIs like Claude or Gemini) to interact with the archive securely and efficiently, replacing legacy ad-hoc SSH scripts with a structured JSON API.

## Architecture
The system acts as a middleware/client that implements the MCP protocol and communicates with the upstream Decko API.

*   **Primary Role:** MCP Server.
*   **Upstream:** Magi Archive Decko App (`magi-archive` repo).
*   **Auth:** API Key + Role (User, GM, Admin).
*   **Key Capabilities:**
    *   Card management (`get`, `create`, `update`, `delete`).
    *   Search and query (`search_cards`, `run_query`).
    *   Content rendering (`render_snippet`).
    *   Role-based access control enforcement.

## Directory Status
**Current Phase:** ✅ PRODUCTION - Fully operational and deployed.

**Status as of 2025-12-11:**
- All core features implemented and tested
- 132+ integration tests passing
- Deployed to production at wiki.magi-agi.org
- MCP server operational on HTTP (port 3002) and stdio transports
- ChatGPT integration working with admin role authentication

### Key Files
*   `MCP-SPEC.md`: Comprehensive specification of the API, roles, tools, and architecture.
*   `AGENTS.md`: Development guidelines, project structure, and standard commands.
*   `LICENSE`: Project license.

## Development Guidelines (Target)
*As defined in `AGENTS.md`*

### Target Structure
*   **Source:** `lib/magi/archive/` (Namespaced Ruby modules).
*   **CLI:** `bin/` (Thin entrypoints).
*   **Tests:** `spec/` (Mirrors `lib/` structure).
*   **Package:** `pkg/` (Build artifacts).

### Workflow Commands
*   **Install Dependencies:** `bundle install`
*   **Run Tests:** `bundle exec rspec` (Use `--format documentation` for detail).
*   **Linting:** `bundle exec rubocop`
*   **Build Gem:** `bundle exec rake build`
*   **Console:** `bundle exec rake console`

### Coding Conventions
*   **Language:** Ruby.
*   **Style:**
    *   2-space indentation.
    *   `snake_case` for methods/variables.
    *   `CamelCase` for classes/modules.
    *   Explicit `require` statements.
*   **Testing:** RSpec is mandatory for new features and bugfixes.
*   **Git:** Imperative commit messages (e.g., "Add archive writer validation").

## Next Steps
1.  Scaffold the Ruby Gem structure (`bundle gem`, `rspec --init`).
2.  Implement the core `Magi::Archive` module structure.
3.  Develop MCP tool wrappers according to `MCP-SPEC.md`.
