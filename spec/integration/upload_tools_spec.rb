# frozen_string_literal: true

require "spec_helper"
require "base64"
require_relative "../support/integration_helpers"

# Load MCP server tools
Dir[File.join(__dir__, '../../lib/hyperon/wiki/mcp/server/tools/**/*.rb')].sort.each { |f| require f }

RSpec.describe "File Upload Tools", :integration do
  # Integration tests for upload_file, upload_from_url, and get_file_url
  # Run with: INTEGRATION_TEST=true rspec spec/integration/upload_tools_spec.rb

  let(:tools) { Hyperon::Wiki::Mcp::Tools.new }
  let(:test_card_prefix) { "MCP Integration Test" }

  before do
    skip "Integration tests disabled" unless ENV["INTEGRATION_TEST"]
  end

  after do
    # Clean up test cards
    %w[Upload+Text Upload+Image Upload+URL].each do |suffix|
      card_name = "#{test_card_prefix}+#{suffix}"
      tools.delete_card(card_name)
    rescue StandardError
      # Card may not exist, that's fine
    end
  end

  describe "#upload_file" do
    it "uploads a text file and creates a File card" do
      card_name = "#{test_card_prefix}+Upload+Text"
      content = "Hello from MCP integration test at #{Time.now.iso8601}"
      file_data = Base64.strict_encode64(content)

      result = tools.upload_file(card_name, type: "File", file_data: file_data, filename: "test.txt")

      expect(result["name"]).to eq(card_name)
      expect(result["type"]).to eq("File")
      expect(result).to have_key("file_url")
    end

    it "uploads an image from URL and creates an Image card with size variants" do
      card_name = "#{test_card_prefix}+Upload+Image"

      # MCP server downloads the file itself, then sends base64 to Decko
      # — no longer blocks Thin's single thread
      result = tools.upload_from_url(card_name, type: "Image",
        url: "https://www.google.com/images/branding/googlelogo/1x/googlelogo_color_272x92dp.png")

      expect(result["name"]).to eq(card_name)
      expect(result["type"]).to eq("Image")
    end
  end

  describe "#upload_from_url" do
    it "creates a File card from a remote URL" do
      card_name = "#{test_card_prefix}+Upload+URL"

      # Use a small public file
      url = "https://raw.githubusercontent.com/Magi-AGI/hyperon-wiki-mcp/main/LICENSE"

      result = tools.upload_from_url(card_name, type: "File", url: url)

      expect(result["name"]).to eq(card_name)
      expect(result["type"]).to eq("File")
    end
  end

  describe "#get_file_url" do
    it "returns the file URL for a File card" do
      # First create a file card
      card_name = "#{test_card_prefix}+Upload+Text"
      content = "Test content for get_file_url"
      file_data = Base64.strict_encode64(content)
      tools.upload_file(card_name, type: "File", file_data: file_data, filename: "test.txt")

      # Then get its URL
      result = tools.get_file_url(card_name)

      expect(result["name"]).to eq(card_name)
      expect(result["type"]).to eq("File")
      expect(result).to have_key("file_url")
    end

    it "raises NotFoundError for non-existent card" do
      expect {
        tools.get_file_url("#{test_card_prefix}+Nonexistent+File+Card+12345")
      }.to raise_error(Hyperon::Wiki::Mcp::Client::NotFoundError)
    end
  end
end
