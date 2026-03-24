# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "magi/archive/mcp/tools"

RSpec.describe Magi::Archive::Mcp::Tools do
  let(:config) do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["DECKO_API_BASE_URL"] = "https://test.example.com/api/mcp"
    ENV["MCP_ROLE"] = "admin"
    Magi::Archive::Mcp::Config.new
  end

  let(:client) { Magi::Archive::Mcp::Client.new(config) }
  let(:tools) { described_class.new(client) }

  let(:valid_token) { "test-jwt-token" }
  let(:auth_response) do
    {
      "token" => valid_token,
      "role" => "admin",
      "expires_in" => 3600
    }
  end

  before do
    stub_request(:post, "https://test.example.com/api/mcp/auth")
      .with(
        body: { api_key: "test-api-key", role: "admin" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      .to_return(
        status: 201,
        body: auth_response.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  describe "#get_card_history" do
    let(:card_name) { "Test Card" }
    let(:history_url) { "https://test.example.com/api/mcp/cards/Test%20Card/history" }
    let(:history_response) do
      {
        "card" => "Test Card",
        "revisions" => [
          {
            "act_id" => 12345,
            "action" => "update",
            "actor" => "TestUser",
            "acted_at" => "2025-12-24T10:30:00Z",
            "changes" => ["content"]
          },
          {
            "act_id" => 12340,
            "action" => "create",
            "actor" => "TestUser",
            "acted_at" => "2025-12-20T15:00:00Z",
            "changes" => %w[name type content]
          }
        ],
        "total" => 2,
        "in_trash" => false
      }
    end

    before do
      stub_request(:get, history_url)
        .with(
          query: { "limit" => "20" },
          headers: { "Authorization" => "Bearer #{valid_token}" }
        )
        .to_return(
          status: 200,
          body: history_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "fetches card history" do
      result = tools.get_card_history(card_name)
      expect(result["revisions"]).to be_an(Array)
      expect(result["revisions"].size).to eq(2)
    end

    it "returns revision metadata" do
      result = tools.get_card_history(card_name)
      revision = result["revisions"].first
      expect(revision["act_id"]).to eq(12345)
      expect(revision["action"]).to eq("update")
      expect(revision["actor"]).to eq("TestUser")
    end

    context "with custom limit" do
      before do
        stub_request(:get, history_url)
          .with(
            query: { "limit" => "50" },
            headers: { "Authorization" => "Bearer #{valid_token}" }
          )
          .to_return(status: 200, body: history_response.to_json)
      end

      it "passes limit parameter" do
        tools.get_card_history(card_name, limit: 50)
        expect(WebMock).to have_requested(:get, history_url)
          .with(query: { "limit" => "50" })
      end
    end

    context "with limit exceeding maximum" do
      before do
        stub_request(:get, history_url)
          .with(
            query: { "limit" => "100" },
            headers: { "Authorization" => "Bearer #{valid_token}" }
          )
          .to_return(status: 200, body: history_response.to_json)
      end

      it "caps limit at 100" do
        tools.get_card_history(card_name, limit: 200)
        expect(WebMock).to have_requested(:get, history_url)
          .with(query: { "limit" => "100" })
      end
    end

    context "when card not found" do
      before do
        stub_request(:get, history_url)
          .with(query: { "limit" => "20" })
          .to_return(
            status: 404,
            body: { "error" => "not_found", "message" => "Card not found" }.to_json
          )
      end

      it "raises NotFoundError" do
        expect { tools.get_card_history(card_name) }.to raise_error(
          Magi::Archive::Mcp::Client::NotFoundError
        )
      end
    end
  end

  describe "#get_revision" do
    let(:card_name) { "Test Card" }
    let(:act_id) { 12340 }
    let(:revision_url) { "https://test.example.com/api/mcp/cards/Test%20Card/history/#{act_id}" }
    let(:revision_response) do
      {
        "card" => "Test Card",
        "act_id" => act_id,
        "acted_at" => "2025-12-20T15:00:00Z",
        "actor" => "TestUser",
        "snapshot" => {
          "name" => "Test Card",
          "type" => "RichText",
          "content" => "<p>Original content...</p>"
        }
      }
    end

    before do
      stub_request(:get, revision_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(
          status: 200,
          body: revision_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "fetches specific revision" do
      result = tools.get_revision(card_name, act_id: act_id)
      expect(result["act_id"]).to eq(act_id)
    end

    it "includes snapshot with content" do
      result = tools.get_revision(card_name, act_id: act_id)
      expect(result["snapshot"]["content"]).to include("Original content")
    end

    context "when revision not found" do
      before do
        stub_request(:get, revision_url)
          .to_return(
            status: 404,
            body: { "error" => "not_found", "message" => "Revision not found" }.to_json
          )
      end

      it "raises NotFoundError" do
        expect { tools.get_revision(card_name, act_id: act_id) }.to raise_error(
          Magi::Archive::Mcp::Client::NotFoundError
        )
      end
    end
  end

  describe "#restore_card" do
    let(:card_name) { "Test Card" }
    let(:restore_url) { "https://test.example.com/api/mcp/cards/Test%20Card/restore" }

    context "restoring to specific revision" do
      let(:act_id) { 12340 }
      let(:restore_response) do
        {
          "success" => true,
          "card" => "Test Card",
          "restored_from" => {
            "act_id" => act_id,
            "acted_at" => "2025-12-20T15:00:00Z"
          },
          "message" => "Card restored to revision from 2025-12-20"
        }
      end

      before do
        stub_request(:post, restore_url)
          .with(
            body: { act_id: act_id }.to_json,
            headers: {
              "Authorization" => "Bearer #{valid_token}",
              "Content-Type" => "application/json"
            }
          )
          .to_return(
            status: 200,
            body: restore_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "restores to specific revision" do
        result = tools.restore_card(card_name, act_id: act_id)
        expect(result["success"]).to be true
        expect(result["restored_from"]["act_id"]).to eq(act_id)
      end
    end

    context "restoring from trash" do
      let(:restore_response) do
        {
          "success" => true,
          "card" => "Test Card",
          "message" => "Card restored from trash"
        }
      end

      before do
        stub_request(:post, restore_url)
          .with(
            body: { from_trash: true }.to_json,
            headers: {
              "Authorization" => "Bearer #{valid_token}",
              "Content-Type" => "application/json"
            }
          )
          .to_return(
            status: 200,
            body: restore_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "restores from trash" do
        result = tools.restore_card(card_name, from_trash: true)
        expect(result["success"]).to be true
        expect(result["message"]).to include("trash")
      end
    end

    context "with neither act_id nor from_trash" do
      it "raises ArgumentError" do
        expect { tools.restore_card(card_name) }.to raise_error(
          ArgumentError, /Must specify either act_id or from_trash/
        )
      end
    end

    context "when user lacks permission" do
      before do
        stub_request(:post, restore_url)
          .to_return(
            status: 403,
            body: { "error" => "permission_denied", "message" => "Admin role required" }.to_json
          )
      end

      it "raises AuthorizationError" do
        expect { tools.restore_card(card_name, from_trash: true) }.to raise_error(
          Magi::Archive::Mcp::Client::AuthorizationError
        )
      end
    end
  end

  describe "#list_trash" do
    let(:trash_url) { "https://test.example.com/api/mcp/trash" }
    let(:trash_response) do
      {
        "cards" => [
          {
            "name" => "Deleted Card 1",
            "type" => "Basic",
            "deleted_at" => "2025-12-24T09:00:00Z",
            "deleted_by" => "TestAdmin"
          },
          {
            "name" => "Deleted Card 2",
            "type" => "RichText",
            "deleted_at" => "2025-12-23T14:00:00Z",
            "deleted_by" => "TestAdmin"
          }
        ],
        "total" => 2
      }
    end

    before do
      stub_request(:get, trash_url)
        .with(
          query: { "limit" => "50", "offset" => "0" },
          headers: { "Authorization" => "Bearer #{valid_token}" }
        )
        .to_return(
          status: 200,
          body: trash_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "lists deleted cards" do
      result = tools.list_trash
      expect(result["cards"]).to be_an(Array)
      expect(result["cards"].size).to eq(2)
    end

    it "includes deletion metadata" do
      result = tools.list_trash
      card = result["cards"].first
      expect(card["name"]).to eq("Deleted Card 1")
      expect(card["deleted_by"]).to eq("TestAdmin")
    end

    context "with custom limit and offset" do
      before do
        stub_request(:get, trash_url)
          .with(
            query: { "limit" => "20", "offset" => "10" },
            headers: { "Authorization" => "Bearer #{valid_token}" }
          )
          .to_return(status: 200, body: trash_response.to_json)
      end

      it "passes pagination parameters" do
        tools.list_trash(limit: 20, offset: 10)
        expect(WebMock).to have_requested(:get, trash_url)
          .with(query: { "limit" => "20", "offset" => "10" })
      end
    end

    context "with limit exceeding maximum" do
      before do
        stub_request(:get, trash_url)
          .with(
            query: { "limit" => "100", "offset" => "0" },
            headers: { "Authorization" => "Bearer #{valid_token}" }
          )
          .to_return(status: 200, body: trash_response.to_json)
      end

      it "caps limit at 100" do
        tools.list_trash(limit: 200)
        expect(WebMock).to have_requested(:get, trash_url)
          .with(query: { "limit" => "100", "offset" => "0" })
      end
    end

    context "when user lacks permission" do
      before do
        stub_request(:get, trash_url)
          .with(query: hash_including({}))
          .to_return(
            status: 403,
            body: { "error" => "permission_denied", "message" => "Admin role required" }.to_json
          )
      end

      it "raises AuthorizationError" do
        expect { tools.list_trash }.to raise_error(
          Magi::Archive::Mcp::Client::AuthorizationError
        )
      end
    end
  end
end
