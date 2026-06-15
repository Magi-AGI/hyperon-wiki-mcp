# frozen_string_literal: true

require "spec_helper"
require "hyperon/wiki/mcp/rack_app"

# Security regression test for the "public-access" token fallback.
#
# The hosted MCP token endpoint used to issue a long-lived (1 year) Bearer token
# named "public-access" whenever OAuth components were not initialized. Because
# the auth gate also keys off oauth_enabled?, a failure to initialize OAuth would
# both (a) hand out a public token and (b) stop gating requests — collapsing into
# an unauthenticated path to the default identity. The endpoint must now FAIL
# CLOSED instead of issuing any token.
RSpec.describe Hyperon::Wiki::Mcp::RackApp, "token endpoint fail-closed behaviour" do
  let(:app) { described_class.new }

  before do
    described_class.rate_limiter = nil
    described_class.instance_variable_set(:@session_manager, nil)
  end

  def token_request(grant_type)
    body = grant_type ? JSON.generate(grant_type: grant_type) : "{}"
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/token",
      "CONTENT_TYPE" => "application/json",
      "rack.input" => StringIO.new(body)
    }
    app.call(env)
  end

  context "when OAuth is NOT initialized (the dangerous state)" do
    before do
      described_class.token_issuer = nil
      described_class.credential_store = nil
      described_class.client_cards = nil
    end

    it "refuses client_credentials with 503 and never issues a public-access token" do
      status, _headers, body = token_request("client_credentials")
      expect(status).to eq(503)
      expect(body.join).not_to include("public-access")
      expect(JSON.parse(body.join)["error"]).to eq("server_error")
    end

    it "refuses an unknown/missing grant_type with 503, not a public token" do
      status, _headers, body = token_request(nil)
      expect(status).to eq(503)
      expect(body.join).not_to include("public-access")
    end
  end

  context "when OAuth IS initialized" do
    before do
      described_class.token_issuer = instance_double("TokenIssuer")
      described_class.credential_store = instance_double("CredentialStore")
      described_class.client_cards = instance_double("ClientCards")
    end

    it "rejects an unknown grant_type with the standard 400 unsupported_grant_type" do
      status, _headers, body = token_request("totally_bogus")
      expect(status).to eq(400)
      expect(JSON.parse(body.join)["error"]).to eq("unsupported_grant_type")
    end
  end
end
