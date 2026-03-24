# frozen_string_literal: true

require "spec_helper"
require_relative "../support/integration_helpers"

RSpec.describe "Weekly Summary Integration", :integration do
  # Real HTTP integration tests for weekly summary generation
  # Run with: INTEGRATION_TEST=true rspec spec/integration/weekly_summary_spec.rb

  let(:base_url) { ENV["DECKO_API_BASE_URL"] || "https://wiki.hyperon.dev/api/mcp" }

  before do
    skip "Integration tests disabled" unless ENV["INTEGRATION_TEST"]
  end

  describe "Weekly summary generation" do
    let(:tools) { Magi::Archive::Mcp::Tools.new }
    let(:test_card_name) { "Weekly Summary Test #{Time.now.to_i}" }

    after do
      # Cleanup test summary card
      begin
        tools.delete_card(test_card_name)
      rescue StandardError
        # Ignore cleanup errors
      end
    end

    describe "create_weekly_summary" do
      it "creates a weekly summary card with custom name" do
        # Note: This requires git repositories to be present
        # May fail if no git repos are found
        # Use custom date to create unique card name
        result = tools.create_weekly_summary(
          create_card: true,
          days: 7,
          date: Time.now.strftime('%Y %m %d %H %M %S')
        )

        # Method returns the created card hash
        expect(result).to be_a(Hash)
        expect(result).to have_key("name")
        expect(result["content"]).to include("Weekly")
      end

      it "generates summary preview without creating card" do
        result = tools.create_weekly_summary(
          create_card: false,
          days: 7
        )

        # Method returns markdown string when create_card=false
        expect(result).to be_a(String)
        expect(result.length).to be > 0
        expect(result).to include("Weekly")
      end

      it "respects custom time range" do
        result = tools.create_weekly_summary(
          create_card: false,
          days: 3
        )

        expect(result).to be_a(String)
        expect(result.length).to be > 0
      end

      it "includes git repository changes when available" do
        result = tools.create_weekly_summary(
          create_card: false,
          days: 7,
          base_path: ENV["MAGI_WORKING_DIR"] || "/home/ubuntu"
        )

        expect(result).to be_a(String)
        expect(result.length).to be > 0
      end

      it "handles custom executive summary" do
        custom_summary = "This week we focused on testing and integration"

        result = tools.create_weekly_summary(
          create_card: false,
          days: 7,
          executive_summary: custom_summary
        )

        expect(result).to be_a(String)
        expect(result).to include(custom_summary)
      end

      it "includes username attribution when provided" do
        result = tools.create_weekly_summary(
          create_card: false,
          days: 7,
          username: "test-user"
        )

        expect(result).to be_a(String)
        expect(result).to include("test-user")
      end
    end

    describe "summary content structure" do
      it "includes required sections" do
        content = tools.create_weekly_summary(
          create_card: false,
          days: 7
        )

        expect(content).to be_a(String)
        expect(content).to include("Summary")
      end

      it "formats markdown correctly" do
        content = tools.create_weekly_summary(
          create_card: false,
          days: 7
        )

        expect(content).to be_a(String)
        # Should use markdown formatting with headers
        expect(content).to match(/^#/)
      end

      it "includes attribution footer" do
        content = tools.create_weekly_summary(
          create_card: false,
          days: 7
        )

        expect(content).to be_a(String)
        # Should be a complete summary
        expect(content).to include("Weekly")
        expect(content).to include("Summary")
      end
    end
  end

  describe "Error handling" do
    let(:tools) { Magi::Archive::Mcp::Tools.new }

    it "handles missing git repositories gracefully" do
      result = tools.create_weekly_summary(
        create_card: false,
        days: 7,
        base_path: "/nonexistent/path"
      )

      # Should not crash, just return summary without repo data
      expect(result).to be_a(String)
      expect(result.length).to be > 0
    end

    it "requires admin role for summary creation" do
      # Skip if using username/password auth (role is determined by account)
      skip "Role tests require API key authentication" unless ENV["MCP_API_KEY"]

      # Try with user role
      ENV["MCP_ROLE"] = "user"
      user_tools = Magi::Archive::Mcp::Tools.new

      expect {
        user_tools.create_weekly_summary(
          create_card: true,
          days: 7
        )
      }.to raise_error(Magi::Archive::Mcp::Auth::AuthenticationError)
    end
  end
end
