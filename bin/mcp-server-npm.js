#!/usr/bin/env node

import { spawn } from 'child_process';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { readFileSync } from 'fs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Check for help/version flags before authentication
const args = process.argv.slice(2);
if (args.includes('--help') || args.includes('-h')) {
  console.log(`
Hyperon Wiki MCP Server

USAGE:
  hyperon-wiki-mcp [WORKING_DIR]

ARGUMENTS:
  WORKING_DIR    Optional working directory for git repo scanning (default: current directory)

ENVIRONMENT VARIABLES:
  Authentication (choose one method):
    MCP_USERNAME           Decko wiki username (recommended)
    MCP_PASSWORD           Decko wiki password

    MCP_API_KEY            API key (for service accounts)
    MCP_ROLE               Role: user, gm, or admin

  Configuration:
    DECKO_API_BASE_URL     API endpoint (default: https://wiki.hyperon.dev/api/mcp)

DESCRIPTION:
  MCP server providing secure access to the Hyperon Wiki wiki for AI assistants.
  Supports ChatGPT Desktop, Claude Desktop, and other MCP-compatible clients.

  Available tools:
  - get_card, search_cards, create_card, update_card, delete_card
  - list_children, get_tags, search_by_tags, get_relationships
  - validate_card, get_recommendations, get_types
  - render_content, admin_backup, create_weekly_summary

EXAMPLES:
  # Run with username/password authentication
  export MCP_USERNAME=your-username
  export MCP_PASSWORD=your-password
  hyperon-wiki-mcp

  # Run with API key authentication
  export MCP_API_KEY=your-key
  export MCP_ROLE=user
  hyperon-wiki-mcp

  # Specify custom working directory
  hyperon-wiki-mcp /path/to/repos

MORE INFO:
  Documentation: https://github.com/your-org/hyperon-wiki-mcp
  Wiki: https://wiki.hyperon.dev
`);
  process.exit(0);
}

if (args.includes('--version') || args.includes('-v')) {
  const packagePath = join(__dirname, '..', 'package.json');
  const pkg = JSON.parse(readFileSync(packagePath, 'utf8'));
  console.log(`hyperon-wiki-mcp v${pkg.version}`);
  process.exit(0);
}

// Path to the Ruby MCP server
const serverPath = join(__dirname, 'mcp-server');
const gemRoot = join(__dirname, '..');

// Get working directory argument (optional)
const workingDir = args[0] || process.cwd();

// Environment variables required for the server
const env = {
  ...process.env,
  DECKO_API_BASE_URL: process.env.DECKO_API_BASE_URL || 'https://wiki.hyperon.dev/api/mcp',
  BUNDLE_GEMFILE: join(gemRoot, 'Gemfile')
};

// Verify authentication credentials are provided
if (!env.MCP_USERNAME && !env.MCP_API_KEY) {
  console.error('❌ Authentication required!');
  console.error('   Set either:');
  console.error('   - MCP_USERNAME and MCP_PASSWORD');
  console.error('   - MCP_API_KEY and MCP_ROLE');
  console.error('');
  console.error('   Run "hyperon-wiki-mcp --help" for more information');
  process.exit(1);
}

// Launch the Ruby MCP server
const ruby = spawn('ruby', [serverPath, workingDir], {
  env,
  stdio: 'inherit'
});

// Handle exit
ruby.on('exit', (code) => {
  process.exit(code || 0);
});

// Handle errors
ruby.on('error', (err) => {
  console.error('❌ Failed to start MCP server:', err.message);
  console.error('   Ensure Ruby is installed and available in PATH');
  process.exit(1);
});
