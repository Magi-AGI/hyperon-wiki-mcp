# frozen_string_literal: true

require_relative "mcp/version"
require_relative "mcp/config"
require_relative "mcp/auth"
require_relative "mcp/client"
require_relative "mcp/tools"

# Magi Archive MCP Client
#
# Provides secure, role-aware API access to the Magi Archive Decko application
# using the Model Context Protocol (MCP).
#
# @example Basic usage
#   # Set environment variables:
#   # MCP_API_KEY=your-api-key
#   # MCP_ROLE=user  # or gm, admin
#   # DECKO_API_BASE_URL=https://wiki.hyperon.dev/api/mcp (optional)
#
#   client = Magi::Archive::Mcp::Client.new
#   cards = client.get("/cards", limit: 10)
#   card = client.get("/cards/User")
#
# @example With custom configuration
#   config = Magi::Archive::Mcp::Config.new
#   client = Magi::Archive::Mcp::Client.new(config)
#
# @example Paginated queries
#   client.each_page("/cards", limit: 50) do |page|
#     page.each { |card| puts card["name"] }
#   end
#
# @see Config
# @see Auth
# @see Client
module Magi
  module Archive
    module Mcp
      class Error < StandardError; end
    end
  end
end
