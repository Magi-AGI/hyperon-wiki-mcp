# frozen_string_literal: true

require "http"
require_relative "dispatch_deadline"

module Hyperon
  module Wiki
    module Mcp
      # The single timeout policy for every outbound Decko HTTP call, and the
      # single gate that refuses one when a server dispatch has no budget left.
      #
      # WHY THIS IS A CONTRACT, NOT A TUNING DETAIL
      #
      # http.rb applies NO timeout by default. A Decko socket that accepts the
      # connection and then never answers blocks the calling thread forever --
      # not slowly, permanently. Every outbound call in this gem is reachable
      # from inside RackApp::DISPATCH_LOCK (tool dispatch -> Client#request ->
      # Auth#token -> #fetch_token, the verification path -> #fetch_jwks, and
      # the health/ping/backup tools), and that lock serializes EVERY MCP
      # dispatch. So one hung socket is not a slow request, it is a stalled
      # server: no other session can acquire the lock to make progress, and
      # nothing ever releases it. These budgets are the only thing that bounds
      # that stall.
      #
      # WHY ONE SHARED POLICY
      #
      # Auth and Client previously each spelled the same three numbers out
      # locally, which meant the parity between them could only be checked by
      # scraping one file's source from the other's spec. Owning the numbers
      # here makes that parity an identity instead of a coincidence: there is
      # one place to read the policy, one place to change it, and no second
      # budget that can drift. The module is deliberately neutral -- neither
      # Auth nor Client owns it -- so neither has to require the other to stay
      # bounded.
      #
      # WHY THE DEADLINE IS ENFORCED HERE AND NOT ONLY ON THE RETRY PATH
      #
      # Bounding retries bounds one request's chain. It does not bound a
      # dispatch that makes MANY requests, each of them fast: Client#each_page
      # walks a card list page by page, and a tool can issue request after
      # request without ever retrying once. Those paths never consult a retry
      # budget, so a per-retry check leaves them unbounded. Every Decko-bound
      # call comes through here, because this is the only builder that produces
      # a client for Client and Auth. So this is where an expired budget has to
      # stop work: not by shrinking the next attempt's timeouts, but by
      # refusing to start it.
      #
      # "Every Decko-bound call" is the honest scope, and it is narrower than
      # "every outbound call in the process": Tools#upload_from_url fetches an
      # arbitrary third-party URL with its own Net::HTTP timeouts and never
      # touches this seam. See DispatchDeadline's WHAT THIS DOES NOT BOUND.
      module HttpTimeouts
        # Raised instead of starting outbound work the dispatch budget cannot
        # pay for.
        #
        # An HTTP::TimeoutError subclass on purpose. The budget expiring IS a
        # timeout, and the mapped call sites in this gem already rescue
        # HTTP::Error: Client#request and #get_raw map it to APIError,
        # Auth#fetch_jwks to JWKSError, Auth#fetch_token to
        # AuthenticationError. A fresh StandardError would escape all of those
        # and turn a bounded refusal into an unhandled crash in whatever tool
        # happened to be running.
        #
        # Two call sites deliberately do NOT map it: Client#health_check and
        # #ping have no `rescue HTTP::Error`, so a refusal surfaces there as a
        # raw BudgetExhaustedError. That is still a bounded, named failure --
        # the MCP tool wrapper catches StandardError -- but it is not an
        # APIError, and callers matching on APIError will not see it.
        class BudgetExhaustedError < HTTP::TimeoutError; end

        # Per-operation budgets for outbound Decko traffic.
        #
        # Per-operation rather than a single global budget on purpose: a global
        # timeout would also cap legitimate long reads, while these bound each
        # phase independently -- a dead connect fails in 5s, a stalled read in
        # 30s. The read budget is the generous one because it is the only one a
        # slow-but-working deployment actually needs.
        #
        # THESE ARE THE UNARMED NUMBERS, AND THEY ARE NOT NARROWED.
        #
        # Off the server path -- CLI, batch, stdio -- this hash is handed over
        # untouched, which is why lowering 30 would be a policy change and not
        # a fix: it would start failing slow-but-working deployments that
        # currently succeed.
        #
        # Under an armed server dispatch the read allowance IS narrowed, and
        # deliberately: .phase_budgets scales it to the budget, so a fresh 15s
        # dispatch reads for 10s and a 9s remainder reads for 6s. That is a
        # real tightening with a real cost -- a response that takes 12s can
        # fail inside a 15s dispatch even though the socket would have answered
        # -- and it is the chosen trade, because the alternative is holding
        # DISPATCH_LOCK past the point the caller has already hung up. The
        # 30s figure survives wherever nobody is blocked waiting on it.
        OUTBOUND = { connect: 5, write: 5, read: 30 }.freeze

        # How many times http.rb actually SPENDS each declared budget in one
        # attempt against an HTTPS endpoint.
        #
        # This is the correction that makes the advertised bound true. The
        # obvious reading of OUTBOUND is "one attempt costs at most 40s of
        # socket time", and that is wrong: http-5.3.1 charges @connect_timeout
        # TWICE on a TLS endpoint -- once in PerOperation#connect for the TCP
        # handshake, then again in #connect_ssl for the TLS handshake
        # (lib/http/timeout/per_operation.rb). Every Decko URL this gem talks
        # to is https, so connect is a 2x line item and not a 1x one.
        #
        # Splitting `remaining` across the three HASH ENTRIES therefore did not
        # bound socket time: a 15s budget allocated {5, 5, 5} summed to 15 but
        # permitted 5 + 5 + 5 + 5 = 20s on the wire. The allocation below
        # divides the budget by what the phases COST rather than by how many
        # entries the hash has.
        #
        # Not a derived constant: it is a fact about the gem's socket loop that
        # only a reader of that loop can confirm, so it is written down where
        # the arithmetic that depends on it lives, and pinned by spec.
        PHASE_SPENDS = { connect: 2, write: 1, read: 1 }.freeze

        # The weighted cost of one unclamped attempt: what OUTBOUND actually
        # spends on an HTTPS socket, as opposed to what its values sum to.
        #
        # 45s (5 connect x2, 5 write, 30 read), not the 40s the hash sums to.
        # This is the denominator the allocation scales by, so a budget at or
        # above it is handed OUTBOUND untouched.
        WEIGHTED_OUTBOUND_SECONDS = OUTBOUND.sum { |phase, seconds| seconds * PHASE_SPENDS.fetch(phase) }

        # The floor under any single phase of an attempt that is allowed to
        # start. Zero or a negative timeout is not "fail fast" to http.rb, it
        # is an argument it has no sane reading of, so an attempt admitted with
        # a sliver of budget left still gets a positive, finite number.
        #
        # This floor is the one documented way an attempt can outlive the
        # remaining budget. Work whose budget is already GONE is refused
        # outright rather than floored -- see .effective_budgets.
        MIN_PHASE_SECONDS = 1

        # The worst case one floored attempt can spend on an HTTPS socket:
        # MIN_PHASE_SECONDS charged once per SPEND, so 4s today and not 3s.
        #
        # The 3s figure that stood here counted hash entries instead of socket
        # operations and so understated the floor by exactly the TLS handshake.
        # This is the number the deadline's documented overshoot is stated in.
        MIN_ATTEMPT_SOCKET_SECONDS = MIN_PHASE_SECONDS * PHASE_SPENDS.values.sum

        # A timeout-bounded HTTP client, ready to chain (.headers, .get, ...).
        #
        # Call sites should start from this rather than from HTTP directly:
        # `HTTP.get(url)` is unbounded and looks perfectly ordinary, so the
        # bounded builder being the obvious entry point is what keeps an
        # unbounded call from being reintroduced by accident.
        #
        # Built fresh per call rather than memoized: HTTP::Client carries
        # per-connection state and these call sites are reachable concurrently
        # (two sessions, or a verification path racing a refresh), so a shared
        # instance would be cross-thread mutable state for no gain --
        # `HTTP.timeout` only branches an options object. Building per call is
        # also what makes this a usable gate: the budget is re-read at every
        # outbound call rather than once per process.
        #
        # Callers need no new rescue: HTTP::TimeoutError,
        # HTTP::ConnectTimeoutError and BudgetExhaustedError all descend from
        # HTTP::Error, so an expired budget surfaces through an existing
        # `rescue HTTP::Error` and fails closed like any other transport
        # failure instead of escaping as an unmapped error class.
        #
        # @return [HTTP::Client] a client carrying this call's budgets
        # @raise [BudgetExhaustedError] when an armed dispatch budget is spent
        def self.client
          HTTP.timeout(effective_budgets)
        end

        # OUTBOUND, narrowed to whatever a server dispatch has left.
        #
        # Unarmed -- every CLI, batch, and stdio caller -- this IS OUTBOUND,
        # the same object, so nothing outside server dispatch changes.
        #
        # Under an armed DispatchDeadline, two things happen that did not
        # before:
        #
        #   * A spent budget REFUSES the call. Floor budgets for expired work
        #     were how a paginated walk stayed unbounded: each page was
        #     individually quick, nothing retried, and the deadline only ever
        #     shrank timeouts it never enforced.
        #   * The surviving budget is SPLIT across the phases rather than
        #     handed to each of them. http.rb runs connect, then write, then
        #     read, sequentially, so clamping each one to `remaining`
        #     independently allowed remaining + connect + write -- 25s of
        #     socket time on a 15s budget. Splitting makes SOCKET SPEND the
        #     thing the deadline bounds, which is what "total" has to mean.
        #
        # THE CLOCK IS READ EXACTLY ONCE.
        #
        # This is load-bearing, not tidiness. Reading it twice -- once to ask
        # "expired?", again to ask "how much is left?" -- is a
        # time-of-check/time-of-use hole: a thread descheduled between the two
        # reads (a GC pause, a Puma worker losing its slice) passed the gate on
        # a live budget and then allocated against a DEAD one. `left` went
        # negative, every phase floored to MIN_PHASE_SECONDS, and already-dead
        # work was handed a fresh socket allowance -- verbatim the behavior the
        # refusal exists to remove. One read cannot disagree with itself.
        #
        # @return [Hash] per-operation budgets for this call
        # @raise [BudgetExhaustedError] when an armed dispatch budget is spent
        def self.effective_budgets
          left = DispatchDeadline.remaining
          return OUTBOUND if left.nil?

          refuse_exhausted_budget(left)
          phase_budgets(left)
        end

        # Stop an expired dispatch before it opens another socket.
        #
        # Raising rather than returning a flag so there is no way to call the
        # seam and ignore the answer: every outbound path that builds a client
        # through .client goes through here, and the raise is what makes the
        # refusal unskippable. The message carries the overspend because the
        # operator question this answers -- "did the request fail, or did we
        # refuse to make it?" -- is otherwise unanswerable from the logs.
        #
        # Takes `left` rather than re-reading the clock: the value that
        # refuses and the value that allocates must be the same observation,
        # or the gate can pass on a budget the allocation then finds dead.
        #
        # @param left [Numeric] seconds the deadline had on the single read
        def self.refuse_exhausted_budget(left)
          return if left.positive?

          raise BudgetExhaustedError,
                format("server dispatch budget exhausted %.1fs ago; refusing to start another outbound request",
                       -left.to_f)
        end
        private_class_method :refuse_exhausted_budget

        # Split `left` seconds across the phases of one attempt.
        #
        # Scales each declared budget by the fraction of a full attempt's
        # SOCKET COST the budget can pay for, so what the deadline bounds is
        # time actually spent on the wire rather than the sum of three hash
        # entries. WEIGHTED_OUTBOUND_SECONDS is that full cost (45s), which
        # charges connect twice because a TLS attempt spends it twice.
        #
        # Proportional rather than sequential-with-reservations, which is what
        # stood here: reserving a floor for each phase still to come made the
        # ENTRIES sum to `left` while the SPEND still overshot by a whole
        # connect allowance, and it spent the budget front-to-back, so a 9s
        # remainder gave connect its full 5s and left read with 1s. Scaling
        # keeps the phases in their declared proportion at every budget, so a
        # narrowed attempt looks like a smaller version of a full one rather
        # than a full connect followed by a starved read.
        #
        # Above WEIGHTED_OUTBOUND_SECONDS every phase pins to its declared
        # value, so a generous budget is OUTBOUND's numbers unchanged.
        #
        # One honest caveat remains, documented on DispatchDeadline: http.rb's
        # read and write budgets are inactivity windows re-armed per wait, so a
        # peer that trickles one byte per window outlives any total this module
        # can express. That needs an absolute deadline inside the socket loop
        # and is not fixable here.
        #
        # @param left [Numeric] seconds the deadline has left; must be positive
        # @return [Hash] budgets whose weighted socket cost is at most `left`,
        #   except for the MIN_ATTEMPT_SOCKET_SECONDS floor
        def self.phase_budgets(left)
          share = left / WEIGHTED_OUTBOUND_SECONDS.to_f

          # Floored with a beginless range rather than clamp(MIN, cap): a
          # nearly-spent budget makes the scaled share smaller than the floor,
          # and a two-argument clamp raises when its min exceeds its max.
          OUTBOUND.transform_values do |declared|
            [declared, declared * share].min.clamp(MIN_PHASE_SECONDS..)
          end
        end
        private_class_method :phase_budgets
      end
    end
  end
end
