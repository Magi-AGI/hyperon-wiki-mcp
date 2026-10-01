# frozen_string_literal: true

# The total retry-chain deadline that keeps RackApp::DISPATCH_LOCK from being
# held for the full ~127s worst case.
#
# What this file pins, and why each half matters:
#
#   * ARMED (server dispatch only): the whole chain -- attempts, backoff
#     sleeps, and all -- is bounded by one total budget. HttpTimeouts already
#     bounds each ATTEMPT at connect 5s / write 5s / read 30s, but four
#     attempts plus 1+2+4s of backoff is ~127s, and every second of that is
#     spent holding the global dispatch lock, during which NO other session can
#     be served at all. A shorter per-attempt read would not fix it (it still
#     multiplies by four) and would start failing slow-but-working deployments.
#
#   * UNARMED (everything else): byte-for-byte the behavior that shipped. The
#     same Client, Auth, and Tools serve the stdio entrypoints
#     (bin/mcp-server, bin/hyperon-wiki-mcp, bin/magi-archive-mcp) and every
#     CLI and batch caller, which take no lock and block nobody. A CLI import
#     WANTS the long tail; capping it would turn slow successes into failures.
#     So the absence of a deadline off the server path is a contract in its own
#     right, asserted here rather than assumed.
#
# Deterministic and offline: time is driven through a stubbed monotonic clock
# and sleeps are captured rather than taken, so nothing here waits on a real
# clock or a real socket.

require "spec_helper"
require "webmock/rspec"
require "hyperon/wiki/mcp/client"
require "hyperon/wiki/mcp/config"
require "hyperon/wiki/mcp/dispatch_deadline"
require "hyperon/wiki/mcp/http_timeouts"

RSpec.describe Hyperon::Wiki::Mcp::DispatchDeadline do
  # A controllable monotonic clock. Real elapsed time would make every budget
  # assertion a race against the test runner's own scheduling.
  let(:clock) { { now: 1000.0 } }

  before { allow(described_class).to receive(:now) { clock[:now] } }

  def advance(seconds)
    clock[:now] += seconds
  end

  describe "SERVER_DISPATCH_BUDGET_SECONDS" do
    it "is the ~15s the caller already imposes from the other end" do
      expect(described_class::SERVER_DISPATCH_BUDGET_SECONDS).to eq(15)
    end

    # An unbounded or zero budget is the exact failure this guards against.
    it "is positive and finite" do
      expect(described_class::SERVER_DISPATCH_BUDGET_SECONDS).to be_a(Numeric)
      expect(described_class::SERVER_DISPATCH_BUDGET_SECONDS).to be > 0
      expect(described_class::SERVER_DISPATCH_BUDGET_SECONDS).to be_finite
    end
  end

  describe "when nothing is armed" do
    it "reports no budget at all, rather than an infinite one" do
      expect(described_class).not_to be_armed
      expect(described_class.remaining).to be_nil
    end

    # The CLI/batch contract in two lines: no clamping, no retry refusal.
    it "neither clamps a per-operation budget nor refuses a retry" do
      expect(described_class.clamp(30)).to eq(30)
      expect(described_class).to be_room_for(4)
      expect(described_class.room_for?(10_000)).to be(true)
    end
  end

  describe ".arm" do
    it "exposes a budget for the duration of the block and clears it afterward" do
      described_class.arm(15) do
        expect(described_class).to be_armed
        expect(described_class.remaining).to be_within(0.001).of(15)
      end

      expect(described_class).not_to be_armed
    end

    # Puma reuses worker threads across requests, so a budget left armed by a
    # failed dispatch would silently apply to whatever that thread served next.
    it "clears the budget even when the block raises" do
      expect { described_class.arm(15) { raise "dispatch exploded" } }.to raise_error(RuntimeError)

      expect(described_class).not_to be_armed
    end

    it "spends the budget down as the clock advances" do
      described_class.arm(15) do
        advance(10)

        expect(described_class.remaining).to be_within(0.001).of(5)
      end
    end

    # Negative rather than clamped to zero: callers distinguish "overspent"
    # from "no budget armed" (nil), and the sign is what carries that.
    it "reports a negative remainder once overspent" do
      described_class.arm(15) do
        advance(20)

        expect(described_class.remaining).to be_within(0.001).of(-5)
      end
    end

    # A nested arm that reset the clock would make the outer bound -- the one
    # the lock depends on -- meaningless.
    it "keeps the tighter deadline when nested, never extending the outer one" do
      described_class.arm(15) do
        advance(10)

        described_class.arm(15) do
          expect(described_class.remaining).to be_within(0.001).of(5)
        end

        expect(described_class.remaining).to be_within(0.001).of(5)
      end
    end

    it "restores the outer deadline after an inner arm finishes" do
      described_class.arm(30) do
        described_class.arm(2) { expect(described_class.remaining).to be_within(0.001).of(2) }

        expect(described_class.remaining).to be_within(0.001).of(30)
      end
    end

    # Thread-scoped, not process-global: two Puma workers serving concurrently
    # must not share or stomp one another's budget.
    it "scopes the budget to the arming thread" do
      seen_in_other_thread = nil

      described_class.arm(15) do
        Thread.new { seen_in_other_thread = described_class.armed? }.join
      end

      expect(seen_in_other_thread).to be(false)
    end

    # Client#each_page returns an Enumerator, and external enumeration runs on
    # a Fiber. Fiber-local state (Thread#[]) would vanish there, shedding the
    # deadline exactly where a long chain of paginated requests needs it.
    it "stays visible inside a Fiber, so paginated walks keep the budget" do
      seen_in_fiber = nil

      described_class.arm(15) do
        Fiber.new { seen_in_fiber = described_class.remaining }.resume
      end

      expect(seen_in_fiber).to be_within(0.001).of(15)
    end
  end

  describe ".clamp" do
    it "narrows a per-operation budget that would outlive the deadline" do
      described_class.arm(15) do
        advance(12)

        expect(described_class.clamp(30)).to be_within(0.001).of(3)
      end
    end

    it "leaves a per-operation budget alone when it already fits" do
      described_class.arm(15) { expect(described_class.clamp(5)).to eq(5) }
    end

    # http.rb has no sane reading of a zero or negative timeout, so an expired
    # deadline must still yield a positive, finite attempt budget.
    it "never hands out a zero or negative attempt budget" do
      described_class.arm(15) do
        advance(60)

        expect(described_class.clamp(30)).to eq(described_class::MIN_ATTEMPT_SECONDS)
        expect(described_class.clamp(30)).to be > 0
      end
    end
  end

  describe ".room_for?" do
    it "admits a retry that still fits inside the budget" do
      described_class.arm(15) { expect(described_class).to be_room_for(4) }
    end

    it "refuses a retry that would outlive the budget" do
      described_class.arm(15) do
        advance(13)

        expect(described_class).not_to be_room_for(4)
      end
    end

    it "refuses every retry once the budget is overspent" do
      described_class.arm(15) do
        advance(20)

        expect(described_class).not_to be_room_for(0)
      end
    end
  end
end

RSpec.describe Hyperon::Wiki::Mcp::HttpTimeouts, "under a dispatch deadline" do
  let(:clock) { { now: 1000.0 } }

  before { allow(Hyperon::Wiki::Mcp::DispatchDeadline).to receive(:now) { clock[:now] } }

  def advance(seconds)
    clock[:now] += seconds
  end

  # Identity, not equality: unarmed callers must get the shared policy object
  # itself, so there is provably no second budget off the server path.
  it "hands unarmed callers the shared policy object unchanged" do
    expect(described_class.effective_budgets).to be(described_class::OUTBOUND)
    expect(described_class.client.default_options.timeout_options).to eq(
      connect_timeout: 5, write_timeout: 5, read_timeout: 30
    )
  end

  # Without clamping the total would be advisory: a single 30s read already
  # exceeds a 15s budget and would park the lock for twice it.
  it "clamps a per-operation budget that would outlive the remaining deadline" do
    Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
      advance(12)

      expect(described_class.effective_budgets).to eq(connect: 3, write: 3, read: 3)
      expect(described_class.client.default_options.timeout_options).to eq(
        connect_timeout: 3, write_timeout: 3, read_timeout: 3
      )
    end
  end

  it "leaves budgets that already fit inside the deadline alone" do
    Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
      expect(described_class.effective_budgets).to eq(connect: 5, write: 5, read: 15)
    end
  end

  it "does not mutate the shared policy while clamping" do
    Hyperon::Wiki::Mcp::DispatchDeadline.arm(1) { described_class.effective_budgets }

    expect(described_class::OUTBOUND).to eq(connect: 5, write: 5, read: 30)
    expect(described_class::OUTBOUND).to be_frozen
  end
end

RSpec.describe Hyperon::Wiki::Mcp::Client, "retry chain under a dispatch deadline" do
  let(:client) do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["DECKO_API_BASE_URL"] = "https://test.example.com/api/mcp"
    ENV["MCP_ROLE"] = "user"
    described_class.new(Hyperon::Wiki::Mcp::Config.new)
  end

  let(:cards_url) { "https://test.example.com/api/mcp/cards/Test" }
  let(:clock) { { now: 1000.0 } }

  # Backoff sleeps are recorded, not taken, and they advance the stubbed clock
  # by exactly their delay -- so the budget is spent the way a real chain
  # spends it, without the suite ever waiting.
  let(:slept) { [] }

  before do
    allow(client).to receive(:auth).and_return(instance_double(Hyperon::Wiki::Mcp::Auth, token: "test-token"))
    allow(Hyperon::Wiki::Mcp::DispatchDeadline).to receive(:now) { clock[:now] }
    allow(client).to receive(:sleep) do |seconds|
      slept << seconds
      clock[:now] += seconds
    end
  end

  def stub_always_failing
    stub_request(:get, cards_url).to_return(status: 503, body: '{"error":"unavailable","message":"Server error"}')
  end

  # The default (CLI, batch, stdio) contract. These assertions deliberately
  # restate what client_spec.rb already pins: this change must not have moved
  # them, and a spec that only checked the armed path could not tell.
  describe "with no deadline armed" do
    it "still makes all four attempts and sleeps the full 1s, 2s, 4s chain" do
      stub_always_failing

      expect do
        expect { client.get("/cards/Test") }.to output(/Retrying request after/).to_stderr
      end.to raise_error(described_class::ServerError)

      expect(WebMock).to have_requested(:get, cards_url).times(4)
      expect(slept).to eq([1, 2, 4])
    end

    it "retries transport failures the full three times" do
      stub_request(:get, cards_url).to_timeout

      expect do
        expect { client.get("/cards/Test") }.to output(/Network error, retrying/).to_stderr
      end.to raise_error(described_class::APIError, /HTTP request failed/)

      expect(WebMock).to have_requested(:get, cards_url).times(4)
      expect(slept).to eq([1, 2, 4])
    end

    it "sends the unclamped shared budget on the wire" do
      stub_request(:get, cards_url).to_return(status: 200, body: "{}")

      client.get("/cards/Test")

      expect(client.send(:http_client).default_options.timeout_options).to eq(
        connect_timeout: 5, write_timeout: 5, read_timeout: 30
      )
    end
  end

  describe "with a server dispatch deadline armed" do
    # The headline: the chain stops once the budget is gone instead of running
    # all four attempts, so the lock is released in bounded time.
    it "stops retrying once the budget cannot cover the next backoff" do
      stub_always_failing

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(5) { client.get("/cards/Test") }
        end.to output(/Dispatch budget exhausted/).to_stderr
      end.to raise_error(described_class::ServerError)

      # 1s and 2s fit in 5s; the 4s backoff does not, so the 4th attempt is
      # never made.
      expect(slept).to eq([1, 2])
      expect(WebMock).to have_requested(:get, cards_url).times(3)
    end

    it "makes no retry at all when the budget is already spent" do
      stub_always_failing

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(0.5) { client.get("/cards/Test") }
        end.to output(/Dispatch budget exhausted/).to_stderr
      end.to raise_error(described_class::ServerError)

      expect(slept).to be_empty
      expect(WebMock).to have_requested(:get, cards_url).times(1)
    end

    # Giving up must fail the way the upstream failure already fails. A
    # synthetic deadline error class would be unhandled by every caller that
    # already maps ServerError.
    it "fails with the status Decko actually returned, not a synthetic error" do
      stub_always_failing

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(0.5) { client.get("/cards/Test") }
        end.to output(/Dispatch budget exhausted/).to_stderr
      end.to raise_error(described_class::ServerError) { |error| expect(error.status).to eq(503) }
    end

    it "bounds transport-failure retries by the same budget" do
      stub_request(:get, cards_url).to_timeout

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(2.5) { client.get("/cards/Test") }
        end.to output(/Network error, retrying/).to_stderr
      end.to raise_error(described_class::APIError, /HTTP request failed/)

      # 1s fits in 2.5s; the 2s backoff does not.
      expect(slept).to eq([1])
      expect(WebMock).to have_requested(:get, cards_url).times(2)
    end

    it "keeps retrying normally while the budget comfortably covers the chain" do
      stub_request(:get, cards_url).to_return(
        { status: 503, body: '{"error":"unavailable"}' },
        { status: 200, body: '{"name":"Test"}', headers: { "Content-Type" => "application/json" } }
      )

      result = nil
      expect do
        Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) { result = client.get("/cards/Test") }
      end.to output(/Retrying request after 1s/).to_stderr

      expect(result).to eq("name" => "Test")
      expect(slept).to eq([1])
    end

    # The sleep schedule is a budget-spending concern, so the chain must stop
    # on the TOTAL rather than on elapsed-per-attempt bookkeeping. This pins
    # the whole chain's wall-clock cost under the budget it was armed with.
    it "never spends more wall-clock on backoff than the armed budget" do
      stub_always_failing

      started = clock[:now]
      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(5) { client.get("/cards/Test") }
        end.to output(/Dispatch budget exhausted/).to_stderr
      end.to raise_error(described_class::ServerError)

      expect(clock[:now] - started).to be <= 5
    end
  end
end
