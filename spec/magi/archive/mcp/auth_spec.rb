# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "magi/archive/mcp/config"
require "magi/archive/mcp/auth"

RSpec.describe Magi::Archive::Mcp::Auth do
  let(:config) do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["DECKO_API_BASE_URL"] = "https://test.example.com/api/mcp"
    ENV["MCP_ROLE"] = "user"
    Magi::Archive::Mcp::Config.new
  end

  let(:auth) { described_class.new(config) }

  let(:jwks_response) do
    {
      "keys" => [
        {
          "kty" => "RSA",
          "kid" => "test-key-001",
          "use" => "sig",
          "alg" => "RS256",
          "n" => "xGOr-H7A-PWgqZ4kVEWkwJ6RNfqPdJCYBqvr",
          "e" => "AQAB"
        }
      ]
    }
  end

  let(:auth_response) do
    {
      "token" => "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2V5LTAwMSJ9.eyJzdWIiOiJ0ZXN0IiwiaXNzIjoibWFnaS1hcmNoaXZlIiwicm9sZSI6InVzZXIiLCJpYXQiOjE2MDAwMDAwMDAsImV4cCI6MTYwMDAwMzYwMH0.test-signature",
      "role" => "user",
      "expires_in" => 3600
    }
  end

  before do
    WebMock.disable_net_connect!(allow_localhost: false)
  end

  after do
    WebMock.reset!
  end

  describe "#initialize" do
    it "initializes with config" do
      expect(auth.config).to eq(config)
    end

    it "initializes with nil token and cache" do
      expect(auth.instance_variable_get(:@token)).to be_nil
      expect(auth.instance_variable_get(:@jwks_cache)).to be_nil
    end
  end

  describe "#fetch_jwks" do
    let(:jwks_url) { "https://test.example.com/api/mcp/.well-known/jwks.json" }

    context "when JWKS fetch succeeds" do
      before do
        stub_request(:get, jwks_url)
          .to_return(
            status: 200,
            body: jwks_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "fetches and caches JWKS" do
        keys = auth.fetch_jwks

        expect(keys).to eq(jwks_response["keys"])
        expect(auth.instance_variable_get(:@jwks_cache)).to eq(jwks_response["keys"])
        expect(auth.instance_variable_get(:@jwks_cached_at)).to be_within(1).of(Time.now)
      end

      it "uses cached JWKS on second call" do
        auth.fetch_jwks
        auth.fetch_jwks

        expect(WebMock).to have_requested(:get, jwks_url).once
      end

      it "refreshes cache when forced" do
        auth.fetch_jwks
        auth.fetch_jwks(force: true)

        expect(WebMock).to have_requested(:get, jwks_url).twice
      end
    end

    context "when JWKS fetch fails" do
      before do
        stub_request(:get, jwks_url)
          .to_return(status: 500, body: "Internal Server Error")
      end

      it "raises JWKSError" do
        expect { auth.fetch_jwks }.to raise_error(
          Magi::Archive::Mcp::Auth::JWKSError,
          /JWKS fetch failed: HTTP 500/
        )
      end
    end

    context "when JWKS response is invalid JSON" do
      before do
        stub_request(:get, jwks_url)
          .to_return(status: 200, body: "invalid json")
      end

      it "raises JWKSError" do
        expect { auth.fetch_jwks }.to raise_error(
          Magi::Archive::Mcp::Auth::JWKSError,
          /JWKS parse failed/
        )
      end
    end
  end

  describe "#token" do
    let(:auth_url) { "https://test.example.com/api/mcp/auth" }

    before do
      stub_request(:post, auth_url)
        .with(
          body: { api_key: "test-api-key", role: "user" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
        .to_return(
          status: 201,
          body: auth_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "fetches and caches token" do
      token = auth.token

      expect(token).to eq(auth_response["token"])
      expect(auth.instance_variable_get(:@token)).to eq(auth_response["token"])
      expect(WebMock).to have_requested(:post, auth_url).once
    end

    it "returns cached token on second call" do
      auth.token
      auth.token

      expect(WebMock).to have_requested(:post, auth_url).once
    end

    it "sets token expiry time" do
      auth.token

      expires_at = auth.instance_variable_get(:@token_expires_at)
      expect(expires_at).to be_within(2).of(Time.now + 3600)
    end
  end

  describe "#token_valid?" do
    it "returns false when no token exists" do
      expect(auth.token_valid?).to be false
    end

    it "returns false when token is expired" do
      auth.instance_variable_set(:@token, "test-token")
      auth.instance_variable_set(:@token_expires_at, Time.now - 100)

      expect(auth.token_valid?).to be false
    end

    it "returns false when token is within refresh buffer" do
      auth.instance_variable_set(:@token, "test-token")
      auth.instance_variable_set(:@token_expires_at, Time.now + 200) # Within 300s buffer

      expect(auth.token_valid?).to be false
    end

    it "returns true when token is valid and not within refresh buffer" do
      auth.instance_variable_set(:@token, "test-token")
      auth.instance_variable_set(:@token_expires_at, Time.now + 400) # Outside 300s buffer

      expect(auth.token_valid?).to be true
    end
  end

  describe "#refresh_token!" do
    let(:auth_url) { "https://test.example.com/api/mcp/auth" }

    before do
      stub_request(:post, auth_url)
        .to_return(
          status: 201,
          body: auth_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      # Set up existing token
      auth.instance_variable_set(:@token, "old-token")
      auth.instance_variable_set(:@token_expires_at, Time.now + 1000)
    end

    it "clears existing token and fetches new one" do
      new_token = auth.refresh_token!

      expect(new_token).to eq(auth_response["token"])
      expect(new_token).not_to eq("old-token")
    end
  end

  describe "#clear_cache!" do
    before do
      auth.instance_variable_set(:@token, "test-token")
      auth.instance_variable_set(:@token_expires_at, Time.now + 1000)
      auth.instance_variable_set(:@jwks_cache, jwks_response["keys"])
      auth.instance_variable_set(:@jwks_cached_at, Time.now)
    end

    it "clears all cached data" do
      auth.clear_cache!

      expect(auth.instance_variable_get(:@token)).to be_nil
      expect(auth.instance_variable_get(:@token_expires_at)).to be_nil
      expect(auth.instance_variable_get(:@jwks_cache)).to be_nil
      expect(auth.instance_variable_get(:@jwks_cached_at)).to be_nil
    end
  end

  describe "error handling" do
    let(:auth_url) { "https://test.example.com/api/mcp/auth" }

    context "when auth endpoint returns 401" do
      before do
        stub_request(:post, auth_url)
          .to_return(
            status: 401,
            body: { error: "invalid_credentials", message: "Invalid API key" }.to_json
          )
      end

      it "raises AuthenticationError with error code" do
        expect { auth.token }.to raise_error(
          Magi::Archive::Mcp::Auth::AuthenticationError,
          /Token fetch failed.*invalid_credentials/
        )
      end
    end

    context "when auth endpoint returns invalid JSON" do
      before do
        stub_request(:post, auth_url)
          .to_return(status: 201, body: "invalid json")
      end

      it "raises AuthenticationError" do
        expect { auth.token }.to raise_error(
          Magi::Archive::Mcp::Auth::AuthenticationError,
          /Token response parse failed/
        )
      end
    end
  end
end
