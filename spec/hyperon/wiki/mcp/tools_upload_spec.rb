# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "hyperon/wiki/mcp/tools"

RSpec.describe Hyperon::Wiki::Mcp::Tools, "file upload" do
  before do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["DECKO_API_BASE_URL"] = base_url
    ENV["MCP_ROLE"] = "user"
  end

  after do
    ENV.delete("MCP_API_KEY")
    ENV.delete("DECKO_API_BASE_URL")
    ENV.delete("MCP_ROLE")
  end

  let(:base_url) { "https://test.example.com/api/mcp" }
  let(:config) { Hyperon::Wiki::Mcp::Config.new }
  let(:client) { Hyperon::Wiki::Mcp::Client.new(config) }
  let(:tools) { Hyperon::Wiki::Mcp::Tools.new(client) }

  let(:valid_token) { "test-jwt-token" }
  let(:auth_response) do
    {
      "token" => valid_token,
      "role" => "user",
      "expires_in" => 3600
    }
  end

  before do
    stub_request(:post, "#{base_url}/auth")
      .to_return(
        status: 201,
        body: auth_response.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  # ===== upload_file Tests =====

  describe "#upload_file" do
    let(:card_name) { "My Document" }
    let(:upload_url) { "#{base_url}/cards/My%20Document/upload" }

    context "when uploading a file" do
      let(:response_data) do
        {
          "name" => "My Document",
          "id" => 42,
          "type" => "File",
          "file_url" => "https://wiki.hyperon.dev/files/my_document/report.pdf"
        }
      end

      before do
        stub_request(:post, upload_url)
          .with(
            body: hash_including("type" => "File", "file_data" => "dGVzdA==", "filename" => "report.pdf"),
            headers: { "Authorization" => "Bearer #{valid_token}" }
          )
          .to_return(status: 200, body: response_data.to_json,
                     headers: { "Content-Type" => "application/json" })
      end

      it "returns card data with file_url" do
        result = tools.upload_file(card_name, type: "File", file_data: "dGVzdA==", filename: "report.pdf")

        expect(result["name"]).to eq("My Document")
        expect(result["type"]).to eq("File")
        expect(result["file_url"]).to eq("https://wiki.hyperon.dev/files/my_document/report.pdf")
      end
    end

    context "when uploading an image" do
      let(:response_data) do
        {
          "name" => "My Document",
          "id" => 43,
          "type" => "Image",
          "file_url" => "https://wiki.hyperon.dev/files/my_document/original/diagram.png",
          "image_urls" => {
            "icon" => "https://wiki.hyperon.dev/files/my_document/icon/diagram.png",
            "small" => "https://wiki.hyperon.dev/files/my_document/small/diagram.png",
            "medium" => "https://wiki.hyperon.dev/files/my_document/medium/diagram.png",
            "large" => "https://wiki.hyperon.dev/files/my_document/large/diagram.png",
            "original" => "https://wiki.hyperon.dev/files/my_document/original/diagram.png"
          }
        }
      end

      before do
        stub_request(:post, upload_url)
          .with(
            body: hash_including("type" => "Image", "file_data" => "iVBOR==", "filename" => "diagram.png"),
            headers: { "Authorization" => "Bearer #{valid_token}" }
          )
          .to_return(status: 200, body: response_data.to_json,
                     headers: { "Content-Type" => "application/json" })
      end

      it "returns image_urls with size variants" do
        result = tools.upload_file(card_name, type: "Image", file_data: "iVBOR==", filename: "diagram.png")

        expect(result["type"]).to eq("Image")
        expect(result["image_urls"]).to be_a(Hash)
        expect(result["image_urls"].keys).to include("icon", "small", "medium", "large", "original")
        expect(result["file_url"]).to include("original/diagram.png")
      end
    end
  end

  # ===== upload_from_url Tests =====

  describe "#upload_from_url" do
    let(:card_name) { "Remote Image" }
    let(:upload_url) { "#{base_url}/cards/Remote%20Image/upload" }
    let(:source_url) { "https://example.com/photo.jpg" }

    let(:response_data) do
      {
        "name" => "Remote Image",
        "id" => 44,
        "type" => "Image",
        "file_url" => "https://wiki.hyperon.dev/files/remote_image/original/photo.jpg",
        "image_urls" => {
          "icon" => "https://wiki.hyperon.dev/files/remote_image/icon/photo.jpg",
          "small" => "https://wiki.hyperon.dev/files/remote_image/small/photo.jpg",
          "medium" => "https://wiki.hyperon.dev/files/remote_image/medium/photo.jpg",
          "large" => "https://wiki.hyperon.dev/files/remote_image/large/photo.jpg",
          "original" => "https://wiki.hyperon.dev/files/remote_image/original/photo.jpg"
        }
      }
    end

    before do
      stub_request(:post, upload_url)
        .with(
          body: hash_including("type" => "Image", "remote_url" => source_url),
          headers: { "Authorization" => "Bearer #{valid_token}" }
        )
        .to_return(status: 200, body: response_data.to_json,
                   headers: { "Content-Type" => "application/json" })
    end

    it "creates a card from a remote URL" do
      result = tools.upload_from_url(card_name, type: "Image", url: source_url)

      expect(result["name"]).to eq("Remote Image")
      expect(result["type"]).to eq("Image")
      expect(result["file_url"]).to include("remote_image")
      expect(result["image_urls"]).to be_a(Hash)
    end
  end

  # ===== get_file_url Tests =====

  describe "#get_file_url" do
    let(:card_name) { "My Document" }
    let(:file_url_endpoint) { "#{base_url}/cards/My%20Document/file_url" }

    context "for a file card" do
      let(:response_data) do
        {
          "name" => "My Document",
          "file_url" => "https://wiki.hyperon.dev/files/my_document/report.pdf"
        }
      end

      before do
        stub_request(:get, file_url_endpoint)
          .with(headers: { "Authorization" => "Bearer #{valid_token}" })
          .to_return(status: 200, body: response_data.to_json,
                     headers: { "Content-Type" => "application/json" })
      end

      it "returns the file URL" do
        result = tools.get_file_url(card_name)

        expect(result["name"]).to eq("My Document")
        expect(result["file_url"]).to eq("https://wiki.hyperon.dev/files/my_document/report.pdf")
      end
    end

    context "for an image card" do
      let(:response_data) do
        {
          "name" => "My Document",
          "file_url" => "https://wiki.hyperon.dev/files/my_document/original/diagram.png",
          "image_urls" => {
            "icon" => "https://wiki.hyperon.dev/files/my_document/icon/diagram.png",
            "small" => "https://wiki.hyperon.dev/files/my_document/small/diagram.png",
            "medium" => "https://wiki.hyperon.dev/files/my_document/medium/diagram.png",
            "large" => "https://wiki.hyperon.dev/files/my_document/large/diagram.png",
            "original" => "https://wiki.hyperon.dev/files/my_document/original/diagram.png"
          }
        }
      end

      before do
        stub_request(:get, file_url_endpoint)
          .with(headers: { "Authorization" => "Bearer #{valid_token}" })
          .to_return(status: 200, body: response_data.to_json,
                     headers: { "Content-Type" => "application/json" })
      end

      it "returns all size variants" do
        result = tools.get_file_url(card_name)

        expect(result["image_urls"]).to be_a(Hash)
        expect(result["image_urls"].keys).to include("icon", "small", "medium", "large", "original")
      end

      it "sets selected_url when size is specified" do
        result = tools.get_file_url(card_name, size: "medium")

        expect(result["selected_url"]).to eq("https://wiki.hyperon.dev/files/my_document/medium/diagram.png")
      end

      it "falls back to file_url when size variant not found" do
        result = tools.get_file_url(card_name, size: "nonexistent")

        expect(result["selected_url"]).to eq(result["file_url"])
      end
    end
  end
end
