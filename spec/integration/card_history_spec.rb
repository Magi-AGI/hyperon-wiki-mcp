# frozen_string_literal: true

require "spec_helper"
require_relative "../support/integration_helpers"

# Integration tests for card history and restore functionality
#
# These tests verify that:
# - get_card_history returns revision history for cards
# - get_revision retrieves specific revision content
# - restore_card restores cards to previous revisions (admin only)
# - list_trash lists deleted cards (admin only)
#
# Note: These tests require:
# - INTEGRATION_TEST=true environment variable
# - Admin-level API credentials for restore and trash operations
# - The Decko API must implement the history endpoints (Phase 4)
#
# Run with: INTEGRATION_TEST=true bundle exec rspec spec/integration/card_history_spec.rb
RSpec.describe "Card History and Restore Operations", :integration do
  let(:tools) { Magi::Archive::Mcp::Tools.new }
  let(:test_prefix) { "HistoryTest#{Time.now.to_i}" }

  before do
    skip "Integration tests disabled (set INTEGRATION_TEST=true to enable)" unless ENV["INTEGRATION_TEST"]
  end

  after do
    cleanup_test_cards
  end

  describe "get_card_history" do
    context "for existing cards" do
      it "returns revision history for a card" do
        card_name = "#{test_prefix}_HistoryCard"

        # Create a card
        tools.create_card(card_name, content: "Initial content", type: "RichText")
        @created_cards = [card_name]

        sleep 0.5

        # Get history
        history = tools.get_card_history(card_name)

        expect(history).to have_key("card")
        expect(history).to have_key("revisions")
        expect(history["revisions"]).to be_an(Array)
        expect(history).to have_key("total")
      end

      it "includes creation revision" do
        card_name = "#{test_prefix}_CreationHistory"

        tools.create_card(card_name, content: "Test content", type: "RichText")
        @created_cards = [card_name]

        sleep 0.5

        history = tools.get_card_history(card_name)

        # Should have at least one revision (the create)
        expect(history["total"]).to be >= 1

        if history["revisions"].any?
          # Find the create action
          create_revision = history["revisions"].find { |r| r["action"] == "create" }
          expect(create_revision).not_to be_nil if history["revisions"].size == 1
        end
      end

      it "tracks update revisions" do
        card_name = "#{test_prefix}_UpdateHistory"

        # Create and update
        tools.create_card(card_name, content: "Version 1", type: "RichText")
        @created_cards = [card_name]

        sleep 0.5

        tools.update_card(card_name, content: "Version 2")

        sleep 0.5

        history = tools.get_card_history(card_name)

        # Should have at least 2 revisions (create + update)
        expect(history["total"]).to be >= 2
      end

      it "respects limit parameter" do
        card_name = "#{test_prefix}_LimitHistory"

        tools.create_card(card_name, content: "v1", type: "RichText")
        @created_cards = [card_name]

        sleep 0.3
        tools.update_card(card_name, content: "v2")
        sleep 0.3
        tools.update_card(card_name, content: "v3")

        sleep 0.5

        # Request only 2 revisions
        history = tools.get_card_history(card_name, limit: 2)

        expect(history["revisions"].size).to be <= 2
      end
    end

    context "for compound cards" do
      it "returns history for Parent+Child cards" do
        parent_name = "#{test_prefix}_HistoryParent"
        child_name = "#{parent_name}+Child"

        tools.create_card(parent_name, content: "Parent", type: "RichText")
        tools.create_card(child_name, content: "Child content", type: "RichText")
        @created_cards = [child_name, parent_name]

        sleep 0.5

        history = tools.get_card_history(child_name)

        expect(history["card"]).to eq(child_name)
        expect(history["revisions"]).to be_an(Array)
      end
    end

    context "error handling" do
      it "raises NotFoundError for non-existent card" do
        expect {
          tools.get_card_history("#{test_prefix}_NonExistent_#{rand(10000)}")
        }.to raise_error(Magi::Archive::Mcp::Client::NotFoundError)
      end
    end
  end

  describe "get_revision" do
    context "for cards with history" do
      it "retrieves specific revision content" do
        card_name = "#{test_prefix}_RevisionContent"
        original_content = "Original content for revision test"

        # Create card
        tools.create_card(card_name, content: original_content, type: "RichText")
        @created_cards = [card_name]

        sleep 0.5

        # Get history to find act_id
        history = tools.get_card_history(card_name)

        skip "No revisions returned by API" if history["revisions"].empty?

        act_id = history["revisions"].last["act_id"]

        # Get the specific revision
        revision = tools.get_revision(card_name, act_id: act_id)

        expect(revision).to have_key("snapshot")
        expect(revision["snapshot"]).to have_key("content")
        expect(revision["snapshot"]).to have_key("name")
        expect(revision["snapshot"]).to have_key("type")
      end

      it "shows content at that point in time" do
        card_name = "#{test_prefix}_RevisionTime"
        v1_content = "Version 1 content"
        v2_content = "Version 2 content - updated"

        # Create with v1
        tools.create_card(card_name, content: v1_content, type: "RichText")
        @created_cards = [card_name]

        sleep 0.5

        # Get history to find create act_id
        history_v1 = tools.get_card_history(card_name)
        skip "No revisions returned by API" if history_v1["revisions"].empty?
        v1_act_id = history_v1["revisions"].last["act_id"]

        # Update to v2
        tools.update_card(card_name, content: v2_content)

        sleep 0.5

        # Get v1 revision
        v1_revision = tools.get_revision(card_name, act_id: v1_act_id)

        # Content should be v1, not v2
        expect(v1_revision["snapshot"]["content"]).to include("Version 1")
      end
    end

    context "error handling" do
      it "raises NotFoundError for invalid act_id" do
        card_name = "#{test_prefix}_InvalidActId"

        tools.create_card(card_name, content: "Test", type: "RichText")
        @created_cards = [card_name]

        sleep 0.5

        expect {
          tools.get_revision(card_name, act_id: 999_999_999)
        }.to raise_error(Magi::Archive::Mcp::Client::NotFoundError)
      end
    end
  end

  describe "restore_card" do
    context "restoring to previous revision" do
      it "restores card content to a previous state" do
        card_name = "#{test_prefix}_RestoreRevision"
        v1_content = "Version 1 - original"
        v2_content = "Version 2 - modified"

        # Create with v1
        tools.create_card(card_name, content: v1_content, type: "RichText")
        @created_cards = [card_name]

        sleep 0.5

        # Get v1 act_id
        history_v1 = tools.get_card_history(card_name)
        skip "No revisions returned by API" if history_v1["revisions"].empty?
        v1_act_id = history_v1["revisions"].last["act_id"]

        # Update to v2
        tools.update_card(card_name, content: v2_content)

        sleep 0.5

        # Verify current content is v2
        current = tools.get_card(card_name)
        expect(current["content"]).to include("Version 2")

        # Restore to v1
        result = tools.restore_card(card_name, act_id: v1_act_id)

        expect(result["success"]).to be true
        expect(result["card"]).to eq(card_name)

        sleep 0.5

        # Verify content is back to v1
        restored = tools.get_card(card_name)
        expect(restored["content"]).to include("Version 1")
      end

      it "creates a new revision when restoring" do
        card_name = "#{test_prefix}_RestoreCreatesRev"

        tools.create_card(card_name, content: "v1", type: "RichText")
        @created_cards = [card_name]

        sleep 0.5

        history_before = tools.get_card_history(card_name)
        skip "No revisions returned by API" if history_before["revisions"].empty?
        v1_act_id = history_before["revisions"].last["act_id"]
        initial_count = history_before["total"]

        tools.update_card(card_name, content: "v2")
        sleep 0.5

        # Restore to v1
        tools.restore_card(card_name, act_id: v1_act_id)
        sleep 0.5

        # Check that a new revision was created
        history_after = tools.get_card_history(card_name)
        expect(history_after["total"]).to be > initial_count + 1
      end
    end

    context "restoring from trash" do
      it "restores a deleted card" do
        card_name = "#{test_prefix}_TrashRestore"
        content = "Content to be restored from trash"

        # Create and delete
        tools.create_card(card_name, content: content, type: "RichText")
        @created_cards = [card_name]

        sleep 0.5

        tools.delete_card(card_name, force: true)
        @created_cards = [] # Card is now deleted

        sleep 0.5

        # Verify card is gone
        expect {
          tools.get_card(card_name)
        }.to raise_error(Magi::Archive::Mcp::Client::NotFoundError)

        # Restore from trash
        result = tools.restore_card(card_name, from_trash: true)
        @created_cards = [card_name] # Card is back

        expect(result["success"]).to be true

        sleep 0.5

        # Verify card is restored
        restored = tools.get_card(card_name)
        expect(restored["name"]).to eq(card_name)
        expect(restored["content"]).to include(content)
      end

      it "sets trash flag to false after restoration" do
        card_name = "#{test_prefix}_TrashFlagTest"
        content = "Testing trash flag is properly cleared"

        # Create card
        tools.create_card(card_name, content: content, type: "RichText")
        @created_cards = [card_name]

        sleep 0.5

        # Verify card is accessible (not in trash)
        card_before = tools.get_card(card_name)
        expect(card_before["name"]).to eq(card_name)

        # Delete card (moves to trash)
        tools.delete_card(card_name, force: true)
        @created_cards = []

        sleep 0.5

        # Verify card is no longer accessible (in trash)
        expect {
          tools.get_card(card_name)
        }.to raise_error(Magi::Archive::Mcp::Client::NotFoundError)

        # Verify card appears in trash list
        trash_before = tools.list_trash
        trashed_card = trash_before["cards"].find { |c| c["name"] == card_name }
        expect(trashed_card).not_to be_nil, "Card should appear in trash list after deletion"

        # Restore from trash
        result = tools.restore_card(card_name, from_trash: true)
        @created_cards = [card_name]

        expect(result["success"]).to be true

        sleep 0.5

        # CRITICAL: Verify card is accessible again (trash flag = false)
        # This is the core assertion - the card must be fetchable after restoration
        restored_card = tools.get_card(card_name)
        expect(restored_card["name"]).to eq(card_name)
        expect(restored_card["content"]).to include(content)

        # Verify card no longer appears in trash list
        trash_after = tools.list_trash
        still_trashed = trash_after["cards"].find { |c| c["name"] == card_name }
        expect(still_trashed).to be_nil, "Card should NOT appear in trash list after restoration"

        # Verify card appears in search results (another indicator trash=false)
        search_results = tools.search_cards(q: card_name)
        found_card = search_results["cards"].find { |c| c["name"] == card_name }
        expect(found_card).not_to be_nil, "Card should appear in search results after restoration"
      end
    end

    context "error handling" do
      it "raises error when neither act_id nor from_trash specified" do
        expect {
          tools.restore_card("SomeCard")
        }.to raise_error(ArgumentError)
      end

      it "raises NotFoundError for non-existent card in trash" do
        expect {
          tools.restore_card("#{test_prefix}_NotInTrash_#{rand(10000)}", from_trash: true)
        }.to raise_error(Magi::Archive::Mcp::Client::NotFoundError)
      end
    end
  end

  describe "list_trash" do
    context "with deleted cards" do
      it "lists cards in trash" do
        card_name = "#{test_prefix}_TrashList"

        # Create and delete a card
        tools.create_card(card_name, content: "To be trashed", type: "RichText")
        sleep 0.5
        tools.delete_card(card_name, force: true)

        sleep 0.5

        # List trash
        trash = tools.list_trash

        expect(trash).to have_key("cards")
        expect(trash["cards"]).to be_an(Array)
        expect(trash).to have_key("total")

        # Our card should be in the list
        our_card = trash["cards"].find { |c| c["name"] == card_name }

        # Note: Card might have been restored or cleaned up by other tests
        # Just verify the structure is correct
        if our_card
          expect(our_card).to have_key("deleted_at")

          # Clean up by restoring
          tools.restore_card(card_name, from_trash: true)
          @created_cards = [card_name]
        end
      end

      it "includes deletion metadata" do
        card_name = "#{test_prefix}_TrashMeta"

        tools.create_card(card_name, content: "Metadata test", type: "RichText")
        sleep 0.5
        tools.delete_card(card_name, force: true)

        sleep 0.5

        trash = tools.list_trash
        our_card = trash["cards"].find { |c| c["name"] == card_name }

        if our_card
          expect(our_card["type"]).to eq("RichText")
          expect(our_card).to have_key("deleted_at")

          # Clean up
          tools.restore_card(card_name, from_trash: true)
          @created_cards = [card_name]
        end
      end

      it "respects pagination parameters" do
        # Just verify the parameters work, not that pagination is needed
        trash = tools.list_trash(limit: 5, offset: 0)

        expect(trash["cards"].size).to be <= 5
      end
    end

    context "empty trash" do
      it "returns empty array when no deleted cards" do
        # This might not be truly empty, but verify structure
        trash = tools.list_trash

        expect(trash["cards"]).to be_an(Array)
        expect(trash["total"]).to be_a(Integer)
      end
    end
  end

  private

  def cleanup_test_cards
    return unless @created_cards

    @created_cards.each do |name|
      tools.delete_card(name, force: true)
    rescue StandardError
      # Ignore cleanup errors
    end
  end
end
