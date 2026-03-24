# frozen_string_literal: true

require "spec_helper"
require_relative "../support/integration_helpers"

# Integration tests for render_content (convert_content) functionality
#
# These tests verify that:
# - HTML to Markdown conversion works correctly
# - Markdown to HTML conversion works correctly
# - Response format is correct and extractable
# - Error handling works correctly
#
# Run with: INTEGRATION_TEST=true bundle exec rspec spec/integration/render_content_spec.rb
RSpec.describe "Render Content Operations", :integration do
  let(:tools) { Magi::Archive::Mcp::Tools.new }

  before do
    skip "Integration tests disabled (set INTEGRATION_TEST=true to enable)" unless ENV["INTEGRATION_TEST"]
  end

  describe "HTML to Markdown conversion" do
    it "converts simple HTML to Markdown" do
      html_content = "<p>Hello <strong>world</strong></p>"

      result = tools.convert_content(html_content, from: :html, to: :markdown)

      # Should return a hash with markdown key
      expect(result).to be_a(Hash),
        "Expected Hash response, got #{result.class}: #{result.inspect}"

      # Should have markdown key (string or symbol)
      markdown = result["markdown"] || result[:markdown]
      expect(markdown).not_to be_nil,
        "Missing markdown key in response: #{result.keys.inspect}"

      # Markdown should contain the converted text
      expect(markdown).to include("world"),
        "Converted markdown missing expected content: #{markdown}"
    end

    it "converts complex HTML with multiple elements" do
      html_content = <<~HTML
        <h1>Title</h1>
        <p>Paragraph with <em>emphasis</em> and <strong>bold</strong>.</p>
        <ul>
          <li>Item 1</li>
          <li>Item 2</li>
        </ul>
      HTML

      result = tools.convert_content(html_content, from: :html, to: :markdown)

      markdown = result["markdown"] || result[:markdown]
      expect(markdown).not_to be_nil

      # Should contain heading, text, and list markers
      expect(markdown).to include("Title")
      expect(markdown).to match(/emphasis|_emphasis_|\*emphasis\*/)
    end

    it "returns proper format indicator" do
      html_content = "<p>Test</p>"

      result = tools.convert_content(html_content, from: :html, to: :markdown)

      format = result["format"] || result[:format]
      expect(format).to eq("gfm"),
        "Expected format 'gfm', got: #{format}"
    end
  end

  describe "Markdown to HTML conversion" do
    it "converts simple Markdown to HTML" do
      markdown_content = "Hello **world**"

      result = tools.convert_content(markdown_content, from: :markdown, to: :html)

      # Should return a hash with html key
      expect(result).to be_a(Hash),
        "Expected Hash response, got #{result.class}: #{result.inspect}"

      html = result["html"] || result[:html]
      expect(html).not_to be_nil,
        "Missing html key in response: #{result.keys.inspect}"

      # HTML should contain the converted text
      expect(html).to include("world"),
        "Converted HTML missing expected content: #{html}"
    end

    it "converts Markdown with headings and lists" do
      markdown_content = <<~MARKDOWN
        # Title

        Paragraph with *emphasis* and **bold**.

        - Item 1
        - Item 2
      MARKDOWN

      result = tools.convert_content(markdown_content, from: :markdown, to: :html)

      html = result["html"] || result[:html]
      expect(html).not_to be_nil

      # Should contain HTML tags
      expect(html).to include("Title")
    end

    it "returns proper format indicator for HTML" do
      markdown_content = "# Test"

      result = tools.convert_content(markdown_content, from: :markdown, to: :html)

      format = result["format"] || result[:format]
      expect(format).to eq("html"),
        "Expected format 'html', got: #{format}"
    end
  end

  describe "response format consistency" do
    it "always returns a hash with extractable content key" do
      # HTML to Markdown
      html_result = tools.convert_content("<p>Test</p>", from: :html, to: :markdown)
      expect(html_result).to respond_to(:keys),
        "HTML to Markdown result should be hash-like"

      # Extract markdown - try both string and symbol keys
      markdown = html_result["markdown"] || html_result[:markdown]
      expect(markdown).to be_a(String),
        "Markdown value should be a string, got: #{markdown.class}"

      # Markdown to HTML
      md_result = tools.convert_content("**Test**", from: :markdown, to: :html)
      expect(md_result).to respond_to(:keys),
        "Markdown to HTML result should be hash-like"

      # Extract html
      html = md_result["html"] || md_result[:html]
      expect(html).to be_a(String),
        "HTML value should be a string, got: #{html.class}"
    end

    it "does not return raw hash as string representation" do
      # This catches the bug where result.to_s was being used
      result = tools.convert_content("<p>Test</p>", from: :html, to: :markdown)

      markdown = result["markdown"] || result[:markdown]

      # Should not look like a hash string representation
      expect(markdown).not_to match(/^\{.*=>.*\}$/),
        "Markdown looks like raw hash: #{markdown}"
      expect(markdown).not_to include('"markdown"'),
        "Markdown contains hash key: #{markdown}"
    end
  end

  describe "error handling" do
    it "raises error for same source and target format" do
      expect {
        tools.convert_content("test", from: :html, to: :html)
      }.to raise_error(ArgumentError, /same/)
    end

    it "raises error for invalid format" do
      expect {
        tools.convert_content("test", from: :invalid, to: :html)
      }.to raise_error(ArgumentError)
    end
  end

  describe "MCP tool wrapper (render_content)" do
    # These tests verify the MCP tool layer extracts content correctly
    # when used through the server

    it "extracts markdown content from API response" do
      result = tools.convert_content("<h1>Heading</h1>", from: :html, to: :markdown)

      markdown = result["markdown"] || result[:markdown]

      # Should be plain markdown, not wrapped in hash
      expect(markdown).to be_a(String)
      expect(markdown.strip).not_to be_empty
      expect(markdown).not_to start_with("{")
    end

    it "handles GFM format response correctly" do
      # Test with content that might use GFM features
      html_content = "<p>Test with <code>code</code> and a link</p>"

      result = tools.convert_content(html_content, from: :html, to: :markdown)

      markdown = result["markdown"] || result[:markdown]
      expect(markdown).to include("code").or include("`")
    end
  end
end
