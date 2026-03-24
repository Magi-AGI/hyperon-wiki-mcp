# frozen_string_literal: true

require "spec_helper"
require_relative "../support/integration_helpers"

# Integration tests for search consistency
#
# These tests verify that search operations return consistent results:
# - Count matches actual returned cards
# - Virtual card filtering is applied consistently
# - Pagination works correctly after filtering
#
# Run with: INTEGRATION_TEST=true bundle exec rspec spec/integration/search_consistency_spec.rb
RSpec.describe "Search Consistency", :integration do
  let(:tools) { Magi::Archive::Mcp::Tools.new }
  let(:test_prefix) { "SearchConsistTest#{Time.now.to_i}" }

  before do
    skip "Integration tests disabled (set INTEGRATION_TEST=true to enable)" unless ENV["INTEGRATION_TEST"]
  end

  after do
    # Cleanup test cards
    cleanup_test_cards
  end

  describe "search count matches actual results" do
    it "returns consistent count and cards when filtering is applied" do
      # Create a mix of real and virtual cards
      real_card_1 = create_test_card("Real1", content: "Substantial content for testing")
      real_card_2 = create_test_card("Real2", content: "More substantial content here")
      virtual_card = create_test_card("Virtual", content: "", type: "Phrase")

      sleep 1 # Allow database commit

      # Search with default filtering (include_virtual=false)
      results = tools.search_cards(q: test_prefix, search_in: "name", limit: 50)

      total_reported = results["total"]
      actual_count = results["cards"].size

      # The reported total should match actual cards returned (when within limit)
      # This catches the bug where count_search_results didn't filter virtual cards
      if actual_count < results["limit"]
        expect(total_reported).to eq(actual_count),
          "Count mismatch: reported #{total_reported}, but got #{actual_count} cards"
      end

      # Virtual card should be filtered out
      card_names = results["cards"].map { |c| c["name"] }
      expect(card_names).not_to include(virtual_card_name("Virtual"))
    end

    it "correctly counts when include_virtual=true" do
      # Create cards
      real_card = create_test_card("RealCount", content: "Real content")
      virtual_card = create_test_card("VirtualCount", content: "", type: "Phrase")

      sleep 1

      # Search with include_virtual=true
      results = tools.search_cards(q: test_prefix, search_in: "name", include_virtual: true)

      total_reported = results["total"]
      actual_count = results["cards"].size

      # Both cards should be included
      if actual_count < results["limit"]
        expect(total_reported).to eq(actual_count),
          "Count mismatch with include_virtual=true: reported #{total_reported}, got #{actual_count}"
      end

      card_names = results["cards"].map { |c| c["name"] }
      expect(card_names).to include(virtual_card_name("VirtualCount"))
      expect(card_names).to include(virtual_card_name("RealCount"))
    end

    it "handles pagination correctly after filtering" do
      # Create several cards to test pagination
      5.times do |i|
        create_test_card("RealPaginated#{i}", content: "Substantial content #{i}")
      end

      sleep 1

      # Fetch with small limit to force pagination
      page1 = tools.search_cards(q: test_prefix, search_in: "name", limit: 2, offset: 0)
      page2 = tools.search_cards(q: test_prefix, search_in: "name", limit: 2, offset: 2)

      # Collect all unique cards from both pages
      all_names = (page1["cards"] + page2["cards"]).map { |c| c["name"] }.uniq

      # Should have 4 unique cards total (2 per page)
      expect(all_names.size).to eq(4),
        "Pagination failed: expected 4 unique cards, got #{all_names.size}"

      # No duplicates between pages
      page1_names = page1["cards"].map { |c| c["name"] }
      page2_names = page2["cards"].map { |c| c["name"] }
      expect(page1_names & page2_names).to be_empty,
        "Pagination error: duplicate cards across pages"
    end

    it "never returns 'Found N, showing 0' scenario" do
      # This specific test catches the bug where count showed results but none were returned
      virtual_only = create_test_card("VirtualOnly", content: "", type: "Phrase")

      sleep 1

      # Search with default filtering
      results = tools.search_cards(q: "#{test_prefix}_VirtualOnly", search_in: "name")

      if results["total"] > 0
        # If count says there are results, there should be actual cards
        expect(results["cards"]).not_to be_empty,
          "Bug regression: count=#{results['total']} but no cards returned"
      end
    end
  end

  describe "list_children count consistency" do
    it "returns consistent count for children" do
      parent_name = "#{test_prefix}_Parent"

      # Create parent
      tools.create_card(parent_name, content: "Parent card", type: "RichText")

      # Create children
      3.times do |i|
        tools.create_card("#{parent_name}+Child#{i}", content: "Child content #{i}", type: "RichText")
      end

      sleep 1

      result = tools.list_children(parent_name)

      expect(result["child_count"]).to eq(result["children"].size),
        "Child count mismatch: reported #{result['child_count']}, got #{result['children'].size}"

      # Cleanup parent and children
      3.times { |i| tools.delete_card("#{parent_name}+Child#{i}") rescue nil }
      tools.delete_card(parent_name) rescue nil
    end
  end

  private

  def create_test_card(suffix, content:, type: "RichText")
    name = virtual_card_name(suffix)
    tools.create_card(name, content: content, type: type)
    @created_cards ||= []
    @created_cards << name
    name
  end

  def virtual_card_name(suffix)
    "#{test_prefix}_#{suffix}"
  end

  def cleanup_test_cards
    return unless @created_cards

    @created_cards.each do |name|
      tools.delete_card(name)
    rescue StandardError
      # Ignore cleanup errors
    end
  end
end
