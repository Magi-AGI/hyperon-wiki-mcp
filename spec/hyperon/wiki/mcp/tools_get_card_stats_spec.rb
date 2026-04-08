# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "hyperon/wiki/mcp/tools"

RSpec.describe Hyperon::Wiki::Mcp::Tools, "#get_card_stats" do
  let(:base_url) { "https://test.example.com/api/mcp" }

  before do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["MCP_ROLE"] = "user"
    ENV["DECKO_API_BASE_URL"] = base_url
  end

  after do
    ENV.delete("MCP_API_KEY")
    ENV.delete("MCP_ROLE")
    ENV.delete("DECKO_API_BASE_URL")
  end

  let(:config) { Hyperon::Wiki::Mcp::Config.new }
  let(:client) { Hyperon::Wiki::Mcp::Client.new(config) }
  let(:tools) { described_class.new(client) }

  before do
    stub_request(:post, "#{base_url}/auth")
      .to_return(
        status: 201,
        body: { token: "test-jwt-token", role: "user", expires_in: 3600 }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  context "with HTML content" do
    let(:card_name) { "Test Page" }
    let(:html_content) do
      <<~HTML
        <h1>Main Title</h1>
        <p>This is the first paragraph with some text.</p>
        <p>Second paragraph here with <a href="https://example.com">an external link</a>.</p>
        <h2>Section One</h2>
        <p>Content with a [[Wiki Link]] and another [[Second Link]].</p>
        <p>Here is an image: <img src="photo.jpg" alt="A photo"></p>
        <h2>Section Two</h2>
        <p>More content with <a href="/page">internal link</a>.</p>
      HTML
    end

    before do
      stub_request(:get, "#{base_url}/cards/Test%20Page")
        .with(headers: { "Authorization" => "Bearer test-jwt-token" })
        .to_return(
          status: 200,
          body: {
            "name" => card_name,
            "content" => html_content,
            "type" => "RichText",
            "updated_at" => "2026-04-01T12:00:00Z"
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, "#{base_url}/cards/Test%20Page/outline")
        .with(headers: { "Authorization" => "Bearer test-jwt-token" })
        .to_return(
          status: 200,
          body: {
            "card" => card_name,
            "type" => "RichText",
            "content_length" => html_content.length,
            "headings" => [
              { "level" => 1, "text" => "Main Title", "format" => "html", "position" => 0 },
              { "level" => 2, "text" => "Section One", "format" => "html", "position" => 150 },
              { "level" => 2, "text" => "Section Two", "format" => "html", "position" => 300 }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "returns correct card metadata" do
      result = tools.get_card_stats(card_name)

      expect(result["card"]).to eq("Test Page")
      expect(result["type"]).to eq("RichText")
      expect(result["updated_at"]).to eq("2026-04-01T12:00:00Z")
    end

    it "counts sections from outline headings" do
      result = tools.get_card_stats(card_name)

      expect(result["stats"]["section_count"]).to eq(3)
    end

    it "counts words" do
      result = tools.get_card_stats(card_name)

      expect(result["stats"]["word_count"]).to be > 0
    end

    it "counts characters" do
      result = tools.get_card_stats(card_name)

      expect(result["stats"]["char_count"]).to eq(html_content.length)
    end

    it "counts wiki links" do
      result = tools.get_card_stats(card_name)

      expect(result["stats"]["wiki_links"]).to eq(2)
    end

    it "counts HTML links as external" do
      result = tools.get_card_stats(card_name)

      expect(result["stats"]["external_links"]).to eq(2)
    end

    it "counts total links" do
      result = tools.get_card_stats(card_name)

      # 2 wiki + 2 html
      expect(result["stats"]["link_count"]).to eq(4)
    end

    it "counts HTML images" do
      result = tools.get_card_stats(card_name)

      expect(result["stats"]["image_count"]).to eq(1)
    end

    it "counts paragraphs from <p> tags" do
      result = tools.get_card_stats(card_name)

      expect(result["stats"]["paragraph_count"]).to be >= 4
    end
  end

  context "with Markdown content" do
    let(:card_name) { "Markdown Card" }
    let(:md_content) do
      <<~MARKDOWN
        # Introduction

        This is the first paragraph with some words.

        Here is a [link to example](https://example.com) and a ![screenshot](img.png).

        ## Details

        More text with [[Wiki Reference]] and [another link](https://other.com).

        And another ![diagram](diagram.png) image.
      MARKDOWN
    end

    before do
      stub_request(:get, "#{base_url}/cards/Markdown%20Card")
        .with(headers: { "Authorization" => "Bearer test-jwt-token" })
        .to_return(
          status: 200,
          body: {
            "name" => card_name,
            "content" => md_content,
            "type" => "Markdown",
            "updated_at" => "2026-03-15T08:30:00Z"
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, "#{base_url}/cards/Markdown%20Card/outline")
        .with(headers: { "Authorization" => "Bearer test-jwt-token" })
        .to_return(
          status: 200,
          body: {
            "card" => card_name,
            "type" => "Markdown",
            "content_length" => md_content.length,
            "headings" => [
              { "level" => 1, "text" => "Introduction", "format" => "markdown", "position" => 0 },
              { "level" => 2, "text" => "Details", "format" => "markdown", "position" => 120 }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "counts markdown links as external" do
      result = tools.get_card_stats(card_name)

      expect(result["stats"]["external_links"]).to eq(2)
    end

    it "counts wiki links in markdown content" do
      result = tools.get_card_stats(card_name)

      expect(result["stats"]["wiki_links"]).to eq(1)
    end

    it "counts markdown images" do
      result = tools.get_card_stats(card_name)

      expect(result["stats"]["image_count"]).to eq(2)
    end

    it "counts sections from outline" do
      result = tools.get_card_stats(card_name)

      expect(result["stats"]["section_count"]).to eq(2)
    end

    it "counts paragraphs separated by blank lines" do
      result = tools.get_card_stats(card_name)

      expect(result["stats"]["paragraph_count"]).to be >= 3
    end

    it "returns correct type" do
      result = tools.get_card_stats(card_name)

      expect(result["type"]).to eq("Markdown")
    end
  end

  context "with empty card" do
    let(:card_name) { "Empty Card" }

    before do
      stub_request(:get, "#{base_url}/cards/Empty%20Card")
        .with(headers: { "Authorization" => "Bearer test-jwt-token" })
        .to_return(
          status: 200,
          body: {
            "name" => card_name,
            "content" => "",
            "type" => "Basic",
            "updated_at" => "2026-01-01T00:00:00Z"
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, "#{base_url}/cards/Empty%20Card/outline")
        .with(headers: { "Authorization" => "Bearer test-jwt-token" })
        .to_return(
          status: 200,
          body: {
            "card" => card_name,
            "type" => "Basic",
            "content_length" => 0,
            "headings" => []
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "returns zero for all stats" do
      result = tools.get_card_stats(card_name)

      expect(result["stats"]["word_count"]).to eq(0)
      expect(result["stats"]["char_count"]).to eq(0)
      expect(result["stats"]["section_count"]).to eq(0)
      expect(result["stats"]["paragraph_count"]).to eq(0)
      expect(result["stats"]["link_count"]).to eq(0)
      expect(result["stats"]["image_count"]).to eq(0)
      expect(result["stats"]["wiki_links"]).to eq(0)
      expect(result["stats"]["external_links"]).to eq(0)
    end

    it "returns correct card metadata" do
      result = tools.get_card_stats(card_name)

      expect(result["card"]).to eq("Empty Card")
      expect(result["type"]).to eq("Basic")
      expect(result["updated_at"]).to eq("2026-01-01T00:00:00Z")
    end
  end

  context "when outline endpoint fails" do
    let(:card_name) { "Special Card" }

    before do
      stub_request(:get, "#{base_url}/cards/Special%20Card")
        .with(headers: { "Authorization" => "Bearer test-jwt-token" })
        .to_return(
          status: 200,
          body: {
            "name" => card_name,
            "content" => "<h2>Title</h2><p>Some content here.</p>",
            "type" => "RichText",
            "updated_at" => "2026-02-20T10:00:00Z"
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, "#{base_url}/cards/Special%20Card/outline")
        .with(headers: { "Authorization" => "Bearer test-jwt-token" })
        .to_return(status: 500, body: "Internal Server Error")
    end

    it "returns section_count of 0 when outline fails" do
      result = tools.get_card_stats(card_name)

      expect(result["stats"]["section_count"]).to eq(0)
    end

    it "still computes other stats correctly" do
      result = tools.get_card_stats(card_name)

      expect(result["stats"]["word_count"]).to be > 0
      expect(result["stats"]["char_count"]).to be > 0
      expect(result["card"]).to eq("Special Card")
      expect(result["type"]).to eq("RichText")
    end
  end
end
