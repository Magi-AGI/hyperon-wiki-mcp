# frozen_string_literal: true

require "spec_helper"
require "hyperon/wiki/mcp/tools"

# Contract tests using recorded response shapes from the Decko MCP server
#
# These tests verify that our client correctly handles the actual response
# formats returned by the server, catching schema drift and contract mismatches.
#
# Note: These use WebMock with recorded response shapes. For full integration
# testing, run against a live Decko MCP server in a staging environment.
RSpec.describe "Hyperon::Wiki::Mcp Contract Tests", type: :integration do
  let(:base_url) { "https://test.example.com/api/mcp" }
  let(:valid_token) { "test-jwt-token" }

  before do
    ENV["MCP_API_KEY"] = "test-key"
    ENV["DECKO_API_BASE_URL"] = base_url

    # Stub authentication
    stub_request(:post, "#{base_url}/auth")
      .to_return(
        status: 200,
        body: { token: valid_token, expires_at: (Time.now + 3600).iso8601 }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    # Stub JWKS endpoint
    stub_request(:get, "#{base_url}/.well-known/jwks.json")
      .to_return(
        status: 200,
        body: { keys: [{ kid: "test-key", kty: "RSA" }] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  after do
    ENV.delete("MCP_API_KEY")
    ENV.delete("DECKO_API_BASE_URL")
  end

  let(:tools) { Hyperon::Wiki::Mcp::Tools.new }

  describe "GET /cards/:name" do
    it "handles real card response shape" do
      # Recorded response from live server (Phase 2)
      stub_request(:get, "#{base_url}/cards/Main%20Page")
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(
          status: 200,
          body: {
            name: "Main Page",
            content: "Welcome to the Hyperon Wiki.",
            type: "RichText",
            id: 1,
            url: "https://wiki.hyperon.dev/Main_Page",
            created_at: "2024-01-01T00:00:00Z",
            updated_at: "2024-01-02T00:00:00Z"
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      card = tools.get_card("Main Page")

      expect(card).to be_a(Hash)
      expect(card["name"]).to eq("Main Page")
      expect(card["content"]).to eq("Welcome to the Hyperon Wiki.")
      expect(card["type"]).to eq("RichText")
      expect(card["id"]).to eq(1)
      expect(card["url"]).to be_a(String)
      expect(card["created_at"]).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/)
    end
  end

  describe "GET /cards/:name/children" do
    it "handles real children response shape" do
      # Recorded response from live server (Phase 2)
      stub_request(:get, "#{base_url}/cards/Business%20Plan/children")
        .with(
          query: { limit: 50, offset: 0, include_virtual: false },
          headers: { "Authorization" => "Bearer #{valid_token}" }
        )
        .to_return(
          status: 200,
          body: {
            parent: "Business Plan",
            children: [
              {
                name: "Business Plan+Overview",
                content: "Executive summary",
                type: "RichText",
                id: 101
              },
              {
                name: "Business Plan+Goals",
                content: "Key objectives",
                type: "RichText",
                id: 102
              }
            ],
            child_count: 2,
            depth: 1,
            limit: 50,
            offset: 0
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = tools.list_children("Business Plan")

      expect(result).to be_a(Hash)
      expect(result["parent"]).to eq("Business Plan")
      expect(result["children"]).to be_an(Array)
      expect(result["children"].length).to eq(2)
      expect(result["child_count"]).to eq(2)
      expect(result["depth"]).to eq(1)

      first_child = result["children"].first
      expect(first_child["name"]).to eq("Business Plan+Overview")
      expect(first_child).to have_key("content")
      expect(first_child).to have_key("type")
      expect(first_child).to have_key("id")
    end
  end

  describe "POST /cards/batch" do
    it "handles real batch response shape (HTTP 207 Multi-Status)" do
      # Recorded response from live server (Phase 2)
      ops = [
        { action: "create", name: "Test Card 1", content: "Content 1" },
        { action: "create", name: "Test Card 2", content: "Content 2" }
      ]

      stub_request(:post, "#{base_url}/cards/batch")
        .with(
          body: hash_including("ops" => ops, "mode" => "per_item"),
          headers: { "Authorization" => "Bearer #{valid_token}", "Content-Type" => "application/json" }
        )
        .to_return(
          status: 207,
          body: {
            results: [
              {
                status: 201,
                success: true,
                card: {
                  name: "Test Card 1",
                  content: "Content 1",
                  type: "RichText",
                  id: 201,
                  url: "https://wiki.hyperon.dev/Test_Card_1"
                }
              },
              {
                status: 201,
                success: true,
                card: {
                  name: "Test Card 2",
                  content: "Content 2",
                  type: "RichText",
                  id: 202,
                  url: "https://wiki.hyperon.dev/Test_Card_2"
                }
              }
            ],
            mode: "per_item",
            total: 2,
            succeeded: 2,
            failed: 0
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = tools.batch_operations(ops, mode: "per_item")

      expect(result).to be_a(Hash)
      expect(result["results"]).to be_an(Array)
      expect(result["results"].length).to eq(2)
      expect(result["mode"]).to eq("per_item")
      expect(result["succeeded"]).to eq(2)
      expect(result["failed"]).to eq(0)

      first_result = result["results"].first
      expect(first_result["status"]).to eq(201)
      expect(first_result["success"]).to be true
      expect(first_result["card"]).to be_a(Hash)
      expect(first_result["card"]["name"]).to eq("Test Card 1")
    end
  end

  describe "POST /render" do
    it "handles real HTML→Markdown response shape" do
      # Recorded response from live server (Phase 2)
      html_content = "<h1>Hello</h1><p>This is <strong>bold</strong>.</p>"

      stub_request(:post, "#{base_url}/render")
        .with(
          body: hash_including("content" => html_content),
          headers: { "Authorization" => "Bearer #{valid_token}", "Content-Type" => "application/json" }
        )
        .to_return(
          status: 200,
          body: {
            markdown: "# Hello\n\nThis is **bold**.",
            format: "gfm"
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = tools.convert_content(html_content, from: :html, to: :markdown)

      expect(result).to be_a(Hash)
      expect(result).to have_key("markdown")
      expect(result).not_to have_key("html")
      expect(result["markdown"]).to be_a(String)
      expect(result["format"]).to eq("gfm")
    end
  end

  describe "POST /render/markdown" do
    it "handles real Markdown→HTML response shape" do
      # Recorded response from live server (Phase 2)
      markdown_content = "# Hello\n\nThis is **bold**."

      stub_request(:post, "#{base_url}/render/markdown")
        .with(
          body: hash_including("content" => markdown_content),
          headers: { "Authorization" => "Bearer #{valid_token}", "Content-Type" => "application/json" }
        )
        .to_return(
          status: 200,
          body: {
            html: "<h1>Hello</h1>\n<p>This is <strong>bold</strong>.</p>",
            format: "html"
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = tools.convert_content(markdown_content, from: :markdown, to: :html)

      expect(result).to be_a(Hash)
      expect(result).to have_key("html")
      expect(result).not_to have_key("markdown")
      expect(result["html"]).to be_a(String)
      expect(result["format"]).to eq("html")
    end
  end

  describe "error responses" do
    it "handles 404 Not Found with error message" do
      stub_request(:get, "#{base_url}/cards/Nonexistent")
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(
          status: 404,
          body: {
            error: "not_found",
            message: "Card 'Nonexistent' not found"
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect { tools.get_card("Nonexistent") }.to raise_error(
        Hyperon::Wiki::Mcp::Client::NotFoundError,
        /Card 'Nonexistent' not found/
      )
    end

    it "handles 422 Validation Error with details" do
      stub_request(:post, "#{base_url}/cards")
        .with(
          body: hash_including("name" => ""),
          headers: { "Authorization" => "Bearer #{valid_token}", "Content-Type" => "application/json" }
        )
        .to_return(
          status: 422,
          body: {
            error: "validation_error",
            message: "Card name cannot be blank",
            details: {
              name: ["cannot be blank", "must be at least 1 character"]
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect { tools.create_card("") }.to raise_error(
        Hyperon::Wiki::Mcp::Client::ValidationError
      ) do |error|
        expect(error.details).to be_a(Hash)
        expect(error.details["name"]).to include("cannot be blank")
      end
    end
  end
end
