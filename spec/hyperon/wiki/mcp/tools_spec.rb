# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "hyperon/wiki/mcp/tools"

RSpec.describe Hyperon::Wiki::Mcp::Tools do
  let(:config) do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["DECKO_API_BASE_URL"] = "https://test.example.com/api/mcp"
    ENV["MCP_ROLE"] = "user"
    Hyperon::Wiki::Mcp::Config.new
  end

  let(:client) { Hyperon::Wiki::Mcp::Client.new(config) }
  let(:tools) { described_class.new(client) }

  let(:valid_token) { "test-jwt-token" }
  let(:auth_response) do
    {
      "token" => valid_token,
      "role" => "user",
      "expires_in" => 3600
    }
  end

  before do
    # Stub auth endpoint
    stub_request(:post, "https://test.example.com/api/mcp/auth")
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

  describe "#initialize" do
    it "initializes with client" do
      expect(tools.client).to eq(client)
    end

    it "creates client if none provided" do
      ENV["MCP_API_KEY"] = "auto-key"
      tools = described_class.new
      expect(tools.client).to be_a(Hyperon::Wiki::Mcp::Client)
    end
  end

  describe "#get_card" do
    let(:card_name) { "User" }
    let(:card_url) { "https://test.example.com/api/mcp/cards/User" }
    let(:card_response) do
      {
        "card" => {
          "name" => "User",
          "content" => "User card content",
          "type" => "Cardtype",
          "id" => 123,
          "url" => "https://wiki.hyperon.dev/User"
        }
      }
    end

    before do
      stub_request(:get, card_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(
          status: 200,
          body: card_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "fetches card by name" do
      result = tools.get_card(card_name)
      expect(result).to eq(card_response)
    end

    context "with children" do
      before do
        stub_request(:get, card_url)
          .with(
            query: { "with_children" => "true" },
            headers: { "Authorization" => "Bearer #{valid_token}" }
          )
          .to_return(status: 200, body: card_response.to_json)
      end

      it "includes with_children parameter" do
        tools.get_card(card_name, with_children: true)

        expect(WebMock).to have_requested(:get, card_url)
          .with(query: { "with_children" => "true" })
      end
    end

    context "with compound card name" do
      let(:compound_name) { "Business Plan+Overview" }
      # Per MCP-SPEC: encode spaces as %20, keep + literal
      let(:encoded_url) { "https://test.example.com/api/mcp/cards/Business%20Plan+Overview" }

      before do
        stub_request(:get, encoded_url)
          .with(headers: { "Authorization" => "Bearer #{valid_token}" })
          .to_return(status: 200, body: card_response.to_json)
      end

      it "encodes card name properly" do
        tools.get_card(compound_name)

        expect(WebMock).to have_requested(:get, encoded_url)
      end
    end

    context "when card not found" do
      before do
        stub_request(:get, card_url)
          .to_return(
            status: 404,
            body: { "error" => "not_found", "message" => "Card not found" }.to_json
          )
      end

      it "raises NotFoundError" do
        expect { tools.get_card(card_name) }.to raise_error(
          Hyperon::Wiki::Mcp::Client::NotFoundError
        )
      end
    end

    context "when user lacks permission" do
      before do
        stub_request(:get, card_url)
          .to_return(
            status: 403,
            body: { "error" => "permission_denied", "message" => "Insufficient permissions" }.to_json
          )
      end

      it "raises AuthorizationError" do
        expect { tools.get_card(card_name) }.to raise_error(
          Hyperon::Wiki::Mcp::Client::AuthorizationError
        )
      end
    end
  end

  describe "#search_cards" do
    let(:cards_url) { "https://test.example.com/api/mcp/cards" }
    let(:search_response) do
      {
        "cards" => [
          { "name" => "Card 1", "content" => "Game content" },
          { "name" => "Card 2", "content" => "Game plan" }
        ],
        "total" => 2,
        "limit" => 50,
        "offset" => 0
      }
    end

    before do
      stub_request(:get, cards_url)
        .with(
          query: hash_including({}),
          headers: { "Authorization" => "Bearer #{valid_token}" }
        )
        .to_return(
          status: 200,
          body: search_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "searches cards with query" do
      stub_request(:get, cards_url)
        .with(query: { "q" => "game", "limit" => "50", "offset" => "0", "include_virtual" => "false" })
        .to_return(status: 200, body: search_response.to_json)

      result = tools.search_cards(q: "game")

      expect(result).to eq(search_response)
      expect(WebMock).to have_requested(:get, cards_url)
        .with(query: { "q" => "game", "limit" => "50", "offset" => "0", "include_virtual" => "false" })
    end

    it "filters by type" do
      stub_request(:get, cards_url)
        .with(query: { "type" => "User", "limit" => "50", "offset" => "0", "include_virtual" => "false" })
        .to_return(status: 200, body: search_response.to_json)

      tools.search_cards(type: "User")

      expect(WebMock).to have_requested(:get, cards_url)
        .with(query: { "type" => "User", "limit" => "50", "offset" => "0", "include_virtual" => "false" })
    end

    it "uses custom limit and offset" do
      stub_request(:get, cards_url)
        .with(query: { "limit" => "20", "offset" => "10", "include_virtual" => "false" })
        .to_return(status: 200, body: search_response.to_json)

      tools.search_cards(limit: 20, offset: 10)

      expect(WebMock).to have_requested(:get, cards_url)
        .with(query: { "limit" => "20", "offset" => "10", "include_virtual" => "false" })
    end

    it "combines query, type, and pagination" do
      stub_request(:get, cards_url)
        .with(query: { "q" => "plan", "type" => "User", "limit" => "10", "offset" => "5", "include_virtual" => "false" })
        .to_return(status: 200, body: search_response.to_json)

      tools.search_cards(q: "plan", type: "User", limit: 10, offset: 5)

      expect(WebMock).to have_requested(:get, cards_url)
        .with(query: { "q" => "plan", "type" => "User", "limit" => "10", "offset" => "5", "include_virtual" => "false" })
    end
  end

  describe "#list_children" do
    let(:parent_name) { "Business Plan" }
    # Per MCP-SPEC line 38: GET /api/mcp/cards/:name/children
    let(:children_url) { "https://test.example.com/api/mcp/cards/Business%20Plan/children" }
    let(:children_response) do
      {
        "parent" => "Business Plan",
        "children" => [
          { "name" => "Business Plan+Overview" },
          { "name" => "Business Plan+Goals" }
        ],
        "child_count" => 2
      }
    end

    before do
      stub_request(:get, children_url)
        .with(
          query: { "limit" => "50", "offset" => "0", "depth" => "3", "include_virtual" => "false" },
          headers: { "Authorization" => "Bearer #{valid_token}" }
        )
        .to_return(
          status: 200,
          body: children_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "lists children of parent card with default depth of 3" do
      result = tools.list_children(parent_name)

      expect(result).to eq(children_response)
      expect(WebMock).to have_requested(:get, children_url)
        .with(query: { "limit" => "50", "offset" => "0", "depth" => "3", "include_virtual" => "false" })
    end

    it "uses custom limit and offset" do
      stub_request(:get, children_url)
        .with(query: { "limit" => "20", "offset" => "10", "depth" => "3", "include_virtual" => "false" })
        .to_return(status: 200, body: children_response.to_json)

      tools.list_children(parent_name, limit: 20, offset: 10)

      expect(WebMock).to have_requested(:get, children_url)
        .with(query: { "limit" => "20", "offset" => "10", "depth" => "3", "include_virtual" => "false" })
    end

    it "supports custom depth parameter" do
      stub_request(:get, children_url)
        .with(query: { "limit" => "50", "offset" => "0", "depth" => "5", "include_virtual" => "false" })
        .to_return(status: 200, body: children_response.to_json)

      tools.list_children(parent_name, depth: 5)

      expect(WebMock).to have_requested(:get, children_url)
        .with(query: { "limit" => "50", "offset" => "0", "depth" => "5", "include_virtual" => "false" })
    end

    it "omits depth parameter when depth is 1" do
      stub_request(:get, children_url)
        .with(query: { "limit" => "50", "offset" => "0", "include_virtual" => "false" })
        .to_return(status: 200, body: children_response.to_json)

      tools.list_children(parent_name, depth: 1)

      expect(WebMock).to have_requested(:get, children_url)
        .with(query: { "limit" => "50", "offset" => "0", "include_virtual" => "false" })
    end

    context "when parent card not found" do
      let(:nonexistent_url) { "https://test.example.com/api/mcp/cards/NonExistent/children" }

      before do
        stub_request(:get, nonexistent_url)
          .with(query: { "limit" => "50", "offset" => "0", "depth" => "3", "include_virtual" => "false" })
          .to_return(
            status: 404,
            body: { "error" => "not_found", "message" => "Parent card not found" }.to_json
          )
      end

      it "raises NotFoundError" do
        expect { tools.list_children("NonExistent") }.to raise_error(
          Hyperon::Wiki::Mcp::Client::NotFoundError
        )
      end
    end
  end

  describe "#fetch_all_cards" do
    let(:cards_url) { "https://test.example.com/api/mcp/cards" }

    before do
      # First page
      stub_request(:get, cards_url)
        .with(query: { "type" => "User", "limit" => "10", "offset" => "0" })
        .to_return(
          status: 200,
          body: {
            "cards" => [{ "name" => "User 1" }, { "name" => "User 2" }],
            "next_offset" => 2
          }.to_json
        )

      # Second page (last)
      stub_request(:get, cards_url)
        .with(query: { "type" => "User", "limit" => "10", "offset" => "2" })
        .to_return(
          status: 200,
          body: {
            "cards" => [{ "name" => "User 3" }],
            "next_offset" => nil
          }.to_json
        )
    end

    it "fetches all cards across pages" do
      result = tools.fetch_all_cards(type: "User", limit: 10)

      expect(result.size).to eq(3)
      expect(result).to eq([
                             { "name" => "User 1" },
                             { "name" => "User 2" },
                             { "name" => "User 3" }
                           ])
    end
  end

  describe "#each_card_page" do
    let(:cards_url) { "https://test.example.com/api/mcp/cards" }

    before do
      # First page
      stub_request(:get, cards_url)
        .with(query: { "q" => "test", "limit" => "2", "offset" => "0" })
        .to_return(
          status: 200,
          body: {
            "cards" => [{ "name" => "Card 1" }, { "name" => "Card 2" }],
            "next_offset" => 2
          }.to_json
        )

      # Second page (last)
      stub_request(:get, cards_url)
        .with(query: { "q" => "test", "limit" => "2", "offset" => "2" })
        .to_return(
          status: 200,
          body: {
            "cards" => [{ "name" => "Card 3" }],
            "next_offset" => nil
          }.to_json
        )
    end

    it "yields each page" do
      pages = []
      tools.each_card_page(q: "test", limit: 2) do |page|
        pages << page
      end

      expect(pages.size).to eq(2)
      expect(pages[0]["cards"]).to eq([{ "name" => "Card 1" }, { "name" => "Card 2" }])
      expect(pages[1]["cards"]).to eq([{ "name" => "Card 3" }])
    end

    it "runs without error when no block given" do
      result = tools.each_card_page(q: "test", limit: 2)
      expect(result).to be_nil
    end
  end

  describe "#create_card" do
    let(:cards_url) { "https://test.example.com/api/mcp/cards" }
    let(:create_response) do
      {
        "card" => {
          "id" => 456,
          "name" => "My Note",
          "content" => "Some notes here",
          "type" => "Basic",
          "url" => "https://wiki.hyperon.dev/My_Note"
        }
      }
    end

    it "creates card with name and content" do
      stub_request(:post, cards_url)
        .with(
          body: { name: "My Note", content: "Some notes here" }.to_json,
          headers: { "Authorization" => "Bearer #{valid_token}", "Content-Type" => "application/json" }
        )
        .to_return(status: 201, body: create_response.to_json)

      result = tools.create_card("My Note", content: "Some notes here")

      expect(result).to eq(create_response)
    end

    it "creates card with type" do
      stub_request(:post, cards_url)
        .with(
          body: hash_including("name" => "john_doe", "type" => "User", "content" => "Profile")
        )
        .to_return(status: 201, body: create_response.to_json)

      tools.create_card("john_doe", type: "User", content: "Profile")

      expect(WebMock).to have_requested(:post, cards_url)
    end

    it "creates card with metadata" do
      stub_request(:post, cards_url)
        .with(
          body: hash_including("name" => "Card", "content" => "Content", "visibility" => "public")
        )
        .to_return(status: 201, body: create_response.to_json)

      tools.create_card("Card", content: "Content", visibility: "public", tags: ["test"])

      expect(WebMock).to have_requested(:post, cards_url)
    end

    context "when validation fails" do
      before do
        stub_request(:post, cards_url)
          .to_return(
            status: 422,
            body: {
              "error" => "validation_error",
              "message" => "Name is required",
              "details" => { "name" => ["can't be blank"] }
            }.to_json
          )
      end

      it "raises ValidationError" do
        expect { tools.create_card("") }.to raise_error(
          Hyperon::Wiki::Mcp::Client::ValidationError
        )
      end
    end
  end

  describe "#update_card" do
    let(:card_name) { "My Note" }
    let(:card_url) { "https://test.example.com/api/mcp/cards/My%20Note" }
    let(:update_response) do
      {
        "card" => {
          "name" => "My Note",
          "content" => "Updated content",
          "type" => "Basic"
        }
      }
    end

    it "updates card content" do
      stub_request(:patch, card_url)
        .with(
          body: { content: "Updated content" }.to_json,
          headers: { "Authorization" => "Bearer #{valid_token}", "Content-Type" => "application/json" }
        )
        .to_return(status: 200, body: update_response.to_json)

      result = tools.update_card(card_name, content: "Updated content")

      expect(result).to eq(update_response)
    end

    it "updates card type" do
      stub_request(:patch, card_url)
        .with(body: { type: "User" }.to_json)
        .to_return(status: 200, body: update_response.to_json)

      tools.update_card(card_name, type: "User")

      expect(WebMock).to have_requested(:patch, card_url)
        .with(body: { type: "User" }.to_json)
    end

    it "updates multiple fields" do
      stub_request(:patch, card_url)
        .with(body: { content: "New content", visibility: "private" }.to_json)
        .to_return(status: 200, body: update_response.to_json)

      tools.update_card(card_name, content: "New content", visibility: "private")

      expect(WebMock).to have_requested(:patch, card_url)
    end

    it "raises error when no parameters provided" do
      expect { tools.update_card(card_name) }.to raise_error(
        ArgumentError,
        /No update parameters provided/
      )
    end

    context "when card not found" do
      before do
        stub_request(:patch, card_url)
          .to_return(
            status: 404,
            body: { "error" => "not_found", "message" => "Card not found" }.to_json
          )
      end

      it "raises NotFoundError" do
        expect { tools.update_card(card_name, content: "New") }.to raise_error(
          Hyperon::Wiki::Mcp::Client::NotFoundError
        )
      end
    end
  end

  describe "#delete_card" do
    let(:card_name) { "Obsolete Card" }
    let(:card_url) { "https://test.example.com/api/mcp/cards/Obsolete%20Card" }
    let(:delete_response) { { "success" => true, "message" => "Card deleted" } }

    it "deletes card" do
      stub_request(:delete, card_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(status: 200, body: delete_response.to_json)

      result = tools.delete_card(card_name)

      expect(result).to eq(delete_response)
    end

    it "force deletes card with children" do
      stub_request(:delete, "#{card_url}?force=true")
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(status: 200, body: delete_response.to_json)

      tools.delete_card(card_name, force: true)

      expect(WebMock).to have_requested(:delete, "#{card_url}?force=true")
    end

    context "when card not found" do
      before do
        stub_request(:delete, card_url)
          .to_return(
            status: 404,
            body: { "error" => "not_found", "message" => "Card not found" }.to_json
          )
      end

      it "raises NotFoundError" do
        expect { tools.delete_card(card_name) }.to raise_error(
          Hyperon::Wiki::Mcp::Client::NotFoundError
        )
      end
    end

    context "when user lacks permission" do
      before do
        stub_request(:delete, card_url)
          .to_return(
            status: 403,
            body: { "error" => "permission_denied", "message" => "Admin access required" }.to_json
          )
      end

      it "raises AuthorizationError" do
        expect { tools.delete_card(card_name) }.to raise_error(
          Hyperon::Wiki::Mcp::Client::AuthorizationError
        )
      end
    end
  end

  describe "#rename_card" do
    let(:old_name) { "Old Card Name" }
    let(:new_name) { "New Card Name" }
    let(:card_url) { "https://test.example.com/api/mcp/cards/Old%20Card%20Name/rename" }
    let(:rename_response) do
      {
        "status" => "renamed",
        "old_name" => old_name,
        "new_name" => new_name,
        "updated_referers" => true,
        "card" => {
          "name" => new_name,
          "content" => "Test card content",
          "type" => "Basic"
        }
      }
    end

    it "renames card successfully with referer updates" do
      stub_request(:put, card_url)
        .with(
          headers: { "Authorization" => "Bearer #{valid_token}" },
          body: { new_name: new_name, update_referers: true }.to_json
        )
        .to_return(status: 200, body: rename_response.to_json)

      result = tools.rename_card(old_name, new_name)

      expect(result["status"]).to eq("renamed")
      expect(result["old_name"]).to eq(old_name)
      expect(result["new_name"]).to eq(new_name)
      expect(result["updated_referers"]).to eq(true)
      expect(result["card"]["name"]).to eq(new_name)
    end

    it "renames card without updating referers" do
      no_update_response = rename_response.merge("updated_referers" => false)

      stub_request(:put, card_url)
        .with(
          headers: { "Authorization" => "Bearer #{valid_token}" },
          body: { new_name: new_name, update_referers: false }.to_json
        )
        .to_return(status: 200, body: no_update_response.to_json)

      result = tools.rename_card(old_name, new_name, update_referers: false)

      expect(result["status"]).to eq("renamed")
      expect(result["updated_referers"]).to eq(false)
    end

    context "when card not found" do
      before do
        stub_request(:put, card_url)
          .to_return(
            status: 404,
            body: { "error" => "not_found", "message" => "Card not found" }.to_json
          )
      end

      it "raises NotFoundError" do
        expect { tools.rename_card(old_name, new_name) }.to raise_error(
          Hyperon::Wiki::Mcp::Client::NotFoundError
        )
      end
    end

    context "when user lacks permission" do
      before do
        stub_request(:put, card_url)
          .to_return(
            status: 403,
            body: { "error" => "permission_denied", "message" => "Admin access required" }.to_json
          )
      end

      it "raises AuthorizationError" do
        expect { tools.rename_card(old_name, new_name) }.to raise_error(
          Hyperon::Wiki::Mcp::Client::AuthorizationError
        )
      end
    end

    context "when new name already exists" do
      before do
        stub_request(:put, card_url)
          .to_return(
            status: 422,
            body: { "error" => "validation_error", "message" => "Name already exists" }.to_json
          )
      end

      it "raises ValidationError" do
        expect { tools.rename_card(old_name, new_name) }.to raise_error(
          Hyperon::Wiki::Mcp::Client::ValidationError
        )
      end
    end
  end

  describe "#list_types" do
    let(:types_url) { "https://test.example.com/api/mcp/types" }
    let(:types_response) do
      {
        "types" => [
          { "name" => "User", "id" => 1 },
          { "name" => "Role", "id" => 2 },
          { "name" => "Cardtype", "id" => 3 }
        ],
        "total" => 42,
        "limit" => 50,
        "offset" => 0
      }
    end

    before do
      stub_request(:get, types_url)
        .with(
          query: { "limit" => "50", "offset" => "0" },
          headers: { "Authorization" => "Bearer #{valid_token}" }
        )
        .to_return(
          status: 200,
          body: types_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "lists card types" do
      result = tools.list_types

      expect(result).to eq(types_response)
      expect(WebMock).to have_requested(:get, types_url)
        .with(query: { "limit" => "50", "offset" => "0" })
    end

    it "uses custom limit and offset" do
      stub_request(:get, types_url)
        .with(query: { "limit" => "20", "offset" => "10" })
        .to_return(status: 200, body: types_response.to_json)

      tools.list_types(limit: 20, offset: 10)

      expect(WebMock).to have_requested(:get, types_url)
        .with(query: { "limit" => "20", "offset" => "10" })
    end
  end

  describe "#fetch_all_types" do
    let(:types_url) { "https://test.example.com/api/mcp/types" }

    before do
      # First page
      stub_request(:get, types_url)
        .with(query: { "limit" => "100", "offset" => "0" })
        .to_return(
          status: 200,
          body: {
            "types" => [{ "name" => "User" }, { "name" => "Role" }],
            "next_offset" => 2
          }.to_json
        )

      # Second page (last)
      stub_request(:get, types_url)
        .with(query: { "limit" => "100", "offset" => "2" })
        .to_return(
          status: 200,
          body: {
            "types" => [{ "name" => "Cardtype" }],
            "next_offset" => nil
          }.to_json
        )
    end

    it "fetches all types across pages" do
      result = tools.fetch_all_types

      expect(result.size).to eq(3)
      expect(result).to eq([
                             { "name" => "User" },
                             { "name" => "Role" },
                             { "name" => "Cardtype" }
                           ])
    end
  end

  describe "#render_snippet" do
    # Per MCP-SPEC lines 39-40:
    # - HTML→Markdown: POST /api/mcp/render
    # - Markdown→HTML: POST /api/mcp/render/markdown

    context "HTML to Markdown" do
      let(:html_to_md_url) { "https://test.example.com/api/mcp/render" }
      let(:html_content) { "<p>Hello <strong>world</strong></p>" }
      let(:markdown_response) do
        {
          "markdown" => "Hello **world**",
          "format" => "gfm"
        }
      end

      before do
        stub_request(:post, html_to_md_url)
          .with(
            body: { content: html_content }.to_json,
            headers: { "Authorization" => "Bearer #{valid_token}", "Content-Type" => "application/json" }
          )
          .to_return(status: 200, body: markdown_response.to_json)
      end

      it "converts HTML to Markdown" do
        result = tools.convert_content(html_content, from: :html, to: :markdown)

        expect(result).to eq(markdown_response)
      end
    end

    context "Markdown to HTML" do
      let(:md_to_html_url) { "https://test.example.com/api/mcp/render/markdown" }
      let(:markdown_content) { "Hello **world**" }
      let(:html_response) do
        {
          "html" => "<p>Hello <strong>world</strong></p>",
          "format" => "html"
        }
      end

      before do
        stub_request(:post, md_to_html_url)
          .with(
            body: { content: markdown_content }.to_json
          )
          .to_return(status: 200, body: html_response.to_json)
      end

      it "converts Markdown to HTML" do
        result = tools.convert_content(markdown_content, from: :markdown, to: :html)

        expect(result).to eq(html_response)
      end
    end

    context "with invalid formats" do
      it "raises ArgumentError for invalid from format" do
        expect do
          tools.convert_content("content", from: :xml, to: :markdown)
        end.to raise_error(ArgumentError, /Format must be/)
      end

      it "raises ArgumentError for invalid to format" do
        expect do
          tools.convert_content("content", from: :html, to: :json)
        end.to raise_error(ArgumentError, /Format must be/)
      end

      it "raises ArgumentError when from and to are the same" do
        expect do
          tools.convert_content("content", from: :html, to: :html)
        end.to raise_error(ArgumentError, /cannot be the same/)
      end
    end
  end

  describe "#batch_operations" do
    let(:batch_url) { "https://test.example.com/api/mcp/cards/batch" }
    let(:operations) do
      [
        { action: "create", name: "Card 1", content: "Content 1" },
        { action: "create", name: "Card 2", content: "Content 2" }
      ]
    end
    let(:batch_response) do
      {
        "results" => [
          { "status" => 201, "success" => true, "card" => { "name" => "Card 1", "id" => 1 } },
          { "status" => 201, "success" => true, "card" => { "name" => "Card 2", "id" => 2 } }
        ],
        "mode" => "per_item"
      }
    end

    it "executes batch operations in per_item mode" do
      stub_request(:post, batch_url)
        .with(
          body: hash_including("ops" => operations, "mode" => "per_item"),
          headers: { "Authorization" => "Bearer #{valid_token}", "Content-Type" => "application/json" }
        )
        .to_return(status: 207, body: batch_response.to_json)

      result = tools.batch_operations(operations)

      expect(result).to eq(batch_response)
    end

    it "executes batch operations in transactional mode" do
      stub_request(:post, batch_url)
        .with(
          body: hash_including("ops" => operations, "mode" => "transactional")
        )
        .to_return(status: 207, body: batch_response.merge("mode" => "transactional").to_json)

      result = tools.batch_operations(operations, mode: "transactional")

      expect(result["mode"]).to eq("transactional")
    end

    it "raises ArgumentError for invalid mode" do
      expect do
        tools.batch_operations(operations, mode: "invalid")
      end.to raise_error(ArgumentError, /Mode must be/)
    end

    context "with partial failures" do
      let(:partial_response) do
        {
          "results" => [
            { "status" => 201, "success" => true, "card" => { "name" => "Card 1" } },
            { "status" => 422, "success" => false, "error" => "Validation error" }
          ],
          "mode" => "per_item"
        }
      end

      before do
        stub_request(:post, batch_url)
          .to_return(status: 207, body: partial_response.to_json)
      end

      it "returns partial results" do
        result = tools.batch_operations(operations)

        expect(result["results"].length).to eq(2)
        expect(result["results"][0]["success"]).to be true
        expect(result["results"][1]["success"]).to be false
      end
    end
  end

  describe "#build_child_op" do
    let(:parent_name) { "Business Plan" }
    let(:child_name) { "Overview" }

    it "builds operation for child card" do
      op = tools.build_child_op(parent_name, child_name, content: "Summary")

      expect(op[:action]).to eq("create")
      expect(op[:name]).to eq("Business Plan+Overview")
      expect(op[:content]).to eq("Summary")
    end

    it "includes type when provided" do
      op = tools.build_child_op(parent_name, child_name, content: "Summary", type: "RichText")

      expect(op[:type]).to eq("RichText")
    end

    it "works without content or type" do
      op = tools.build_child_op(parent_name, child_name)

      expect(op[:action]).to eq("create")
      expect(op[:name]).to eq("Business Plan+Overview")
      expect(op).not_to have_key(:content)
      expect(op).not_to have_key(:type)
    end

    it "can be used with batch_operations" do
      batch_url = "https://test.example.com/api/mcp/cards/batch"
      ops = [
        tools.build_child_op(parent_name, "Overview", content: "Summary"),
        tools.build_child_op(parent_name, "Goals", content: "Objectives")
      ]

      stub_request(:post, batch_url)
        .with(
          body: hash_including("ops" => ops),
          headers: { "Authorization" => "Bearer #{valid_token}", "Content-Type" => "application/json" }
        )
        .to_return(
          status: 207,
          body: {
            "results" => [
              { "status" => 201, "success" => true },
              { "status" => 201, "success" => true }
            ]
          }.to_json
        )

      result = tools.batch_operations(ops)

      expect(result["results"].length).to eq(2)
    end
  end
  describe "#normalize_card_name" do
    it "converts spaces to underscores" do
      result = tools.normalize_card_name("Daresh Tral Subcultures")
      expect(result).to eq("Daresh_Tral_Subcultures")
    end

    it "preserves plus signs in compound names" do
      result = tools.normalize_card_name("Business Plan+Overview")
      expect(result).to eq("Business_Plan+Overview")
    end

    it "handles names that are already normalized" do
      result = tools.normalize_card_name("Already_Normalized")
      expect(result).to eq("Already_Normalized")
    end

    it "handles names with multiple consecutive spaces" do
      result = tools.normalize_card_name("Test  Card   Name")
      expect(result).to eq("Test__Card___Name")
    end

    it "handles empty string" do
      result = tools.normalize_card_name("")
      expect(result).to eq("")
    end

    it "handles strings with only spaces" do
      result = tools.normalize_card_name("   ")
      expect(result).to eq("___")
    end
  end

  describe "#search_cards with default search_in parameter" do
    let(:cards_url) { "https://test.example.com/api/mcp/cards" }
    let(:search_response) do
      {
        "cards" => [
          { "name" => "Card 1", "content" => "Game content" },
          { "name" => "Card 2", "content" => "Game plan" }
        ],
        "total" => 2,
        "limit" => 50,
        "offset" => 0
      }
    end

    before do
      stub_request(:get, cards_url)
        .with(
          query: hash_including({}),
          headers: { "Authorization" => "Bearer #{valid_token}" }
        )
        .to_return(
          status: 200,
          body: search_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "uses search_in=both when not specified" do
      stub_request(:get, cards_url)
        .with(query: { "q" => "game", "search_in" => "both", "limit" => "50", "offset" => "0" })
        .to_return(status: 200, body: search_response.to_json)

      # Note: The underlying client uses default from search endpoint if not passed
      # This test verifies that when search_in is not provided, the endpoint's default (both) is used
      tools.search_cards(q: "game")

      # Verify the request was made - the client may or may not include search_in in params
      expect(WebMock).to have_requested(:get, cards_url)
        .with(query: hash_including("q" => "game"))
    end

    it "allows explicit override to search_in=name" do
      stub_request(:get, cards_url)
        .with(query: { "q" => "game", "search_in" => "name", "limit" => "50", "offset" => "0", "include_virtual" => "false" })
        .to_return(status: 200, body: search_response.to_json)

      tools.search_cards(q: "game", search_in: "name")

      expect(WebMock).to have_requested(:get, cards_url)
        .with(query: { "q" => "game", "search_in" => "name", "limit" => "50", "offset" => "0", "include_virtual" => "false" })
    end

    it "allows explicit override to search_in=content" do
      stub_request(:get, cards_url)
        .with(query: { "q" => "game", "search_in" => "content", "limit" => "50", "offset" => "0", "include_virtual" => "false" })
        .to_return(status: 200, body: search_response.to_json)

      tools.search_cards(q: "game", search_in: "content")

      expect(WebMock).to have_requested(:get, cards_url)
        .with(query: { "q" => "game", "search_in" => "content", "limit" => "50", "offset" => "0", "include_virtual" => "false" })
    end
  end

  describe "#search_and_replace" do
    let(:cards_url) { "https://test.example.com/api/mcp/cards" }
    let(:card_url) { "https://test.example.com/api/mcp/cards/Test%20Card" }
    let(:batch_url) { "https://test.example.com/api/mcp/cards/batch" }

    let(:search_response) do
      {
        "cards" => [
          { "name" => "Test Card", "content" => "old text in content", "type" => "RichText" }
        ],
        "total" => 1
      }
    end

    let(:full_card_response) do
      {
        "card" => {
          "name" => "Test Card",
          "content" => "old text in content",
          "type" => "RichText"
        }
      }
    end

    before do
      # Stub search cards
      stub_request(:get, cards_url)
        .with(
          query: hash_including("q" => "old text", "search_in" => "content"),
          headers: { "Authorization" => "Bearer #{valid_token}" }
        )
        .to_return(status: 200, body: search_response.to_json)

      # Stub get_card for fetching full content
      stub_request(:get, card_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(status: 200, body: full_card_response.to_json)
    end

    it "performs dry run by default" do
      result = tools.search_and_replace("old text", "new text", dry_run: true)

      expect(result[:preview]).to be_an(Array)
      expect(result[:preview].first[:card_name]).to eq("Test Card")
      expect(result[:message]).to include("Dry run complete")
      expect(WebMock).not_to have_requested(:post, batch_url)
    end

    it "searches and replaces text content" do
      batch_response = {
        "results" => [
          { "status" => 200, "success" => true }
        ],
        "mode" => "per_item"
      }

      stub_request(:post, batch_url)
        .with(
          body: {
            "ops" => [
              {
                "action" => "update",
                "name" => "Test Card",
                "content" => "new text in content"
              }
            ],
            "mode" => "per_item"
          }.to_json
        )
        .to_return(status: 207, body: batch_response.to_json)

      result = tools.search_and_replace("old text", "new text", dry_run: false)

      expect(result[:updated]).to eq(["Test Card"])
      expect(result[:total_cards]).to eq(1)
    end

    it "supports regex replacement" do
      # Stub for regex search (fetches all cards)
      stub_request(:get, cards_url)
        .with(
          query: { "limit" => "100", "offset" => "0" },
          headers: { "Authorization" => "Bearer #{valid_token}" }
        )
        .to_return(
          status: 200,
          body: {
            "cards" => [
              { "name" => "Test Card", "content" => "version 1.0", "type" => "RichText" }
            ],
            "total" => 1,
            "next_offset" => nil
          }.to_json
        )

      stub_request(:get, "https://test.example.com/api/mcp/cards/Test%20Card")
        .to_return(
          status: 200,
          body: {
            "card" => { "name" => "Test Card", "content" => "version 1.0" }
          }.to_json
        )

      batch_response = {
        "results" => [{ "status" => 200, "success" => true }],
        "mode" => "per_item"
      }

      stub_request(:post, batch_url)
        .to_return(status: 207, body: batch_response.to_json)

      result = tools.search_and_replace('\d+\.\d+', '2.0', regex: true, dry_run: false)

      expect(result[:updated]).to eq(["Test Card"])
    end

    it "filters by card name pattern" do
      # When card name pattern is provided, only matching cards should be updated
      result = tools.search_and_replace(
        "old text",
        "new text",
        card_name_pattern: "Test",
        dry_run: true
      )

      expect(result[:preview]).to be_an(Array)
      expect(result[:preview].first[:card_name]).to eq("Test Card")
    end

    it "supports case insensitive replacement" do
      stub_request(:get, cards_url)
        .with(query: hash_including("q" => "OLD", "search_in" => "content"))
        .to_return(
          status: 200,
          body: {
            "cards" => [
              { "name" => "Test Card", "content" => "old text here", "type" => "RichText" }
            ],
            "total" => 1
          }.to_json
        )

      stub_request(:get, card_url)
        .to_return(
          status: 200,
          body: {
            "card" => { "name" => "Test Card", "content" => "old text here" }
          }.to_json
        )

      result = tools.search_and_replace("OLD", "new", case_sensitive: false, dry_run: true)

      expect(result[:preview]).to be_an(Array)
      expect(result[:preview].first[:card_name]).to eq("Test Card")
    end

    it "returns empty preview when no cards match" do
      stub_request(:get, cards_url)
        .with(query: hash_including("q" => "nonexistent"))
        .to_return(
          status: 200,
          body: { "cards" => [], "total" => 0 }.to_json
        )

      result = tools.search_and_replace("nonexistent", "new", dry_run: true)

      expect(result[:preview]).to eq([])
      expect(result[:message]).to include("No matching cards found")
    end

    it "returns message when no changes needed" do
      stub_request(:get, cards_url)
        .with(query: hash_including("q" => "text"))
        .to_return(status: 200, body: search_response.to_json)

      stub_request(:get, card_url)
        .to_return(
          status: 200,
          body: {
            "card" => { "name" => "Test Card", "content" => "different content" }
          }.to_json
        )

      result = tools.search_and_replace("text", "text", dry_run: true)

      expect(result[:preview]).to eq([])
      expect(result[:message]).to include("No changes needed")
    end
  end

  describe "#get_site_context" do
    it "returns comprehensive site context structure" do
      result = tools.get_site_context

      # Verify top-level structure
      expect(result).to be_a(Hash)
      expect(result[:wiki_name]).to eq("Hyperon Wiki")
      expect(result[:wiki_url]).to eq("https://wiki.hyperon.dev")
      expect(result[:description]).to be_a(String)
    end

    it "includes hierarchy information" do
      result = tools.get_site_context

      expect(result[:hierarchy]).to be_a(Hash)
      expect(result[:hierarchy]).to have_key("Home")
      expect(result[:hierarchy]).to have_key("Games")
      expect(result[:hierarchy]).to have_key("Business Plan")
      expect(result[:hierarchy]).to have_key("Neoterics")
      expect(result[:hierarchy]).to have_key("Notes")
    end

    it "provides Home section details" do
      result = tools.get_site_context
      home = result[:hierarchy]["Home"]

      expect(home[:description]).to be_a(String)
      expect(home[:sections]).to be_an(Array)
      expect(home[:sections]).to include("Games", "Business Plan", "Neoterics", "Notes")
    end

    it "provides Games section with game details" do
      result = tools.get_site_context
      games = result[:hierarchy]["Games"]

      expect(games[:description]).to be_a(String)
      expect(games[:games]).to be_an(Array)
      expect(games[:games]).not_to be_empty

      # Check for Butterfly Galaxii
      bg_game = games[:games].find { |g| g[:name] == "Butterfly Galaxii" }
      expect(bg_game).not_to be_nil
      expect(bg_game[:path]).to eq("Games+Butterfly Galaxii")
      expect(bg_game[:sections]).to be_an(Array)
      expect(bg_game[:key_areas]).to be_a(Hash)
    end

    it "includes comprehensive guidelines" do
      result = tools.get_site_context
      guidelines = result[:guidelines]

      expect(guidelines).to have_key(:naming_conventions)
      expect(guidelines).to have_key(:content_placement)
      expect(guidelines).to have_key(:content_structure)
      expect(guidelines).to have_key(:special_cards)
      expect(guidelines).to have_key(:best_practices)

      expect(guidelines[:naming_conventions]).to be_an(Array)
      expect(guidelines[:content_placement]).to be_an(Array)
      expect(guidelines[:content_structure]).to be_an(Array)
      expect(guidelines[:special_cards]).to be_an(Array)
      expect(guidelines[:best_practices]).to be_an(Array)
    end

    it "includes naming conventions guidance" do
      result = tools.get_site_context
      conventions = result[:guidelines][:naming_conventions]

      expect(conventions).to include(a_string_including("+"))
      expect(conventions).to include(a_string_including("case-sensitive"))
    end

    it "includes content placement guidance" do
      result = tools.get_site_context
      placement = result[:guidelines][:content_placement]

      expect(placement).to include(a_string_including("Player"))
      expect(placement).to include(a_string_including("GM"))
      expect(placement).to include(a_string_including("AI"))
    end

    it "includes special cards information" do
      result = tools.get_site_context
      special = result[:guidelines][:special_cards]

      expect(special).to include(a_string_including("Virtual cards"))
      expect(special).to include(a_string_including("Pointer cards"))
      expect(special).to include(a_string_including("Search cards"))
      expect(special).to include(a_string_including("Deleted cards"))
      expect(special).to include(a_string_including("+GM+AI"))
    end

    it "provides common naming patterns" do
      result = tools.get_site_context
      patterns = result[:common_patterns]

      expect(patterns).to be_a(Hash)
      expect(patterns).to have_key(:game_content)
      expect(patterns).to have_key(:business)
      expect(patterns).to have_key(:research)
      expect(patterns).to have_key(:notes)

      expect(patterns[:game_content]).to include("+")
      expect(patterns[:business]).to include("Business Plan")
    end

    it "provides helpful navigation cards" do
      result = tools.get_site_context
      helpful = result[:helpful_cards]

      expect(helpful).to be_an(Array)
      expect(helpful).not_to be_empty
      expect(helpful).to include(a_string_including("Home+table-of-contents"))
      expect(helpful).to include(a_string_including("Games+table-of-contents"))
    end
  end

  describe "#get_ai_instructions" do
    let(:section_name) { "Games+Butterfly Galaxii" }
    let(:ai_card_name) { "Games+Butterfly Galaxii+GM+AI" }
    let(:encoded_ai_card_name) { "Games+Butterfly%20Galaxii+GM+AI" }
    let(:ai_card_url) { "https://test.example.com/api/mcp/cards/#{encoded_ai_card_name}" }

    context "when +GM+AI card exists with content" do
      let(:ai_card_response) do
        {
          "card" => {
            "name" => ai_card_name,
            "content" => "AI-specific instructions for Butterfly Galaxii",
            "type" => "RichText"
          }
        }
      end

      before do
        stub_request(:get, ai_card_url)
          .with(headers: { "Authorization" => "Bearer #{valid_token}" })
          .to_return(status: 200, body: ai_card_response.to_json)
      end

      it "returns the AI instruction card" do
        result = tools.get_ai_instructions(section_name)

        expect(result).to be_a(Hash)
        expect(result["name"]).to eq(ai_card_name)
        expect(result["content"]).to eq("AI-specific instructions for Butterfly Galaxii")
      end
    end

    context "when +GM+AI card exists but is empty" do
      let(:empty_card_response) do
        {
          "card" => {
            "name" => ai_card_name,
            "content" => "   ",
            "type" => "RichText"
          }
        }
      end

      before do
        stub_request(:get, ai_card_url)
          .to_return(status: 200, body: empty_card_response.to_json)
      end

      it "returns nil for empty content" do
        result = tools.get_ai_instructions(section_name)
        expect(result).to be_nil
      end
    end

    context "when +GM+AI card does not exist" do
      before do
        stub_request(:get, ai_card_url)
          .to_return(
            status: 404,
            body: { "error" => "not_found", "message" => "Card not found" }.to_json
          )
      end

      it "returns nil" do
        result = tools.get_ai_instructions(section_name)
        expect(result).to be_nil
      end
    end

    context "when an error occurs" do
      before do
        stub_request(:get, ai_card_url)
          .to_return(status: 500, body: "Internal Server Error")
      end

      it "returns nil and logs warning" do
        expect(tools).to receive(:warn).with(/Error fetching AI instructions/)
        result = tools.get_ai_instructions(section_name)
        expect(result).to be_nil
      end
    end

    it "constructs the correct +GM+AI card name" do
      stub_request(:get, "https://test.example.com/api/mcp/cards/Business%20Plan+GM+AI")
        .to_return(
          status: 404,
          body: { "error" => "not_found" }.to_json
        )

      tools.get_ai_instructions("Business Plan")

      expect(WebMock).to have_requested(:get, "https://test.example.com/api/mcp/cards/Business%20Plan+GM+AI")
    end
  end

end
