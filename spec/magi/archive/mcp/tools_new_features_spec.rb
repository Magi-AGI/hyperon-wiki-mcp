# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "magi/archive/mcp/tools"

RSpec.describe Magi::Archive::Mcp::Tools, "new features" do
  before do
    # Set up required environment variables before config initialization
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["DECKO_API_BASE_URL"] = "https://test.example.com/api/mcp"
    ENV["MCP_ROLE"] = "admin"
  end

  after do
    # Clean up environment variables
    ENV.delete("MCP_API_KEY")
    ENV.delete("DECKO_API_BASE_URL")
    ENV.delete("MCP_ROLE")
  end

  let(:config) { Magi::Archive::Mcp::Config.new }
  let(:client) { Magi::Archive::Mcp::Client.new(config) }
  let(:tools) { Magi::Archive::Mcp::Tools.new(client) }

  let(:valid_token) { "test-jwt-token" }
  let(:auth_response) do
    {
      "token" => valid_token,
      "role" => "admin",
      "expires_in" => 3600
    }
  end

  before do
    # Stub auth endpoint
    stub_request(:post, "https://test.example.com/api/mcp/auth")
      .to_return(
        status: 201,
        body: auth_response.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  # ===== Card Relationship Tests =====

  describe "#get_referers" do
    let(:card_name) { "Main Page" }
    let(:url) { "https://test.example.com/api/mcp/cards/Main%20Page/referers" }
    let(:response_data) do
      {
        "card" => "Main Page",
        "referers" => [
          { "name" => "Home", "id" => 1, "type" => "Page" },
          { "name" => "About", "id" => 2, "type" => "Page" }
        ],
        "referer_count" => 2
      }
    end

    before do
      stub_request(:get, url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(status: 200, body: response_data.to_json)
    end

    it "returns cards that reference this card" do
      result = tools.get_referers(card_name)

      expect(result["card"]).to eq("Main Page")
      expect(result["referers"]).to be_an(Array)
      expect(result["referers"].length).to eq(2)
      expect(result["referer_count"]).to eq(2)
    end
  end

  describe "#get_nested_in" do
    it "returns cards that nest this card" do
      url = "https://test.example.com/api/mcp/cards/Template/nested_in"
      stub_request(:get, url)
        .to_return(status: 200, body: { "nested_in" => [], "nested_in_count" => 0 }.to_json)

      result = tools.get_nested_in("Template")
      expect(result).to have_key("nested_in")
    end
  end

  describe "#get_nests" do
    it "returns cards that this card nests" do
      url = "https://test.example.com/api/mcp/cards/Main%20Page/nests"
      stub_request(:get, url)
        .to_return(status: 200, body: { "nests" => [], "nests_count" => 0 }.to_json)

      result = tools.get_nests("Main Page")
      expect(result).to have_key("nests")
    end
  end

  describe "#get_links" do
    it "returns cards that this card links to" do
      url = "https://test.example.com/api/mcp/cards/Main%20Page/links"
      stub_request(:get, url)
        .to_return(status: 200, body: { "links" => [], "links_count" => 0 }.to_json)

      result = tools.get_links("Main Page")
      expect(result).to have_key("links")
    end
  end

  describe "#get_linked_by" do
    it "returns cards that link to this card" do
      url = "https://test.example.com/api/mcp/cards/Main%20Page/linked_by"
      stub_request(:get, url)
        .to_return(status: 200, body: { "linked_by" => [], "linked_by_count" => 0 }.to_json)

      result = tools.get_linked_by("Main Page")
      expect(result).to have_key("linked_by")
    end
  end

  # ===== Tag Search Tests =====

  describe "#search_by_tag" do
    it "searches for cards with a specific tag" do
      url = "https://test.example.com/api/mcp/cards"
      stub_request(:get, url)
        .with(query: hash_including("q" => "tags:Article"))
        .to_return(status: 200, body: { "cards" => [], "total" => 0 }.to_json)

      result = tools.search_by_tag("Article")
      expect(result).to have_key("cards")
    end
  end

  describe "#search_by_tags" do
    it "searches for cards with multiple tags (AND logic)" do
      url = "https://test.example.com/api/mcp/cards"
      stub_request(:get, url)
        .with(query: hash_including("q" => "tags:Article AND tags:Published"))
        .to_return(status: 200, body: { "cards" => [], "total" => 0 }.to_json)

      result = tools.search_by_tags(["Article", "Published"])
      expect(result).to have_key("cards")
    end
  end

  describe "#search_by_tags_any" do
    it "searches for cards with any of the specified tags (OR logic)" do
      url = "https://test.example.com/api/mcp/cards"
      stub_request(:get, url)
        .with(query: hash_including("q" => "tags:Article OR tags:Draft"))
        .to_return(status: 200, body: { "cards" => [], "total" => 0 }.to_json)

      result = tools.search_by_tags_any(["Article", "Draft"])
      expect(result).to have_key("cards")
    end
  end

  describe "#get_all_tags" do
    let(:url) { "https://test.example.com/api/mcp/cards" }

    it "returns all tags in the system" do
      stub_request(:get, url)
        .with(query: hash_including("type" => "Tag"))
        .to_return(status: 200, body: {
          "cards" => [
            { "name" => "Article" },
            { "name" => "Draft" },
            { "name" => "Published" }
          ]
        }.to_json)

      result = tools.get_all_tags
      expect(result).to be_an(Array)
      expect(result.length).to eq(3)
    end
  end

  describe "#get_card_tags" do
    let(:card_url) { "https://test.example.com/api/mcp/cards/Main%20Page%2Btags" }

    context "when tags exist" do
      before do
        stub_request(:get, card_url)
          .to_return(status: 200, body: {
            "name" => "Main Page+tags",
            "content" => "[[Article]]\n[[Published]]"
          }.to_json)
      end

      it "returns tags for a card" do
        result = tools.get_card_tags("Main Page")
        expect(result).to eq(["Article", "Published"])
      end
    end

    context "when tags card doesn't exist" do
      before do
        stub_request(:get, card_url)
          .to_return(status: 404, body: { "error" => "not_found" }.to_json)
      end

      it "returns empty array" do
        result = tools.get_card_tags("Main Page")
        expect(result).to eq([])
      end
    end
  end

  describe "#parse_tags_from_content" do
    it "parses tags from bracket format" do
      content = "[[Article]]\n[[Draft]]"
      result = tools.send(:parse_tags_from_content, content)
      expect(result).to eq(["Article", "Draft"])
    end

    it "parses tags from line-separated format" do
      content = "Article\nDraft\nPublished"
      result = tools.send(:parse_tags_from_content, content)
      expect(result).to eq(["Article", "Draft", "Published"])
    end

    it "returns unique tags" do
      content = "[[Article]]\n[[Article]]"
      result = tools.send(:parse_tags_from_content, content)
      expect(result).to eq(["Article"])
    end
  end

  # ===== Validation Tests =====

  describe "#validate_card_tags" do
    let(:url) { "https://test.example.com/api/mcp/validation/tags" }
    let(:validation_response) do
      {
        "valid" => true,
        "errors" => [],
        "warnings" => [],
        "required_tags" => ["GM"],
        "suggested_tags" => ["Game"],
        "provided_tags" => ["GM", "Game"]
      }
    end

    before do
      stub_request(:post, url)
        .with(body: hash_including("type" => "Game Master Document"))
        .to_return(status: 200, body: validation_response.to_json)
    end

    it "validates tags for a card type" do
      result = tools.validate_card_tags("Game Master Document", ["GM", "Game"])

      expect(result["valid"]).to be true
      expect(result).to have_key("errors")
      expect(result).to have_key("warnings")
    end

    it "includes content in validation" do
      stub_request(:post, url)
        .with(body: hash_including("content" => "Test content"))
        .to_return(status: 200, body: validation_response.to_json)

      tools.validate_card_tags("Article", [], content: "Test content")

      expect(WebMock).to have_requested(:post, url)
        .with(body: hash_including("content" => "Test content"))
    end
  end

  describe "#validate_card_structure" do
    let(:url) { "https://test.example.com/api/mcp/validation/structure" }

    it "validates card structure" do
      stub_request(:post, url)
        .to_return(status: 200, body: {
          "valid" => true,
          "errors" => [],
          "warnings" => [],
          "required_children" => [],
          "suggested_children" => ["*traits"]
        }.to_json)

      result = tools.validate_card_structure("Species", name: "Vulcans", has_children: true)

      expect(result).to have_key("valid")
      expect(result).to have_key("errors")
    end
  end

  describe "#get_type_requirements" do
    it "returns requirements for a card type" do
      url = "https://test.example.com/api/mcp/validation/requirements/Species"
      stub_request(:get, url)
        .to_return(status: 200, body: {
          "required_tags" => [],
          "suggested_tags" => ["Game"],
          "required_children" => [],
          "suggested_children" => ["*traits", "*description"]
        }.to_json)

      result = tools.get_type_requirements("Species")

      expect(result).to have_key("required_tags")
      expect(result).to have_key("suggested_children")
    end
  end

  describe "#create_card_with_validation" do
    let(:validation_url) { "https://test.example.com/api/mcp/validation/tags" }
    let(:batch_url) { "https://test.example.com/api/mcp/cards/batch" }

    context "when validation passes" do
      before do
        stub_request(:post, validation_url)
          .to_return(status: 200, body: { "valid" => true, "warnings" => [] }.to_json)

        # Batch operation returns multi-status with results for each operation
        stub_request(:post, batch_url)
          .to_return(status: 207, body: {
            "results" => [
              { "status" => "success", "card" => { "name" => "Test Card", "id" => 123 } },
              { "status" => "success", "card" => { "name" => "Test Card+tags", "id" => 124 } }
            ]
          }.to_json)
      end

      it "validates then creates the card and tags atomically" do
        result = tools.create_card_with_validation(
          "Test Card",
          type: "Species",
          tags: ["Game"],
          content: "Test content"
        )

        expect(result).to have_key("name")
        expect(result["name"]).to eq("Test Card")
        expect(WebMock).to have_requested(:post, validation_url)
        expect(WebMock).to have_requested(:post, batch_url).with { |req|
          body = JSON.parse(req.body)
          # Verify it's using transactional mode
          body["mode"] == "transactional" &&
            # Verify both card and tags operations are included
            body["ops"]&.size == 2 &&
            body["ops"][0]["action"] == "create" &&
            body["ops"][1]["name"].end_with?("+tags")
        }
      end
    end

    context "when validation fails" do
      before do
        stub_request(:post, validation_url)
          .to_return(status: 200, body: {
            "valid" => false,
            "errors" => ["Missing required tags: GM"],
            "warnings" => []
          }.to_json)
      end

      it "returns validation errors without creating" do
        result = tools.create_card_with_validation(
          "Test Card",
          type: "Game Master Document",
          tags: [],
          content: "Test"
        )

        expect(result["status"]).to eq("validation_failed")
        expect(result["errors"]).not_to be_empty
        expect(WebMock).not_to have_requested(:post, batch_url)
      end
    end

    context "when batch transaction fails" do
      before do
        stub_request(:post, validation_url)
          .to_return(status: 200, body: { "valid" => true, "warnings" => [] }.to_json)

        # Simulate transactional batch failure (all-or-nothing)
        stub_request(:post, batch_url)
          .to_return(status: 400, body: {
            "message" => "Transaction failed: Card name already exists",
            "results" => [
              { "status" => "error", "error" => "Card 'Test Card' already exists" }
            ]
          }.to_json)
      end

      it "returns error without creating partial data" do
        result = tools.create_card_with_validation(
          "Test Card",
          type: "Species",
          tags: ["Game"],
          content: "Test content"
        )

        # Should return error status, not a valid card
        expect(result["status"]).to eq("error")
        expect(result).to have_key("message")
        expect(result).to have_key("errors")
      end
    end
  end

  # ===== Recommendation Tests =====

  describe "#recommend_card_structure" do
    let(:url) { "https://test.example.com/api/mcp/validation/recommend_structure" }
    let(:recommendations) do
      {
        "card_type" => "Species",
        "card_name" => "Vulcans",
        "children" => [
          {
            "name" => "Vulcans+traits",
            "type" => "RichText",
            "purpose" => "Characteristics and traits",
            "priority" => "suggested"
          }
        ],
        "tags" => {
          "required" => [],
          "suggested" => ["Game"],
          "content_based" => []
        },
        "naming" => [],
        "summary" => "Recommendations: 1 suggested children, 1 suggested tags"
      }
    end

    before do
      stub_request(:post, url)
        .to_return(status: 200, body: recommendations.to_json)
    end

    it "returns comprehensive structure recommendations" do
      result = tools.recommend_card_structure(
        "Species",
        "Vulcans",
        tags: [],
        content: ""
      )

      expect(result["card_type"]).to eq("Species")
      expect(result["children"]).to be_an(Array)
      expect(result["tags"]).to have_key("required")
      expect(result).to have_key("summary")
    end
  end

  describe "#suggest_card_improvements" do
    let(:url) { "https://test.example.com/api/mcp/validation/suggest_improvements" }
    let(:improvements) do
      {
        "card_name" => "Vulcans",
        "card_type" => "Species",
        "missing_children" => [],
        "missing_tags" => [],
        "suggested_additions" => [
          {
            "pattern" => "*culture",
            "suggestion" => "Vulcans+culture",
            "priority" => "suggested"
          }
        ],
        "naming_issues" => [],
        "summary" => "1 suggested additions"
      }
    end

    before do
      stub_request(:post, url)
        .with(body: { "name" => "Vulcans" }.to_json)
        .to_return(status: 200, body: improvements.to_json)
    end

    it "analyzes existing card and suggests improvements" do
      result = tools.suggest_card_improvements("Vulcans")

      expect(result["card_name"]).to eq("Vulcans")
      expect(result).to have_key("suggested_additions")
      expect(result).to have_key("summary")
    end
  end

  # ===== Admin Backup Tests =====

  describe "#download_database_backup" do
    let(:url) { "https://test.example.com/api/mcp/admin/database/backup" }
    let(:backup_content) { "-- SQL DUMP\nCREATE TABLE..." }

    before do
      # Stub get_raw method to return a response with body
      allow(client).to receive(:get_raw).with("/admin/database/backup")
        .and_return(double("Response", body: backup_content))
    end

    it "downloads database backup to file" do
      require "tempfile"
      tempfile = Tempfile.new("test_backup")

      result = tools.download_database_backup(save_path: tempfile.path)

      expect(result).to eq(tempfile.path)
      expect(File.read(tempfile.path)).to eq(backup_content)

      tempfile.close
      tempfile.unlink
    end

    it "returns backup content without save_path" do
      result = tools.download_database_backup

      expect(result).to eq(backup_content)
    end
  end

  describe "#list_database_backups" do
    let(:url) { "https://test.example.com/api/mcp/admin/database/backup/list" }
    let(:backups_list) do
      {
        "backups" => [
          {
            "filename" => "magi_archive_backup_20251203_120000.sql",
            "size" => 12345678,
            "size_human" => "11.77 MB",
            "age" => "2 hours ago"
          }
        ],
        "total" => 1
      }
    end

    before do
      stub_request(:get, url)
        .to_return(status: 200, body: backups_list.to_json)
    end

    it "lists all available backups" do
      result = tools.list_database_backups

      expect(result["backups"]).to be_an(Array)
      expect(result["total"]).to eq(1)
      expect(result["backups"].first).to have_key("filename")
      expect(result["backups"].first).to have_key("size_human")
    end
  end

  describe "#download_database_backup_file" do
    let(:filename) { "magi_archive_backup_20251203_120000.sql" }
    let(:backup_content) { "-- SQL DUMP" }

    before do
      allow(client).to receive(:get_raw).with("/admin/database/backup/download/#{filename}")
        .and_return(double("Response", body: backup_content))
    end

    it "downloads specific backup file" do
      require "tempfile"
      tempfile = Tempfile.new("test_backup")

      result = tools.download_database_backup_file(filename, save_path: tempfile.path)

      expect(result).to eq(tempfile.path)
      expect(File.read(tempfile.path)).to eq(backup_content)

      tempfile.close
      tempfile.unlink
    end
  end

  describe "#delete_database_backup" do
    let(:filename) { "magi_archive_backup_20251203_120000.sql" }
    let(:url) { "https://test.example.com/api/mcp/admin/database/backup/#{filename}" }

    before do
      stub_request(:delete, url)
        .to_return(status: 200, body: {
          "message" => "Backup deleted successfully",
          "filename" => filename
        }.to_json)
    end

    it "deletes a backup file" do
      result = tools.delete_database_backup(filename)

      expect(result["message"]).to include("deleted successfully")
      expect(result["filename"]).to eq(filename)
    end
  end
end
