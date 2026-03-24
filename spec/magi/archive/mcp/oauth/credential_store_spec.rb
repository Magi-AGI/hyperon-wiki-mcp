# frozen_string_literal: true

require "spec_helper"
require "magi/archive/mcp/oauth/credential_store"

RSpec.describe Magi::Archive::Mcp::OAuth::CredentialStore do
  let(:store) { described_class.new }
  let(:session_id) { "sess-#{SecureRandom.uuid}" }
  let(:tools_double) { double("Tools") }

  describe "#store_session and #get_session" do
    it "stores and retrieves a session" do
      store.store_session(session_id, username: "alice", role: "user", tools: tools_double)
      session = store.get_session(session_id)

      expect(session[:username]).to eq("alice")
      expect(session[:role]).to eq("user")
      expect(session[:tools]).to eq(tools_double)
    end

    it "returns nil for unknown session" do
      expect(store.get_session("nonexistent")).to be_nil
    end

    it "updates last_used_at on access" do
      store.store_session(session_id, username: "alice", role: "user", tools: tools_double)
      first_access = store.get_session(session_id)[:last_used_at]

      sleep 0.01
      second_access = store.get_session(session_id)[:last_used_at]

      expect(second_access).to be >= first_access
    end
  end

  describe "#store_refresh_token and #consume_refresh_token" do
    let(:refresh_token) { SecureRandom.uuid }

    it "stores and consumes a refresh token" do
      store.store_refresh_token(
        refresh_token,
        session_id: session_id,
        username: "alice",
        password: "secret",
        role: "gm"
      )

      data = store.consume_refresh_token(refresh_token)
      expect(data[:username]).to eq("alice")
      expect(data[:password]).to eq("secret")
      expect(data[:role]).to eq("gm")
      expect(data[:session_id]).to eq(session_id)
    end

    it "consumes token only once" do
      store.store_refresh_token(
        refresh_token,
        session_id: session_id,
        username: "alice",
        password: "secret",
        role: "user"
      )

      expect(store.consume_refresh_token(refresh_token)).not_to be_nil
      expect(store.consume_refresh_token(refresh_token)).to be_nil
    end

    it "returns nil for unknown refresh token" do
      expect(store.consume_refresh_token("nonexistent")).to be_nil
    end

    it "returns nil for expired refresh token" do
      store.store_refresh_token(
        refresh_token,
        session_id: session_id,
        username: "alice",
        password: "secret",
        role: "user"
      )

      # Simulate expiry by manipulating created_at
      store.instance_variable_get(:@refresh_tokens)[refresh_token][:created_at] =
        Time.now - described_class::REFRESH_TOKEN_TTL - 1

      expect(store.consume_refresh_token(refresh_token)).to be_nil
    end
  end

  describe "#revoke_session" do
    it "removes session and associated refresh tokens" do
      refresh_token = SecureRandom.uuid
      store.store_session(session_id, username: "alice", role: "user", tools: tools_double)
      store.store_refresh_token(
        refresh_token,
        session_id: session_id,
        username: "alice",
        password: "secret",
        role: "user"
      )

      store.revoke_session(session_id)

      expect(store.get_session(session_id)).to be_nil
      expect(store.consume_refresh_token(refresh_token)).to be_nil
    end
  end

  describe "#revoke_token" do
    it "revokes by session_id" do
      store.store_session(session_id, username: "alice", role: "user", tools: tools_double)
      store.revoke_token(session_id)
      expect(store.get_session(session_id)).to be_nil
    end

    it "revokes by refresh token" do
      refresh_token = SecureRandom.uuid
      store.store_session(session_id, username: "alice", role: "user", tools: tools_double)
      store.store_refresh_token(
        refresh_token,
        session_id: session_id,
        username: "alice",
        password: "secret",
        role: "user"
      )

      store.revoke_token(refresh_token)
      expect(store.get_session(session_id)).to be_nil
      expect(store.consume_refresh_token(refresh_token)).to be_nil
    end
  end

  describe "#store_auth_code and #consume_auth_code" do
    let(:code) { SecureRandom.urlsafe_base64(32) }

    it "stores and consumes an auth code" do
      store.store_auth_code(
        code,
        client_id: "client-123",
        redirect_uri: "https://example.com/callback",
        code_challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        code_challenge_method: "S256",
        username: "alice@example.com",
        password: "secret",
        role: "user"
      )

      data = store.consume_auth_code(code)
      expect(data[:client_id]).to eq("client-123")
      expect(data[:redirect_uri]).to eq("https://example.com/callback")
      expect(data[:code_challenge]).to eq("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
      expect(data[:username]).to eq("alice@example.com")
      expect(data[:password]).to eq("secret")
      expect(data[:role]).to eq("user")
    end

    it "consumes auth code only once (single-use)" do
      store.store_auth_code(code, client_id: "c1", username: "a", password: "p", role: "user")

      expect(store.consume_auth_code(code)).not_to be_nil
      expect(store.consume_auth_code(code)).to be_nil
    end

    it "returns nil for unknown auth code" do
      expect(store.consume_auth_code("nonexistent")).to be_nil
    end

    it "returns nil for expired auth code" do
      store.store_auth_code(code, client_id: "c1", username: "a", password: "p", role: "user")

      # Simulate expiry
      store.instance_variable_get(:@auth_codes)[code][:created_at] =
        Time.now - described_class::AUTH_CODE_TTL - 1

      expect(store.consume_auth_code(code)).to be_nil
    end
  end

  describe "#store_registered_client and #get_registered_client" do
    let(:client_id) { SecureRandom.uuid }

    it "stores and retrieves a registered client" do
      store.store_registered_client(
        client_id,
        client_name: "Test App",
        redirect_uris: ["https://example.com/callback"],
        grant_types: ["authorization_code"]
      )

      data = store.get_registered_client(client_id)
      expect(data[:client_name]).to eq("Test App")
      expect(data[:redirect_uris]).to eq(["https://example.com/callback"])
      expect(data[:grant_types]).to eq(["authorization_code"])
    end

    it "returns nil for unknown client" do
      expect(store.get_registered_client("nonexistent")).to be_nil
    end

    it "returns nil for expired registered client" do
      store.store_registered_client(client_id, client_name: "Old App")

      store.instance_variable_get(:@registered_clients)[client_id][:created_at] =
        Time.now - described_class::REGISTERED_CLIENT_TTL - 1

      expect(store.get_registered_client(client_id)).to be_nil
    end
  end

  describe "#registered_client_count and #auth_code_count" do
    it "returns correct counts" do
      expect(store.registered_client_count).to eq(0)
      expect(store.auth_code_count).to eq(0)

      store.store_registered_client("c1", client_name: "App1")
      store.store_registered_client("c2", client_name: "App2")
      store.store_auth_code("code1", client_id: "c1", username: "a", password: "p", role: "user")

      expect(store.registered_client_count).to eq(2)
      expect(store.auth_code_count).to eq(1)
    end
  end

  describe "#cleanup!" do
    it "removes expired sessions" do
      store.store_session(session_id, username: "alice", role: "user", tools: tools_double)

      # Simulate expiry
      store.instance_variable_get(:@sessions)[session_id][:last_used_at] =
        Time.now - described_class::SESSION_TTL - 1

      purged = store.cleanup!
      expect(purged).to eq(1)
      expect(store.get_session(session_id)).to be_nil
    end

    it "keeps active sessions" do
      store.store_session(session_id, username: "alice", role: "user", tools: tools_double)
      purged = store.cleanup!
      expect(purged).to eq(0)
      expect(store.get_session(session_id)).not_to be_nil
    end

    it "removes expired refresh tokens" do
      refresh_token = SecureRandom.uuid
      store.store_refresh_token(
        refresh_token,
        session_id: session_id,
        username: "alice",
        password: "secret",
        role: "user"
      )

      store.instance_variable_get(:@refresh_tokens)[refresh_token][:created_at] =
        Time.now - described_class::REFRESH_TOKEN_TTL - 1

      store.cleanup!
      expect(store.refresh_token_count).to eq(0)
    end

    it "removes expired auth codes" do
      store.store_auth_code("code1", client_id: "c1", username: "a", password: "p", role: "user")

      store.instance_variable_get(:@auth_codes)["code1"][:created_at] =
        Time.now - described_class::AUTH_CODE_TTL - 1

      store.cleanup!
      expect(store.auth_code_count).to eq(0)
    end

    it "removes expired registered clients" do
      store.store_registered_client("c1", client_name: "Old App")

      store.instance_variable_get(:@registered_clients)["c1"][:created_at] =
        Time.now - described_class::REGISTERED_CLIENT_TTL - 1

      store.cleanup!
      expect(store.registered_client_count).to eq(0)
    end
  end

  describe "#session_count and #refresh_token_count" do
    it "returns correct counts" do
      expect(store.session_count).to eq(0)
      expect(store.refresh_token_count).to eq(0)

      store.store_session("s1", username: "alice", role: "user", tools: tools_double)
      store.store_session("s2", username: "bob", role: "gm", tools: tools_double)
      store.store_refresh_token("r1", session_id: "s1", username: "alice", password: "p", role: "user")

      expect(store.session_count).to eq(2)
      expect(store.refresh_token_count).to eq(1)
    end
  end

  describe "thread safety" do
    it "handles concurrent access without errors" do
      threads = 10.times.map do |i|
        Thread.new do
          sid = "sess-#{i}"
          store.store_session(sid, username: "user#{i}", role: "user", tools: tools_double)
          store.get_session(sid)
          store.store_refresh_token("rt-#{i}", session_id: sid, username: "u#{i}", password: "p", role: "user")
          store.consume_refresh_token("rt-#{i}")
        end
      end

      expect { threads.each(&:join) }.not_to raise_error
    end
  end
end
