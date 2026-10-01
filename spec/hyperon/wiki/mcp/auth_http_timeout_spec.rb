# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "hyperon/wiki/mcp/config"
require "hyperon/wiki/mcp/auth"
require "hyperon/wiki/mcp/client"
require "hyperon/wiki/mcp/dispatch_deadline"
require "hyperon/wiki/mcp/http_timeouts"

# Auth's outbound calls -- the JWKS fetch and the token fetch -- must carry
# explicit per-operation timeouts.
#
# Why this is worth its own spec rather than a line in auth_spec: both calls are
# reachable from inside RackApp::DISPATCH_LOCK, which serializes EVERY MCP
# dispatch. http.rb applies no timeout by default, so a Decko socket that
# accepts a connection and then never answers does not degrade one request --
# it parks the lock holder forever and no other session can dispatch at all.
# The timeout is the only thing that bounds that, so it is a contract, not a
# tuning detail, and a regression that silently drops it must fail a test.
RSpec.describe Hyperon::Wiki::Mcp::Auth do
  let(:config) do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["DECKO_API_BASE_URL"] = "https://test.example.com/api/mcp"
    ENV["MCP_ROLE"] = "user"
    Hyperon::Wiki::Mcp::Config.new
  end

  let(:auth) { described_class.new(config) }
  let(:jwks_url) { "https://test.example.com/api/mcp/.well-known/jwks.json" }
  let(:auth_url) { "https://test.example.com/api/mcp/auth" }

  before { WebMock.disable_net_connect!(allow_localhost: false) }

  after { WebMock.reset! }

  describe "HTTP_TIMEOUTS" do
    it "declares connect, write, and read budgets" do
      expect(described_class::HTTP_TIMEOUTS).to eq(connect: 5, write: 5, read: 30)
    end

    # An unbounded budget is the exact failure this guards against, so a zero
    # or nil entry is as bad as a missing one.
    it "gives every budget a positive, finite value" do
      described_class::HTTP_TIMEOUTS.each_value do |seconds|
        expect(seconds).to be_a(Numeric)
        expect(seconds).to be > 0
        expect(seconds).to be_finite
      end
    end

    # The constant is the server's stall bound; a caller that mutates it in
    # place would widen that bound for every later request process-wide.
    it "is frozen" do
      expect(described_class::HTTP_TIMEOUTS).to be_frozen
    end

    # Parity with Client is deliberate: one documented timeout policy for all
    # outbound Decko traffic rather than a second auth-only budget that drifts.
    #
    # Asserted as object identity against the shared policy, not by scraping
    # Client's source for a literal. The old string-scrape could only ever
    # prove the two files SPELL the same numbers, and would pass just as
    # happily if Client stopped applying them; identity proves there is only
    # one policy object to begin with.
    it "is the shared outbound policy, not a second copy of it" do
      expect(described_class::HTTP_TIMEOUTS).to be(Hyperon::Wiki::Mcp::HttpTimeouts::OUTBOUND)
    end

    it "is the same policy object Client applies" do
      expect(described_class::HTTP_TIMEOUTS).to be(Hyperon::Wiki::Mcp::Client::HTTP_TIMEOUTS)
    end
  end

  describe "#http_client" do
    subject(:http_client) { auth.send(:http_client) }

    it "applies per-operation timeouts rather than a global or null budget" do
      expect(http_client.default_options.timeout_class).to eq(HTTP::Timeout::PerOperation)
    end

    it "carries the declared budgets onto the client" do
      expect(http_client.default_options.timeout_options).to eq(
        connect_timeout: 5, write_timeout: 5, read_timeout: 30
      )
    end

    # A memoized client would be shared mutable per-connection state across the
    # threads that can reach #fetch_jwks and #fetch_token concurrently, and
    # buys nothing: HTTP.timeout only branches an options object.
    it "builds a fresh client per call" do
      expect(auth.send(:http_client)).not_to be(auth.send(:http_client))
    end
  end

  describe "#fetch_jwks" do
    it "requests JWKS through a timeout-bounded client" do
      stub_request(:get, jwks_url)
        .to_return(status: 200, body: { "keys" => [] }.to_json)

      bounded = HTTP.timeout(described_class::HTTP_TIMEOUTS)
      allow(auth).to receive(:http_client).and_return(bounded)

      auth.fetch_jwks

      expect(auth).to have_received(:http_client)
    end

    # HTTP::TimeoutError descends from HTTP::Error, so the existing rescue
    # already maps it. This pins that: an expired budget must fail closed as
    # JWKSError, not escape as a transport class callers do not handle.
    it "surfaces an expired budget as JWKSError" do
      stub_request(:get, jwks_url).to_timeout

      expect { auth.fetch_jwks }.to raise_error(Hyperon::Wiki::Mcp::Auth::JWKSError, /JWKS fetch failed/)
    end

    # Fail-closed means no cached keys: a timed-out fetch must not leave a
    # half-populated cache that a later verification would trust.
    it "leaves the JWKS cache empty when the budget expires" do
      stub_request(:get, jwks_url).to_timeout

      expect { auth.fetch_jwks }.to raise_error(Hyperon::Wiki::Mcp::Auth::JWKSError)

      expect(auth.instance_variable_get(:@jwks_cache)).to be_nil
      expect(auth.instance_variable_get(:@jwks_cached_at)).to be_nil
    end
  end

  describe "#fetch_token" do
    it "posts to the auth endpoint through a timeout-bounded client" do
      stub_request(:post, auth_url)
        .to_return(
          status: 200,
          body: { "token" => "test-token", "role" => "user", "expires_in" => 3600 }.to_json
        )

      bounded = HTTP.timeout(described_class::HTTP_TIMEOUTS)
      allow(auth).to receive(:http_client).and_return(bounded)

      auth.token

      expect(auth).to have_received(:http_client)
    end

    it "surfaces an expired budget as AuthenticationError" do
      stub_request(:post, auth_url).to_timeout

      expect { auth.token }.to raise_error(
        Hyperon::Wiki::Mcp::Auth::AuthenticationError, /Token fetch failed/
      )
    end

    # A timed-out fetch must publish no credential: a token with no deadline,
    # or a deadline with no token, is exactly the half-rotated pair
    # #publish_credential exists to prevent.
    it "publishes no credential when the budget expires" do
      stub_request(:post, auth_url).to_timeout

      expect { auth.token }.to raise_error(Hyperon::Wiki::Mcp::Auth::AuthenticationError)

      expect(auth.instance_variable_get(:@token)).to be_nil
      expect(auth.instance_variable_get(:@token_expires_at)).to be_nil
      expect(auth.token_valid?).to be(false)
    end
  end

  # The regression this fix closes was a bare HTTP.get / HTTP.post with no
  # budget. Asserting on the source keeps that specific shape from coming back
  # via a new call site that the behavioral specs above would not cover.
  describe "outbound call sites" do
    let(:source) do
      File.read(File.expand_path("../../../../lib/hyperon/wiki/mcp/auth.rb", __dir__))
    end

    it "makes no unbounded HTTP module-level calls" do
      unbounded = source.scan(/HTTP\.(?:get|post|put|patch|delete|head)\b/)

      expect(unbounded).to be_empty
    end
  end

  # Auth under an armed server-dispatch deadline.
  #
  # Worth its own section because Auth is on the critical path of every other
  # bounded call: Client#request calls auth.token BEFORE it builds a request,
  # and the verification path calls #fetch_jwks. If the deadline did not reach
  # these, an expired dispatch could still spend a fresh token fetch (connect +
  # write + read) before the request it was fetched for was refused -- so the
  # budget would bound the request and not the dispatch.
  #
  # Both paths reach the budget through HttpTimeouts.client, the same seam
  # Client uses, and both already rescue HTTP::Error -- which is why
  # BudgetExhaustedError is an HTTP::TimeoutError and not a new class.
  describe "under an armed dispatch deadline" do
    let(:clock) { { now: 1000.0 } }

    before { allow(Hyperon::Wiki::Mcp::DispatchDeadline).to receive(:now) { clock[:now] } }

    it "splits the remaining budget across the token fetch's phases" do
      stub_request(:post, auth_url).to_return(
        status: 200,
        body: { "token" => "test-token", "role" => "user", "expires_in" => 3600 }.to_json
      )

      Hyperon::Wiki::Mcp::DispatchDeadline.arm(9) do
        expect(auth.send(:http_client).default_options.timeout_options).to eq(
          connect_timeout: 5, write_timeout: 3, read_timeout: 1
        )
        expect(auth.token).to eq("test-token")
      end
    end

    it "refuses a token fetch once the budget is spent, as AuthenticationError" do
      stub_request(:post, auth_url).to_return(
        status: 200,
        body: { "token" => "test-token", "role" => "user", "expires_in" => 3600 }.to_json
      )

      Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
        clock[:now] += 20

        expect { auth.token }.to raise_error(
          Hyperon::Wiki::Mcp::Auth::AuthenticationError, /Token fetch failed/
        )
      end

      expect(WebMock).not_to have_requested(:post, auth_url)
    end

    it "refuses a JWKS fetch once the budget is spent, as JWKSError" do
      stub_request(:get, jwks_url).to_return(status: 200, body: { "keys" => [] }.to_json)

      Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
        clock[:now] += 20

        expect { auth.fetch_jwks }.to raise_error(
          Hyperon::Wiki::Mcp::Auth::JWKSError, /JWKS fetch failed/
        )
      end

      expect(WebMock).not_to have_requested(:get, jwks_url)
    end

    # Fail-closed, same as a timeout: a refused fetch must leave no credential
    # and no cached keys behind for a later call to trust.
    it "publishes no credential and caches no keys when refused" do
      Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
        clock[:now] += 20

        expect { auth.token }.to raise_error(Hyperon::Wiki::Mcp::Auth::AuthenticationError)
        expect { auth.fetch_jwks }.to raise_error(Hyperon::Wiki::Mcp::Auth::JWKSError)
      end

      expect(auth.instance_variable_get(:@token)).to be_nil
      expect(auth.token_valid?).to be(false)
      expect(auth.instance_variable_get(:@jwks_cache)).to be_nil
    end

    # The CLI/stdio half of the contract at Auth's seam: unarmed, a long auth
    # round trip is fine and must not be refused or narrowed.
    it "leaves unarmed callers on the full shared budget" do
      expect(auth.send(:http_client).default_options.timeout_options).to eq(
        connect_timeout: 5, write_timeout: 5, read_timeout: 30
      )
    end
  end
end
