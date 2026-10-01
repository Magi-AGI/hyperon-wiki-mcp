# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "hyperon/wiki/mcp/config"
require "hyperon/wiki/mcp/client"
require "hyperon/wiki/mcp/http_timeouts"

# EVERY outbound Decko call must carry the shared timeout budget -- not just
# the ones in Client#request.
#
# Why this is a contract rather than a tuning detail: http.rb applies no
# timeout by default, so a socket that accepts a connection and then never
# answers parks the calling thread forever. These calls are reachable from
# inside RackApp::DISPATCH_LOCK, which serializes EVERY MCP dispatch, so one
# hung socket is a stalled server rather than one slow request.
#
# #health_check, #ping, and #get_raw were each unbounded while #request beside
# them was bounded, which is exactly the shape of regression these specs exist
# to catch: a new call site that reaches for HTTP directly looks ordinary and
# would otherwise pass review.
RSpec.describe Hyperon::Wiki::Mcp::HttpTimeouts do
  describe "OUTBOUND" do
    it "declares connect, write, and read budgets" do
      expect(described_class::OUTBOUND).to eq(connect: 5, write: 5, read: 30)
    end

    # An unbounded budget is the exact failure this guards against, so a zero,
    # nil, or infinite entry is as bad as a missing one.
    it "gives every budget a positive, finite value" do
      described_class::OUTBOUND.each_value do |seconds|
        expect(seconds).to be_a(Numeric)
        expect(seconds).to be > 0
        expect(seconds).to be_finite
      end
    end

    # The constant is the server's stall bound; a caller that mutated it in
    # place would widen that bound process-wide for every later request.
    it "is frozen" do
      expect(described_class::OUTBOUND).to be_frozen
    end
  end

  describe ".client" do
    it "applies per-operation timeouts rather than a global or null budget" do
      expect(described_class.client.default_options.timeout_class).to eq(HTTP::Timeout::PerOperation)
    end

    it "carries the declared budgets onto the client" do
      expect(described_class.client.default_options.timeout_options).to eq(
        connect_timeout: 5, write_timeout: 5, read_timeout: 30
      )
    end

    # HTTP::Client carries per-connection state and these call sites are
    # reachable concurrently, so a memoized instance would be cross-thread
    # mutable state for no gain.
    it "builds a fresh client per call" do
      expect(described_class.client).not_to be(described_class.client)
    end
  end
end

RSpec.describe Hyperon::Wiki::Mcp::Client do
  let(:client) do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["DECKO_API_BASE_URL"] = "https://test.example.com/api/mcp"
    ENV["MCP_ROLE"] = "user"
    described_class.new(Hyperon::Wiki::Mcp::Config.new)
  end

  let(:health_url) { "https://test.example.com/api/mcp/health" }
  let(:ping_url) { "https://test.example.com/api/mcp/health/ping" }
  let(:cards_url) { "https://test.example.com/api/mcp/cards" }
  let(:auth_url) { "https://test.example.com/api/mcp/auth" }

  before do
    WebMock.disable_net_connect!(allow_localhost: false)
    stub_request(:post, auth_url).to_return(
      status: 200,
      body: { "token" => "test-token", "role" => "user", "expires_in" => 3600 }.to_json
    )
  end

  after { WebMock.reset! }

  describe "HTTP_TIMEOUTS" do
    # Identity, not equality: the point of the shared module is that there is
    # ONE policy object. Two equal-but-separate hashes are the drift this
    # replaced.
    it "is the shared outbound policy, not a second copy of it" do
      expect(described_class::HTTP_TIMEOUTS).to be(Hyperon::Wiki::Mcp::HttpTimeouts::OUTBOUND)
    end
  end

  describe "#http_client" do
    it "returns a timeout-bounded client when given no headers" do
      expect(client.send(:http_client).default_options.timeout_options).to eq(
        connect_timeout: 5, write_timeout: 5, read_timeout: 30
      )
    end

    # Chaining .headers must not drop the budget -- HTTP's builder returns a
    # new options object at each step, so order and preservation matter.
    it "keeps the budget when headers are applied" do
      bounded = client.send(:http_client, { "Authorization" => "Bearer t" })

      expect(bounded.default_options.timeout_options).to eq(
        connect_timeout: 5, write_timeout: 5, read_timeout: 30
      )
      expect(bounded.default_options.headers["Authorization"]).to eq("Bearer t")
    end
  end

  # These three were the unbounded sites. Each is asserted two ways: that it
  # routes through the bounded builder at all, and that an expired budget
  # surfaces as the APIError callers already handle rather than escaping as a
  # raw transport class.
  describe "#health_check" do
    it "requests through the timeout-bounded client" do
      stub_request(:get, health_url).to_return(status: 200, body: { "status" => "healthy" }.to_json)

      allow(client).to receive(:http_client).and_call_original

      client.health_check

      expect(client).to have_received(:http_client)
    end

    it "surfaces an expired budget as an HTTP::Error rather than hanging" do
      stub_request(:get, health_url).to_timeout

      expect { client.health_check }.to raise_error(HTTP::Error)
    end
  end

  describe "#ping" do
    it "requests through the timeout-bounded client" do
      stub_request(:get, ping_url).to_return(status: 200, body: { "status" => "ok" }.to_json)

      allow(client).to receive(:http_client).and_call_original

      client.ping

      expect(client).to have_received(:http_client)
    end

    it "surfaces an expired budget as an HTTP::Error rather than hanging" do
      stub_request(:get, ping_url).to_timeout

      expect { client.ping }.to raise_error(HTTP::Error)
    end
  end

  describe "#get_raw" do
    it "requests through the timeout-bounded client" do
      stub_request(:get, cards_url).to_return(status: 200, body: "{}")

      allow(client).to receive(:http_client).and_call_original

      client.get_raw("/cards")

      expect(client).to have_received(:http_client).with(hash_including("Authorization"))
    end

    it "maps an expired budget onto APIError" do
      stub_request(:get, cards_url).to_timeout

      expect { client.get_raw("/cards") }.to raise_error(
        Hyperon::Wiki::Mcp::Client::APIError, /HTTP request failed/
      )
    end
  end

  describe "#request" do
    it "sends authenticated requests through the timeout-bounded client" do
      stub_request(:get, cards_url).to_return(status: 200, body: "{}")

      allow(client).to receive(:http_client).and_call_original

      client.get("/cards")

      expect(client).to have_received(:http_client).with(hash_including("Authorization"))
    end
  end

  # Source-level guard. The behavioral specs above only cover the call sites
  # that exist today; this is what fails when a NEW method reaches for the
  # unbounded HTTP module singleton, which is how all three original gaps got
  # in.
  describe "outbound call sites" do
    # Code only: comments in this file legitimately discuss `HTTP.get` and
    # `.timeout(` while explaining why neither may be called, and a guard that
    # its own rationale trips is a guard nobody keeps.
    let(:code_lines) do
      File.readlines(File.expand_path("../../../../lib/hyperon/wiki/mcp/client.rb", __dir__))
          .reject { |line| line.strip.start_with?("#") }
    end

    it "makes no unbounded HTTP module-level verb calls" do
      offenders = code_lines.grep(/\bHTTP\.(?:get|post|put|patch|delete|head)\b/)

      expect(offenders).to be_empty
    end

    # A local `.timeout(...)` would be a second budget outside the shared
    # policy -- the drift the shared module exists to prevent.
    it "declares no timeout budget of its own" do
      offenders = code_lines.grep(/\.timeout\(/)

      expect(offenders).to be_empty
    end
  end
end
