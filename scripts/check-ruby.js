#!/usr/bin/env node

import { execSync } from 'child_process';
import { platform } from 'os';

const REQUIRED_RUBY_VERSION = '2.7.0';

function checkCommand(command, name) {
  try {
    execSync(command, { stdio: 'pipe' });
    return true;
  } catch (error) {
    console.error(`❌ ${name} not found. Please install ${name} first.`);
    return false;
  }
}

function getRubyVersion() {
  try {
    const version = execSync('ruby --version', { encoding: 'utf8' });
    const match = version.match(/ruby (\d+\.\d+\.\d+)/);
    return match ? match[1] : null;
  } catch (error) {
    return null;
  }
}

function compareVersions(version1, version2) {
  const v1Parts = version1.split('.').map(Number);
  const v2Parts = version2.split('.').map(Number);
  
  for (let i = 0; i < 3; i++) {
    if (v1Parts[i] > v2Parts[i]) return 1;
    if (v1Parts[i] < v2Parts[i]) return -1;
  }
  return 0;
}

console.log('🔍 Checking Magi Archive MCP Server prerequisites...\n');

// Check Ruby
if (!checkCommand('ruby --version', 'Ruby')) {
  console.error('\n📚 Install Ruby from: https://www.ruby-lang.org/en/downloads/');
  process.exit(1);
}

const rubyVersion = getRubyVersion();
if (rubyVersion && compareVersions(rubyVersion, REQUIRED_RUBY_VERSION) < 0) {
  console.error(`❌ Ruby ${REQUIRED_RUBY_VERSION} or higher required (found ${rubyVersion})`);
  process.exit(1);
}
console.log(`✅ Ruby ${rubyVersion} found`);

// Check Bundler
if (!checkCommand('bundle --version', 'Bundler')) {
  console.error('\n💎 Install Bundler with: gem install bundler');
  process.exit(1);
}
console.log('✅ Bundler found');

// Install Ruby gems
console.log('\n📦 Installing Ruby dependencies...');
try {
  execSync('bundle install', { 
    stdio: 'inherit',
    cwd: process.cwd()
  });
  console.log('✅ Ruby dependencies installed');
} catch (error) {
  console.error('❌ Failed to install Ruby dependencies');
  console.error('   Run "bundle install" manually to see detailed error');
  process.exit(1);
}

console.log('\n✅ Magi Archive MCP Server is ready!');
console.log('\n📝 Configuration required:');
console.log('   Set environment variables:');
console.log('   - MCP_USERNAME and MCP_PASSWORD (recommended)');
console.log('   - Or MCP_API_KEY and MCP_ROLE');
console.log('   - DECKO_API_BASE_URL (defaults to https://wiki.hyperon.dev/api/mcp)');
