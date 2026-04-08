# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "hyperon/wiki/mcp/tools"

RSpec.describe Hyperon::Wiki::Mcp::Tools, "#diff_card" do
  let(:config) do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["DECKO_API_BASE_URL"] = "https://test.example.com/api/mcp"
    ENV["MCP_ROLE"] = "admin"
    Hyperon::Wiki::Mcp::Config.new
  end

  let(:client) { Hyperon::Wiki::Mcp::Client.new(config) }
  let(:tools) { described_class.new(client) }

  let(:valid_token) { "test-jwt-token" }
  let(:auth_response) do
    {
      "token" => valid_token,
      "role" => "admin",
      "expires_in" => 3600
    }
  end

  let(:card_name) { "Test Card" }
  let(:base_url) { "https://test.example.com/api/mcp" }
  let(:card_url) { "#{base_url}/cards/Test%20Card" }
  let(:history_url) { "#{card_url}/history" }

  before do
    stub_request(:post, "#{base_url}/auth")
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

  describe "diff between two specific revisions" do
    let(:from_act_id) { 100 }
    let(:to_act_id) { 200 }

    let(:from_revision_response) do
      {
        "card" => card_name,
        "act_id" => from_act_id,
        "acted_at" => "2025-12-20T10:00:00Z",
        "actor" => "TestUser",
        "snapshot" => {
          "name" => card_name,
          "type" => "RichText",
          "content" => "Line one\nLine two\nLine three"
        }
      }
    end

    let(:to_revision_response) do
      {
        "card" => card_name,
        "act_id" => to_act_id,
        "acted_at" => "2025-12-24T14:00:00Z",
        "actor" => "TestUser",
        "snapshot" => {
          "name" => card_name,
          "type" => "RichText",
          "content" => "Line one\nLine two modified\nLine three\nLine four"
        }
      }
    end

    before do
      stub_request(:get, "#{history_url}/#{from_act_id}")
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(
          status: 200,
          body: from_revision_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, "#{history_url}/#{to_act_id}")
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(
          status: 200,
          body: to_revision_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "returns a diff with correct structure" do
      result = tools.diff_card(card_name, from_revision: from_act_id, to_revision: to_act_id)

      expect(result["card"]).to eq(card_name)
      expect(result["from"]).to include("revision 100")
      expect(result["to"]).to include("revision 200")
      expect(result["diff"]).to be_a(String)
      expect(result["summary"]).to be_a(Hash)
    end

    it "detects added and removed lines" do
      result = tools.diff_card(card_name, from_revision: from_act_id, to_revision: to_act_id)

      expect(result["diff"]).to include("-Line two")
      expect(result["diff"]).to include("+Line two modified")
      expect(result["diff"]).to include("+Line four")
    end

    it "computes summary statistics" do
      result = tools.diff_card(card_name, from_revision: from_act_id, to_revision: to_act_id)

      summary = result["summary"]
      expect(summary["lines_added"]).to be > 0
      expect(summary["lines_removed"]).to be > 0
      expect(summary["total_changes"]).to eq(summary["lines_added"] + summary["lines_removed"])
    end
  end

  describe "diff from revision to current content" do
    let(:from_act_id) { 100 }

    let(:from_revision_response) do
      {
        "card" => card_name,
        "act_id" => from_act_id,
        "acted_at" => "2025-12-20T10:00:00Z",
        "actor" => "TestUser",
        "snapshot" => {
          "name" => card_name,
          "type" => "RichText",
          "content" => "Old content here"
        }
      }
    end

    let(:current_card_response) do
      {
        "name" => card_name,
        "type" => "RichText",
        "content" => "New content here"
      }
    end

    before do
      stub_request(:get, "#{history_url}/#{from_act_id}")
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(
          status: 200,
          body: from_revision_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, card_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(
          status: 200,
          body: current_card_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "compares revision with current content" do
      result = tools.diff_card(card_name, from_revision: from_act_id)

      expect(result["to"]).to eq("current")
      expect(result["from"]).to include("revision 100")
      expect(result["diff"]).to include("-Old content here")
      expect(result["diff"]).to include("+New content here")
    end

    it "includes summary with changes" do
      result = tools.diff_card(card_name, from_revision: from_act_id)

      summary = result["summary"]
      expect(summary["lines_added"]).to eq(1)
      expect(summary["lines_removed"]).to eq(1)
      expect(summary["total_changes"]).to eq(2)
    end
  end

  describe "no differences case" do
    let(:from_act_id) { 100 }
    let(:identical_content) { "Same content\nLine two\nLine three" }

    let(:from_revision_response) do
      {
        "card" => card_name,
        "act_id" => from_act_id,
        "acted_at" => "2025-12-20T10:00:00Z",
        "actor" => "TestUser",
        "snapshot" => {
          "name" => card_name,
          "type" => "RichText",
          "content" => identical_content
        }
      }
    end

    let(:current_card_response) do
      {
        "name" => card_name,
        "type" => "RichText",
        "content" => identical_content
      }
    end

    before do
      stub_request(:get, "#{history_url}/#{from_act_id}")
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(
          status: 200,
          body: from_revision_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, card_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(
          status: 200,
          body: current_card_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "reports no differences" do
      result = tools.diff_card(card_name, from_revision: from_act_id)

      expect(result["diff"]).to include("(no differences)")
      expect(result["summary"]["lines_added"]).to eq(0)
      expect(result["summary"]["lines_removed"]).to eq(0)
      expect(result["summary"]["total_changes"]).to eq(0)
    end
  end

  describe "card not found error" do
    before do
      stub_request(:get, "#{history_url}/999")
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(
          status: 404,
          body: { "error" => "not_found", "message" => "Card not found" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "raises NotFoundError for missing revision" do
      expect { tools.diff_card(card_name, from_revision: 999, to_revision: 200) }.to raise_error(
        Hyperon::Wiki::Mcp::Client::NotFoundError
      )
    end
  end

  describe "no revision history" do
    let(:empty_history_response) do
      {
        "card" => card_name,
        "revisions" => [],
        "total" => 0,
        "in_trash" => false
      }
    end

    before do
      stub_request(:get, history_url)
        .with(
          query: { "limit" => "1" },
          headers: { "Authorization" => "Bearer #{valid_token}" }
        )
        .to_return(
          status: 200,
          body: empty_history_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "raises ValidationError when no from_revision specified and history is empty" do
      expect { tools.diff_card(card_name) }.to raise_error(
        Hyperon::Wiki::Mcp::Client::ValidationError,
        /no revision history/
      )
    end
  end
end
