# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "magi/archive/mcp/client"

RSpec.describe Magi::Archive::Mcp::Client do
  let(:config) do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["DECKO_API_BASE_URL"] = "https://test.example.com/api/mcp"
    ENV["MCP_ROLE"] = "user"
    Magi::Archive::Mcp::Config.new
  end

  let(:client) { described_class.new(config) }

  let(:valid_token) { "test-jwt-token" }
  let(:auth_response) do
    {
      "token" => valid_token,
      "role" => "user",
      "expires_in" => 3600
    }
  end

  before do
    # Stub auth endpoint
    stub_request(:post, "https://test.example.com/api/mcp/auth")
      .with(
        body: { api_key: "test-api-key", role: "user" }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      .to_return(
        status: 201,
        body: auth_response.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  describe "#initialize" do
    it "initializes with config" do
      expect(client.config).to eq(config)
    end

    it "creates auth instance" do
      expect(client.auth).to be_a(Magi::Archive::Mcp::Auth)
    end

    it "creates config if none provided" do
      ENV["MCP_API_KEY"] = "auto-created-key"
      client = described_class.new
      expect(client.config).to be_a(Magi::Archive::Mcp::Config)
    end
  end

  describe "#get" do
    let(:cards_url) { "https://test.example.com/api/mcp/cards" }
    let(:cards_response) do
      {
        "cards" => [
          { "name" => "Card 1", "content" => "Content 1" },
          { "name" => "Card 2", "content" => "Content 2" }
        ],
        "total" => 2
      }
    end

    before do
      stub_request(:get, cards_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(
          status: 200,
          body: cards_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "makes GET request with authentication" do
      response = client.get("/cards")

      expect(response).to eq(cards_response)
      expect(WebMock).to have_requested(:get, cards_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
    end

    it "includes query parameters" do
      stub_request(:get, cards_url)
        .with(
          query: { "limit" => "10", "offset" => "20" },
          headers: { "Authorization" => "Bearer #{valid_token}" }
        )
        .to_return(status: 200, body: cards_response.to_json)

      client.get("/cards", limit: 10, offset: 20)

      expect(WebMock).to have_requested(:get, cards_url)
        .with(query: { "limit" => "10", "offset" => "20" })
    end
  end

  describe "#post" do
    let(:cards_url) { "https://test.example.com/api/mcp/cards" }
    let(:create_payload) { { "name" => "New Card", "content" => "New content" } }
    let(:create_response) { { "card" => { "name" => "New Card", "id" => 123 } } }

    before do
      stub_request(:post, cards_url)
        .with(
          body: create_payload.to_json,
          headers: {
            "Authorization" => "Bearer #{valid_token}",
            "Content-Type" => "application/json"
          }
        )
        .to_return(
          status: 201,
          body: create_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "makes POST request with JSON body" do
      response = client.post("/cards", **create_payload)

      expect(response).to eq(create_response)
      expect(WebMock).to have_requested(:post, cards_url)
        .with(body: create_payload.to_json)
    end
  end

  describe "#patch" do
    let(:card_url) { "https://test.example.com/api/mcp/cards/MyCard" }
    let(:update_payload) { { "content" => "Updated content" } }
    let(:update_response) { { "card" => { "name" => "MyCard", "content" => "Updated content" } } }

    before do
      stub_request(:patch, card_url)
        .with(
          body: update_payload.to_json,
          headers: {
            "Authorization" => "Bearer #{valid_token}",
            "Content-Type" => "application/json"
          }
        )
        .to_return(
          status: 200,
          body: update_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "makes PATCH request with JSON body" do
      response = client.patch("/cards/MyCard", **update_payload)

      expect(response).to eq(update_response)
      expect(WebMock).to have_requested(:patch, card_url)
    end
  end

  describe "#delete" do
    let(:card_url) { "https://test.example.com/api/mcp/cards/MyCard" }
    let(:delete_response) { { "success" => true } }

    before do
      stub_request(:delete, card_url)
        .with(headers: { "Authorization" => "Bearer #{valid_token}" })
        .to_return(
          status: 200,
          body: delete_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "makes DELETE request" do
      response = client.delete("/cards/MyCard")

      expect(response).to eq(delete_response)
      expect(WebMock).to have_requested(:delete, card_url)
    end
  end

  describe "#paginated_get" do
    let(:cards_url) { "https://test.example.com/api/mcp/cards" }
    let(:paginated_response) do
      {
        "cards" => [
          { "name" => "Card 1" },
          { "name" => "Card 2" },
          { "name" => "Card 3" }
        ],
        "total" => 10,
        "limit" => 3,
        "offset" => 0,
        "next_offset" => 3
      }
    end

    before do
      stub_request(:get, cards_url)
        .with(
          query: { "limit" => "3", "offset" => "0" },
          headers: { "Authorization" => "Bearer #{valid_token}" }
        )
        .to_return(
          status: 200,
          body: paginated_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "returns structured pagination data" do
      result = client.paginated_get("/cards", limit: 3, offset: 0)

      expect(result[:data]).to eq(paginated_response["cards"])
      expect(result[:total]).to eq(10)
      expect(result[:limit]).to eq(3)
      expect(result[:offset]).to eq(0)
      expect(result[:next_offset]).to eq(3)
    end

    it "enforces maximum limit of 100" do
      stub_request(:get, cards_url)
        .with(query: { "limit" => "100", "offset" => "0" })
        .to_return(status: 200, body: paginated_response.to_json)

      client.paginated_get("/cards", limit: 200)

      expect(WebMock).to have_requested(:get, cards_url)
        .with(query: { "limit" => "100", "offset" => "0" })
    end
  end

  describe "#each_page" do
    let(:cards_url) { "https://test.example.com/api/mcp/cards" }

    before do
      # First page
      stub_request(:get, cards_url)
        .with(query: { "limit" => "2", "offset" => "0" })
        .to_return(
          status: 200,
          body: {
            "cards" => [{ "name" => "Card 1" }, { "name" => "Card 2" }],
            "total" => 5,
            "limit" => 2,
            "offset" => 0,
            "next_offset" => 2
          }.to_json
        )

      # Second page
      stub_request(:get, cards_url)
        .with(query: { "limit" => "2", "offset" => "2" })
        .to_return(
          status: 200,
          body: {
            "cards" => [{ "name" => "Card 3" }, { "name" => "Card 4" }],
            "total" => 5,
            "limit" => 2,
            "offset" => 2,
            "next_offset" => 4
          }.to_json
        )

      # Third page (last)
      stub_request(:get, cards_url)
        .with(query: { "limit" => "2", "offset" => "4" })
        .to_return(
          status: 200,
          body: {
            "cards" => [{ "name" => "Card 5" }],
            "total" => 5,
            "limit" => 2,
            "offset" => 4,
            "next_offset" => nil
          }.to_json
        )
    end

    it "yields each page" do
      pages = []
      client.each_page("/cards", limit: 2) do |page|
        pages << page
      end

      expect(pages.size).to eq(3)
      expect(pages[0]).to eq([{ "name" => "Card 1" }, { "name" => "Card 2" }])
      expect(pages[1]).to eq([{ "name" => "Card 3" }, { "name" => "Card 4" }])
      expect(pages[2]).to eq([{ "name" => "Card 5" }])
    end

    it "returns enumerator without block" do
      enumerator = client.each_page("/cards", limit: 2)
      expect(enumerator).to be_a(Enumerator)

      pages = enumerator.to_a
      expect(pages.size).to eq(3)
    end
  end

  describe "#fetch_all" do
    let(:cards_url) { "https://test.example.com/api/mcp/cards" }

    before do
      # First page
      stub_request(:get, cards_url)
        .with(query: { "limit" => "2", "offset" => "0" })
        .to_return(
          status: 200,
          body: {
            "cards" => [{ "name" => "Card 1" }, { "name" => "Card 2" }],
            "next_offset" => 2
          }.to_json
        )

      # Second page (last)
      stub_request(:get, cards_url)
        .with(query: { "limit" => "2", "offset" => "2" })
        .to_return(
          status: 200,
          body: {
            "cards" => [{ "name" => "Card 3" }],
            "next_offset" => nil
          }.to_json
        )
    end

    it "fetches all items across pages" do
      items = client.fetch_all("/cards", limit: 2)

      expect(items.size).to eq(3)
      expect(items).to eq([
                            { "name" => "Card 1" },
                            { "name" => "Card 2" },
                            { "name" => "Card 3" }
                          ])
    end
  end

  describe "error handling" do
    let(:cards_url) { "https://test.example.com/api/mcp/cards" }

    context "when API returns 401 Unauthorized" do
      before do
        stub_request(:get, cards_url)
          .to_return(
            status: 401,
            body: { "error" => "invalid_token", "message" => "Token expired" }.to_json
          )
      end

      it "raises AuthenticationError" do
        expect { client.get("/cards") }.to raise_error(
          Magi::Archive::Mcp::Client::AuthenticationError,
          /Token expired/
        ) do |error|
          expect(error.status).to eq(401)
          expect(error.error_code).to eq("invalid_token")
        end
      end
    end

    context "when API returns 403 Forbidden" do
      before do
        stub_request(:get, cards_url)
          .to_return(
            status: 403,
            body: { "error" => "permission_denied", "message" => "Insufficient permissions" }.to_json
          )
      end

      it "raises AuthorizationError" do
        expect { client.get("/cards") }.to raise_error(
          Magi::Archive::Mcp::Client::AuthorizationError
        ) do |error|
          expect(error.status).to eq(403)
        end
      end
    end

    context "when API returns 404 Not Found" do
      before do
        stub_request(:get, cards_url)
          .to_return(
            status: 404,
            body: { "error" => "not_found", "message" => "Card not found" }.to_json
          )
      end

      it "raises NotFoundError" do
        expect { client.get("/cards") }.to raise_error(
          Magi::Archive::Mcp::Client::NotFoundError
        )
      end
    end

    context "when API returns 422 Validation Error" do
      before do
        stub_request(:get, cards_url)
          .to_return(
            status: 422,
            body: {
              "error" => "validation_error",
              "message" => "Invalid input",
              "details" => { "name" => ["is required"] }
            }.to_json
          )
      end

      it "raises ValidationError with details" do
        expect { client.get("/cards") }.to raise_error(
          Magi::Archive::Mcp::Client::ValidationError
        ) do |error|
          expect(error.details).to eq({ "name" => ["is required"] })
        end
      end
    end

    context "when API returns 500 Server Error" do
      before do
        stub_request(:get, cards_url)
          .to_return(
            status: 500,
            body: { "error" => "internal_error", "message" => "Database error" }.to_json
          )
      end

      it "raises ServerError" do
        expect { client.get("/cards") }.to raise_error(
          Magi::Archive::Mcp::Client::ServerError
        ) do |error|
          expect(error.status).to eq(500)
        end
      end
    end
  end

  describe "Retry logic" do
    let(:cards_url) { "https://test.example.com/api/mcp/cards/Test" }

    before do
      # Stub successful auth
      allow(client).to receive_message_chain(:auth, :token).and_return(valid_token)
    end

    it "retries on 5xx server errors" do
      # First two attempts fail with 500, third succeeds
      stub_request(:get, cards_url)
        .to_return(
          { status: 500, body: '{"error":"internal_error"}' },
          { status: 500, body: '{"error":"internal_error"}' },
          { status: 200, body: '{"name":"Test"}', headers: { "Content-Type" => "application/json" } }
        )

      # Should succeed after retries (suppress stderr output during test)
      expect { client.get("/cards/Test") }.to output(/Retrying request after/).to_stderr

      # Verify it made 3 requests
      expect(WebMock).to have_requested(:get, cards_url).times(3)
    end

    it "retries on 429 rate limit errors" do
      # First attempt fails with 429, second succeeds
      stub_request(:get, cards_url)
        .to_return(
          { status: 429, body: '{"error":"rate_limit"}' },
          { status: 200, body: '{"name":"Test"}', headers: { "Content-Type" => "application/json" } }
        )

      expect { client.get("/cards/Test") }.to output(/Retrying request after/).to_stderr
      expect(WebMock).to have_requested(:get, cards_url).times(2)
    end

    it "gives up after 3 retry attempts" do
      # All 4 attempts (initial + 3 retries) fail
      stub_request(:get, cards_url)
        .to_return(status: 500, body: '{"error":"internal_error","message":"Server error"}')
        .times(4)

      # Should raise error after exhausting retries
      expect {
        expect { client.get("/cards/Test") }.to output(/Retrying request after/).to_stderr
      }.to raise_error(Magi::Archive::Mcp::Client::ServerError)

      # Verify it made exactly 4 requests (initial + 3 retries)
      expect(WebMock).to have_requested(:get, cards_url).times(4)
    end

    it "uses exponential backoff (1s, 2s, 4s)" do
      stub_request(:get, cards_url)
        .to_return(
          { status: 500 },
          { status: 500 },
          { status: 500 },
          { status: 200, body: '{"name":"Test"}', headers: { "Content-Type" => "application/json" } }
        )

      # Track sleep calls to verify backoff delays without waiting
      sleep_calls = []
      allow(client).to receive(:sleep) do |duration|
        sleep_calls << duration
      end

      # Capture stderr to verify retry messages with correct delays
      expect {
        client.get("/cards/Test")
      }.to output(/Retrying request after 1s.*Retrying request after 2s.*Retrying request after 4s/m).to_stderr

      # Verify exponential backoff: 1s, 2s, 4s
      expect(sleep_calls).to eq([1, 2, 4])
    end

    it "does not retry on 4xx client errors" do
      stub_request(:get, cards_url)
        .to_return(status: 404, body: '{"error":"not_found"}')

      # Should raise immediately without retry
      expect {
        client.get("/cards/Test")
      }.to raise_error(Magi::Archive::Mcp::Client::NotFoundError)

      # Should only make 1 request (no retries)
      expect(WebMock).to have_requested(:get, cards_url).once
    end

    it "retries on network errors" do
      # First two attempts have network errors, third succeeds
      stub_request(:get, cards_url)
        .to_raise(HTTP::ConnectionError).then
        .to_raise(HTTP::TimeoutError).then
        .to_return(status: 200, body: '{"name":"Test"}', headers: { "Content-Type" => "application/json" })

      expect { client.get("/cards/Test") }.to output(/Network error, retrying/).to_stderr
      expect(WebMock).to have_requested(:get, cards_url).times(3)
    end
  end
end
