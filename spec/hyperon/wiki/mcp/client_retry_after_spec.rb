# frozen_string_literal: true

# Honoring Retry-After on 429, and the two things that must NOT change while it
# is honored.
#
# WHY THIS IS A SEPARATE FILE
#
# client_spec.rb pins the default retry schedule and dispatch_deadline_spec.rb
# pins the budget that bounds it. Retry-After sits exactly between them: it is
# the one input to the delay that neither this client nor its deadline chooses,
# and the risks it introduces are therefore risks to both files' contracts at
# once. Keeping them here makes the three-way interaction readable in one place.
#
# Two describes, because there are two things to check. RetryAfter is pinned
# directly -- parsing and the delay arithmetic, no chain, no sockets -- and then
# Client is driven end to end to show the chain actually spends what that module
# returns and gates it like any other backoff. The second is what the first
# cannot prove: a module returning the right number is worthless if #request
# ignores it.
#
# WHAT IS ACTUALLY BEING ASSERTED
#
#   * HONORED, as a LOWER BOUND. Retry-After tells a client not to retry BEFORE
#     a point in time; it does not tell it to retry AT that point. So the delay
#     is the MAXIMUM of the exponential backoff and the server's request, which
#     is why honoring it cannot make any existing retry more aggressive. A
#     response without the header takes the identical 1s/2s/4s path, and that
#     is asserted here rather than left to client_spec.rb, because a regression
#     that shortened the default would pass over there if it only shortened the
#     429 case.
#   * CAPPED, because the value comes from the peer. Off the server path there
#     is no deadline to refuse an absurd number with -- deliberately, that is
#     the CLI contract -- so RetryAfter::MAX_SECONDS is what stops a
#     `Retry-After: 86400` from parking a batch import for a day.
#   * BOUNDED BY THE DEADLINE, not exempt from it. A Retry-After is spent
#     through the same gate as any backoff, so one that does not fit in a
#     server dispatch's budget is REFUSED rather than slept. This is the
#     assertion that matters most: a peer-supplied delay that could outlive the
#     dispatch deadline would hold RackApp::DISPATCH_LOCK past the point the
#     caller has hung up, which is the exact failure the deadline exists to
#     prevent.
#   * 429 ONLY. 5xx retry timing is existing behavior; a Decko sending
#     Retry-After with a 503 must not silently lengthen every server-error
#     chain in the gem.
#
# Deterministic and offline: the monotonic clock is stubbed, sleeps are recorded
# rather than taken, and every response is a WebMock stub. Nothing here waits.

require "spec_helper"
require "webmock/rspec"
require "hyperon/wiki/mcp/client"
require "hyperon/wiki/mcp/config"
require "hyperon/wiki/mcp/dispatch_deadline"
require "hyperon/wiki/mcp/http_timeouts"
require "hyperon/wiki/mcp/retry_after"

# The header reading on its own, with no retry chain around it. Reachable
# directly because it lives in a neutral module rather than inside Client's
# retry policy -- which is most of the reason it lives there.
RSpec.describe Hyperon::Wiki::Mcp::RetryAfter do
  describe "MAX_SECONDS" do
    # Pinned to the shared read budget rather than spelled as a bare literal:
    # the justification for the number is that this gem already tolerates
    # waiting that long on this same peer, and a copy of "30" could drift away
    # from the budget that justifies it.
    it "is the shared outbound read budget, not an independent number" do
      expect(described_class::MAX_SECONDS)
        .to eq(Hyperon::Wiki::Mcp::HttpTimeouts::OUTBOUND.fetch(:read))
    end

    it "is a positive, finite number of seconds" do
      expect(described_class::MAX_SECONDS).to be_a(Numeric)
      expect(described_class::MAX_SECONDS).to be > 0
      expect(described_class::MAX_SECONDS).to be_finite
    end
  end

  describe ".parse" do
    it "reads delta-seconds" do
      expect(described_class.parse("7")).to eq(7)
      expect(described_class.parse("0")).to eq(0)
      expect(described_class.parse("  12  ")).to eq(12)
    end

    # The delta, not its rounding: httpdate has one-second resolution, so this
    # range is satisfied by rounding in either direction. The direction itself
    # is pinned below, on a frozen clock.
    it "reads an HTTP-date as a delta from now" do
      expect(described_class.parse((Time.now + 10).httpdate)).to be_between(9, 10).inclusive
    end

    it "reads a past HTTP-date as no wait rather than a negative one" do
      expect(described_class.parse((Time.now - 500).httpdate)).to eq(0)
    end

    # ROUNDED UP, exactly, and not merely "rounded". The range assertion above
    # stays green if from_http_date uses .floor or .round, so the direction
    # needs a clock frozen at a known fraction of a second to be assertable at
    # all. It is worth asserting because rounding DOWN retries just BEFORE the
    # instant the server named, which is the single thing RFC 9110 asks a
    # client honoring this header not to do.
    #
    # Time.now is stubbed rather than the delta computed from a real clock:
    # these examples are about the arithmetic on a fractional remainder, and a
    # real clock cannot be asked for one. Time.httpdate is untouched, so the
    # header still parses as the absolute instant it names.
    describe "the rounding direction on an HTTP-date" do
      let(:instant) { Time.utc(2026, 1, 1, 12, 0, 0) }

      # 9.75s to go: .ceil 10, .floor 9, .round 10.
      it "rounds a fractional delta up rather than down" do
        allow(Time).to receive(:now).and_return(instant + 0.25)

        expect(described_class.parse((instant + 10).httpdate)).to eq(10)
      end

      # 9.25s to go: .ceil 10, .floor 9, .round 9 -- the case that rules out
      # nearest-rounding as well as truncation.
      it "rounds up even where nearest-rounding would go down" do
        allow(Time).to receive(:now).and_return(instant + 0.75)

        expect(described_class.parse((instant + 10).httpdate)).to eq(10)
      end

      # Rounding up must not resurrect an elapsed date as a one-second wait:
      # the zero floor is applied after the rounding, not before it.
      it "still reads a fractionally-past date as no wait at all" do
        allow(Time).to receive(:now).and_return(instant + 0.25)

        expect(described_class.parse((instant - 30).httpdate)).to eq(0)
      end
    end

    # nil rather than 0 for each of these: "cannot read this" has to be
    # distinguishable from "wait zero seconds", because the caller turns the
    # former into its own backoff and the latter into a lower bound of zero.
    [nil, "", "   ", "soon", "-5", "1.5", "5s", "Wed, 21 Oct 2015", "0x10"].each do |value|
      it "returns nil for #{value.inspect} rather than guessing a number" do
        expect(described_class.parse(value)).to be_nil
      end
    end
  end

  describe ".delay" do
    # Built by hand rather than via a request so the arithmetic is tested
    # without a socket or a retry chain anywhere near it.
    def response(code, header = nil)
      headers = header.nil? ? {} : { "Retry-After" => header }
      instance_double(HTTP::Response, code: code, headers: headers)
    end

    it "returns the caller's default when there is no header" do
      expect(described_class.delay(response(429), default: 2)).to eq(2)
    end

    it "returns the caller's default for a non-429, header or not" do
      expect(described_class.delay(response(503, "20"), default: 1)).to eq(1)
      expect(described_class.delay(response(500, "20"), default: 4)).to eq(4)
      expect(described_class.delay(response(404, "20"), default: 1)).to eq(1)
    end

    it "honors a longer request" do
      expect(described_class.delay(response(429, "9"), default: 2)).to eq(9)
    end

    # The lower-bound reading of the header, which is what makes honoring it
    # safe: a server asking for less than the backoff cannot speed the chain
    # up.
    it "never returns less than the caller's default" do
      expect(described_class.delay(response(429, "1"), default: 4)).to eq(4)
      expect(described_class.delay(response(429, "0"), default: 1)).to eq(1)
    end

    it "caps a peer's demand at MAX_SECONDS" do
      expect(described_class.delay(response(429, "86400"), default: 1)).to eq(described_class::MAX_SECONDS)
    end

    # The cap must never cut into the CALLER's own backoff -- it exists to
    # limit the peer, not this gem.
    it "still returns the default when the default itself exceeds MAX_SECONDS" do
      oversized = described_class::MAX_SECONDS + 10
      expect(described_class.delay(response(429, "1"), default: oversized)).to eq(oversized)
      expect(described_class.delay(response(429, "86400"), default: oversized)).to eq(oversized)
    end

    it "takes a repeated header's first value rather than the whole array" do
      expect(described_class.delay(response(429, %w[5 9]), default: 1)).to eq(5)
    end
  end
end

RSpec.describe Hyperon::Wiki::Mcp::Client, "Retry-After on 429" do
  let(:client) do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["DECKO_API_BASE_URL"] = "https://test.example.com/api/mcp"
    ENV["MCP_ROLE"] = "user"
    described_class.new(Hyperon::Wiki::Mcp::Config.new)
  end

  let(:cards_url) { "https://test.example.com/api/mcp/cards/Test" }
  let(:clock) { { now: 1000.0 } }
  let(:slept) { [] }

  before do
    allow(client).to receive(:auth).and_return(instance_double(Hyperon::Wiki::Mcp::Auth, token: "test-token"))
    allow(Hyperon::Wiki::Mcp::DispatchDeadline).to receive(:now) { clock[:now] }
    allow(client).to receive(:sleep) do |seconds|
      slept << seconds
      clock[:now] += seconds
    end
  end

  def ok
    { status: 200, body: '{"name":"Test"}', headers: { "Content-Type" => "application/json" } }
  end

  def rate_limited(headers = {})
    { status: 429, body: '{"error":"rate_limit","message":"Too many requests"}', headers: headers }
  end

  # Recover the delay the chain actually chose, with one 429 followed by a
  # success, so each example names a single number instead of a schedule.
  def delay_for(response_headers)
    stub_request(:get, cards_url).to_return(rate_limited(response_headers), ok)
    expect { client.get("/cards/Test") }.to output(/Retrying request after/).to_stderr
    slept
  end

  describe "MAX_SECONDS, as this chain sees it" do
    # The chain's own sanity check on the constant it depends on: the examples
    # below assume the cap is longer than the longest default backoff, or
    # "capped" and "defaulted" would be indistinguishable.
    it "is longer than the longest default backoff" do
      expect(Hyperon::Wiki::Mcp::RetryAfter::MAX_SECONDS).to be > 4
    end
  end

  # The regression guard. Everything below changes a delay; this is the part
  # that must be observably unchanged, restated here rather than trusted to
  # client_spec.rb because a bug that only touched the 429 path would leave
  # that file green.
  describe "the default schedule, with no Retry-After present" do
    it "sleeps the unchanged 1s, 2s, 4s chain on repeated 429s" do
      stub_request(:get, cards_url).to_return(rate_limited)

      expect do
        expect { client.get("/cards/Test") }.to output(/Retrying request after/).to_stderr
      end.to raise_error(described_class::APIError) { |error| expect(error.status).to eq(429) }

      expect(slept).to eq([1, 2, 4])
      expect(WebMock).to have_requested(:get, cards_url).times(4)
    end

    it "sleeps the unchanged 1s, 2s, 4s chain on repeated 5xx" do
      stub_request(:get, cards_url).to_return(status: 503, body: '{"error":"unavailable"}')

      expect do
        expect { client.get("/cards/Test") }.to output(/Retrying request after/).to_stderr
      end.to raise_error(described_class::ServerError)

      expect(slept).to eq([1, 2, 4])
    end

    # The transport path has no response to read a header off, so it must be
    # byte-for-byte the old behavior -- including that nothing in the new code
    # is reached with a nil response.
    it "leaves the transport-failure chain on the default schedule" do
      stub_request(:get, cards_url).to_timeout

      expect do
        expect { client.get("/cards/Test") }.to output(/Network error, retrying/).to_stderr
      end.to raise_error(described_class::APIError, /HTTP request failed/)

      expect(slept).to eq([1, 2, 4])
    end

    it "does not retry a 4xx that is not a 429, header or no header" do
      stub_request(:get, cards_url).to_return(status: 404, body: '{"error":"not_found"}',
                                              headers: { "Retry-After" => "5" })

      expect { client.get("/cards/Test") }.to raise_error(described_class::NotFoundError)

      expect(slept).to be_empty
      expect(WebMock).to have_requested(:get, cards_url).once
    end
  end

  describe "a Retry-After the server sends with a 429" do
    it "waits the requested delta-seconds when it is longer than the backoff" do
      expect(delay_for("Retry-After" => "7")).to eq([7])
    end

    it "says the honored delay out loud rather than the backoff it replaced" do
      stub_request(:get, cards_url).to_return(rate_limited("Retry-After" => "7"), ok)

      expect { client.get("/cards/Test") }.to output(%r{Retrying request after 7s \(attempt 1/3\)}).to_stderr
    end

    it "succeeds on the attempt the honored wait was taken for" do
      stub_request(:get, cards_url).to_return(rate_limited("Retry-After" => "7"), ok)

      result = nil
      expect { result = client.get("/cards/Test") }.to output(/Retrying request after/).to_stderr

      expect(result).to eq("name" => "Test")
      expect(WebMock).to have_requested(:get, cards_url).times(2)
    end

    # Retry-After is a floor on when to retry, not an instruction to retry
    # sooner. A server asking for less than the backoff already scheduled is
    # satisfied by the longer wait, so this must not shorten anything.
    it "keeps the longer exponential backoff when the server asks for less" do
      stub_request(:get, cards_url)
        .to_return(rate_limited("Retry-After" => "1"), rate_limited("Retry-After" => "1"),
                   rate_limited("Retry-After" => "1"), ok)

      expect { client.get("/cards/Test") }.to output(/Retrying request after/).to_stderr

      expect(slept).to eq([1, 2, 4])
    end

    it "treats a zero-second request as no reason to shorten the backoff" do
      expect(delay_for("Retry-After" => "0")).to eq([1])
    end

    # The peer chooses this number, so it needs a ceiling that does not depend
    # on a deadline being armed.
    it "caps an absurd request at RetryAfter::MAX_SECONDS" do
      expect(delay_for("Retry-After" => "86400")).to eq([Hyperon::Wiki::Mcp::RetryAfter::MAX_SECONDS])
    end

    it "takes a repeated header's first value rather than the whole array" do
      expect(delay_for("Retry-After" => %w[5 9])).to eq([5])
    end

    it "is indifferent to header-name casing" do
      expect(delay_for("retry-after" => "6")).to eq([6])
    end
  end

  # Both forms RFC 9110 defines are accepted; the date form is the one a proxy
  # is most likely to emit.
  describe "the HTTP-date form" do
    it "waits until the stated instant" do
      stub_request(:get, cards_url).to_return(rate_limited("Retry-After" => (Time.now + 12).httpdate), ok)

      expect { client.get("/cards/Test") }.to output(/Retrying request after/).to_stderr

      # Bounded rather than exact: httpdate has one-second resolution, so the
      # computed delta lands just under the offset asked for.
      expect(slept.length).to eq(1)
      expect(slept.first).to be_between(11, 12).inclusive
    end

    it "falls back to the backoff for a date already in the past" do
      expect(delay_for("Retry-After" => (Time.now - 300).httpdate)).to eq([1])
    end

    it "caps a far-future date like any other oversized request" do
      expect(delay_for("Retry-After" => (Time.now + 86_400).httpdate))
        .to eq([Hyperon::Wiki::Mcp::RetryAfter::MAX_SECONDS])
    end
  end

  # An unreadable header is not a reason to invent a number or to stop
  # retrying; the chain falls back to the schedule it would have used anyway.
  describe "a Retry-After this client cannot read" do
    {
      "an empty value" => "",
      "whitespace" => "   ",
      "a word" => "soon",
      "a negative delta" => "-5",
      "a fractional delta" => "1.5",
      "a number with a unit" => "5s",
      "a half-parseable date" => "Wed, 21 Oct 2015"
    }.each do |label, value|
      it "ignores #{label} and uses the default backoff" do
        expect(delay_for("Retry-After" => value)).to eq([1])
      end
    end

    it "keeps retrying rather than giving up on an unreadable header" do
      stub_request(:get, cards_url).to_return(rate_limited("Retry-After" => "soon"), ok)

      result = nil
      expect { result = client.get("/cards/Test") }.to output(/Retrying request after 1s/).to_stderr

      expect(result).to eq("name" => "Test")
    end
  end

  # Scope. Honoring the header on 5xx may well be an improvement, but it is a
  # change to existing retry timing that nothing has asked for, and this spec
  # is what makes that a decision rather than a drift.
  describe "statuses other than 429" do
    it "ignores Retry-After on a 503" do
      stub_request(:get, cards_url)
        .to_return({ status: 503, body: '{"error":"unavailable"}', headers: { "Retry-After" => "20" } }, ok)

      expect { client.get("/cards/Test") }.to output(/Retrying request after 1s/).to_stderr

      expect(slept).to eq([1])
    end

    it "ignores Retry-After on a 500" do
      stub_request(:get, cards_url)
        .to_return({ status: 500, body: '{"error":"internal"}', headers: { "Retry-After" => "25" } }, ok)

      expect { client.get("/cards/Test") }.to output(/Retrying request after 1s/).to_stderr

      expect(slept).to eq([1])
    end
  end

  # The part that protects DISPATCH_LOCK. A peer-chosen delay is spent through
  # the same gate as any other backoff, so it cannot buy itself an exemption
  # from the budget the lock depends on.
  describe "under an armed server-dispatch deadline" do
    it "refuses a Retry-After that does not fit instead of sleeping it" do
      stub_request(:get, cards_url).to_return(rate_limited("Retry-After" => "20"))

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(5) { client.get("/cards/Test") }
        end.to output(/Dispatch budget exhausted before backoff/).to_stderr
      end.to raise_error(described_class::APIError) { |error| expect(error.status).to eq(429) }

      expect(slept).to be_empty
      expect(WebMock).to have_requested(:get, cards_url).once
    end

    # The contrast that proves the previous example is about the HEADER and not
    # about the budget being too small in general: the same 5s budget runs two
    # retries when the server does not ask for a longer wait.
    it "still runs the default chain on the same budget without the header" do
      stub_request(:get, cards_url).to_return(rate_limited)

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(5) { client.get("/cards/Test") }
        end.to output(/Dispatch budget exhausted/).to_stderr
      end.to raise_error(described_class::APIError)

      expect(slept).to eq([1, 2])
      expect(WebMock).to have_requested(:get, cards_url).times(3)
    end

    it "honors a Retry-After the budget can comfortably cover" do
      stub_request(:get, cards_url).to_return(rate_limited("Retry-After" => "3"), ok)

      result = nil
      expect do
        Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) { result = client.get("/cards/Test") }
      end.to output(/Retrying request after 3s/).to_stderr

      expect(result).to eq("name" => "Test")
      expect(slept).to eq([3])
    end

    # The invariant stated as wall-clock: a server can lengthen the waits, but
    # it cannot talk the chain into STARTING one that does not fit. Asserted as
    # the chain's own arithmetic, which is all a cooperative gate decides --
    # each honored wait is refused unless the budget covers it plus an
    # attempt, so the sleeps this chain chooses stay inside the 15s. A sleep
    # that OVERRAN its own number is a different case, caught by the recheck
    # rather than by this example; see the overrun example below.
    it "refuses an honored wait the budget cannot cover, however long the server asks for" do
      stub_request(:get, cards_url).to_return(rate_limited("Retry-After" => "6"))

      started = clock[:now]
      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) { client.get("/cards/Test") }
        end.to output(/Dispatch budget exhausted/).to_stderr
      end.to raise_error(described_class::APIError)

      expect(slept).to eq([6, 6])
      expect(clock[:now] - started).to be <= 15
    end

    # Same recheck the default path gets: the pre-check is a prediction, and an
    # honored wait that overran must abandon the attempt it was taken for
    # rather than start it on a dead budget.
    it "re-checks the budget after an honored wait that overran" do
      stub_request(:get, cards_url).to_return(rate_limited("Retry-After" => "3"))
      allow(client).to receive(:sleep) do |seconds|
        slept << seconds
        clock[:now] += seconds * 10
      end

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) { client.get("/cards/Test") }
        end.to output(/Dispatch budget exhausted after 3s backoff/).to_stderr
      end.to raise_error(described_class::APIError)

      expect(slept).to eq([3])
      expect(WebMock).to have_requested(:get, cards_url).once
    end

    # A budget too small to admit ANY retry, which is not the same as a spent
    # one: 0.5s is still positive, so the first attempt is made and it is the
    # retry gate that declines -- #room_for_retry? wants the 1s wait plus
    # MIN_ATTEMPT_SECONDS and has 0.5s. Header or no header, because the floor
    # the gate charges already exceeds the budget.
    it "refuses the first retry when the budget cannot admit one, header or no header" do
      stub_request(:get, cards_url).to_return(rate_limited("Retry-After" => "1"))

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(0.5) { client.get("/cards/Test") }
        end.to output(/Dispatch budget exhausted/).to_stderr
      end.to raise_error(described_class::APIError)

      expect(slept).to be_empty
      expect(WebMock).to have_requested(:get, cards_url).once
    end
  end

  # Off the server path nothing is armed, which is the whole reason the cap
  # above has to exist in this class rather than in the deadline.
  describe "with no deadline armed" do
    it "takes the full capped wait a CLI caller has no budget to refuse" do
      expect(Hyperon::Wiki::Mcp::RetryAfter::MAX_SECONDS).to be > 4
      expect(delay_for("Retry-After" => "3600")).to eq([Hyperon::Wiki::Mcp::RetryAfter::MAX_SECONDS])
    end
  end
end
