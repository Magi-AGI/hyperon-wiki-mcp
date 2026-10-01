# frozen_string_literal: true

module Hyperon
  module Wiki
    module Mcp
      # A total wall-clock deadline for everything one server dispatch sends
      # outbound, including its retries.
      #
      # WHY A TOTAL DEADLINE AND NOT A SMALLER PER-CALL TIMEOUT
      #
      # HttpTimeouts bounds each outbound ATTEMPT (connect 5s, write 5s, read
      # 30s). Client#request then retries up to three times on 429/5xx and on
      # transport errors, sleeping 1s, 2s, then 4s between them. Four bounded
      # attempts chained together are not bounded by any one attempt's budget:
      # 4 x 30s of read plus 7s of backoff is roughly 127 seconds, and that
      # figure is itself a floor rather than a ceiling -- it counts neither the
      # connect and write phases nor TLS, and http.rb's budgets are inactivity
      # windows (see WHAT THIS DOES NOT BOUND).
      #
      # That number only matters because of where the chain runs. RackApp
      # serializes EVERY MCP dispatch behind RackApp::DISPATCH_LOCK, and the
      # chain runs inside it. So a single slow Decko turns a two-minute retry
      # chain into a two-minute outage for every other session: they are not
      # slow, they cannot acquire the lock at all. Shortening the read budget
      # would not fix this (it multiplies by four just the same) and would
      # start failing slow-but-working deployments, which is a policy change
      # rather than a fix. Capping the TOTAL is the only bound that holds
      # regardless of how the attempts are arranged.
      #
      # WHAT THE BOUND ACTUALLY IS
      #
      # Stated precisely, because an advertised bound that does not hold is
      # worse than none -- it stops people looking:
      #
      #   * No outbound attempt STARTS once the budget is spent. HttpTimeouts
      #     refuses at the shared seam (BudgetExhaustedError), so an expired
      #     dispatch stops making requests instead of starting one more with a
      #     floor budget. That is what bounds a paginated walk, where the cost
      #     is the NUMBER of requests rather than any one request's timeout.
      #     The budget is read ONCE per decision, so the refusal and the
      #     allocation cannot disagree about whether it is still alive.
      #   * No retry is authorized unless the backoff AND the attempt it
      #     authorizes both fit (see #room_for_retry?), and the budget is
      #     re-checked after the backoff sleep actually happens.
      #   * One attempt's MODELED SOCKET SPEND is at most what the deadline
      #     has left, except for the per-phase floor. Modeled spend is each
      #     granted allowance multiplied by HttpTimeouts::PHASE_SPENDS -- not
      #     the plain sum of the three timeout values, because http.rb charges
      #     the connect allowance twice against a TLS endpoint (connect, then
      #     connect_ssl), so a hash summing to 15 is billed 20 by that model.
      #     HttpTimeouts allocates against the weighted cost for that reason.
      #   * The floor means a single attempt admitted with a sliver of budget
      #     left can overshoot THE MODEL by at most
      #     HttpTimeouts::MIN_ATTEMPT_SOCKET_SECONDS -- 4s today, counting the
      #     TLS handshake, where an earlier version of this comment said 3s by
      #     counting hash entries instead of socket operations.
      #
      # MODELED, AND NOT A STOPWATCH. Read that third bullet as the arithmetic
      # it is. The deadline bounds what http.rb is TOLD, weighted by how many
      # times it is told it; it does not bound elapsed wall-clock time on the
      # socket. Each of http.rb's three allowances -- read, write, AND the TLS
      # half of connect -- is an INACTIVITY window that re-arms on every
      # readiness wait, so real elapsed time is (number of waits) x (the
      # allowance) with nothing capping the wait count. PHASE_SPENDS[:connect]
      # = 2 is therefore a FLOOR on what a TLS attempt costs, never a ceiling.
      # Measured against the installed HTTP::Timeout::PerOperation: a 1s
      # connect allowance spends 1.851s in connect_ssl alone across six
      # readiness waits, and 2.034s across five 0.4s waits -- the latter is
      # half the whole-attempt floor burned by one phase. See WHAT THIS DOES
      # NOT BOUND, and HttpTimeouts::PHASE_SPENDS.
      #
      # So one armed dispatch is MODELED to spend at most its budget plus 4s,
      # against the ~127s+ the unbounded chain modeled before. What is
      # genuinely enforced regardless of peer behavior is narrower and still
      # worth having: no attempt STARTS on a spent budget, no retry is
      # authorized that cannot pay for itself, and every allowance handed to a
      # socket shrinks with the budget. A peer that keeps each phase barely
      # alive outlives all of that, which is the honest statement of the gap.
      #
      # Where the floor actually bites, in exact numbers rather than "about":
      # scaled allocation covers itself down to a 9.0s remainder, the point at
      # which connect and write land exactly on
      # HttpTimeouts::MIN_PHASE_SECONDS. Below 9.0 those two are floored while
      # read still scales -- left=3.0 allocates {1, 1, 2} for a modeled 5.0s.
      # At or below 1.5 all three are floored to {1, 1, 1}, a modeled
      # MIN_ATTEMPT_SOCKET_SECONDS of 4s however little is left, which is
      # where the worst modeled overshoot (+3.99s at left=0.01) lives. That
      # window is bounded in the model and is the price of never handing a
      # socket a zero timeout, which http.rb cannot read as "fail fast".
      #
      # WHAT THIS DOES NOT BOUND
      #
      #   * A trickling peer. http.rb's read and write budgets are INACTIVITY
      #     timeouts, re-armed on every wait_readable / wait_writable
      #     (http-5.3.1 lib/http/timeout/per_operation.rb #readpartial and
      #     #write). A server that emits one byte inside each window outlives
      #     any total this module can express.
      #   * A dribbling TLS handshake -- the same defect, through the same
      #     mechanism, in the phase the bullets above model as costing exactly
      #     2x. PerOperation#connect_ssl wraps @socket.connect_nonblock in
      #     rescue_readable(@connect_timeout) / rescue_writable(...), and
      #     those helpers (lib/http/timeout/null.rb) are written
      #     `retry if @socket.to_io.wait_readable(timeout)`: every handshake
      #     record that arrives inside the window re-arms the FULL connect
      #     allowance. Only the TCP half is genuinely capped, because
      #     #connect wraps it in ::Timeout.timeout. So PHASE_SPENDS[:connect]
      #     = 2 states the minimum a TLS attempt is billed, and a handshake
      #     split across N records can spend N x the allowance instead.
      #
      #     Both of these want the same fix: an absolute deadline INSIDE the
      #     socket loop -- a custom HTTP::Timeout subclass that compares a
      #     fixed wall-clock deadline before each retry rather than re-arming
      #     a fresh window. One class closes read, write and TLS together. It
      #     is a tracked follow-up and not this seam, and until it lands the
      #     bound above must be read as a bound on the allocation model and on
      #     the NUMBER of attempts, which is exactly what it is.
      #   * Outbound calls that do not go through HttpTimeouts. Tools
      #     #upload_from_url downloads an arbitrary third-party URL with its
      #     own Net::HTTP open/read timeouts; it never touches Decko, and it
      #     is unaffected by this budget.
      #   * Work that is not outbound HTTP at all: local computation inside a
      #     tool is not measured or interrupted here.
      #
      # WHY SERVER DISPATCH ONLY
      #
      # Client, Auth, and Tools are shared verbatim by the HTTP server
      # (RackApp) and by the stdio entrypoints (bin/mcp-server,
      # bin/hyperon-wiki-mcp, bin/magi-archive-mcp) plus every CLI and batch
      # caller. A CLI import or a backup walking thousands of cards WANTS the
      # long tail: there is no lock, nobody else is blocked, and giving up at
      # 15s would turn a slow success into a failure. The lock is what makes
      # the long tail harmful, so the deadline is armed where the lock is
      # taken and nowhere else. Outside server dispatch nothing here is armed
      # and every retry behaves exactly as it always has -- that absence is
      # the contract, not an oversight.
      #
      # WHY THREAD-SCOPED STATE
      #
      # The budget has to reach code it does not call directly: RackApp arms
      # it, then MCP::Server dispatches a tool, which reaches Tools, Client,
      # and Auth. Threading a deadline argument through all of that would mean
      # every one of those signatures, and any new call site that forgot the
      # argument would silently become unbounded again -- the same shape of
      # gap that left #health_check, #ping, and #get_raw without timeouts.
      #
      # Thread-scoped (Thread#thread_variable_set) rather than fiber-scoped
      # (Thread#[]) on purpose: Client#each_page hands back an Enumerator, and
      # external enumeration runs the block on a Fiber. Fiber-local state is
      # invisible there, so a paginated walk would quietly shed the deadline
      # exactly where a long chain of requests makes it matter most.
      #
      # Puma reuses worker threads across requests, so an armed budget left
      # behind would apply to whatever that thread served next. #arm restores
      # the previous value in an ensure for that reason, including when
      # dispatch raises.
      module DispatchDeadline
        # The total budget one server dispatch may spend on outbound Decko
        # traffic, retries and backoff sleeps included.
        #
        # 15 seconds because that is the constraint the client already imposes
        # from the other end: Client#request documents ChatGPT's ~15s timeout,
        # past which the connection is killed and nginx logs a 499. Work that
        # outlives the budget has no reader left -- it is only still holding
        # the lock. Making the server give up at the same point the caller
        # does converts a silent two-minute stall into one bounded error, and
        # leaves the lock free for the sessions queued behind it.
        SERVER_DISPATCH_BUDGET_SECONDS = 15

        # The smallest attempt worth authorizing a backoff sleep for.
        #
        # #room_for_retry? charges a retry for the backoff AND for the attempt
        # the backoff exists to make: sleeping 1s to start an attempt that the
        # seam will refuse the instant it begins spends lock time to learn
        # nothing.
        #
        # An ADMISSION HEURISTIC, not the real cost of an attempt. The modeled
        # floor cost is HttpTimeouts::MIN_ATTEMPT_SOCKET_SECONDS (4s), and
        # this is deliberately smaller: requiring 4s of headroom before any
        # retry would refuse retries that usually succeed in milliseconds,
        # trading a frequent real failure for a rare bounded overshoot. What
        # this number buys is the guarantee that an authorized attempt will
        # not be REFUSED outright -- it does not promise the attempt finishes
        # inside the budget. The overshoot that remains is the floor window
        # documented above, bounded by MIN_ATTEMPT_SOCKET_SECONDS in the
        # allocation model and not on the stopwatch (see WHAT THIS DOES NOT
        # BOUND).
        #
        # This is also NOT a floor handed to a socket --
        # HttpTimeouts::MIN_PHASE_SECONDS is that, and only for an attempt
        # that still has budget left when it starts.
        MIN_ATTEMPT_SECONDS = 1

        # Where the armed deadline lives on the current thread. Namespaced so
        # it cannot collide with a host application's own thread variables.
        VARIABLE = :hyperon_wiki_mcp_dispatch_deadline

        class << self
          # Monotonic, so arming the budget and checking it cannot be skewed
          # by a wall-clock adjustment (NTP step, DST) mid-dispatch.
          #
          # @return [Float] seconds from an arbitrary fixed point
          def now
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          # Run a block under a total outbound budget.
          #
          # Nesting does NOT extend the budget: an inner arm keeps whichever
          # deadline expires first. Otherwise a nested dispatch would hand
          # itself a fresh 15s and the outer bound -- the one the lock
          # actually depends on -- would mean nothing.
          #
          # @param seconds [Numeric] the total budget
          # @return [Object] the block's value
          def arm(seconds = SERVER_DISPATCH_BUDGET_SECONDS)
            previous = deadline_at
            candidate = now + seconds
            self.deadline_at = previous ? [previous, candidate].min : candidate
            yield
          ensure
            self.deadline_at = previous
          end

          # @return [Boolean] whether a budget is armed on this thread
          def armed?
            !deadline_at.nil?
          end

          # Seconds left in the armed budget, negative once it has been
          # overspent so callers can tell "nothing left" from "no budget".
          #
          # @return [Float, nil] nil when no budget is armed
          def remaining
            at = deadline_at
            at && (at - now)
          end

          # Whether an armed budget has been spent.
          #
          # The gate HttpTimeouts applies before it will build a client at
          # all. Distinct from `remaining <= 0` at the call site because an
          # UNARMED deadline must not read as expired: off the server path
          # there is no budget to spend, and work there must never be refused.
          #
          # @return [Boolean] true only when a budget is armed and gone
          def expired?
            left = remaining
            !left.nil? && left <= 0
          end

          # Whether a cost of `seconds` still fits in the armed budget.
          #
          # With no budget armed this is always true, which is what keeps CLI
          # and batch callers exactly as they were.
          #
          # @param seconds [Numeric] the cost about to be incurred
          # @return [Boolean]
          def room_for?(seconds)
            left = remaining
            left.nil? || left > seconds
          end

          # Whether a retry -- the backoff sleep AND the attempt it exists to
          # make -- still fits.
          #
          # Charging the backoff alone was the bug this replaces: with 1.1s
          # left and a 1s delay the chain slept, woke with 0.1s, and started
          # an attempt that could not accomplish anything. A retry is only
          # worth authorizing if there is still an attempt's worth of budget
          # on the far side of the sleep.
          #
          # Asked BEFORE the sleep, and the budget is checked AGAIN after it
          # (see Client#take_retry_pause): this predicts, the recheck
          # observes, and only the recheck knows what the sleep actually
          # cost.
          #
          # @param delay [Numeric] the backoff about to be slept
          # @return [Boolean]
          def room_for_retry?(delay)
            room_for?(delay + MIN_ATTEMPT_SECONDS)
          end

          private

          def deadline_at
            Thread.current.thread_variable_get(VARIABLE)
          end

          def deadline_at=(value)
            Thread.current.thread_variable_set(VARIABLE, value)
          end
        end
      end
    end
  end
end
