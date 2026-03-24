#!/usr/bin/env node

/**
 * Node.js wrapper for Magi Archive MCP Server
 *
 * This script allows Node.js/npm users to run the Ruby MCP server
 * without needing to know Ruby commands.
 */

const { spawn } = require('child_process');
const path = require('path');

// Path to the Ruby MCP server
const serverPath = path.join(__dirname, 'bin', 'mcp-server');

// Get working directory from args or use current directory
const workingDir = process.argv[2] || process.cwd();

// Check if Ruby is available
function checkRuby() {
  return new Promise((resolve, reject) => {
    const ruby = spawn('ruby', ['--version']);

    ruby.on('error', () => {
      reject(new Error('Ruby not found. Please install Ruby 3.2+ first.'));
    });

    ruby.on('close', (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error('Ruby check failed'));
      }
    });
  });
}

// Run the MCP server
async function runServer() {
  try {
    await checkRuby();

    // Spawn the Ruby MCP server
    const server = spawn('ruby', [serverPath, workingDir], {
      stdio: ['inherit', 'inherit', 'inherit']
    });

    server.on('error', (error) => {
      console.error('Error starting MCP server:', error.message);
      process.exit(1);
    });

    server.on('close', (code) => {
      process.exit(code || 0);
    });

    // Handle termination signals
    process.on('SIGINT', () => {
      server.kill('SIGINT');
    });

    process.on('SIGTERM', () => {
      server.kill('SIGTERM');
    });

  } catch (error) {
    console.error('Fatal error:', error.message);
    console.error('\nPlease ensure:');
    console.error('  1. Ruby 3.2+ is installed');
    console.error('  2. Run "npm install" to install dependencies');
    console.error('  3. Authentication is configured (.env or environment variables)');
    process.exit(1);
  }
}

runServer();
