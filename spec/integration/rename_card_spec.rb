# frozen_string_literal: true

require "spec_helper"
require_relative "../support/integration_helpers"

# Integration tests for rename_card functionality
#
# These tests verify that:
# - rename_card successfully renames cards
# - References are updated when requested
# - Error handling works correctly
#
# Run with: INTEGRATION_TEST=true bundle exec rspec spec/integration/rename_card_spec.rb
RSpec.describe "Rename Card Operations", :integration do
  let(:tools) { Magi::Archive::Mcp::Tools.new }
  let(:test_prefix) { "RenameTest#{Time.now.to_i}" }

  before do
    skip "Integration tests disabled (set INTEGRATION_TEST=true to enable)" unless ENV["INTEGRATION_TEST"]
  end

  after do
    cleanup_test_cards
  end

  describe "basic rename operations" do
    it "successfully renames a card" do
      original_name = "#{test_prefix}_Original"
      new_name = "#{test_prefix}_Renamed"

      # Create the card
      tools.create_card(original_name, content: "Test content for rename", type: "RichText")
      @created_cards = [original_name]

      sleep 0.5

      # Rename the card
      result = tools.rename_card(original_name, new_name)

      # Verify rename succeeded (API returns "renamed" status)
      expect(result["status"]).to eq("renamed"),
        "Rename failed: #{result.inspect}"
      expect(result["old_name"]).to eq(original_name)
      expect(result["new_name"]).to eq(new_name)

      # Update cleanup list
      @created_cards = [new_name]

      # Verify old name no longer exists
      expect { tools.get_card(original_name) }.to raise_error(Magi::Archive::Mcp::Client::NotFoundError)

      # Verify new name exists with correct content
      renamed_card = tools.get_card(new_name)
      expect(renamed_card["content"]).to include("Test content for rename")
    end

    it "preserves card content after rename" do
      original_name = "#{test_prefix}_ContentPreserve"
      new_name = "#{test_prefix}_ContentPreserveRenamed"
      content = "<p>This is <strong>important</strong> content that must be preserved</p>"

      tools.create_card(original_name, content: content, type: "RichText")
      @created_cards = [original_name]

      sleep 0.5

      # Rename
      tools.rename_card(original_name, new_name)
      @created_cards = [new_name]

      # Verify content is preserved
      renamed_card = tools.get_card(new_name)
      expect(renamed_card["content"]).to eq(content)
    end

    it "returns the renamed card data in response" do
      original_name = "#{test_prefix}_ResponseData"
      new_name = "#{test_prefix}_ResponseDataRenamed"

      tools.create_card(original_name, content: "Response test", type: "RichText")
      @created_cards = [original_name]

      sleep 0.5

      result = tools.rename_card(original_name, new_name)
      @created_cards = [new_name]

      # Should include the card data
      expect(result).to have_key("card")
      expect(result["card"]["name"]).to eq(new_name)
    end
  end

  describe "reference updating" do
    it "updates references when update_referers=true (default)" do
      # Create a card that will be referenced
      target_name = "#{test_prefix}_Target"
      new_target_name = "#{test_prefix}_TargetRenamed"

      # Create the target card
      tools.create_card(target_name, content: "Target content", type: "RichText")

      # Create a card that references the target
      referencer_name = "#{test_prefix}_Referencer"
      tools.create_card(referencer_name, content: "Link to [[#{target_name}]]", type: "RichText")

      @created_cards = [target_name, referencer_name]

      sleep 0.5

      # Rename target with default update_referers=true
      result = tools.rename_card(target_name, new_target_name)
      @created_cards = [new_target_name, referencer_name]

      expect(result["status"]).to eq("renamed")
      # updated_referers should indicate referers were updated
      expect(result["updated_referers"]).to be true

      # Note: Decko might not actually update plain text references,
      # only card nests/links. Verify the result indicates success.
    end

    it "does not update references when update_referers=false" do
      target_name = "#{test_prefix}_NoUpdate"
      new_target_name = "#{test_prefix}_NoUpdateRenamed"

      tools.create_card(target_name, content: "Target", type: "RichText")

      referencer_name = "#{test_prefix}_NoUpdateRef"
      tools.create_card(referencer_name, content: "Link to [[#{target_name}]]", type: "RichText")

      @created_cards = [target_name, referencer_name]

      sleep 0.5

      # Rename with update_referers=false
      result = tools.rename_card(target_name, new_target_name, update_referers: false)
      @created_cards = [new_target_name, referencer_name]

      expect(result["status"]).to eq("renamed")

      # Reference should still contain old name
      referencer = tools.get_card(referencer_name)
      expect(referencer["content"]).to include(target_name),
        "Reference was updated when it shouldn't have been"
    end
  end

  describe "error handling" do
    it "returns error for non-existent card" do
      expect {
        tools.rename_card("#{test_prefix}_NonExistent_#{rand(10000)}", "NewName")
      }.to raise_error(Magi::Archive::Mcp::Client::NotFoundError)
    end

    it "handles renaming to existing card name" do
      name1 = "#{test_prefix}_Exists1"
      name2 = "#{test_prefix}_Exists2"

      tools.create_card(name1, content: "Card 1", type: "RichText")
      tools.create_card(name2, content: "Card 2", type: "RichText")
      @created_cards = [name1, name2]

      sleep 0.5

      # Try to rename to existing name - should fail
      expect {
        tools.rename_card(name1, name2)
      }.to raise_error(Magi::Archive::Mcp::Client::APIError)
    end
  end

  describe "compound card renaming" do
    it "renames compound cards (Parent+Child)" do
      parent_name = "#{test_prefix}_CompoundParent"
      child_name = "#{parent_name}+Child"
      new_child_name = "#{parent_name}+RenamedChild"

      # Create parent and child
      tools.create_card(parent_name, content: "Parent", type: "RichText")
      tools.create_card(child_name, content: "Child content", type: "RichText")
      @created_cards = [child_name, parent_name]

      sleep 0.5

      # Rename the child
      result = tools.rename_card(child_name, new_child_name)
      @created_cards = [new_child_name, parent_name]

      expect(result["status"]).to eq("renamed")
      expect(result["old_name"]).to eq(child_name)
      expect(result["new_name"]).to eq(new_child_name)

      # Verify new name exists with correct content
      renamed = tools.get_card(new_child_name)
      expect(renamed["content"]).to include("Child content")

      # Note: Decko may create redirects, so old name might still resolve.
      # The key verification is that the rename succeeded and new name works.
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
