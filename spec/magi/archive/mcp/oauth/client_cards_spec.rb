# frozen_string_literal: true

require "spec_helper"
require "magi/archive/mcp/oauth/client_cards"
require "magi/archive/mcp/oauth/token_issuer"

RSpec.describe Magi::Archive::Mcp::OAuth::ClientCards do
  let(:token_issuer) { Magi::Archive::Mcp::OAuth::TokenIssuer.new(issuer: "test") }
  let(:encryption_key) { token_issuer.encryption_key }
  let(:tools_double) { double("Tools") }
  let(:client_cards) { described_class.new(tools: tools_double, encryption_key: encryption_key) }

  let(:client_id) { SecureRandom.uuid }
  let(:client_secret) { SecureRandom.hex(32) }
  let(:username) { "alice@example.com" }
  let(:password) { "decko-password-123" }
  let(:role) { "user" }

  describe "#create_client" do
    it "creates a card with hashed secret and encrypted password" do
      expect(tools_double).to receive(:create_card) do |name, content:, type:|
        expect(name).to eq("MCP OAuth Clients+#{client_id}")
        expect(type).to eq("PlainText")

        data = JSON.parse(content)
        expect(data["username"]).to eq(username)
        expect(data["role"]).to eq(role)
        expect(data["client_name"]).to eq("Claude.ai")
        expect(data["secret_hash"]).to start_with("$2a$")
        expect(data["encrypted_password"]).not_to be_empty
        expect(data["encryption_iv"]).not_to be_empty
        expect(data["created_at"]).not_to be_nil

        # Verify the hashed secret matches
        expect(BCrypt::Password.new(data["secret_hash"])).to eq(client_secret)

        { "name" => name }
      end

      client_cards.create_client(
        client_id: client_id,
        client_secret: client_secret,
        username: username,
        password: password,
        role: role,
        client_name: "Claude.ai"
      )
    end
  end

  describe "#verify_client" do
    let(:stored_card_content) do
      # Create a card content like create_client would
      secret_hash = BCrypt::Password.create(client_secret)

      # Encrypt password using same logic
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.encrypt
      cipher.key = encryption_key
      iv = cipher.random_iv
      ciphertext = cipher.update(password) + cipher.final
      tag = cipher.auth_tag

      JSON.generate({
                      username: username,
                      secret_hash: secret_hash.to_s,
                      encrypted_password: Base64.strict_encode64(ciphertext + tag),
                      encryption_iv: Base64.strict_encode64(iv),
                      role: role,
                      created_at: Time.now.utc.iso8601,
                      client_name: "Test Client"
                    })
    end

    before do
      allow(tools_double).to receive(:get_card)
        .with("MCP OAuth Clients+#{client_id}")
        .and_return({ "card" => { "content" => stored_card_content } })
    end

    it "returns credentials for valid client_secret" do
      result = client_cards.verify_client(client_id: client_id, client_secret: client_secret)

      expect(result[:username]).to eq(username)
      expect(result[:password]).to eq(password)
      expect(result[:role]).to eq(role)
      expect(result[:client_name]).to eq("Test Client")
    end

    it "raises ClientError for wrong client_secret" do
      expect do
        client_cards.verify_client(client_id: client_id, client_secret: "wrong-secret")
      end.to raise_error(described_class::ClientError, /Invalid client credentials/)
    end

    it "raises ClientError for non-existent client" do
      allow(tools_double).to receive(:get_card)
        .and_raise(StandardError.new("404 not found"))

      expect do
        client_cards.verify_client(client_id: "nonexistent", client_secret: "any")
      end.to raise_error(described_class::ClientError, /Client not found/)
    end
  end

  describe "#revoke_client" do
    it "deletes the client card" do
      expect(tools_double).to receive(:delete_card)
        .with("MCP OAuth Clients+#{client_id}")
        .and_return({ "success" => true })

      client_cards.revoke_client(client_id: client_id)
    end
  end

  describe "#list_clients" do
    let(:card1_content) do
      JSON.generate({
                      username: "alice@example.com",
                      secret_hash: "$2a$12$dummy",
                      role: "user",
                      client_name: "Claude.ai",
                      created_at: "2026-02-11T00:00:00Z"
                    })
    end

    let(:card2_content) do
      JSON.generate({
                      username: "bob@example.com",
                      secret_hash: "$2a$12$dummy",
                      role: "gm",
                      client_name: "ChatGPT",
                      created_at: "2026-02-11T01:00:00Z"
                    })
    end

    before do
      allow(tools_double).to receive(:search_cards).and_return({
                                                                 "cards" => [
                                                                   { "name" => "MCP OAuth Clients+uuid-1", "content" => card1_content },
                                                                   { "name" => "MCP OAuth Clients+uuid-2", "content" => card2_content }
                                                                 ]
                                                               })
    end

    it "returns all clients when no username filter" do
      clients = client_cards.list_clients
      expect(clients.length).to eq(2)
      expect(clients[0][:client_id]).to eq("uuid-1")
      expect(clients[1][:client_id]).to eq("uuid-2")
    end

    it "filters by username" do
      clients = client_cards.list_clients(username: "alice@example.com")
      expect(clients.length).to eq(1)
      expect(clients[0][:username]).to eq("alice@example.com")
    end
  end

  describe "encryption round-trip" do
    it "encrypts and decrypts passwords correctly" do
      # Use create_client to store, then verify_client to decrypt
      stored_content = nil

      allow(tools_double).to receive(:create_card) do |_name, content:, **_|
        stored_content = content
        { "name" => "test" }
      end

      client_cards.create_client(
        client_id: client_id,
        client_secret: client_secret,
        username: username,
        password: password,
        role: role
      )

      # Now verify using the stored content
      allow(tools_double).to receive(:get_card)
        .and_return({ "card" => { "content" => stored_content } })

      result = client_cards.verify_client(client_id: client_id, client_secret: client_secret)
      expect(result[:password]).to eq(password)
    end

    it "handles passwords with special characters" do
      special_password = "p@$$w0rd!with\"quotes'and<html>&entities"
      stored_content = nil

      allow(tools_double).to receive(:create_card) do |_name, content:, **_|
        stored_content = content
        { "name" => "test" }
      end

      client_cards.create_client(
        client_id: client_id,
        client_secret: client_secret,
        username: username,
        password: special_password,
        role: role
      )

      allow(tools_double).to receive(:get_card)
        .and_return({ "card" => { "content" => stored_content } })

      result = client_cards.verify_client(client_id: client_id, client_secret: client_secret)
      expect(result[:password]).to eq(special_password)
    end
  end
end
