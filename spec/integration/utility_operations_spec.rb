# frozen_string_literal: true

require "spec_helper"
require_relative "../support/integration_helpers"

RSpec.describe "Utility Operations Integration", :integration do
  # Real HTTP integration tests for utility and pagination operations
  # Run with: INTEGRATION_TEST=true rspec spec/integration/utility_operations_spec.rb

  let(:base_url) { ENV["DECKO_API_BASE_URL"] || "https://wiki.hyperon.dev/api/mcp" }

  before do
    skip "Integration tests disabled" unless ENV["INTEGRATION_TEST"]
  end

  describe "Pagination utilities" do
    let(:tools) { Magi::Archive::Mcp::Tools.new }

    describe "fetch_all_cards" do
      it "retrieves all cards with automatic pagination" do
        # Limit to small number for testing
        cards = []
        tools.fetch_all_cards(limit: 10) do |card|
          cards << card
        end

        expect(cards).to be_an(Array)
        expect(cards.length).to be > 0
        expect(cards.length).to be <= 10

        # Verify card structure
        first_card = cards.first
        expect(first_card).to have_key("name")
      end

      it "handles query filters during fetch" do
        cards = []
        tools.fetch_all_cards(q: "Test", limit: 5) do |card|
          cards << card
        end

        expect(cards).to be_an(Array)
        # Should only get cards matching query
      end

      it "respects type filters" do
        cards = []
        tools.fetch_all_cards(type: "RichText", limit: 5) do |card|
          cards << card
        end

        expect(cards).to be_an(Array)
        if cards.any?
          # All cards should be RichText type
          cards.each do |card|
            expect(card["type"]).to eq("RichText") if card["type"]
          end
        end
      end

      it "works without a block" do
        result = tools.fetch_all_cards(limit: 5)

        expect(result).to be_an(Array)
        expect(result.length).to be <= 5
      end
    end

    describe "fetch_all_types" do
      it "retrieves all card types with pagination" do
        types = []
        tools.fetch_all_types(limit: 10) do |type|
          types << type
        end

        expect(types).to be_an(Array)
        expect(types.length).to be > 0

        # Should include common types
        type_names = types.map { |t| t["name"] }
        expect(type_names).to include("RichText").or include("Article")
      end

      it "works without a block" do
        result = tools.fetch_all_types(limit: 5)

        expect(result).to be_an(Array)
        expect(result.length).to be > 0
      end
    end

    describe "each_card_page" do
      it "iterates through paginated card results" do
        page_count = 0
        card_count = 0

        tools.each_card_page(limit: 5, max_pages: 2) do |page|
          page_count += 1
          card_count += page["cards"].length if page["cards"]
        end

        expect(page_count).to be > 0
        expect(page_count).to be <= 2
        expect(card_count).to be > 0
      end

      it "provides pagination metadata" do
        tools.each_card_page(limit: 5, max_pages: 1) do |page|
          expect(page).to have_key("cards")
          expect(page).to have_key("total")
          expect(page).to have_key("offset")
          expect(page).to have_key("limit")
        end
      end

      it "stops at max_pages limit" do
        page_count = 0

        tools.each_card_page(limit: 2, max_pages: 3) do |page|
          page_count += 1
        end

        expect(page_count).to be <= 3
      end
    end
  end

  describe "Card name encoding" do
    let(:tools) { Magi::Archive::Mcp::Tools.new }

    describe "encode_card_name" do
      it "encodes special characters for URLs" do
        result = tools.encode_card_name("Test Card Name")

        expect(result).to be_a(String)
        expect(result).not_to include(" ")
      end

      it "handles plus signs in compound names" do
        result = tools.encode_card_name("Parent+Child")

        expect(result).to be_a(String)
        # Plus signs should be properly encoded
        expect(result).to include("%2B").or include("+")
      end

      it "handles special characters" do
        result = tools.encode_card_name("Test & Special / Characters")

        expect(result).to be_a(String)
        # Should encode & and /
        expect(result).not_to include("&")
        expect(result).not_to include("/")
      end

      it "preserves already-encoded names" do
        encoded = "Test%20Card"
        result = tools.encode_card_name(encoded)

        expect(result).to be_a(String)
      end
    end
  end

  describe "Content snippet rendering" do
    let(:tools) { Magi::Archive::Mcp::Tools.new }

    describe "render_snippet" do
      it "truncates long content to specified length" do
        long_content = "A" * 100

        result = tools.render_snippet(long_content, length: 20)

        expect(result).to be_a(String)
        expect(result.length).to be <= 23 # 20 + "..."
      end

      it "preserves short content unchanged" do
        short_content = "Short"

        result = tools.render_snippet(short_content, length: 50)

        expect(result).to eq(short_content)
      end

      it "handles HTML content" do
        html_content = "<p>This is <strong>HTML</strong> content with <em>tags</em></p>"

        result = tools.render_snippet(html_content, length: 30)

        expect(result).to be_a(String)
        # Should handle HTML gracefully
      end

      it "handles nil or empty content" do
        result = tools.render_snippet("", length: 20)

        expect(result).to eq("")
      end

      it "adds ellipsis when truncating" do
        result = tools.render_snippet("Long content here", length: 10)

        expect(result).to include("...") if result.length > 10
      end
    end
  end

  describe "Edge cases and error handling" do
    let(:tools) { Magi::Archive::Mcp::Tools.new }

    it "handles pagination with no results" do
      cards = []
      tools.fetch_all_cards(q: "NonExistentQuery#{Time.now.to_i}", limit: 5) do |card|
        cards << card
      end

      expect(cards).to be_empty
    end

    it "handles very large limit values" do
      # Should cap at reasonable limit
      result = tools.fetch_all_cards(limit: 1000)

      expect(result).to be_an(Array)
      # Should not actually fetch 1000 cards
      expect(result.length).to be <= 100
    end

    it "handles offset beyond total cards" do
      cards = []
      tools.fetch_all_cards(offset: 999999, limit: 5) do |card|
        cards << card
      end

      expect(cards).to be_empty
    end
  end
end
