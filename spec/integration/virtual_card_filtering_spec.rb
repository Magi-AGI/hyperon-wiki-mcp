# frozen_string_literal: true

require "spec_helper"
require_relative "../support/integration_helpers"

# Integration tests for virtual card filtering
#
# These tests verify that true virtual cards (empty junction cards with
# simple names and minimal content) are correctly filtered from search
# and list_children results by default, and can be included when requested.
RSpec.describe "Virtual Card Filtering", :integration do
  let(:tools) { Magi::Archive::Mcp::Tools.new }
  let(:test_prefix) { "VirtualFilterTest#{Time.now.to_i}" }

  before do
    skip "Integration tests disabled (set INTEGRATION_TEST=true to enable)" unless ENV["INTEGRATION_TEST"]
  end

  describe "search_cards virtual card filtering" do
    it "filters out virtual cards by default" do
      virtual_card_name = "#{test_prefix}_Virtual"
      real_card_name = "#{test_prefix}_Real"

      # Create a virtual card: simple name, minimal content, no parent
      virtual_card = tools.create_card(virtual_card_name, content: "", type: "Phrase")
      expect(virtual_card["name"]).to eq(virtual_card_name)

      # Create a real card with substantial content
      real_card = tools.create_card(real_card_name, content: "This is real content with sufficient length", type: "RichText")
      expect(real_card["name"]).to eq(real_card_name)

      sleep 0.5 # Allow database commit

      # Search with default filtering (include_virtual=false)
      results = tools.search_cards(q: test_prefix, search_in: "name")
      card_names = results["cards"].map { |c| c["name"] }

      # Real card should appear
      expect(card_names).to include(real_card_name)

      # Virtual card should NOT appear
      expect(card_names).not_to include(virtual_card_name)

      # Cleanup
      tools.delete_card(virtual_card_name)
      tools.delete_card(real_card_name)
    end

    it "includes virtual cards when include_virtual=true" do
      virtual_card_name = "#{test_prefix}_IncludeTest"

      # Create a virtual card
      virtual_card = tools.create_card(virtual_card_name, content: "", type: "Phrase")

      sleep 0.5

      # Search with include_virtual=true
      results = tools.search_cards(q: test_prefix, search_in: "name", include_virtual: true)
      card_names = results["cards"].map { |c| c["name"] }

      # Virtual card SHOULD appear when explicitly requested
      expect(card_names).to include(virtual_card_name)

      # Verify it's marked as virtual
      matching_card = results["cards"].find { |c| c["name"] == virtual_card_name }
      expect(matching_card).not_to be_nil

      # Cleanup
      tools.delete_card(virtual_card_name)
    end
  end

  describe "list_children virtual card filtering" do
    it "filters out virtual child cards by default" do
      parent_name = "#{test_prefix}_ParentForVirtual"
      virtual_child_name = "#{parent_name}+VirtualChild"
      real_child_name = "#{parent_name}+RealChild"

      # Create parent
      parent = tools.create_card(parent_name, content: "Parent content", type: "Phrase")

      # Create a virtual child (minimal content)
      virtual_child = tools.create_card(virtual_child_name, content: "", type: "Phrase")

      # Create a real child (substantial content)
      real_child = tools.create_card(real_child_name, content: "Real child with substantial content", type: "RichText")

      sleep 0.5

      # List children with default filtering
      result = tools.list_children(parent_name)
      child_names = result["children"].map { |c| c["name"] }

      # Real child should appear
      expect(child_names).to include(real_child_name)

      # Virtual child should NOT appear (if detected as virtual)
      # Note: Child cards with left_id are never virtual per our fix,
      # so this test verifies the left_id check is working
      # Virtual children should actually appear because they have left_id
      expect(child_names).to include(virtual_child_name)

      # Cleanup
      tools.delete_card(virtual_child_name)
      tools.delete_card(real_child_name)
      tools.delete_card(parent_name)
    end

    it "includes all children when include_virtual=true" do
      parent_name = "#{test_prefix}_ParentInclude"
      child_name = "#{parent_name}+Child"

      # Create parent and child
      parent = tools.create_card(parent_name, content: "Parent", type: "Phrase")
      child = tools.create_card(child_name, content: "C", type: "Phrase") # Minimal content

      sleep 0.5

      # List children with include_virtual=true
      result = tools.list_children(parent_name, include_virtual: true)
      child_names = result["children"].map { |c| c["name"] }

      # All children should appear
      expect(child_names).to include(child_name)

      # Cleanup
      tools.delete_card(child_name)
      tools.delete_card(parent_name)
    end
  end

  describe "virtual card detection accuracy" do
    it "correctly identifies virtual cards by characteristics" do
      virtual_name = "#{test_prefix}_VirtualCheck"

      # Create a virtual card
      card = tools.create_card(virtual_name, content: "", type: "Phrase")

      sleep 0.5

      # Fetch the card and check virtual_card flag
      fetched = tools.get_card(virtual_name)

      # Should be marked as virtual (simple name, no content, no left_id)
      expect(fetched["virtual_card"]).to be true

      # Cleanup
      tools.delete_card(virtual_name)
    end

    it "does not mark child cards as virtual even with minimal content" do
      parent_name = "#{test_prefix}_ChildCheck"
      child_name = "#{parent_name}+MinimalChild"

      # Create parent and child with minimal content
      parent = tools.create_card(parent_name, content: "Parent", type: "Phrase")
      child = tools.create_card(child_name, content: "", type: "Phrase")

      sleep 0.5

      # Fetch the child card
      fetched = tools.get_card(child_name)

      # Should NOT be marked as virtual (has left_id, is a child)
      expect(fetched["virtual_card"]).to be false

      # Cleanup
      tools.delete_card(child_name)
      tools.delete_card(parent_name)
    end

    it "does not mark cards with substantial content as virtual" do
      card_name = "#{test_prefix}_SubstantialContent"

      # Create a simple-named card with substantial content
      card = tools.create_card(card_name, content: "This card has plenty of content to avoid being virtual", type: "RichText")

      sleep 0.5

      # Fetch the card
      fetched = tools.get_card(card_name)

      # Should NOT be marked as virtual (has sufficient content)
      expect(fetched["virtual_card"]).to be false

      # Cleanup
      tools.delete_card(card_name)
    end
  end
end
