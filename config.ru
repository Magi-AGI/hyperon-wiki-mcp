# config.ru - Rack configuration for MCP HTTP server
# This gives us complete control over the middleware stack

require 'bundler/setup'
require 'mcp'
require 'sinatra/base'
require 'json'
require_relative 'lib/magi/archive/mcp'

# Load all tool classes (same as bin/mcp-server-http)
Dir[File.join(__dir__, 'lib/magi/archive/mcp/server/tools/**/*.rb')].sort.each { |f| require f }

# Initialize tools
magi_tools = Magi::Archive::Mcp::Tools.new

# Configuration
PORT = ENV.fetch("MCP_SERVER_PORT", "3002").to_i
HOST = ENV.fetch("MCP_SERVER_HOST", "127.0.0.1")
working_directory = ENV["MAGI_WORKING_DIR"] || "/home/ubuntu"

server_context = {
  magi_tools: magi_tools,
  working_directory: working_directory
}

# Create MCP server
mcp_server = ::MCP::Server.new(
  name: "magi-archive",
  version: Magi::Archive::Mcp::VERSION,
  tools: [
    # Core card operations
    Magi::Archive::Mcp::Server::Tools::GetCard,
    Magi::Archive::Mcp::Server::Tools::SearchCards,
    Magi::Archive::Mcp::Server::Tools::CreateCard,
    Magi::Archive::Mcp::Server::Tools::UpdateCard,
    Magi::Archive::Mcp::Server::Tools::DeleteCard,
    Magi::Archive::Mcp::Server::Tools::RenameCard,
    Magi::Archive::Mcp::Server::Tools::ListChildren,

    # Tag operations
    Magi::Archive::Mcp::Server::Tools::GetTags,
    Magi::Archive::Mcp::Server::Tools::SearchByTags,
    Magi::Archive::Mcp::Server::Tools::SuggestTags,

    # Relationships
    Magi::Archive::Mcp::Server::Tools::GetRelationships,

    # Types and rendering
    Magi::Archive::Mcp::Server::Tools::GetTypes,
    Magi::Archive::Mcp::Server::Tools::RenderContent,

    # Admin operations
    Magi::Archive::Mcp::Server::Tools::AdminBackup,

    # Card history and restore
    Magi::Archive::Mcp::Server::Tools::GetCardHistory,
    Magi::Archive::Mcp::Server::Tools::GetRevision,
    Magi::Archive::Mcp::Server::Tools::RestoreCard,
    Magi::Archive::Mcp::Server::Tools::ListTrash,

    # Weekly summaries
    Magi::Archive::Mcp::Server::Tools::CreateWeeklySummary,

    # Health check
    Magi::Archive::Mcp::Server::Tools::HealthCheck,

    # Phase 3: Advanced operations
    Magi::Archive::Mcp::Server::Tools::BatchCards,
    Magi::Archive::Mcp::Server::Tools::RunQuery,
    Magi::Archive::Mcp::Server::Tools::SpoilerScan,

    # Auto-linking
    Magi::Archive::Mcp::Server::Tools::AutoLink
  ],
  server_context: server_context
)

# Simple Sinatra app with NO middleware
class MagiArchiveMcpApp < Sinatra::Base
  # CRITICAL: Disable ALL automatic middleware
  set :protection, false
  set :logging, false
  set :static, false
  set :method_override, false

  class << self
    attr_accessor :mcp_server_instance
  end

  get '/health' do
    content_type :json
    {
      status: "healthy",
      version: Magi::Archive::Mcp::VERSION,
      timestamp: Time.now.iso8601
    }.to_json
  end

  get '/debug-headers' do
    content_type :json
    {
      http_host: request.env['HTTP_HOST'],
      server_name: request.env['SERVER_NAME'],
      server_port: request.env['SERVER_PORT'],
      http_x_forwarded_host: request.env['HTTP_X_FORWARDED_HOST'],
      all_http_headers: request.env.select { |k,v| k.start_with?('HTTP_') }
    }.to_json
  end

  get '/sse' do
    content_type 'text/event-stream'
    stream(:keep_open) do |out|
      out << "event: endpoint\n"
      out << "data: /message\n\n"

      Thread.new do
        loop do
          sleep 30
          out << ": keepalive\n\n" rescue break
        end
      end
    end
  end

  post '/message' do
    content_type :json
    request_data = JSON.parse(request.body.read)
    response = self.class.mcp_server_instance.handle_request(request_data)
    response.to_json
  rescue JSON::ParserError => e
    status 400
    { error: "Invalid JSON", message: e.message }.to_json
  rescue StandardError => e
    status 500
    { error: "Server error", message: e.message }.to_json
  end

  get '/' do
    content_type :json
    {
      name: "magi-archive-mcp",
      version: Magi::Archive::Mcp::VERSION,
      protocol: "mcp",
      transport: "http/sse",
      endpoints: {
        health: "/health",
        sse: "/sse",
        message: "/message"
      },
      tools_count: self.class.mcp_server_instance.tools.length
    }.to_json
  end
end

MagiArchiveMcpApp.mcp_server_instance = mcp_server

# Debug: Print middleware stack
puts "=" * 80
puts "MIDDLEWARE STACK:"
MagiArchiveMcpApp.middleware.each_with_index do |middleware, i|
  puts "  #{i}. #{middleware.first} #{middleware[1..-1].inspect}"
end
puts "=" * 80

# Run the app with ZERO middleware except what Sinatra::Base requires
run MagiArchiveMcpApp
