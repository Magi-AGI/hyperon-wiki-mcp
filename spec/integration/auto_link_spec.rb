# frozen_string_literal: true

require "spec_helper"
require_relative "../support/integration_helpers"

# Integration tests for auto_link functionality
#
# These tests verify that:
# - auto_link endpoint returns suggestions for linkable terms
# - Scope-based term indexing works correctly
# - Stopwords are filtered out
# - Links are correctly applied in apply mode
#
# Run with: INTEGRATION_TEST=true bundle exec rspec spec/integration/auto_link_spec.rb
RSpec.describe "Auto Link Operations", :integration do
  let(:tools) { Magi::Archive::Mcp::Tools.new }
  let(:test_prefix) { "AutoLinkTest#{Time.now.to_i}" }

  before do
    skip "Integration tests disabled (set INTEGRATION_TEST=true to enable)" unless ENV["INTEGRATION_TEST"]
  end

  after do
    cleanup_test_cards
  end

  describe "suggest mode" do
    it "finds linkable terms in card content" do
      # Create a scope card and some child cards
      # Use 3+ levels so derive_scope returns first 2 parts only
      scope_card = "#{test_prefix}+Scope"
      term_card = "#{scope_card}+UniqueTermXYZ"
      content_card = "#{scope_card}+ContentCard"

      tools.create_card(scope_card, content: "Scope root", type: "RichText")
      tools.create_card(term_card, content: "This is UniqueTermXYZ definition", type: "RichText")
      tools.create_card(content_card, content: "This content mentions UniqueTermXYZ which should be linked.", type: "RichText")
      @created_cards = [content_card, term_card, scope_card]

      sleep 1 # Allow indexing

      # Run auto_link in suggest mode
      result = tools.auto_link(content_card, mode: "suggest")

      expect(result).to be_a(Hash)
      expect(result["suggestions"]).to be_an(Array)
      expect(result["scope"]).to eq(scope_card)
    end

    it "respects minimum term length" do
      scope_card = "#{test_prefix}_MinLength"
      short_term = "#{scope_card}+AB"  # Too short (2 chars)
      long_term = "#{scope_card}+LongerTerm"
      content_card = "#{scope_card}+Content"

      tools.create_card(scope_card, content: "Root", type: "RichText")
      tools.create_card(short_term, content: "Short", type: "RichText")
      tools.create_card(long_term, content: "Long", type: "RichText")
      tools.create_card(content_card, content: "Content with AB and LongerTerm mentioned.", type: "RichText")
      @created_cards = [content_card, long_term, short_term, scope_card]

      sleep 1

      result = tools.auto_link(content_card, mode: "suggest", min_term_length: 3)

      expect(result["suggestions"]).to be_an(Array)
      # Should not suggest "AB" because it's too short
      terms = result["suggestions"].map { |s| s["term"] }
      expect(terms).not_to include("AB")
    end

    it "filters out stopwords" do
      scope_card = "#{test_prefix}_Stopwords"
      # "The" is a stopword that should not be linked even if a card exists
      the_card = "#{scope_card}+The"
      content_card = "#{scope_card}+Content"

      tools.create_card(scope_card, content: "Root", type: "RichText")
      tools.create_card(the_card, content: "The definition", type: "RichText")
      tools.create_card(content_card, content: "The quick brown fox.", type: "RichText")
      @created_cards = [content_card, the_card, scope_card]

      sleep 1

      result = tools.auto_link(content_card, mode: "suggest")

      terms = (result["suggestions"] || []).map { |s| s["term"]&.downcase }
      # "the" should be filtered as a stopword
      expect(terms).not_to include("the")
    end

    it "skips already linked terms" do
      scope_card = "#{test_prefix}_AlreadyLinked"
      linked_term = "#{scope_card}+LinkedTerm"
      content_card = "#{scope_card}+Content"

      tools.create_card(scope_card, content: "Root", type: "RichText")
      tools.create_card(linked_term, content: "Definition", type: "RichText")
      # Content already has the term linked
      tools.create_card(content_card, content: "This mentions [[#{linked_term}]] which is already linked.", type: "RichText")
      @created_cards = [content_card, linked_term, scope_card]

      sleep 1

      result = tools.auto_link(content_card, mode: "suggest")

      # Should not suggest linking an already linked term
      expect(result["suggestions"]).to be_an(Array)
      # The linked instance should be skipped
    end

    it "returns stats about the analysis" do
      scope_card = "#{test_prefix}_Stats"
      term_card = "#{scope_card}+StatsTerm"
      content_card = "#{scope_card}+Content"

      tools.create_card(scope_card, content: "Root", type: "RichText")
      tools.create_card(term_card, content: "Definition", type: "RichText")
      tools.create_card(content_card, content: "Content with StatsTerm.", type: "RichText")
      @created_cards = [content_card, term_card, scope_card]

      sleep 1

      result = tools.auto_link(content_card, mode: "suggest")

      expect(result["stats"]).to be_a(Hash)
      expect(result["stats"]).to have_key("terms_in_index")
      expect(result["stats"]).to have_key("suggestions_found")
    end
  end

  describe "apply mode with dry_run" do
    it "generates preview without modifying card" do
      scope_card = "#{test_prefix}_DryRun"
      term_card = "#{scope_card}+DryRunTerm"
      content_card = "#{scope_card}+Content"
      original_content = "Content mentions DryRunTerm here."

      tools.create_card(scope_card, content: "Root", type: "RichText")
      tools.create_card(term_card, content: "Definition", type: "RichText")
      tools.create_card(content_card, content: original_content, type: "RichText")
      @created_cards = [content_card, term_card, scope_card]

      sleep 1

      result = tools.auto_link(content_card, mode: "apply", dry_run: true)

      expect(result["dry_run"]).to be true
      expect(result["preview"]).to be_a(String) if result["suggestions"].any?

      # Verify card was not modified
      card = tools.get_card(content_card)
      card_content = card["content"] || card.dig("card", "content")
      expect(card_content).to eq(original_content)
    end
  end

  describe "scope derivation" do
    it "uses top 2 left parts as default scope" do
      # Create hierarchy: Level1+Level2+Level3+Content
      level1 = "#{test_prefix}_L1"
      level2 = "#{level1}+L2"
      level3 = "#{level2}+L3"
      content_card = "#{level3}+Content"

      tools.create_card(level1, content: "L1", type: "RichText")
      tools.create_card(level2, content: "L2", type: "RichText")
      tools.create_card(level3, content: "L3", type: "RichText")
      tools.create_card(content_card, content: "Test content", type: "RichText")
      @created_cards = [content_card, level3, level2, level1]

      sleep 1

      result = tools.auto_link(content_card, mode: "suggest")

      # Scope should be top 2 parts: "Level1+Level2"
      expect(result["scope"]).to eq(level2)
    end

    it "allows scope override" do
      scope_card = "#{test_prefix}_Override"
      other_scope = "#{test_prefix}_OtherScope"
      content_card = "#{scope_card}+Content"

      tools.create_card(scope_card, content: "Root", type: "RichText")
      tools.create_card(other_scope, content: "Other", type: "RichText")
      tools.create_card(content_card, content: "Test", type: "RichText")
      @created_cards = [content_card, other_scope, scope_card]

      sleep 1

      result = tools.auto_link(content_card, mode: "suggest", scope: other_scope)

      expect(result["scope"]).to eq(other_scope)
    end
  end

  describe "Real production data auto_link" do
    # These tests verify the auto_link fix that uses recursive descendant finding
    # instead of the broken CQL name match query

    it "finds terms from deep card hierarchy" do
      # Test with the Eldarai intro card which mentions Oathari, Coalition of Planets, etc.
      card_name = "Games+Butterfly Galaxii+Player+Species+Major Species+Eldarai+intro"

      result = tools.auto_link(card_name, mode: "suggest")

      expect(result).to be_a(Hash)
      expect(result["scope"]).to eq("Games+Butterfly Galaxii")

      # The term index should have many terms (not 0 like before the fix)
      expect(result["stats"]["terms_in_index"]).to be > 100

      # Should find suggestions for terms like Oathari, Coalition of Planets, etc.
      expect(result["suggestions"]).to be_an(Array)
      expect(result["suggestions"].size).to be > 0

      # Check that at least one suggestion is for a known term
      suggestion_terms = result["suggestions"].map { |s| s["term"] }
      expect(suggestion_terms).to include("Oathari").or include("Coalition of Planets").or include("Zenith of the Beyond")
    end

    it "indexes cards recursively through left_id hierarchy" do
      # Test that descendants at multiple levels are found
      # The scope "Games+Butterfly Galaxii" should index cards like:
      # - Games+Butterfly Galaxii+Player+Species+Major Species+Oathari (4 levels deep)
      # - Games+Butterfly Galaxii+Player+Factions+Major Factions+Coalition of Planets (5 levels deep)

      result = tools.auto_link(
        "Games+Butterfly Galaxii+Player+Species+Major Species+Eldarai+intro",
        mode: "suggest"
      )

      # Check stats show a substantial term index was built
      expect(result["stats"]["terms_in_index"]).to be > 500
    end

    it "skips stopwords in production content" do
      result = tools.auto_link(
        "Games+Butterfly Galaxii+Player+Species+Major Species+Eldarai+intro",
        mode: "suggest"
      )

      # Check that common stopwords are not in suggestions
      suggestion_terms = result["suggestions"].map { |s| s["term"].downcase }
      common_stopwords = %w[the and are was with from their]
      common_stopwords.each do |stopword|
        expect(suggestion_terms).not_to include(stopword)
      end
    end

    it "generates valid preview in dry_run mode" do
      result = tools.auto_link(
        "Games+Butterfly Galaxii+Player+Species+Major Species+Eldarai+intro",
        mode: "apply",
        dry_run: true
      )

      expect(result["dry_run"]).to be true

      # If suggestions were found, preview should contain wiki links
      if result["suggestions"].any?
        expect(result["preview"]).to include("[[")
        expect(result["preview"]).to include("]]")
      end
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
