# frozen_string_literal: true

require "magi/archive/mcp"
require "webmock/rspec"

# Configure WebMock
# Allow real connections for integration tests, disable for unit tests
if ENV["INTEGRATION_TEST"]
  WebMock.allow_net_connect!
else
  WebMock.disable_net_connect!(allow_localhost: false)
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Reset environment variables before each test
  # Skip for integration tests which need real credentials
  config.before do |example|
    next if example.metadata[:integration]

    %w[MCP_API_KEY DECKO_API_BASE_URL MCP_ROLE JWT_ISSUER JWKS_CACHE_TTL
       MCP_USERNAME MCP_PASSWORD].each do |key|
      ENV.delete(key)
    end
  end

  # Reset WebMock after each test
  config.after do
    WebMock.reset!
  end
end
