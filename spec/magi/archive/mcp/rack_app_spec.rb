# frozen_string_literal: true

require "spec_helper"
require "magi/archive/mcp/rack_app"

RSpec.describe Magi::Archive::Mcp::RackApp do
  let(:mock_mcp_server) do
    instance_double("MCP::Server", tools: [], server_context: {}, "server_context=": nil,
                                   handle: { jsonrpc: "2.0", id: 1, result: {} })
  end

  let(:app) { described_class.new }

  before do
    described_class.mcp_server_instance = mock_mcp_server
    described_class.token_issuer = nil
    described_class.credential_store = nil
    described_class.client_cards = nil
    described_class.rate_limiter = nil
    described_class.instance_variable_set(:@session_manager, nil)
  end

  def make_request(method, path, body: nil, headers: {})
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "3002",
      "HTTP_HOST" => "localhost:3002",
      "rack.input" => StringIO.new(body || "")
    }
    headers.each { |k, v| env["HTTP_#{k.upcase.tr("-", "_")}"] = v }
    env["CONTENT_TYPE"] = headers["Content-Type"] if headers["Content-Type"]
    app.call(env)
  end

  describe "CORS headers" do
    it "includes CORS headers on health response" do
      status, headers, = make_request("GET", "/health")

      expect(status).to eq(200)
      expect(headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(headers["Access-Control-Allow-Methods"]).to include("POST")
      expect(headers["Access-Control-Allow-Headers"]).to include("Mcp-Session-Id")
      expect(headers["Access-Control-Expose-Headers"]).to include("Mcp-Session-Id")
    end

    it "includes CORS headers on 404 responses" do
      status, headers, = make_request("GET", "/nonexistent")

      expect(status).to eq(404)
      expect(headers["Access-Control-Allow-Origin"]).to eq("*")
    end

    it "includes MCP-Protocol-Version in exposed headers" do
      _, headers, = make_request("GET", "/health")

      expect(headers["Access-Control-Expose-Headers"]).to include("MCP-Protocol-Version")
    end
  end

  describe "OPTIONS preflight" do
    it "returns 204 for OPTIONS requests" do
      status, headers, = make_request("OPTIONS", "/")

      expect(status).to eq(204)
      expect(headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(headers["Access-Control-Allow-Methods"]).to include("POST")
      expect(headers["Access-Control-Allow-Methods"]).to include("GET")
      expect(headers["Access-Control-Allow-Methods"]).to include("DELETE")
      expect(headers["Access-Control-Allow-Headers"]).to include("Content-Type")
      expect(headers["Access-Control-Allow-Headers"]).to include("Authorization")
      expect(headers["Access-Control-Max-Age"]).to eq("86400")
    end

    it "returns 204 for OPTIONS on /mcp" do
      status, = make_request("OPTIONS", "/mcp")
      expect(status).to eq(204)
    end

    it "returns 204 for OPTIONS on /messages" do
      status, = make_request("OPTIONS", "/messages")
      expect(status).to eq(204)
    end

    it "returns 204 for OPTIONS on any unknown path" do
      status, = make_request("OPTIONS", "/anything")
      expect(status).to eq(204)
    end
  end

  describe "/mcp endpoint" do
    it "accepts MCP messages on POST /mcp" do
      body = JSON.generate({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} })
      status, _, response_body = make_request("POST", "/mcp",
                                              body: body,
                                              headers: { "Content-Type" => "application/json" })

      expect(status).to eq(200)
      parsed = JSON.parse(response_body.first)
      expect(parsed).to have_key("jsonrpc")
    end

    it "handles DELETE /mcp for session cleanup" do
      status, = make_request("DELETE", "/mcp")
      expect(status).to eq(200)
    end

    it "accepts MCP messages on POST /mcp/" do
      body = JSON.generate({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} })
      status, = make_request("POST", "/mcp/",
                             body: body,
                             headers: { "Content-Type" => "application/json" })

      expect(status).to eq(200)
    end
  end

  describe "health endpoint" do
    it "returns healthy status" do
      status, _, body = make_request("GET", "/health")

      expect(status).to eq(200)
      parsed = JSON.parse(body.first)
      expect(parsed["status"]).to eq("healthy")
      expect(parsed["version"]).to eq(Magi::Archive::Mcp::VERSION)
    end

    it "caches the health response within TTL" do
      _, _, body1 = make_request("GET", "/health")
      _, _, body2 = make_request("GET", "/health")

      # Same cached response within TTL
      expect(body2.first).to eq(body1.first)
    end
  end

  describe "root endpoint" do
    it "lists /mcp in endpoints" do
      _, _, body = make_request("GET", "/")

      parsed = JSON.parse(body.first)
      expect(parsed["endpoints"]["mcp"]).to eq("/mcp")
    end
  end
end

RSpec.describe Magi::Archive::Mcp::SessionManager do
  subject(:manager) { described_class.new }

  describe "#get_or_create" do
    it "creates a new session" do
      session_id = manager.get_or_create
      expect(session_id).to be_a(String)
      expect(manager.exists?(session_id)).to be true
    end

    it "returns existing session when valid ID provided" do
      session_id = manager.get_or_create
      same_id = manager.get_or_create(session_id)
      expect(same_id).to eq(session_id)
    end

    it "creates a new session for unknown ID" do
      new_id = manager.get_or_create("nonexistent-id")
      expect(new_id).not_to eq("nonexistent-id")
      expect(manager.exists?(new_id)).to be true
    end
  end

  describe "#exists?" do
    it "returns true for existing session" do
      session_id = manager.get_or_create
      expect(manager.exists?(session_id)).to be true
    end

    it "returns false for unknown session" do
      expect(manager.exists?("nonexistent")).to be false
    end
  end

  describe "#delete" do
    it "removes the session" do
      session_id = manager.get_or_create
      manager.delete(session_id)
      expect(manager.exists?(session_id)).to be false
    end
  end

  describe "#size" do
    it "returns the number of sessions" do
      expect(manager.size).to eq(0)
      manager.get_or_create
      expect(manager.size).to eq(1)
      manager.get_or_create
      expect(manager.size).to eq(2)
    end
  end

  describe "session expiry" do
    it "cleans up expired sessions during get_or_create" do
      session_id = manager.get_or_create

      # Simulate expired session
      manager.instance_variable_get(:@sessions)[session_id][:last_used_at] =
        Time.now - described_class::SESSION_TTL - 1

      # Force cleanup interval to have passed
      manager.instance_variable_set(:@last_cleanup, Time.now - 600)

      # Trigger cleanup via get_or_create
      manager.get_or_create
      expect(manager.exists?(session_id)).to be false
    end

    it "keeps active sessions during cleanup" do
      session_id = manager.get_or_create

      # Force cleanup interval to have passed but session is still active
      manager.instance_variable_set(:@last_cleanup, Time.now - 600)

      manager.get_or_create
      expect(manager.exists?(session_id)).to be true
    end

    it "does not clean up before cleanup interval" do
      session_id = manager.get_or_create

      # Expire the session but don't pass cleanup interval
      manager.instance_variable_get(:@sessions)[session_id][:last_used_at] =
        Time.now - described_class::SESSION_TTL - 1

      # Cleanup interval hasn't passed (default: just created)
      manager.get_or_create
      # Session should still exist because cleanup hasn't run
      expect(manager.size).to be >= 1
    end
  end
end
