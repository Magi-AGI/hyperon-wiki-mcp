# frozen_string_literal: true

require "spec_helper"
require "hyperon/wiki/mcp/rack_app"

# Security regression test for the 2026-06-14 incident:
# the hosted MCP server served no-token requests through a privileged DEFAULT
# identity, so anyone could read restricted cards without logging in. This locks
# in the gate: when auth is required and the OAuth components are initialized, a
# request with no valid token must be rejected (401), never served.
#
# (HW has no "localhost bypass" — its gate already rejects all no-token requests.
# A deployment-level check lives in scripts/smoke_test_auth_gate.sh.)
RSpec.describe Hyperon::Wiki::Mcp::RackApp, "unauthenticated access gate" do
  let(:mock_mcp_server) do
    instance_double("MCP::Server", tools: [], server_context: {}, "server_context=": nil,
                                   handle: { jsonrpc: "2.0", id: 1, result: {} })
  end
  let(:app) { described_class.new }

  before do
    described_class.mcp_server_instance = mock_mcp_server
    # oauth_enabled? == token_issuer && credential_store && client_cards
    described_class.token_issuer = instance_double("TokenIssuer")
    described_class.credential_store = instance_double("CredentialStore")
    described_class.client_cards = instance_double("ClientCards")
    described_class.rate_limiter = nil
    described_class.instance_variable_set(:@session_manager, nil)
  end

  around do |example|
    orig = ENV["OAUTH_REQUIRE_AUTH"]
    ENV["OAUTH_REQUIRE_AUTH"] = "true"
    example.run
    ENV["OAUTH_REQUIRE_AUTH"] = orig
  end

  def mcp_request(token: nil)
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/",
      "HTTP_HOST" => "mcp.hyperon.dev",
      "CONTENT_TYPE" => "application/json",
      "rack.input" => StringIO.new('{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
    }
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    app.call(env)
  end

  it "rejects a no-token MCP request with 401 (no unauthenticated default-identity access)" do
    status, = mcp_request
    expect(status).to eq(401)
  end
end
