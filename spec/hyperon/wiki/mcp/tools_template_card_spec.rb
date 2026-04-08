# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "hyperon/wiki/mcp/tools"

RSpec.describe Hyperon::Wiki::Mcp::Tools do
  let(:base_url) { "https://test.example.com/api/mcp" }

  before do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["MCP_ROLE"] = "admin"
    ENV["DECKO_API_BASE_URL"] = base_url
  end

  after do
    ENV.delete("MCP_API_KEY")
    ENV.delete("DECKO_API_BASE_URL")
    ENV.delete("MCP_ROLE")
  end

  let(:config) { Hyperon::Wiki::Mcp::Config.new }
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

  # encode_card_name keeps + literal but encodes * as %2A
  # So "Article+*type+*default" becomes "Article+%2Atype+%2Adefault"
  let(:encoded_template_name) { "Article+%2Atype+%2Adefault" }
  let(:template_url) { "#{base_url}/cards/#{encoded_template_name}" }

  describe "#get_template" do
    context "when template exists" do
      let(:card_response) do
        {
          "name" => "Article+*type+*default",
          "content" => "<h2>Overview</h2>\n<p>Write your article here.</p>",
          "type" => "Basic",
          "id" => 999
        }
      end

      before do
        stub_request(:get, template_url)
          .with(headers: { "Authorization" => "Bearer #{valid_token}" })
          .to_return(
            status: 200,
            body: card_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns template data with exists: true" do
        result = tools.get_template("Article")

        expect(result["type"]).to eq("Article")
        expect(result["template_card"]).to eq("Article+*type+*default")
        expect(result["content"]).to eq("<h2>Overview</h2>\n<p>Write your article here.</p>")
        expect(result["exists"]).to be true
      end
    end

    context "when template does not exist" do
      before do
        stub_request(:get, template_url)
          .with(headers: { "Authorization" => "Bearer #{valid_token}" })
          .to_return(
            status: 404,
            body: { "error" => "not_found", "message" => "Card not found" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns empty template data with exists: false" do
        result = tools.get_template("Article")

        expect(result["type"]).to eq("Article")
        expect(result["template_card"]).to eq("Article+*type+*default")
        expect(result["content"]).to eq("")
        expect(result["exists"]).to be false
      end
    end
  end

  describe "#set_template" do
    let(:template_content) { "# New Article\n\nWrite content here." }

    context "when template already exists (update)" do
      let(:updated_response) do
        {
          "name" => "Article+*type+*default",
          "content" => template_content,
          "type" => "Basic",
          "id" => 999
        }
      end

      before do
        stub_request(:patch, template_url)
          .with(
            body: { content: template_content }.to_json,
            headers: {
              "Authorization" => "Bearer #{valid_token}",
              "Content-Type" => "application/json"
            }
          )
          .to_return(
            status: 200,
            body: updated_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "patches the existing template card" do
        result = tools.set_template("Article", content: template_content)

        expect(result["name"]).to eq("Article+*type+*default")
        expect(result["content"]).to eq(template_content)
      end
    end

    context "when template does not exist (create)" do
      let(:created_response) do
        {
          "name" => "Article+*type+*default",
          "content" => template_content,
          "type" => "Basic",
          "id" => 1001
        }
      end

      before do
        # PATCH returns 404 (template doesn't exist yet)
        stub_request(:patch, template_url)
          .with(
            body: { content: template_content }.to_json,
            headers: {
              "Authorization" => "Bearer #{valid_token}",
              "Content-Type" => "application/json"
            }
          )
          .to_return(
            status: 404,
            body: { "error" => "not_found", "message" => "Card not found" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        # Falls back to POST to create new card
        stub_request(:post, "#{base_url}/cards")
          .with(
            body: {
              name: "Article+*type+*default",
              type: "Basic",
              content: template_content
            }.to_json,
            headers: {
              "Authorization" => "Bearer #{valid_token}",
              "Content-Type" => "application/json"
            }
          )
          .to_return(
            status: 201,
            body: created_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "creates a new template card after patch 404" do
        result = tools.set_template("Article", content: template_content)

        expect(result["name"]).to eq("Article+*type+*default")
        expect(result["content"]).to eq(template_content)
        expect(result["id"]).to eq(1001)
      end
    end
  end
end
