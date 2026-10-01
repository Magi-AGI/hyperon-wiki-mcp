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

  # The TLS correction. OUTBOUND's three values are what http.rb is TOLD, and
  # PHASE_SPENDS is how many times it actually charges each of them in one
  # attempt. The gap between those is what made the old bound wrong: a budget
  # split so the hash summed to 15 still permitted 20s of socket time, because
  # connect is spent twice against an https endpoint.
  describe "PHASE_SPENDS" do
    # The fact being asserted is about http-5.3.1's socket loop:
    # PerOperation#connect spends @connect_timeout on the TCP handshake and
    # #connect_ssl spends it AGAIN on the TLS handshake, while #write and
    # #readpartial each spend theirs once. Every Decko URL is https.
    it "charges connect twice and the other phases once" do
      expect(described_class::PHASE_SPENDS).to eq(connect: 2, write: 1, read: 1)
    end

    it "covers exactly the declared phases, so no budget goes uncounted" do
      expect(described_class::PHASE_SPENDS.keys).to eq(described_class::OUTBOUND.keys)
    end

    it "is frozen" do
      expect(described_class::PHASE_SPENDS).to be_frozen
    end

    # Guards the gem assumption this arithmetic rests on. If a future http.rb
    # stopped reusing the connect timeout for TLS -- or started charging write
    # twice -- the weighting here would silently become wrong, and the only
    # symptom would be an overshoot nobody is measuring.
    #
    # Asserted structurally (which method spends which ivar) rather than by
    # counting occurrences, so a cosmetic edit upstream does not fail this while
    # a real change in spending behavior still does.
    it "matches where http.rb actually spends each timeout" do
      gem_path = Gem.loaded_specs["http"].full_gem_path
      source = File.read(File.join(gem_path, "lib/http/timeout/per_operation.rb"))

      # Split the class into method bodies: each chunk runs from one `def` to
      # the next. Crude, but it is reading one small known file, and it is what
      # lets each assertion below name a single method rather than the whole
      # source.
      bodies = source.split(/^\s*def /).each_with_object({}) do |chunk, found|
        name = chunk[/\A(\w+)/, 1]
        found[name] = chunk if name
      end

      # connect is spent TWICE: once on the TCP handshake, again on TLS.
      expect(bodies.fetch("connect")).to include("@connect_timeout")
      expect(bodies.fetch("connect_ssl")).to include("@connect_timeout")
      # write and read are each spent in exactly one method, and never in the
      # other's -- so neither is a 2x line item the way connect is.
      expect(bodies.fetch("write")).to include("@write_timeout")
      expect(bodies.fetch("write")).not_to include("@read_timeout")
      expect(bodies.fetch("readpartial")).to include("@read_timeout")
      expect(bodies.fetch("readpartial")).not_to include("@write_timeout")
      # And neither connect method touches those, which is what makes connect
      # the only phase charged more than once.
      expect(bodies.fetch("connect")).not_to include("@read_timeout")
      expect(bodies.fetch("connect_ssl")).not_to include("@read_timeout")
    end

    # D1. PHASE_SPENDS is a FLOOR on what an attempt is billed, never a
    # ceiling on what it costs, and the docs that read it as a ceiling were
    # wrong three revisions running. These examples pin the mechanism so the
    # overclaim cannot come back as prose.
    #
    # The mechanism: PerOperation#connect_ssl is not wrapped in
    # ::Timeout.timeout the way #connect is. It delegates to rescue_readable /
    # rescue_writable (lib/http/timeout/null.rb), which are written
    # `retry if @socket.to_io.wait_readable(timeout)` -- so every handshake
    # record that lands inside the window restarts the FULL allowance. The
    # same shape governs #readpartial and #write.
    describe "the readiness-wait escape hatch PHASE_SPENDS cannot express" do
      # A socket that needs N readiness waits before connect_nonblock
      # completes -- exactly the case rescue_readable's retry loop exists to
      # handle, and exactly what a TLS handshake arriving in several records
      # looks like. Built anonymously so the spec declares no constant.
      #
      # Records every timeout it is handed, which is the direct evidence of
      # re-arming: a decrementing budget would hand down shrinking values.
      def trickling_socket(waits_needed:, wait_cost:)
        Class.new do
          attr_reader :wait_timeouts

          define_method(:initialize) do
            @waits_needed = waits_needed
            @wait_cost = wait_cost
            @wait_timeouts = []
            # IO::WaitReadable is a module and cannot be raised on its own; a
            # real non-blocking socket raises an Errno extended with it.
            @not_ready = Class.new(Errno::EWOULDBLOCK) { include IO::WaitReadable }
          end

          def connect_nonblock
            raise @not_ready, "tls record incomplete" if @wait_timeouts.length < @waits_needed

            :ok
          end

          # http.rb calls @socket.to_io.wait_readable(timeout).
          def to_io
            self
          end

          # Named by http.rb's socket contract, not by us: PerOperation calls
          # @socket.to_io.wait_readable(timeout). It returns truthy for "a
          # byte arrived", which is a readiness signal and not a predicate
          # about this object, so the `?` suffix the cop wants would break
          # the interface being doubled.
          def wait_readable(timeout) # rubocop:disable Naming/PredicateMethod
            @wait_timeouts << timeout
            sleep(@wait_cost)
            true # a byte arrived -> rescue_readable retries, re-arming `timeout`
          end
          alias_method :wait_writable, :wait_readable
        end.new
      end

      def time_connect_ssl(allowance, socket)
        timeout = HTTP::Timeout::PerOperation.new(
          connect_timeout: allowance, write_timeout: allowance, read_timeout: allowance
        )
        timeout.instance_variable_set(:@socket, socket)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        timeout.connect_ssl
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end

      # The direct refutation of "connect costs at most 2x its allowance".
      # Real HTTP::Timeout::PerOperation, real wall clock, scaled down so the
      # suite does not pay for the demonstration: six waits of 0.05s against a
      # 0.05s allowance spends ~0.3s, which is 6x the allowance and 3x the 2x
      # the model charges. Nothing times out -- that is the point.
      it "lets a TLS handshake outlive PHASE_SPENDS[:connect] x its allowance" do
        allowance = 0.05
        socket = trickling_socket(waits_needed: 6, wait_cost: allowance)

        elapsed = time_connect_ssl(allowance, socket)

        modeled_ceiling = allowance * described_class::PHASE_SPENDS.fetch(:connect)
        expect(socket.wait_timeouts.length).to eq(6)
        expect(elapsed).to be > modeled_ceiling
      end

      # WHY it outlives it: the allowance is re-armed, not decremented. Every
      # wait is handed the whole @connect_timeout, so the handshake's cost is
      # (waits) x (allowance) with nothing capping the wait count. This is the
      # assertion that fails the day http.rb grows an absolute deadline, which
      # is the day the docs may be tightened again.
      it "re-arms the full connect allowance on every readiness wait" do
        allowance = 0.02
        socket = trickling_socket(waits_needed: 4, wait_cost: 0.0)

        time_connect_ssl(allowance, socket)

        expect(socket.wait_timeouts).to eq([allowance] * 4)
      end

      # The floored case the deadline's overshoot figure is stated in. An
      # attempt admitted with a sliver of budget gets MIN_PHASE_SECONDS for
      # TLS, and MIN_ATTEMPT_SOCKET_SECONDS claims the WHOLE attempt costs 4s.
      # Measured at full scale that single phase has reached 2.034s on a 1s
      # allowance across five waits; proven here at 1/20th scale so the suite
      # stays fast. The ratio is what matters and the ratio is unbounded.
      it "can burn a floored attempt's whole modeled budget inside TLS alone" do
        scale = 0.05
        allowance = described_class::MIN_PHASE_SECONDS * scale
        socket = trickling_socket(waits_needed: 5, wait_cost: allowance * 0.8)

        elapsed = time_connect_ssl(allowance, socket)

        # 5 waits x 0.8 of the allowance == 4x the allowance == the whole
        # attempt's modeled floor, spent by one phase of it.
        expect(elapsed).to be > described_class::MIN_ATTEMPT_SOCKET_SECONDS * scale * 0.9
      end

      # Source-level guard on the gem, in the same spirit as the PHASE_SPENDS
      # structural check above. If http.rb ever stops re-arming, these fail
      # and the disclosure can be revisited rather than silently rotting.
      it "is a property of the installed http.rb, not of this spec's double" do
        gem_path = Gem.loaded_specs["http"].full_gem_path
        null_source = File.read(File.join(gem_path, "lib/http/timeout/null.rb"))
        per_operation = File.read(File.join(gem_path, "lib/http/timeout/per_operation.rb"))

        # The retry that re-arms, in both helpers.
        expect(null_source).to match(/def rescue_readable.*?retry if @socket\.to_io\.wait_readable\(timeout\)/m)
        expect(null_source).to match(/def rescue_writable.*?retry if @socket\.to_io\.wait_writable\(timeout\)/m)
        # connect_ssl goes through them; connect does NOT, because its
        # ::Timeout.timeout wrapper is a real ceiling on the TCP half.
        connect_ssl = per_operation[/def connect_ssl.*?^      end/m]
        expect(connect_ssl).to include("rescue_readable", "rescue_writable")
        expect(connect_ssl).not_to include("Timeout.timeout")
        expect(per_operation[/def connect\b.*?^      end/m]).to include("Timeout.timeout")
      end
    end
  end

  # The three statements the 8dad8ef closure review found false were all
  # prose, and prose is what regressed twice before it. These pin the
  # disclosure itself: the TLS escape hatch must stay named in the section
  # that lists what is NOT bounded, and PHASE_SPENDS must stay labelled a
  # floor. A future edit that quietly restores "socket spend is bounded"
  # fails here.
  describe "the documented contract" do
    def comments_in(relative_path)
      root = File.expand_path("../../../..", __dir__)
      File.readlines(File.join(root, relative_path), chomp: true)
          .select { |line| line.strip.start_with?("#") }
          .join("\n")
    end

    let(:deadline_comments) { comments_in("lib/hyperon/wiki/mcp/dispatch_deadline.rb") }
    let(:timeouts_comments) { comments_in("lib/hyperon/wiki/mcp/http_timeouts.rb") }

    it "lists the TLS handshake under WHAT THIS DOES NOT BOUND" do
      section = deadline_comments[/WHAT THIS DOES NOT BOUND(.*?)WHY SERVER DISPATCH ONLY/m]

      expect(section).not_to be_nil
      expect(section).to match(/connect_ssl/)
      expect(section).to match(/re-arm/i)
      expect(section).to match(/TLS/)
    end

    it "names the absolute-deadline follow-up as what would close it" do
      expect(deadline_comments).to match(/absolute deadline INSIDE the\s*#\s*socket loop/i)
      expect(timeouts_comments).to match(/absolute-deadline\s*#?\s*HTTP::Timeout subclass/i)
    end

    # The specific overclaim: an unqualified wall-clock bound on socket time.
    # Every surviving statement of the bound must mark itself as modeled.
    it "states the per-attempt bound as modeled rather than measured" do
      expect(deadline_comments).to match(/MODELED SOCKET SPEND/)
      expect(deadline_comments).to match(/MODELED, AND NOT A STOPWATCH/)
      expect(deadline_comments).not_to match(/^\s*#\s*\*\s*One attempt's SOCKET SPEND is at most/)
    end

    it "labels PHASE_SPENDS a floor rather than a ceiling" do
      expect(timeouts_comments).to match(/A FLOOR, not a ceiling/)
      expect(timeouts_comments).to match(/THESE ARE MINIMA/)
    end

    # The review also found "every Decko URL this gem talks to is https"
    # stated as fact while config.rb validates no scheme at all.
    it "qualifies the https assumption as the supported configuration" do
      expect(timeouts_comments).to match(/https in the supported configuration/)
    end
  end

  describe "WEIGHTED_OUTBOUND_SECONDS" do
    # 45s, not the 40s the hash sums to: the extra 5 is the TLS handshake.
    # This is the real cost of one unclamped attempt and the denominator the
    # allocation scales by.
    it "is what one unclamped attempt is billed on an https socket" do
      expect(described_class::WEIGHTED_OUTBOUND_SECONDS).to eq(45)
      expect(described_class::WEIGHTED_OUTBOUND_SECONDS).to be > described_class::OUTBOUND.values.sum
    end
  end

  describe "MIN_PHASE_SECONDS" do
    # http.rb has no sane reading of a zero or negative timeout, so an attempt
    # admitted with a sliver of budget left still needs a positive number per
    # phase. This floor is the ONE documented way an attempt can outlive the
    # remaining budget.
    it "is a positive, finite floor" do
      expect(described_class::MIN_PHASE_SECONDS).to be_a(Numeric)
      expect(described_class::MIN_PHASE_SECONDS).to be > 0
      expect(described_class::MIN_PHASE_SECONDS).to be_finite
    end
  end

  describe "MIN_ATTEMPT_SOCKET_SECONDS" do
    # The worst case a FLOORED attempt spends on the wire, which is the number
    # the deadline's documented overshoot is stated in. It must count socket
    # operations, not hash entries: counting entries gave 3s and understated
    # the floor by exactly the TLS handshake, which is how the overshoot the
    # docs advertised came to be smaller than the one the code allowed.
    it "counts the floor once per socket spend, not once per declared phase" do
      expect(described_class::MIN_ATTEMPT_SOCKET_SECONDS).to eq(4)
      expect(described_class::MIN_ATTEMPT_SOCKET_SECONDS).to eq(
        described_class::MIN_PHASE_SECONDS * described_class::PHASE_SPENDS.values.sum
      )
    end

    # If the floors could outrun the budget by much, "total" would stop meaning
    # anything. Pinning the overshoot keeps that trade visible -- and pinning it
    # against PHASE_SPENDS rather than a literal is what keeps the docs honest
    # if the weighting ever changes.
    it "bounds the worst-case overshoot of one attempt to a few seconds" do
      expect(described_class::MIN_ATTEMPT_SOCKET_SECONDS).to be <= 4
      expect(described_class::MIN_ATTEMPT_SOCKET_SECONDS).to be > described_class::OUTBOUND.size
    end
  end

  describe "BudgetExhaustedError" do
    # The mapped outbound paths rescue HTTP::Error and turn it into their own
    # failure (APIError, JWKSError, AuthenticationError). A refusal that did not
    # descend from it would escape all three and crash whatever tool was
    # running instead of failing closed.
    it "descends from HTTP::Error so existing rescues already map it" do
      expect(described_class::BudgetExhaustedError.ancestors).to include(HTTP::TimeoutError, HTTP::Error)
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
