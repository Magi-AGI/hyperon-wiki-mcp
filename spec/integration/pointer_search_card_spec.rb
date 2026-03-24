# frozen_string_literal: true

require "spec_helper"
require_relative "../support/integration_helpers"

# Load MCP server tools
Dir[File.join(__dir__, '../../lib/magi/archive/mcp/server/tools/**/*.rb')].sort.each { |f| require f }

RSpec.describe "Pointer and Search Card Handling", :integration do
  # Integration tests for get_card tool with Pointer and Search card types
  # Tests the helpful notes added to guide AI agents
  #
  # Run with: INTEGRATION_TEST=true rspec spec/integration/pointer_search_card_spec.rb

  let(:tools) { Magi::Archive::Mcp::Tools.new }

  before do
    skip "Integration tests disabled" unless ENV["INTEGRATION_TEST"]
  end

  describe "Pointer card detection" do
    it "identifies Pointer cards and suggests using list_children" do
      # Find a known Pointer card on the wiki
      # We'll search for cards of type "Pointer"
      search_result = tools.search_cards(type: "Pointer", limit: 1)

      skip "No Pointer cards available for testing" if search_result["cards"].empty?

      pointer_card_name = search_result["cards"].first["name"]

      # Use the get_card tool from lib/magi/archive/mcp/server/tools/get_card.rb
      # This returns an MCP::Tool::Response
      response = Magi::Archive::Mcp::Server::Tools::GetCard.call(
        name: pointer_card_name,
        with_children: false,
        server_context: { magi_tools: tools }
      )

      # Parse JSON response and extract text field
      json_response = JSON.parse(response.content.first[:text])
      text = json_response["text"]

      # Verify the helpful note is present
      expect(text).to include("**Type:** Pointer")
      expect(text).to include("**Note:** This is a Pointer card")
      expect(text).to include("Use list_children to see referenced cards")
      expect(text).to include("with_children=true")
    end

    it "provides helpful context when fetching Pointer card without children" do
      # Find a Pointer card
      search_result = tools.search_cards(type: "Pointer", limit: 1)
      skip "No Pointer cards available for testing" if search_result["cards"].empty?

      pointer_card_name = search_result["cards"].first["name"]

      response = Magi::Archive::Mcp::Server::Tools::GetCard.call(
        name: pointer_card_name,
        with_children: false,
        server_context: { magi_tools: tools }
      )

      # Parse JSON response and extract text field
      json_response = JSON.parse(response.content.first[:text])
      text = json_response["text"]

      # Should have the note but NOT have children section
      expect(text).to include("Use list_children to see referenced cards")
      expect(text).not_to include("## Children")
    end

    it "includes children when requested for Pointer card" do
      # Find a Pointer card
      search_result = tools.search_cards(type: "Pointer", limit: 1)
      skip "No Pointer cards available for testing" if search_result["cards"].empty?

      pointer_card_name = search_result["cards"].first["name"]

      response = Magi::Archive::Mcp::Server::Tools::GetCard.call(
        name: pointer_card_name,
        with_children: true,
        server_context: { magi_tools: tools }
      )

      # Parse JSON response and extract text field
      json_response = JSON.parse(response.content.first[:text])
      text = json_response["text"]

      # Should have both the note AND children if the card has any
      expect(text).to include("**Note:** This is a Pointer card")

      # Verify children section exists if card has children
      card_data = tools.get_card(pointer_card_name, with_children: true)
      if card_data["children"]&.any?
        expect(text).to include("## Children")
      end
    end
  end

  describe "Search card detection" do
    it "identifies Search cards and explains query behavior" do
      # Find a known Search card on the wiki
      search_result = tools.search_cards(type: "Search", limit: 1)

      skip "No Search cards available for testing" if search_result["cards"].empty?

      search_card_name = search_result["cards"].first["name"]

      response = Magi::Archive::Mcp::Server::Tools::GetCard.call(
        name: search_card_name,
        with_children: false,
        server_context: { magi_tools: tools }
      )

      # Parse JSON response and extract text field
      json_response = JSON.parse(response.content.first[:text])
      text = json_response["text"]

      # Verify the helpful note is present
      expect(text).to include("**Type:** Search")
      expect(text).to include("**Note:** This is a Search card")
      expect(text).to include("Content shows the search query")
      expect(text).to include("Results are dynamically generated")
    end

    it "explains that Search card content is a query, not results" do
      search_result = tools.search_cards(type: "Search", limit: 1)
      skip "No Search cards available for testing" if search_result["cards"].empty?

      search_card_name = search_result["cards"].first["name"]

      response = Magi::Archive::Mcp::Server::Tools::GetCard.call(
        name: search_card_name,
        with_children: false,
        server_context: { magi_tools: tools }
      )

      # Parse JSON response and extract text field
      json_response = JSON.parse(response.content.first[:text])
      text = json_response["text"]

      # The note should clarify that content is a query
      expect(text).to include("Content shows the search query")
      expect(text).to include("dynamically generated when viewed on wiki")
    end
  end

  describe "Regular card (non-Pointer, non-Search)" do
    it "does not show special notes for regular cards" do
      # Find a regular card (not Pointer or Search)
      search_result = tools.search_cards(type: "RichText", limit: 1)

      skip "No RichText cards available for testing" if search_result["cards"].empty?

      regular_card_name = search_result["cards"].first["name"]

      response = Magi::Archive::Mcp::Server::Tools::GetCard.call(
        name: regular_card_name,
        with_children: false,
        server_context: { magi_tools: tools }
      )

      # Parse JSON response and extract text field
      json_response = JSON.parse(response.content.first[:text])
      text = json_response["text"]

      # Should NOT have Pointer or Search notes
      expect(text).not_to include("**Note:** This is a Pointer card")
      expect(text).not_to include("**Note:** This is a Search card")
      expect(text).not_to include("Use list_children to see referenced cards")
      expect(text).not_to include("Results are dynamically generated")
    end
  end

  describe "Tool description clarity" do
    it "describes Pointer card behavior in tool description" do
      # The GetCard tool class should have an updated description
      description = Magi::Archive::Mcp::Server::Tools::GetCard.description

      expect(description).to include("Pointer cards contain references")
      expect(description).to include("list_children")
    end

    it "describes Search card behavior in tool description" do
      description = Magi::Archive::Mcp::Server::Tools::GetCard.description

      expect(description).to include("Search cards contain dynamic queries")
      expect(description).to include("content shows query, not results")
    end

    it "mentions underscore usage for exact name matches" do
      description = Magi::Archive::Mcp::Server::Tools::GetCard.description

      expect(description).to include("underscores for exact name matches")
    end
  end
end
