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
      # budget, so a per-retry check leaves them unbounded. Every one of them
      # does come through here, because this is the only builder that produces
      # a client. So this is where an expired budget has to stop work: not by
      # shrinking the next attempt's timeouts, but by refusing to start it.
      module HttpTimeouts
        # Raised instead of starting outbound work the dispatch budget cannot
        # pay for.
        #
        # An HTTP::TimeoutError subclass on purpose. The budget expiring IS a
        # timeout, and every caller in this gem already rescues HTTP::Error:
        # Client#request and #get_raw map it to APIError, Auth#fetch_jwks to
        # JWKSError, Auth#fetch_token to AuthenticationError. A fresh
        # StandardError would escape all of those and turn a bounded refusal
        # into an unhandled crash in whatever tool happened to be running.
        class BudgetExhaustedError < HTTP::TimeoutError; end

        # Per-operation budgets for outbound Decko traffic.
        #
        # Per-operation rather than a single global budget on purpose: a global
        # timeout would also cap legitimate long reads, while these bound each
        # phase independently -- a dead connect fails in 5s, a stalled read in
        # 30s. The read budget is the generous one because it is the only one a
        # slow-but-working deployment actually needs; tightening it would start
        # failing such deployments, which is a policy change and not a fix.
        OUTBOUND = { connect: 5, write: 5, read: 30 }.freeze

        # The floor under any single phase of an attempt that is allowed to
        # start. Zero or a negative timeout is not "fail fast" to http.rb, it
        # is an argument it has no sane reading of, so an attempt admitted with
        # a sliver of budget left still gets a positive, finite number.
        #
        # This floor is the one documented way an attempt can outlive the
        # remaining budget, and it is bounded: at most OUTBOUND.size * this,
        # i.e. 3s today. Work whose budget is already GONE is refused outright
        # rather than floored -- see .effective_budgets.
        MIN_PHASE_SECONDS = 1

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
        #     socket time on a 15s budget. Splitting makes the SUM the thing
        #     the deadline bounds, which is what "total" has to mean.
        #
        # @return [Hash] per-operation budgets for this call
        # @raise [BudgetExhaustedError] when an armed dispatch budget is spent
        def self.effective_budgets
          return OUTBOUND unless DispatchDeadline.armed?

          refuse_exhausted_budget
          phase_budgets(DispatchDeadline.remaining)
        end

        # Stop an expired dispatch before it opens another socket.
        #
        # Raising rather than returning a flag so there is no way to call the
        # seam and ignore the answer: every outbound path in the gem goes
        # through .client, and the raise is what makes the refusal
        # unskippable. The message carries the overspend because the operator
        # question this answers -- "did the request fail, or did we refuse to
        # make it?" -- is otherwise unanswerable from the logs.
        def self.refuse_exhausted_budget
          return unless DispatchDeadline.expired?

          raise BudgetExhaustedError,
                format("server dispatch budget exhausted %.1fs ago; refusing to start another outbound request",
                       -DispatchDeadline.remaining.to_f)
        end
        private_class_method :refuse_exhausted_budget

        # Split `left` seconds across the phases of one attempt.
        #
        # Walks the phases in the order http.rb spends them and gives each the
        # smaller of its declared budget and what is left after reserving
        # MIN_PHASE_SECONDS for every phase still to come -- so a slow connect
        # cannot eat the read phase's whole allowance, and the three budgets
        # sum to at most `left` (floors aside).
        #
        # Two honest caveats, both documented on DispatchDeadline:
        # http.rb spends the connect budget twice on a TLS handshake (connect,
        # then connect_ssl), and its read/write budgets are inactivity
        # windows re-armed per wait, so a trickling peer outlives any sum.
        # Neither is fixable from here; both are far smaller than the
        # unbounded chain this replaces.
        #
        # @param left [Numeric] seconds the deadline has left
        # @return [Hash] per-operation budgets summing to at most `left`
        def self.phase_budgets(left)
          granted = {}
          phases = OUTBOUND.keys

          OUTBOUND.each_with_index do |(phase, declared), index|
            reserved = (phases.length - index - 1) * MIN_PHASE_SECONDS
            available = left - granted.values.sum - reserved
            # Floored with a beginless range rather than clamp(MIN, cap): a
            # nearly-spent budget makes `available` smaller than the floor,
            # and a two-argument clamp raises when its min exceeds its max.
            granted[phase] = [declared, available].min.clamp(MIN_PHASE_SECONDS..)
          end

          granted
        end
        private_class_method :phase_budgets
      end
    end
  end
end
