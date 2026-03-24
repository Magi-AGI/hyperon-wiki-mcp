#!/usr/bin/env node

/**
 * Node.js wrapper for ChatGPT installer
 */

const { spawn } = require('child_process');
const path = require('path');

const installerPath = path.join(__dirname, 'bin', 'install-chatgpt');

const installer = spawn('ruby', [installerPath], {
  stdio: 'inherit'
});

installer.on('error', (error) => {
  console.error('Error running installer:', error.message);
  console.error('Please ensure Ruby is installed');
  process.exit(1);
});

installer.on('close', (code) => {
  process.exit(code || 0);
});
