# frozen_string_literal: true

require "spec_helper"
require "hyperon/wiki/mcp/config"

RSpec.describe Hyperon::Wiki::Mcp::Config do
  let(:valid_env) do
    {
      "MCP_API_KEY" => "test-api-key-123",
      "DECKO_API_BASE_URL" => "https://test.example.com/api/mcp",
      "MCP_ROLE" => "user",
      "JWT_ISSUER" => "test-issuer",
      "JWKS_CACHE_TTL" => "7200"
    }
  end

  before do
    # Clear environment before each test
    %w[MCP_API_KEY DECKO_API_BASE_URL MCP_ROLE JWT_ISSUER JWKS_CACHE_TTL
       MCP_USERNAME MCP_PASSWORD].each do |key|
      ENV.delete(key)
    end
  end

  describe "#initialize" do
    context "with valid configuration" do
      before { valid_env.each { |k, v| ENV[k] = v } }

      it "loads configuration from environment" do
        config = described_class.new

        expect(config.api_key).to eq("test-api-key-123")
        expect(config.base_url).to eq("https://test.example.com/api/mcp")
        expect(config.role).to eq("user")
        expect(config.issuer).to eq("test-issuer")
        expect(config.jwks_cache_ttl).to eq(7200)
      end
    end

    context "with missing credentials" do
      it "raises ConfigurationError for missing both auth methods" do
        expect { described_class.new }.to raise_error(
          Hyperon::Wiki::Mcp::Config::ConfigurationError,
          /Must provide either \(MCP_USERNAME \+ MCP_PASSWORD\) or MCP_API_KEY/
        )
      end
    end

    context "with any Decko role" do
      before do
        ENV["MCP_API_KEY"] = "test-key"
        ENV["MCP_ROLE"] = "magi team"
      end

      it "accepts the role without validation" do
        config = described_class.new
        expect(config.role).to eq("magi team")
      end
    end

    context "with default values" do
      before { ENV["MCP_API_KEY"] = "test-key" }

      it "uses defaults for optional settings" do
        config = described_class.new

        expect(config.base_url).to eq("https://wiki.hyperon.dev/api/mcp")
        expect(config.role).to eq("user")
        expect(config.issuer).to eq("hyperon")
        expect(config.jwks_cache_ttl).to eq(3600)
      end
    end

    context "with GM role" do
      before do
        ENV["MCP_API_KEY"] = "test-key"
        ENV["MCP_ROLE"] = "gm"
      end

      it "loads GM role successfully" do
        config = described_class.new

        expect(config.role).to eq("gm")
        expect(config.api_key).to eq("test-key")
      end
    end

    context "with admin role" do
      before do
        ENV["MCP_API_KEY"] = "test-key"
        ENV["MCP_ROLE"] = "admin"
      end

      it "loads admin role successfully" do
        config = described_class.new

        expect(config.role).to eq("admin")
        expect(config.api_key).to eq("test-key")
      end
    end
  end

  describe "#url_for" do
    before do
      ENV["MCP_API_KEY"] = "test-key"
      ENV["DECKO_API_BASE_URL"] = "https://test.example.com/api/mcp"
    end

    let(:config) { described_class.new }

    it "constructs full URL from path" do
      expect(config.url_for("/cards")).to eq("https://test.example.com/api/mcp/cards")
    end

    it "handles path without leading slash" do
      expect(config.url_for("cards")).to eq("https://test.example.com/api/mcp/cards")
    end

    it "handles auth endpoint" do
      expect(config.url_for("/auth")).to eq("https://test.example.com/api/mcp/auth")
    end
  end

  describe "#auth_payload" do
    before { ENV["MCP_API_KEY"] = "test-key" }

    context "for user role" do
      before { ENV["MCP_ROLE"] = "user" }

      let(:config) { described_class.new }

      it "returns payload with api_key and role only" do
        payload = config.auth_payload

        expect(payload).to eq(
          api_key: "test-key",
          role: "user"
        )
      end
    end

    context "for GM role" do
      before { ENV["MCP_ROLE"] = "gm" }

      let(:config) { described_class.new }

      it "returns payload with api_key and role only" do
        payload = config.auth_payload

        expect(payload).to eq(
          api_key: "test-key",
          role: "gm"
        )
      end
    end

    context "for admin role" do
      before { ENV["MCP_ROLE"] = "admin" }

      let(:config) { described_class.new }

      it "returns payload with api_key and role only" do
        payload = config.auth_payload

        expect(payload).to eq(
          api_key: "test-key",
          role: "admin"
        )
      end
    end
  end
end
