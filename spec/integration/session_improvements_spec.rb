# frozen_string_literal: true

require "spec_helper"
require_relative "../support/integration_helpers"

# Load MCP server tools
Dir[File.join(__dir__, '../../lib/magi/archive/mcp/server/tools/**/*.rb')].sort.each { |f| require f }

RSpec.describe "Session Improvements", :integration do
  # Integration tests for features added in recent session:
  # - Virtual card detection
  # - Trash filtering in list_children
  # - search_and_replace functionality
  # - get_site_context
  #
  # Run with: INTEGRATION_TEST=true rspec spec/integration/session_improvements_spec.rb

  let(:tools) { Magi::Archive::Mcp::Tools.new }

  before do
    skip "Integration tests disabled" unless ENV["INTEGRATION_TEST"]
  end

  describe "Virtual card detection" do
    it "detects virtual cards and provides warning notes" do
      # Search for cards that might be virtual (empty junction cards)
      # These are typically simple names with minimal content
      search_result = tools.search_cards(limit: 50)

      skip "No cards available for testing" if search_result["cards"].empty?

      # Find a card that might be virtual by checking for minimal content
      cards_to_check = search_result["cards"].first(10)

      cards_to_check.each do |card|
        full_card = tools.get_card(card["name"])

        # Check if card is marked as virtual
        if full_card["virtual_card"] == true
          # Use the GetCard MCP tool to verify warning is shown
          response = Magi::Archive::Mcp::Server::Tools::GetCard.call(
            name: card["name"],
            with_children: false,
            server_context: { magi_tools: tools }
          )

          # Parse JSON response and extract text field
          json_response = JSON.parse(response.content.first[:text])
          text = json_response["text"]

          # Verify virtual card warning is present
          expect(text).to include("**Warning:** This is a virtual/junction card")
          expect(text).to include("actual content is likely in a compound child card")
          expect(text).to include("Search for cards containing")

          # Virtual cards should mention looking for full hierarchical paths
          expect(text).to match(/Example:.*\+/)

          break # Found one, no need to check more
        end
      end
    end

    it "explains the compound card pattern for virtual cards" do
      # Virtual cards should have children with compound names
      # Let's find a simple card and check if it has compound children

      # Try to find a simple game name card
      games_result = tools.search_cards(q: "Games", search_in: "name", limit: 10)

      skip "No Games cards found" if games_result["cards"].empty?

      # Look for a simple card name that might be virtual
      simple_cards = games_result["cards"].select do |card|
        # Simple names without + are more likely to be virtual
        card["name"].count("+") <= 1
      end

      skip "No simple cards found to test" if simple_cards.empty?

      simple_cards.first(3).each do |card|
        full_card = tools.get_card(card["name"])

        if full_card["virtual_card"] == true
          # Verify the explanation mentions compound cards
          response = Magi::Archive::Mcp::Server::Tools::GetCard.call(
            name: card["name"],
            server_context: { magi_tools: tools }
          )

          # Parse JSON response and extract text field
          json_response = JSON.parse(response.content.first[:text])
          text = json_response["text"]

          # Should explain about compound child cards
          expect(text).to include("full hierarchical path")
          expect(text).to include("actual content")

          break
        end
      end
    end
  end

  describe "Trash filtering in list_children" do
    it "excludes deleted cards from list_children results" do
      # Find a parent card with children
      # Home is a good candidate as it typically has children
      result = tools.list_children("Home", limit: 50)

      skip "Home card has no children" if result["children"].nil? || result["children"].empty?

      children = result["children"]

      # Verify none of the returned children are deleted/trashed
      # We can verify this by attempting to fetch each child - deleted cards won't be accessible
      children.first(5).each do |child|
        child_name = child["name"]

        # This should succeed for non-deleted cards
        expect { tools.get_card(child_name) }.not_to raise_error

        # Verify the card is not marked as deleted
        child_card = tools.get_card(child_name)
        expect(child_card["trash"]).to be_falsy
      end
    end

    it "filters trash from nested children queries" do
      # Test with depth > 1 to verify trash filtering works recursively
      # Find a card that likely has nested children
      games_card = tools.get_card("Games", with_children: true)

      skip "Games card has no children" unless games_card["children"]&.any?

      # Get children with depth (if supported)
      children_result = tools.list_children("Games", limit: 20)

      skip "No children found" if children_result["children"].nil? || children_result["children"].empty?

      # Verify all returned children are accessible (not trashed)
      children_result["children"].first(5).each do |child|
        expect { tools.get_card(child["name"]) }.not_to raise_error
      end
    end

    it "handles cards with only deleted children gracefully" do
      # This tests the edge case where a parent only has deleted children
      # In this case, list_children should return an empty array or minimal count

      # We can't easily create this scenario in integration tests,
      # but we can verify the response structure is valid
      result = tools.list_children("Home", limit: 1)

      expect(result).to be_a(Hash)
      expect(result).to have_key("parent")
      expect(result).to have_key("children")
      expect(result["children"]).to be_an(Array)
    end
  end

  describe "get_site_context integration" do
    it "returns comprehensive wiki context" do
      context = tools.get_site_context

      # Verify structure
      expect(context).to be_a(Hash)
      expect(context).to have_key(:wiki_name)
      expect(context).to have_key(:wiki_url)
      expect(context).to have_key(:hierarchy)
      expect(context).to have_key(:guidelines)
      expect(context).to have_key(:common_patterns)
      expect(context).to have_key(:helpful_cards)
    end

    it "provides accurate hierarchy information" do
      context = tools.get_site_context
      hierarchy = context[:hierarchy]

      # Verify major sections exist
      expect(hierarchy).to have_key("Home")
      expect(hierarchy).to have_key("Games")

      # Verify Games section has game details
      games = hierarchy["Games"]
      expect(games[:games]).to be_an(Array)
      expect(games[:games]).not_to be_empty
    end

    it "includes helpful navigation cards that exist" do
      context = tools.get_site_context
      helpful_cards = context[:helpful_cards]

      expect(helpful_cards).to be_an(Array)
      expect(helpful_cards).not_to be_empty

      # Verify at least one of the helpful cards exists
      first_card_path = helpful_cards.first.split(" - ").first.strip.delete_prefix("`").delete_suffix("`")

      expect { tools.get_card(first_card_path) }.not_to raise_error
    end

    it "provides guidelines for AI agents" do
      context = tools.get_site_context
      guidelines = context[:guidelines]

      # Verify all guideline categories exist
      expect(guidelines).to have_key(:naming_conventions)
      expect(guidelines).to have_key(:content_placement)
      expect(guidelines).to have_key(:content_structure)
      expect(guidelines).to have_key(:special_cards)
      expect(guidelines).to have_key(:best_practices)

      # Verify special cards mentions key card types
      special_cards = guidelines[:special_cards]
      expect(special_cards.join(" ")).to include("Virtual cards")
      expect(special_cards.join(" ")).to include("Deleted cards")
      expect(special_cards.join(" ")).to include("+GM+AI")
    end
  end

  describe "GetSiteContext MCP tool" do
    it "returns formatted site context" do
      response = Magi::Archive::Mcp::Server::Tools::GetSiteContext.call(
        server_context: { magi_tools: tools }
      )

      expect(response).to be_a(::MCP::Tool::Response)
      expect(response.content).to be_an(Array)
      expect(response.content.first[:type]).to eq("text")

      text = response.content.first[:text]

      # Verify markdown formatting
      expect(text).to include("# Magi Archive - Site Context")
      expect(text).to include("## Wiki Hierarchy")
      expect(text).to include("## Content Guidelines")
      expect(text).to include("## Common Naming Patterns")
      expect(text).to include("## Helpful Navigation Cards")
    end

    it "includes all major sections in formatted output" do
      response = Magi::Archive::Mcp::Server::Tools::GetSiteContext.call(
        server_context: { magi_tools: tools }
      )

      text = response.content.first[:text]

      # Verify hierarchy sections
      expect(text).to include("### Home")
      expect(text).to include("### Games")
      expect(text).to include("### Business Plan")
      expect(text).to include("### Neoterics")

      # Verify guidelines sections
      expect(text).to include("### Naming Conventions")
      expect(text).to include("### Content Placement")
      expect(text).to include("### Content Structure")
      expect(text).to include("### Special Card Types")
      expect(text).to include("### Best Practices")
    end

    it "formats Butterfly Galaxii game details correctly" do
      response = Magi::Archive::Mcp::Server::Tools::GetSiteContext.call(
        server_context: { magi_tools: tools }
      )

      text = response.content.first[:text]

      # Butterfly Galaxii should be prominently featured
      expect(text).to include("#### Butterfly Galaxii")
      expect(text).to include("**Path:** `Games+Butterfly Galaxii`")
      expect(text).to include("**Key Areas:**")
    end

    it "includes deleted card restoration guidance" do
      response = Magi::Archive::Mcp::Server::Tools::GetSiteContext.call(
        server_context: { magi_tools: tools }
      )

      text = response.content.first[:text]

      # Should mention deleted cards and restoration process
      expect(text).to include("Deleted cards")
      expect(text).to include("trash")
      expect(text).to include("history")
    end
  end

  describe "search_and_replace integration" do
    # Note: This is a dry-run only test to avoid modifying production data
    it "performs dry run search and replace" do
      # Find some content to search for
      # Let's search for a common word
      result = tools.search_and_replace(
        "the",
        "THE",
        limit: 5,
        dry_run: true
      )

      # Verify dry run structure
      expect(result).to be_a(Hash)
      expect(result).to have_key(:preview) || have_key(:message)

      if result[:preview]
        expect(result[:preview]).to be_an(Array)
        expect(result[:total_cards]).to be_a(Integer) if result[:total_cards]
      end

      # Should have message about dry run
      expect(result[:message]).to include("Dry run") if result[:message]
    end

    it "provides preview of changes in dry run" do
      # Search for something specific to get fewer results
      result = tools.search_and_replace(
        "Games",
        "GAMES",
        limit: 3,
        card_name_pattern: "Games",
        dry_run: true
      )

      # If matches found, should show preview
      if result[:preview]&.any?
        preview_item = result[:preview].first
        expect(preview_item).to have_key(:card_name)
        expect(preview_item).to have_key(:changes)
      end
    end

    it "handles no matches gracefully" do
      # Search for something that won't match
      result = tools.search_and_replace(
        "xyzzy123nonexistent",
        "replacement",
        dry_run: true
      )

      expect(result[:message]).to include("No matching cards")
    end
  end

  describe "Trash filtering in search_cards" do
    it "excludes deleted cards from search_cards results" do
      # Search for all cards (or a common term)
      result = tools.search_cards(limit: 100)

      skip "No cards found" if result["cards"].nil? || result["cards"].empty?

      # Verify none of the returned cards are deleted/trashed
      # We can verify this by checking that each card is accessible
      result["cards"].first(10).each do |card|
        card_name = card["name"]

        # This should succeed for non-deleted cards
        expect { tools.get_card(card_name) }.not_to raise_error

        # Verify the card is not marked as deleted
        full_card = tools.get_card(card_name)
        card_data = full_card["card"] || full_card
        expect(card_data["trash"]).to be_falsy
      end
    end

    it "filters trashed cards when searching by query" do
      # Search for a common term
      result = tools.search_cards(q: "the", search_in: "content", limit: 50)

      skip "No cards found" if result["cards"].nil? || result["cards"].empty?

      # Check that all returned cards are not trashed
      result["cards"].first(5).each do |card|
        full_card = tools.get_card(card["name"])
        card_data = full_card["card"] || full_card
        expect(card_data["trash"]).to be_falsy
      end
    end

    it "filters trashed cards when filtering by type" do
      # Search for a specific type
      result = tools.search_cards(type: "Basic", limit: 20)

      skip "No Basic cards found" if result["cards"].nil? || result["cards"].empty?

      # Verify all returned cards are not trashed
      result["cards"].first(5).each do |card|
        full_card = tools.get_card(card["name"])
        card_data = full_card["card"] || full_card
        expect(card_data["trash"]).to be_falsy
      end
    end
  end
end
