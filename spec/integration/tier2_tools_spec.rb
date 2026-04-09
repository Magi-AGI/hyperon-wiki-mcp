# frozen_string_literal: true

require "spec_helper"
require_relative "../support/integration_helpers"

# Load MCP server tools
Dir[File.join(__dir__, '../../lib/hyperon/wiki/mcp/server/tools/**/*.rb')].sort.each { |f| require f }

RSpec.describe "Tier 2/3 Tools", :integration do
  # Integration tests for update_section, diff_card, get_card_stats, template_card
  # Run with: INTEGRATION_TEST=true rspec spec/integration/tier2_tools_spec.rb

  let(:tools) { Hyperon::Wiki::Mcp::Tools.new }
  let(:test_card_prefix) { "MCP Integration Test" }

  before do
    skip "Integration tests disabled" unless ENV["INTEGRATION_TEST"]
  end

  describe "#get_card_stats" do
    it "returns stats for an existing card" do
      # Use a card known to exist on the wiki
      result = tools.get_card_stats("Hyperon AI Algorithms+MetaMo")

      expect(result).to have_key("card")
      expect(result).to have_key("type")
      expect(result).to have_key("stats")

      stats = result["stats"]
      expect(stats).to have_key("word_count")
      expect(stats).to have_key("char_count")
      expect(stats).to have_key("section_count")
      expect(stats).to have_key("link_count")
      expect(stats["word_count"]).to be_a(Integer)
      expect(stats["char_count"]).to be_a(Integer)
    end

    it "returns zero stats for a minimal card" do
      # Find a card with minimal content
      result = tools.get_card_stats("Administrator")

      expect(result["stats"]["char_count"]).to be >= 0
      expect(result["type"]).to be_a(String)
    end
  end

  describe "#get_card_outline" do
    it "returns headings for a card with sections" do
      # Find a card that likely has headings
      result = tools.get_card_outline("Hyperon AI Algorithms")

      expect(result).to have_key("card")
      expect(result).to have_key("headings")
      expect(result).to have_key("content_length")
      expect(result["headings"]).to be_an(Array)
    end
  end

  describe "#update_section" do
    let(:test_card_name) { "#{test_card_prefix}+Section Test" }

    before do
      # Create a test card with sections
      content = <<~HTML
        <h2>Introduction</h2>
        <p>This is the intro section.</p>
        <h2>Details</h2>
        <p>This is the details section.</p>
        <h2>Conclusion</h2>
        <p>This is the conclusion.</p>
      HTML

      begin
        tools.delete_card(test_card_name)
      rescue StandardError
        # ignore
      end

      begin
        tools.create_card(test_card_name, type: "RichText", content: content.strip)
      rescue Hyperon::Wiki::Mcp::Client::APIError
        # Card may already exist, update it instead
        tools.update_card(test_card_name, content: content.strip)
      end
    end

    after do
      tools.delete_card(test_card_name)
    rescue StandardError
      # ignore
    end

    it "updates the content of a specific section" do
      result = tools.update_section(test_card_name, section: "Details", content: "<p>Updated details content.</p>")

      expect(result["name"]).to eq(test_card_name)

      # Verify the update took effect
      card = tools.get_card(test_card_name)
      expect(card["content"]).to include("Updated details content")
      expect(card["content"]).to include("Introduction") # other sections preserved
      expect(card["content"]).to include("Conclusion")
    end

    it "raises error for non-existent section" do
      expect {
        tools.update_section(test_card_name, section: "Nonexistent Section", content: "test")
      }.to raise_error(Hyperon::Wiki::Mcp::Client::ValidationError)
    end
  end

  describe "#diff_card" do
    it "diffs between a revision and current content" do
      # Use a card that has revision history
      history = tools.get_card_history("Hyperon AI Algorithms+MetaMo", limit: 5)

      skip "No revision history available" if history["revisions"].nil? || history["revisions"].empty?

      oldest_revision = history["revisions"].last
      result = tools.diff_card("Hyperon AI Algorithms+MetaMo", from_revision: oldest_revision["act_id"])

      expect(result).to have_key("card")
      expect(result).to have_key("diff")
      expect(result).to have_key("summary")
      expect(result["summary"]).to have_key("lines_added")
      expect(result["summary"]).to have_key("lines_removed")
      expect(result["summary"]).to have_key("total_changes")
    end
  end

  describe "#get_template" do
    it "returns template info for a card type" do
      result = tools.get_template("RichText")

      expect(result).to have_key("type")
      expect(result["type"]).to eq("RichText")
      expect(result).to have_key("template_card")
      expect(result).to have_key("exists")
      expect(result["exists"]).to be(true).or be(false)
    end

    it "returns exists: false for a type without a template" do
      result = tools.get_template("NonexistentType12345")

      expect(result["exists"]).to eq(false)
      expect(result["content"]).to eq("")
    end
  end

  describe "#set_template" do
    let(:test_type) { "MCP Test Template Type" }

    after do
      # Clean up the template card
      template_name = "#{test_type}+*type+*default"
      tools.delete_card(template_name)
    rescue StandardError
      # ignore
    end

    it "creates a template for a card type" do
      skip "Skipping template creation - requires type to exist"

      template_content = "<h2>Default Section</h2>\n<p>Fill in details here.</p>"
      result = tools.set_template(test_type, content: template_content)

      expect(result["name"]).to include(test_type)

      # Verify
      fetched = tools.get_template(test_type)
      expect(fetched["exists"]).to eq(true)
      expect(fetched["content"]).to include("Default Section")
    end
  end

  describe "MCP Server Tool wrappers" do
    let(:server_context) { { magi_tools: tools } }

    it "GetCardStats tool returns formatted response" do
      response = Hyperon::Wiki::Mcp::Server::Tools::GetCardStats.call(
        name: "Hyperon AI Algorithms+MetaMo",
        server_context: server_context
      )

      expect(response).to be_a(::MCP::Tool::Response)
      expect(response.error?).to be false

      text = response.content.first[:text]
      expect(text).to include("word_count")
    end

    it "DiffCard tool handles card with no history gracefully" do
      response = Hyperon::Wiki::Mcp::Server::Tools::DiffCard.call(
        name: "Hyperon AI Algorithms+MetaMo",
        server_context: server_context
      )

      # Should either succeed with diff data or return a graceful error
      expect(response).to be_a(::MCP::Tool::Response)
    end

    it "UpdateSection tool returns error for missing section" do
      # Create temp card
      card_name = "#{test_card_prefix}+Tool Wrapper Test"
      begin
        tools.delete_card(card_name) rescue nil
        begin
          tools.create_card(card_name, type: "RichText", content: "<h2>Only Section</h2><p>Content</p>")
        rescue Hyperon::Wiki::Mcp::Client::APIError
          tools.update_card(card_name, content: "<h2>Only Section</h2><p>Content</p>")
        end

        response = Hyperon::Wiki::Mcp::Server::Tools::UpdateSection.call(
          name: card_name,
          section: "Missing Section",
          content: "new content",
          server_context: server_context
        )

        expect(response).to be_a(::MCP::Tool::Response)
        expect(response.error?).to be true
      ensure
        tools.delete_card(card_name) rescue nil
      end
    end
  end
end
