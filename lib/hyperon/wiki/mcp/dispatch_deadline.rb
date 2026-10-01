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
      # worst case is 4 x 30s of read plus 7s of backoff, roughly 127 seconds.
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

        # The floor for any single clamped attempt. A deadline that has
        # already expired must still hand the attempt a positive, finite
        # budget: zero or a negative timeout is not "fail fast" to http.rb,
        # it is an argument it has no sane reading of.
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

          # Narrow a per-operation budget so it cannot outlive the deadline.
          #
          # Without this the total would be advisory: one attempt is allowed a
          # 30s read, so a chain armed at 15s could still park the lock for
          # 30s before anyone checked the clock. Clamping makes the attempt
          # itself expire at the deadline.
          #
          # @param seconds [Numeric] the unclamped per-operation budget
          # @return [Numeric] seconds, or what is left of the budget
          def clamp(seconds)
            left = remaining
            return seconds if left.nil?

            # Floored with a beginless range rather than clamp(MIN, left): an
            # expired deadline makes `left` smaller than the floor, and a
            # two-argument clamp raises when its min exceeds its max.
            [seconds, left].min.clamp(MIN_ATTEMPT_SECONDS..)
          end

          # Whether another attempt costing at least `seconds` still fits.
          #
          # Asked BEFORE a retry sleeps, not after: sleeping out the backoff
          # and then discovering the budget is gone spends lock time to learn
          # nothing. With no budget armed this is always true, which is what
          # keeps CLI and batch retries exactly as they were.
          #
          # @param seconds [Numeric] the cost about to be incurred
          # @return [Boolean]
          def room_for?(seconds)
            left = remaining
            left.nil? || left > seconds
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
