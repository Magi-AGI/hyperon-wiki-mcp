# frozen_string_literal: true

require "spec_helper"
require_relative "../support/integration_helpers"

# Integration tests for hierarchy/compound card search
#
# These tests verify that:
# - search_cards can find cards by exact part name matches in compound names
# - search_cards can find deep hierarchy children (e.g., Parent+Child+Grandchild)
# - list_children returns all non-virtual children at any depth
#
# NOTE: Decko's "part" search does exact matching on compound card parts,
# not substring/partial matching. Searching for "roots" finds cards where
# "roots" is an exact left or right part of the compound name.
#
# Run with: INTEGRATION_TEST=true bundle exec rspec spec/integration/hierarchy_search_spec.rb
RSpec.describe "Hierarchy Search", :integration do
  let(:tools) { Magi::Archive::Mcp::Tools.new }
  let(:test_prefix) { "HierarchyTest#{Time.now.to_i}" }

  before do
    skip "Integration tests disabled (set INTEGRATION_TEST=true to enable)" unless ENV["INTEGRATION_TEST"]
  end

  after do
    cleanup_test_cards
  end

  describe "search_cards with compound card names" do
    it "finds cards by rightmost name part" do
      # Create a deep hierarchy card
      parent_name = "#{test_prefix}_Parent"
      child_name = "#{parent_name}+Child"
      grandchild_name = "#{child_name}+UniqueGrandchild"

      tools.create_card(parent_name, content: "Parent", type: "RichText")
      tools.create_card(child_name, content: "Child", type: "RichText")
      tools.create_card(grandchild_name, content: "Grandchild content", type: "RichText")
      @created_cards = [grandchild_name, child_name, parent_name]

      sleep 1

      # Search for the rightmost part "UniqueGrandchild"
      results = tools.search_cards(q: "UniqueGrandchild", search_in: "name", limit: 20)

      card_names = results["cards"].map { |c| c["name"] }
      expect(card_names).to include(grandchild_name),
        "Expected to find '#{grandchild_name}' when searching for 'UniqueGrandchild', got: #{card_names}"
    end

    it "finds cards by middle name part" do
      parent_name = "#{test_prefix}_TopLevel"
      middle_name = "#{parent_name}+UniqueMiddle"
      child_name = "#{middle_name}+Bottom"

      tools.create_card(parent_name, content: "Top", type: "RichText")
      tools.create_card(middle_name, content: "Middle", type: "RichText")
      tools.create_card(child_name, content: "Bottom", type: "RichText")
      @created_cards = [child_name, middle_name, parent_name]

      sleep 1

      # Search for middle part
      results = tools.search_cards(q: "UniqueMiddle", search_in: "name", limit: 20)

      card_names = results["cards"].map { |c| c["name"] }
      # Should find both the middle card and the child card (both contain "UniqueMiddle")
      expect(card_names).to include(middle_name),
        "Expected to find '#{middle_name}' when searching for 'UniqueMiddle'"
    end

    it "finds cards with spaces in compound name parts" do
      parent_name = "#{test_prefix}_Spaced Parent"
      # Use a unique part name for exact matching
      unique_part = "UniqueSpacedPart#{Time.now.to_i}"
      child_name = "#{parent_name}+#{unique_part}"

      tools.create_card(parent_name, content: "Parent", type: "RichText")
      tools.create_card(child_name, content: "Child", type: "RichText")
      @created_cards = [child_name, parent_name]

      sleep 1

      # Search for exact part name (Decko's part search does exact matching)
      results = tools.search_cards(q: unique_part, search_in: "name", limit: 20)

      card_names = results["cards"].map { |c| c["name"] }
      expect(card_names).to include(child_name),
        "Expected to find '#{child_name}' when searching for '#{unique_part}'"
    end

    it "finds deeply nested hierarchy cards" do
      # Create a 5-level deep hierarchy like the GM+AI+roots pattern
      level1 = "#{test_prefix}_L1"
      level2 = "#{level1}+L2"
      level3 = "#{level2}+L3"
      level4 = "#{level3}+L4"
      level5 = "#{level4}+DeepUniqueLeaf"

      [level1, level2, level3, level4].each do |name|
        tools.create_card(name, content: "Level content", type: "RichText")
      end
      tools.create_card(level5, content: "Deep leaf content", type: "RichText")
      @created_cards = [level5, level4, level3, level2, level1]

      sleep 1

      # Search for the deepest leaf by its unique name
      results = tools.search_cards(q: "DeepUniqueLeaf", search_in: "name", limit: 20)

      card_names = results["cards"].map { |c| c["name"] }
      expect(card_names).to include(level5),
        "Expected to find deeply nested card '#{level5}'"
    end

    it "finds real-world pattern like +GM+AI+roots" do
      # Simulate the actual pattern: Culture+GM+AI+roots
      # Use unique part names to avoid collision with production data
      culture_name = "#{test_prefix}_TestCulture"
      gm_part = "GMTest#{Time.now.to_i}"
      ai_part = "AITest#{Time.now.to_i}"
      roots_part = "rootsTest#{Time.now.to_i}"
      gm_name = "#{culture_name}+#{gm_part}"
      ai_name = "#{gm_name}+#{ai_part}"
      roots_name = "#{ai_name}+#{roots_part}"

      tools.create_card(culture_name, content: "Culture", type: "RichText")
      tools.create_card(gm_name, content: "GM notes", type: "RichText")
      tools.create_card(ai_name, content: "AI notes", type: "RichText")
      tools.create_card(roots_name, content: "Root inventory", type: "RichText")
      @created_cards = [roots_name, ai_name, gm_name, culture_name]

      sleep 1

      # Search for the unique roots part - should find the deeply nested card
      results = tools.search_cards(q: roots_part, search_in: "name", limit: 20)

      card_names = results["cards"].map { |c| c["name"] }
      expect(card_names).to include(roots_name),
        "Expected to find '#{roots_name}' when searching for '#{roots_part}'"
    end
  end

  describe "search_cards with type filter and compound names" do
    it "finds compound cards when filtering by type" do
      parent_name = "#{test_prefix}_TypedParent"
      child_name = "#{parent_name}+TypedChild"

      tools.create_card(parent_name, content: "Parent", type: "RichText")
      tools.create_card(child_name, content: "Typed child", type: "RichText")
      @created_cards = [child_name, parent_name]

      sleep 1

      # Search by type should include compound cards
      results = tools.search_cards(type: "RichText", q: "TypedChild", search_in: "name", limit: 20)

      card_names = results["cards"].map { |c| c["name"] }
      expect(card_names).to include(child_name),
        "Expected to find '#{child_name}' when searching by type and name"
    end
  end

  describe "list_children completeness" do
    it "returns all direct children including those with special characters" do
      parent_name = "#{test_prefix}_ListParent"
      child1 = "#{parent_name}+Regular"
      child2 = "#{parent_name}+With Space"
      child3 = "#{parent_name}+With-Dash"

      tools.create_card(parent_name, content: "Parent", type: "RichText")
      tools.create_card(child1, content: "Regular child", type: "RichText")
      tools.create_card(child2, content: "Spaced child", type: "RichText")
      tools.create_card(child3, content: "Dashed child", type: "RichText")
      @created_cards = [child3, child2, child1, parent_name]

      sleep 1

      result = tools.list_children(parent_name, limit: 50)
      child_names = result["children"].map { |c| c["name"] }

      expect(child_names).to include(child1)
      expect(child_names).to include(child2)
      expect(child_names).to include(child3)
      expect(child_names.size).to eq(3),
        "Expected 3 children, got #{child_names.size}: #{child_names}"
    end

    it "returns children with substantial content (non-virtual)" do
      parent_name = "#{test_prefix}_ContentParent"
      substantial_child = "#{parent_name}+Substantial"

      tools.create_card(parent_name, content: "Parent", type: "RichText")
      tools.create_card(substantial_child, content: "This is substantial content that should not be filtered as virtual", type: "RichText")
      @created_cards = [substantial_child, parent_name]

      sleep 1

      result = tools.list_children(parent_name, limit: 50)
      child_names = result["children"].map { |c| c["name"] }

      expect(child_names).to include(substantial_child),
        "Substantial child card should not be filtered out"
    end
  end

  describe "count consistency with compound names" do
    it "count matches actual results for compound name searches" do
      # Use exact part name that both children share as a grandparent
      parent_name = "#{test_prefix}_CountParent"
      # Create a shared middle part that both children have
      shared_part = "SharedCount#{Time.now.to_i}"
      child1 = "#{parent_name}+#{shared_part}+Child1"
      child2 = "#{parent_name}+#{shared_part}+Child2"

      tools.create_card(parent_name, content: "Parent", type: "RichText")
      tools.create_card("#{parent_name}+#{shared_part}", content: "Shared", type: "RichText")
      tools.create_card(child1, content: "Child 1", type: "RichText")
      tools.create_card(child2, content: "Child 2", type: "RichText")
      @created_cards = [child2, child1, "#{parent_name}+#{shared_part}", parent_name]

      sleep 1

      # Search for the shared part - should find cards that have it as a part
      results = tools.search_cards(q: shared_part, search_in: "name", limit: 50)

      expect(results["total"]).to eq(results["cards"].size),
        "Count (#{results['total']}) should match actual results (#{results['cards'].size})"
      # Should find at least the shared part card and possibly its children
      expect(results["cards"].size).to be >= 1,
        "Expected at least 1 result for '#{shared_part}'"
    end
  end

  private

  def cleanup_test_cards
    return unless @created_cards

    @created_cards.each do |name|
      tools.delete_card(name)
    rescue StandardError
      # Ignore cleanup errors
    end
  end
end
