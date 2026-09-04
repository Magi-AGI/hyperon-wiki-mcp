#!/usr/bin/env ruby
# frozen_string_literal: true

# Quick test to verify Client namespace resolution works

require "bundler/setup"
require_relative "lib/hyperon/wiki/mcp"
require_relative "lib/hyperon/wiki/mcp/server/tools/create_card"

puts "Testing Client namespace resolution..."
puts ""

# Check if Client class is loaded
if defined?(Hyperon::Wiki::Mcp::Client)
  puts "✓ Hyperon::Wiki::Mcp::Client is defined"
else
  puts "✗ Hyperon::Wiki::Mcp::Client is NOT defined"
  exit 1
end

# Check if the alias works in the tool class
tool_class = Hyperon::Wiki::Mcp::Server::Tools::CreateCard

if tool_class.const_defined?(:Client)
  puts "✓ Client constant is defined in CreateCard class"
  client_const = tool_class.const_get(:Client)
  puts "  Client resolves to: #{client_const}"

  # Check if error classes are accessible
  if client_const.const_defined?(:ValidationError)
    puts "✓ Client::ValidationError is accessible"
  else
    puts "✗ Client::ValidationError is NOT accessible"
    exit 1
  end
else
  puts "✗ Client constant is NOT defined in CreateCard class"
  exit 1
end

puts ""
puts "All namespace tests passed!"
