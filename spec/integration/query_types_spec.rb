# frozen_string_literal: true

require "spec_helper"
require_relative "../support/integration_helpers"

RSpec.describe "Query Card Types", :integration do
  it "lists available card types on production server" do
    skip "Integration tests disabled" unless ENV["INTEGRATION_TEST"]

    client = Magi::Archive::Mcp::Client.new

    # Query for Cardtype cards
    result = client.get("/cards", type: "Cardtype", limit: 100)

    puts "\n=========================================="
    puts "Available card types on production server:"
    puts "=========================================="
    result["cards"].each do |card|
      puts "  - #{card['name']}"
    end
    puts "=========================================="
    puts "Total: #{result['cards'].size} card types"
    puts "==========================================\n"

    # This test always passes - it's just for information gathering
    expect(result["cards"].size).to be > 0
  end
end
