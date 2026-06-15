# frozen_string_literal: true

require "spec_helper"
require "hyperon/wiki/mcp/rack_app"

# Security regression test for the 2026-06-14 incident:
# the hosted MCP server served no-token requests through a privileged DEFAULT
# identity, so anyone could read restricted cards without logging in.
#
# The hardened gate fails CLOSED: a request without a valid per-user token is
# rejected unless it is a trusted same-box caller (localhost origin + shared
# secret). This no longer depends on OAUTH_REQUIRE_AUTH or oauth_enabled?, so
# neither an "off" flag (Case A) nor a degraded OAuth stack (Case B) can reopen
# unauthenticated external access. The localhost bypass (Case C) requires the
# X-MCP-Local shared secret and is disabled entirely when none is configured.
#
# (A deployment-level check lives in scripts/smoke_test_auth_gate.sh.)
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
    orig = ENV.fetch("OAUTH_REQUIRE_AUTH", nil)
    orig_secret = ENV.fetch("MCP_LOCAL_SECRET", nil)
    ENV["OAUTH_REQUIRE_AUTH"] = "true"
    example.run
    ENV["OAUTH_REQUIRE_AUTH"] = orig
    if orig_secret
      ENV["MCP_LOCAL_SECRET"] = orig_secret
    else
      ENV.delete("MCP_LOCAL_SECRET")
    end
  end

  def mcp_request(host: "mcp.hyperon.dev", token: nil, local_secret: nil)
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/",
      "HTTP_HOST" => host,
      "CONTENT_TYPE" => "application/json",
      "rack.input" => StringIO.new('{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
    }
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    env["HTTP_X_MCP_LOCAL"] = local_secret if local_secret
    app.call(env)
  end

  it "rejects a no-token MCP request with 401 (no unauthenticated default-identity access)" do
    status, = mcp_request
    expect(status).to eq(401)
  end

  it "rejects external no-token requests even when OAUTH_REQUIRE_AUTH is off (Case A)" do
    ENV["OAUTH_REQUIRE_AUTH"] = "false"
    status, = mcp_request
    expect(status).to eq(401)
  end

  it "rejects external no-token requests even when OAuth failed to initialize (Case B)" do
    described_class.token_issuer = nil
    described_class.credential_store = nil
    described_class.client_cards = nil
    status, = mcp_request
    expect(status).to eq(401)
  end

  context "localhost bypass (Case C)" do
    it "permits a same-box caller that presents the shared secret" do
      ENV["MCP_LOCAL_SECRET"] = "s3cr3t"
      status, = mcp_request(host: "127.0.0.1:3002", local_secret: "s3cr3t")
      expect(status).not_to eq(401)
    end

    it "rejects a localhost caller missing the secret (nginx-misconfig defense)" do
      ENV["MCP_LOCAL_SECRET"] = "s3cr3t"
      status, = mcp_request(host: "127.0.0.1:3002")
      expect(status).to eq(401)
    end

    it "disables the bypass entirely when no secret is configured (fail closed)" do
      ENV.delete("MCP_LOCAL_SECRET")
      status, = mcp_request(host: "127.0.0.1:3002", local_secret: "anything")
      expect(status).to eq(401)
    end
  end
end
