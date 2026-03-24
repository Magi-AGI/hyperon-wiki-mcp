# frozen_string_literal: true

# Integration test helpers for magi-archive-mcp

module IntegrationHelpers
  # Set up environment for integration tests
  def setup_integration_environment
    # Load production environment if it exists
    prod_env_file = File.join(__dir__, "../../.env.production")
    if File.exist?(prod_env_file)
      require "dotenv"
      Dotenv.load(prod_env_file)
    end

    ENV["INTEGRATION_TEST"] = "true"

    # Ensure DECKO_API_BASE_URL is set
    unless ENV["DECKO_API_BASE_URL"]
      raise "Missing DECKO_API_BASE_URL in .env.production"
    end

    # Support both authentication methods:
    # 1. API Key (MCP_API_KEY + MCP_ROLE)
    # 2. Username/Password (MCP_USERNAME + MCP_PASSWORD)
    has_api_key = ENV["MCP_API_KEY"] && ENV["MCP_ROLE"]
    has_username_password = ENV["MCP_USERNAME"] && ENV["MCP_PASSWORD"]

    unless has_api_key || has_username_password
      raise "Missing authentication credentials. Set either (MCP_API_KEY + MCP_ROLE) or (MCP_USERNAME + MCP_PASSWORD) in .env.production"
    end
  end

  # Clean up integration test environment
  def teardown_integration_environment
    # Don't delete INTEGRATION_TEST as it's a flag for all tests
    # Only clean up credentials and server config
    ENV.delete("DECKO_API_BASE_URL")
    ENV.delete("MCP_API_KEY")
    ENV.delete("MCP_ROLE")
    ENV.delete("MCP_USERNAME")
    ENV.delete("MCP_PASSWORD")
  end

  # Get a configured client for integration tests
  def integration_client(role: "admin")
    # If using username/password, role is determined by the account
    # If using API key, set the role explicitly
    if ENV["MCP_API_KEY"]
      ENV["MCP_ROLE"] = role
    end

    # Create and return client (will use either MCP_API_KEY or MCP_USERNAME/MCP_PASSWORD)
    Magi::Archive::Mcp::Client.new
  end

  # Wait for server to be ready
  def wait_for_server(timeout: 30)
    # In production environment, assume the server is ready
    # The integration tests will fail quickly if the API is not responding
    # This avoids the issue of checking for a /health endpoint that doesn't exist
    return true if ENV["DECKO_API_BASE_URL"]&.include?("wiki.hyperon.dev")

    # For other environments, try to verify server is up
    require "http"

    url = ENV["DECKO_API_BASE_URL"] || "https://wiki.hyperon.dev/api/mcp"
    start_time = Time.now

    loop do
      begin
        # Try to create a client and make a simple API call
        client = Magi::Archive::Mcp::Client.new
        client.get_card("Home")
        return true
      rescue StandardError => e
        # Server not ready yet or other error
        puts "Waiting for server... (#{e.class}: #{e.message})"
      end

      if Time.now - start_time > timeout
        raise "Server at #{url} did not become ready within #{timeout} seconds"
      end

      sleep 1
    end
  end
end

RSpec.configure do |config|
  config.include IntegrationHelpers, :integration

  # Use around hook to completely disable WebMock for integration tests
  config.around(:each, :integration) do |example|
    # Skip if integration tests disabled
    if ENV["INTEGRATION_TEST"]
      setup_integration_environment

      # Save current WebMock state and disable it completely
      WebMock.allow_net_connect!

      wait_for_server

      # Run the actual test
      example.run

      teardown_integration_environment

      # Restore WebMock restrictions
      WebMock.disable_net_connect!(allow_localhost: false)
    else
      skip "Integration tests disabled (set INTEGRATION_TEST=true to enable)"
    end
  end
end
