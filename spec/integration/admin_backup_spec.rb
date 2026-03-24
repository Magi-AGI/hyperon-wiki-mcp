# frozen_string_literal: true

require "spec_helper"
require_relative "../support/integration_helpers"

RSpec.describe "Admin Backup Integration", :integration do
  # Real HTTP integration tests for admin database backup operations
  # Run with: INTEGRATION_TEST=true rspec spec/integration/admin_backup_spec.rb
  #
  # Requires admin role for all backup operations

  let(:base_url) { ENV["DECKO_API_BASE_URL"] || "https://wiki.hyperon.dev/api/mcp" }

  before do
    skip "Integration tests disabled" unless ENV["INTEGRATION_TEST"]
  end

  describe "Admin backup operations" do
    let(:tools) { Magi::Archive::Mcp::Tools.new }

    before do
      # Ensure we're using admin role for these tests
      integration_client(role: "admin")
    end

    describe "list_database_backups" do
      it "successfully lists existing backups" do
        result = tools.list_database_backups

        expect(result).to have_key("backups")
        expect(result).to have_key("total")
        expect(result["backups"]).to be_an(Array)
        expect(result["total"]).to be_an(Integer)
      end

      it "includes backup metadata when backups exist" do
        # First create a backup
        tools.download_database_backup

        # Then list backups
        result = tools.list_database_backups

        if result["total"] > 0
          backup = result["backups"].first
          expect(backup).to have_key("filename")
          expect(backup).to have_key("size")
          expect(backup).to have_key("size_human")
          expect(backup).to have_key("age")
          expect(backup).to have_key("created_at")
          expect(backup).to have_key("modified_at")
        end
      end
    end

    describe "download_database_backup" do
      it "successfully creates a new backup" do
        result = tools.download_database_backup

        expect(result).to be_a(String)
        expect(result.length).to be > 0
        # Should be a SQL dump
        expect(result).to include("PostgreSQL")
      end

      it "creates backup file that appears in list" do
        # Get initial count
        before_count = tools.list_database_backups["total"]

        # Create backup
        tools.download_database_backup

        # Verify count increased (or stayed at 5 if cleanup ran)
        after_result = tools.list_database_backups
        # Server keeps max 5 backups, so count may not increase if at limit
        expect(after_result["total"]).to be >= [before_count, 1].max
        expect(after_result["total"]).to be <= 5
      end
    end

    describe "delete_database_backup" do
      it "successfully deletes an existing backup" do
        # Create a backup
        tools.download_database_backup
        list_result = tools.list_database_backups

        # Skip if no backups exist
        skip "No backups to delete" if list_result["total"] == 0

        # Delete the most recent backup
        backup_filename = list_result["backups"].first["filename"]
        result = tools.delete_database_backup(backup_filename)

        expect(result).to have_key("filename")
        expect(result["filename"]).to eq(backup_filename)
      end

      it "removes backup from list after deletion" do
        # Create a backup
        tools.download_database_backup
        before_list = tools.list_database_backups
        before_count = before_list["total"]

        # Skip if no backups
        skip "No backups to delete" if before_count == 0

        # Delete the backup
        backup_filename = before_list["backups"].first["filename"]
        tools.delete_database_backup(backup_filename)

        # Verify count decreased
        after_list = tools.list_database_backups
        expect(after_list["total"]).to eq(before_count - 1)
      end

      it "raises error when deleting non-existent backup" do
        expect {
          tools.delete_database_backup("nonexistent_backup_12345.sql")
        }.to raise_error(Magi::Archive::Mcp::Client::NotFoundError)
      end
    end
  end

  describe "Role-based access control" do
    before do
      # Role tests only work with API key authentication
      # With username/password, the role is determined by the account
      skip "Role tests require API key authentication" unless ENV["MCP_API_KEY"]
    end

    it "denies backup operations to user role" do
      # Set role to user
      ENV["MCP_ROLE"] = "user"
      user_tools = Magi::Archive::Mcp::Tools.new

      expect {
        user_tools.list_database_backups
      }.to raise_error(Magi::Archive::Mcp::Auth::AuthenticationError)
    end

    it "denies backup operations to gm role" do
      # Set role to gm
      ENV["MCP_ROLE"] = "gm"
      gm_tools = Magi::Archive::Mcp::Tools.new

      expect {
        gm_tools.list_database_backups
      }.to raise_error(Magi::Archive::Mcp::Auth::AuthenticationError)
    end
  end
end
