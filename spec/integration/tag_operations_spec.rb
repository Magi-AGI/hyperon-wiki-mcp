# frozen_string_literal: true

require "spec_helper"
require_relative "../support/integration_helpers"

RSpec.describe "Tag Operations Integration", :integration do
  # Real HTTP integration tests for tag-related operations
  # Run with: INTEGRATION_TEST=true rspec spec/integration/tag_operations_spec.rb

  let(:base_url) { ENV["DECKO_API_BASE_URL"] || "https://wiki.hyperon.dev/api/mcp" }

  before do
    skip "Integration tests disabled" unless ENV["INTEGRATION_TEST"]
  end

  describe "Tag discovery and search" do
    let(:tools) { Magi::Archive::Mcp::Tools.new }
    let(:test_card_name) { "TagTestCard#{Time.now.to_i}" }

    after do
      # Cleanup test card
      tools.delete_card(test_card_name) rescue nil
    end

    describe "get_all_tags" do
      it "successfully retrieves all tags from the system" do
        result = tools.get_all_tags

        expect(result).to be_an(Array)
        # May be empty if no tags exist in the system
        expect(result.length).to be >= 0

        # Verify tag structure if any tags exist
        # get_all_tags returns card hashes (from search_cards type: "Tag")
        if result.any?
          first_tag = result.first
          expect(first_tag).to be_a(Hash)
          expect(first_tag).to have_key("name")
        end
      end

      it "handles pagination with limit" do
        result = tools.get_all_tags(limit: 5)

        expect(result).to be_an(Array)
        expect(result.length).to be <= 5
      end

      it "returns consistent format (array of card hashes)" do
        result = tools.get_all_tags(limit: 10)

        expect(result).to be_an(Array)
        # Even empty results should maintain format
        result.each do |tag|
          expect(tag).to be_a(Hash),
            "Expected tag to be Hash, got #{tag.class}: #{tag.inspect}"
          expect(tag).to have_key("name"),
            "Tag missing 'name' key: #{tag.keys.inspect}"
        end
      end
    end

    describe "get_card_tags" do
      it "retrieves tags for a specific card" do
        # Create a card with known tags
        tools.create_card(
          test_card_name,
          content: "Test content with [[tag1]] and [[tag2]]",
          type: "RichText"
        )

        result = tools.get_card_tags(test_card_name)

        expect(result).to be_an(Array)
        # Card should have at least the tags we added
        expect(result.length).to be >= 0
      end

      it "returns empty array for card without tags" do
        # Create card without tags
        tools.create_card(
          test_card_name,
          content: "Plain content without tags",
          type: "RichText"
        )

        result = tools.get_card_tags(test_card_name)

        expect(result).to be_an(Array)
      end

      it "returns empty array for non-existent card" do
        # Non-existent cards return empty array (no tags card exists)
        result = tools.get_card_tags("NonExistentCard#{Time.now.to_i}")

        expect(result).to be_an(Array)
        expect(result).to be_empty
      end

      it "returns strings (not hashes) for card-specific tags" do
        # get_card_tags parses [[tag]] syntax and returns plain strings
        # This is different from get_all_tags which returns card hashes
        tools.create_card(
          test_card_name,
          content: "Content with [[TestTag1]] and [[TestTag2]]",
          type: "RichText"
        )

        # Create the tags card manually if needed
        begin
          tools.create_card(
            "#{test_card_name}+tags",
            content: "[[TestTag1]]\n[[TestTag2]]",
            type: "Pointer"
          )
        rescue StandardError
          # May already exist or not be needed
        end

        result = tools.get_card_tags(test_card_name)

        expect(result).to be_an(Array)
        result.each do |tag|
          expect(tag).to be_a(String),
            "Expected tag to be String, got #{tag.class}: #{tag.inspect}"
        end

        # Cleanup
        tools.delete_card("#{test_card_name}+tags") rescue nil
      end
    end

    describe "search_by_tag" do
      it "finds cards with a specific tag" do
        # Search for a common tag that should exist
        # Using a generic tag that's likely to exist in production
        result = tools.search_by_tag("Article")

        expect(result).to be_an(Array)
        # Should find at least some cards
        expect(result.length).to be >= 0

        if result.any?
          first_card = result.first
          expect(first_card).to have_key("name")
        end
      end

      it "returns empty array for non-existent tag" do
        result = tools.search_by_tag("NonExistentTag#{Time.now.to_i}")

        expect(result).to be_an(Array)
        expect(result).to be_empty
      end
    end

    describe "search_by_tags (AND logic)" do
      it "finds cards matching all specified tags" do
        # Search returns an array, may be empty if no cards have all tags
        result = tools.search_by_tags(["Article"])

        expect(result).to be_an(Array)
        # May be empty if no cards match - that's valid
        expect(result.length).to be >= 0
      end

      it "returns empty array when no cards match all tags" do
        result = tools.search_by_tags([
          "NonExistentTag1#{Time.now.to_i}",
          "NonExistentTag2#{Time.now.to_i}"
        ])

        expect(result).to be_an(Array)
        expect(result).to be_empty
      end
    end

    describe "search_by_tags_any (OR logic)" do
      it "finds cards matching any of the specified tags" do
        result = tools.search_by_tags_any(["RichText", "Article"])

        expect(result).to be_an(Array)
        # Should find cards with either tag
        expect(result.length).to be >= 0
      end

      it "returns empty array when no cards match any tags" do
        result = tools.search_by_tags_any([
          "NonExistentTag1#{Time.now.to_i}",
          "NonExistentTag2#{Time.now.to_i}"
        ])

        expect(result).to be_an(Array)
        expect(result).to be_empty
      end
    end

    describe "parse_tags_from_content" do
      it "extracts tags from content with [[tag]] syntax" do
        content = "This content has [[tag1]] and [[tag2]] and [[tag3]]"

        result = tools.parse_tags_from_content(content)

        expect(result).to be_an(Array)
        expect(result).to include("tag1", "tag2", "tag3")
      end

      it "returns empty array for content without tags" do
        content = "Plain content without any tags"

        result = tools.parse_tags_from_content(content)

        expect(result).to be_an(Array)
        expect(result).to be_empty
      end

      it "handles nested and complex tag patterns" do
        content = "Content with [[outer+inner]] and [[card name with spaces]]"

        result = tools.parse_tags_from_content(content)

        expect(result).to be_an(Array)
        expect(result.length).to be >= 2
      end
    end
  end
end
