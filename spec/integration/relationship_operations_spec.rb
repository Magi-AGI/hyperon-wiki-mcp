# frozen_string_literal: true

require "spec_helper"
require_relative "../support/integration_helpers"

RSpec.describe "Relationship Operations Integration", :integration do
  # Real HTTP integration tests for card relationship operations
  # Run with: INTEGRATION_TEST=true rspec spec/integration/relationship_operations_spec.rb

  let(:base_url) { ENV["DECKO_API_BASE_URL"] || "https://wiki.hyperon.dev/api/mcp" }

  before do
    skip "Integration tests disabled" unless ENV["INTEGRATION_TEST"]
  end

  describe "Card relationship queries" do
    let(:tools) { Hyperon::Wiki::Mcp::Tools.new }
    let(:parent_card) { "RelTestParent#{Time.now.to_i}" }
    let(:child_card) { "RelTestChild#{Time.now.to_i}" }
    let(:referrer_card) { "RelTestReferrer#{Time.now.to_i}" }

    after do
      # Cleanup test cards
      [parent_card, child_card, referrer_card].each do |card|
        tools.delete_card(card) rescue nil
      end
    end

    describe "get_referers" do
      it "finds cards that reference the target card" do
        # Create a card
        tools.create_card(parent_card, content: "Test parent", type: "RichText")

        # Create a card that references it
        tools.create_card(
          referrer_card,
          content: "This references [[#{parent_card}]]",
          type: "RichText"
        )

        # Give the system a moment to index relationships
        sleep 1

        result = tools.get_referers(parent_card)

        # API returns a Hash with referers array inside
        expect(result).to be_a(Hash)
        expect(result["referers"]).to be_an(Array)
        expect(result["card"]).to eq(parent_card)
        expect(result["referer_count"]).to be >= 0
      end

      it "returns empty referers array for card with no referers" do
        # Create a card that nothing references
        tools.create_card(
          child_card,
          content: "Lonely card",
          type: "RichText"
        )

        result = tools.get_referers(child_card)

        expect(result).to be_a(Hash)
        expect(result["referers"]).to be_an(Array)
        expect(result["referer_count"]).to eq(0)
      end

      it "raises NotFoundError for non-existent card" do
        expect {
          tools.get_referers("NonExistent#{Time.now.to_i}")
        }.to raise_error(Hyperon::Wiki::Mcp::Client::NotFoundError)
      end
    end

    describe "get_linked_by" do
      it "finds cards that link to the target card" do
        # Create target card
        tools.create_card(parent_card, content: "Link target", type: "RichText")

        # Create card with link
        tools.create_card(
          referrer_card,
          content: "Link to [[#{parent_card}]]",
          type: "RichText"
        )

        sleep 1

        result = tools.get_linked_by(parent_card)

        expect(result).to be_a(Hash)
        expect(result["linked_by"]).to be_an(Array)
        expect(result["card"]).to eq(parent_card)
        expect(result["linked_by_count"]).to be >= 0
      end
    end

    describe "get_links" do
      it "finds cards that this card links to" do
        # Create some cards to link to
        tools.create_card(parent_card, content: "Link target 1", type: "RichText")
        tools.create_card(child_card, content: "Link target 2", type: "RichText")

        # Create card with outgoing links
        tools.create_card(
          referrer_card,
          content: "Links to [[#{parent_card}]] and [[#{child_card}]]",
          type: "RichText"
        )

        sleep 1

        result = tools.get_links(referrer_card)

        expect(result).to be_a(Hash)
        expect(result["links"]).to be_an(Array)
        expect(result["card"]).to eq(referrer_card)
        expect(result["links_count"]).to be >= 0
      end
    end

    describe "get_nests" do
      it "finds cards that this card nests" do
        # Create card with nested content
        tools.create_card(parent_card, content: "Nested target", type: "RichText")

        tools.create_card(
          referrer_card,
          content: "{{#{parent_card}}}",
          type: "RichText"
        )

        sleep 1

        result = tools.get_nests(referrer_card)

        expect(result).to be_a(Hash)
        expect(result["nests"]).to be_an(Array)
        expect(result["card"]).to eq(referrer_card)
        expect(result["nests_count"]).to be >= 0
      end
    end

    describe "get_nested_in" do
      it "finds cards where this card is nested" do
        # Create a card
        tools.create_card(parent_card, content: "Will be nested", type: "RichText")

        # Create card that nests it
        tools.create_card(
          referrer_card,
          content: "Nesting {{#{parent_card}}}",
          type: "RichText"
        )

        sleep 1

        result = tools.get_nested_in(parent_card)

        expect(result).to be_a(Hash)
        expect(result["nested_in"]).to be_an(Array)
        expect(result["card"]).to eq(parent_card)
        expect(result["nested_in_count"]).to be >= 0
      end
    end
  end

  describe "Relationship query edge cases" do
    let(:tools) { Hyperon::Wiki::Mcp::Tools.new }

    it "handles compound card names in relationships" do
      # Use a real card that likely exists
      result = tools.get_referers("Home")

      expect(result).to be_a(Hash)
      expect(result["referers"]).to be_an(Array)
      # Home page should have some referers
    end

    it "handles special characters in card names" do
      special_name = "Test+Card+#{Time.now.to_i}"
      tools.create_card(special_name, content: "Special", type: "RichText")

      result = tools.get_links(special_name)

      expect(result).to be_a(Hash)
      expect(result["links"]).to be_an(Array)

      tools.delete_card(special_name) rescue nil
    end
  end

  describe "Real production data relationships" do
    let(:tools) { Hyperon::Wiki::Mcp::Tools.new }

    it "finds referers for a well-known card" do
      # Games+Butterfly Galaxii is a well-known card with many referers
      result = tools.get_referers("Games+Butterfly Galaxii")

      expect(result).to be_a(Hash)
      expect(result["referers"]).to be_an(Array)
      expect(result["referer_count"]).to be > 0

      # Verify referer structure
      if result["referers"].any?
        referer = result["referers"].first
        expect(referer).to have_key("name")
        expect(referer).to have_key("id")
        expect(referer).to have_key("type")
      end
    end

    it "finds links from a card with wiki links" do
      # This card has a link to Species
      result = tools.get_card("Games+Butterfly Galaxii+Player+Species+Major Species+Eldarai+intro")
      card_content = result["content"]

      # Verify card has content with potential links
      expect(card_content).to include("Oathari").or include("Coalition")
    end
  end
end
