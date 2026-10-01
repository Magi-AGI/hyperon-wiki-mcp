# frozen_string_literal: true

# The total dispatch deadline that keeps RackApp::DISPATCH_LOCK from being held
# for the ~127s-and-up worst case.
#
# What this file pins, and why each half matters:
#
#   * ARMED (server dispatch only): one total budget bounds the dispatch, and
#     it is enforced in three places rather than one. HttpTimeouts REFUSES a
#     new outbound attempt once the budget is spent -- which is the only thing
#     that can bound a dispatch whose cost is the NUMBER of requests, like a
#     paginated walk where nothing ever retries. It SPLITS the surviving budget
#     across connect/write/read, because http.rb runs those sequentially and
#     clamping each to `remaining` independently authorized remaining + connect
#     + write. And Client's retry gate charges the backoff PLUS the attempt it
#     authorizes, re-checking after the sleep actually happens.
#
#     Stated as an invariant: no attempt starts on a spent budget, and one
#     attempt's MODELED SOCKET SPEND is at most what is left, give or take
#     the MIN_ATTEMPT_SOCKET_SECONDS floor. Modeled spend rather than the sum
#     of the three timeout values, because http.rb charges the connect
#     allowance twice against a TLS endpoint -- a hash summing to 15 is
#     billed 20 -- which is why these specs weight each budget by
#     PHASE_SPENDS.
#
#     MODELED is load-bearing in that sentence, and these specs cannot say
#     more than that. They drive a stubbed clock and allocate budgets; they
#     never open a socket. What they bound is the ALLOCATION. What http.rb
#     then does with an allowance is a separate question, answered in
#     http_timeouts_spec.rb's "readiness-wait escape hatch" examples, which
#     drive the real HTTP::Timeout::PerOperation and show a TLS handshake
#     spending several times its allowance because every readiness wait
#     re-arms it. A sweep over this file's arithmetic structurally cannot
#     detect that, which is how the overclaim survived two reviews.
#
#     What is NOT bounded is documented on DispatchDeadline: a trickling
#     peer defeats any total, through read, write, AND the TLS half of
#     connect, because http.rb's allowances are inactivity windows re-armed
#     per readiness wait.
#
#   * UNARMED (everything else): the behavior that shipped, unchanged. The
#     same Client, Auth, and Tools serve the stdio entrypoints
#     (bin/mcp-server, bin/hyperon-wiki-mcp, bin/magi-archive-mcp) and every
#     CLI and batch caller, which take no lock and block nobody. A CLI import
#     WANTS the long tail; capping it would turn slow successes into failures.
#     So the absence of a deadline off the server path is a contract in its own
#     right, asserted here rather than assumed -- including that "no budget" is
#     never read as "no budget left".
#
# Deterministic and offline: time is driven through a stubbed monotonic clock
# and sleeps are captured rather than taken, so nothing here waits on a real
# clock or a real socket. Note what that means for the elapsed-time
# assertions: they measure backoff and refusal bookkeeping, not real I/O.

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

    # The CLI/batch contract: nothing is ever refused off the server path.
    # #expired? in particular must be FALSE when unarmed -- "no budget" is not
    # "no budget left", and reading it as the latter would make the shared HTTP
    # seam refuse every CLI call in the gem.
    it "refuses nothing: not expired, and room for any cost" do
      expect(described_class).not_to be_expired
      expect(described_class).to be_room_for(4)
      expect(described_class.room_for?(10_000)).to be(true)
      expect(described_class.room_for_retry?(10_000)).to be(true)
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

  # The gate HttpTimeouts applies before it will build a client at all. This
  # is what bounds a dispatch whose cost is the NUMBER of requests -- a
  # paginated walk, a tool issuing call after call -- none of which ever
  # consults a retry budget.
  describe ".expired?" do
    it "is false while budget remains" do
      described_class.arm(15) do
        advance(14)

        expect(described_class).not_to be_expired
      end
    end

    it "is true once the budget is spent" do
      described_class.arm(15) do
        advance(15.001)

        expect(described_class).to be_expired
      end
    end

    it "is true once overspent" do
      described_class.arm(15) do
        advance(60)

        expect(described_class).to be_expired
      end
    end

    # The distinction the whole server-dispatch-only scope rests on: unarmed is
    # not expired. Collapsing the two would refuse every CLI and stdio call.
    it "is false when no budget is armed at all" do
      expect(described_class).not_to be_expired
    end
  end

  describe ".room_for?" do
    it "admits a cost that still fits inside the budget" do
      described_class.arm(15) { expect(described_class).to be_room_for(4) }
    end

    it "refuses a cost that would outlive the budget" do
      described_class.arm(15) do
        advance(13)

        expect(described_class).not_to be_room_for(4)
      end
    end

    it "refuses every cost once the budget is overspent" do
      described_class.arm(15) do
        advance(20)

        expect(described_class).not_to be_room_for(0)
      end
    end
  end

  describe ".room_for_retry?" do
    it "admits a retry when both the backoff and an attempt still fit" do
      described_class.arm(15) { expect(described_class).to be_room_for_retry(4) }
    end

    # The regression this method exists for. Charging only the backoff let a
    # chain with 1.1s left sleep 1s and then start an attempt with 0.1s of
    # budget -- lock time spent to accomplish nothing.
    it "refuses a retry whose backoff fits but whose attempt would not" do
      described_class.arm(15) do
        advance(13.9)

        expect(described_class.remaining).to be_within(0.001).of(1.1)
        expect(described_class).to be_room_for(1)
        expect(described_class).not_to be_room_for_retry(1)
      end
    end

    # Boundary from both sides, so the spec pins delay + MIN_ATTEMPT_SECONDS
    # rather than any number that merely happens to refuse. 4.9s left would be
    # ample room for a 4s backoff alone -- that it is refused is the point.
    it "charges the backoff plus a minimum attempt, not the backoff alone" do
      cost = 4 + described_class::MIN_ATTEMPT_SECONDS

      described_class.arm(15) do
        advance(15 - cost - 0.1) # 5.1s left: backoff and attempt both fit

        expect(described_class).to be_room_for_retry(4)
      end

      described_class.arm(15) do
        advance(15 - cost + 0.1) # 4.9s left: room for the backoff, not the attempt

        expect(described_class).to be_room_for(4)
        expect(described_class).not_to be_room_for_retry(4)
      end
    end

    it "never refuses a retry when no budget is armed" do
      expect(described_class).to be_room_for_retry(4)
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

  # THE invariant, and the one the previous two versions got wrong. http.rb
  # spends connect, then write, then read, SEQUENTIALLY, so clamping each phase
  # to `remaining` independently authorized remaining + connect + write -- 25s
  # of socket time on a 15s budget. Splitting fixed that but still counted
  # HASH ENTRIES: against an https endpoint http.rb charges the connect
  # allowance TWICE (PerOperation#connect, then #connect_ssl), so {5,5,5}
  # summed to 15 and spent 20.
  #
  # What has to be bounded is MODELED SOCKET SPEND, so that is what these
  # specs measure: every assertion below weights each granted budget by
  # PHASE_SPENDS rather than adding the three numbers up.
  #
  # And only modeled spend. These examples never touch a socket, so they
  # measure the allocation, not the wire. PHASE_SPENDS is a floor on what
  # http.rb bills, not a ceiling on what a phase costs -- the real
  # PerOperation re-arms its allowance on every readiness wait, which
  # http_timeouts_spec.rb pins directly. No sweep over this arithmetic can
  # see that, which is exactly why the sweep below is not evidence of a
  # wall-clock bound.
  describe "the per-attempt socket spend" do
    # The weighting that makes these assertions mean something. Adding the
    # hash values is the measurement that let the TLS overshoot through.
    def socket_spend(budgets)
      budgets.sum { |phase, seconds| seconds * described_class::PHASE_SPENDS.fetch(phase) }
    end

    it "never exceeds the remaining budget on a fresh deadline" do
      Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
        budgets = described_class.effective_budgets

        # Two connects, one write, one read: 1.667*2 + 1.667 + 10 == 15.
        expect(socket_spend(budgets)).to be_within(0.001).of(15)
        expect(budgets[:read]).to be_within(0.001).of(10)
      end
    end

    # The exact case Codex measured: a 15s budget that the old split allowed to
    # spend 20s. Pinned as a literal so a regression reads as the same number.
    it "spends 15s and not 20s of socket time on a fresh 15s budget" do
      Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
        expect(socket_spend(described_class.effective_budgets)).to be <= 15.001
      end
    end

    it "never exceeds the remaining budget once partly spent" do
      Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
        advance(6)

        expect(socket_spend(described_class.effective_budgets)).to be_within(0.001).of(9)
      end
    end

    # Swept rather than spot-checked: the bug was an invariant that held at the
    # values someone happened to assert and failed everywhere else. The sweep is
    # against modeled socket spend, and the only slack allowed is the floor --
    # stated as MIN_ATTEMPT_SOCKET_SECONDS (4s, counting TLS) rather than the
    # 3s an entry-count gave.
    #
    # 0.01s steps from 0.01 to 60.00, which is the granularity the commit
    # message claims: 6000 points, all arithmetic, no I/O. A coarser 0.5s grid
    # was what stood here, and a grid coarse enough to miss a boundary is how
    # the first version of this invariant passed while being false.
    it "holds across the whole range of remaining budgets" do
      worst = 0.0

      (1..6000).each do |hundredths|
        Hyperon::Wiki::Mcp::DispatchDeadline.arm(hundredths * 0.01) do
          left = Hyperon::Wiki::Mcp::DispatchDeadline.remaining
          budgets = described_class.effective_budgets
          spend = socket_spend(budgets)

          expect(spend).to be <= left + described_class::MIN_ATTEMPT_SOCKET_SECONDS + 0.001
          budgets.each_value { |seconds| expect(seconds).to be >= described_class::MIN_PHASE_SECONDS }
          worst = [worst, spend - left].max
        end
      end

      # The worst modeled overshoot lives at the smallest admitted budget,
      # where all three phases are floored: 4.0 modeled against 0.01 left.
      # Pinned so a change that widens it has to say so.
      expect(worst).to be_within(0.001).of(described_class::MIN_ATTEMPT_SOCKET_SECONDS - 0.01)
    end

    # Above the weighted cost of a full attempt there is nothing to narrow, so a
    # generous budget must get OUTBOUND's numbers rather than inflated ones.
    it "never grants more than the declared budget however much is left" do
      Hyperon::Wiki::Mcp::DispatchDeadline.arm(600) do
        expect(described_class.effective_budgets).to eq(described_class::OUTBOUND.to_h)
      end
    end

    # Proportional rather than front-to-back. The sequential split gave connect
    # its full 5s at a 9s remainder and left read with 1s -- a narrowed attempt
    # that looked nothing like a full one, and starved the phase that actually
    # needs the time.
    it "keeps the phases in their declared proportion rather than starving the read" do
      Hyperon::Wiki::Mcp::DispatchDeadline.arm(9) do
        budgets = described_class.effective_budgets

        expect(budgets[:read]).to be_within(0.001).of(6)
        expect(budgets[:read]).to be > budgets[:connect]
        expect(socket_spend(budgets)).to be_within(0.001).of(9)
      end
    end

    it "carries the scaled budgets onto the client that is actually built" do
      Hyperon::Wiki::Mcp::DispatchDeadline.arm(9) do
        expect(described_class.client.default_options.timeout_options).to eq(
          connect_timeout: 1.0, write_timeout: 1.0, read_timeout: 6.0
        )
      end
    end

    it "never hands a socket a zero or negative timeout" do
      Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
        advance(14.99)

        described_class.effective_budgets.each_value do |seconds|
          expect(seconds).to be > 0
          expect(seconds).to be_finite
        end
      end
    end

    # The floor window, in exact boundaries rather than "about 4s". The docs
    # said "below a ~4s remainder an admitted attempt is floored to the 4s
    # worst case", and the closure review disproved it in both directions:
    # at left=4.0 the modeled spend is 5.667, not 4.0, and full flooring does
    # not begin until 1.5. These four examples pin the real shape of the
    # curve so the prose cannot drift off it again.
    describe "where the floor actually bites" do
      def budgets_at(left)
        Hyperon::Wiki::Mcp::DispatchDeadline.arm(left) { described_class.effective_budgets }
      end

      # The top of the window. At exactly 9.0 the two 5s phases land on
      # MIN_PHASE_SECONDS without being clamped, so allocation still covers
      # itself: modeled spend is 9.0 on the nose.
      it "needs no floor at all down to a 9.0s remainder" do
        budgets = budgets_at(9.0)

        expect(budgets).to eq(connect: 1.0, write: 1.0, read: 6.0)
        expect(socket_spend(budgets)).to be_within(0.001).of(9.0)
      end

      # One hundredth below it the clamp engages and the overshoot begins --
      # tiny, but this is the boundary, and it is 9.0 rather than "~4s".
      it "starts overshooting immediately below 9.0" do
        budgets = budgets_at(8.99)

        expect(budgets[:connect]).to eq(described_class::MIN_PHASE_SECONDS)
        expect(socket_spend(budgets)).to be > 8.99
        expect(socket_spend(budgets)).to be_within(0.001).of(8.9933)
      end

      # The intermediate case no example covered, and the one that disproves
      # "floored to the 4s worst case" below 4s: at left=3.0 connect and write
      # are floored while read is still scaling, giving {1, 1, 2} -- a modeled
      # 5.0s, which is neither 3.0 nor 4.0.
      it "floors connect and write while read still scales" do
        budgets = budgets_at(3.0)

        expect(budgets).to eq(connect: 1.0, write: 1.0, read: 2.0)
        expect(socket_spend(budgets)).to be_within(0.001).of(5.0)
        expect(socket_spend(budgets)).to be > described_class::MIN_ATTEMPT_SOCKET_SECONDS
      end

      # The bottom of the window. 1.5 is where read finally reaches the floor
      # too (30 * 1.5/45 == 1.0), and from there down every budget is {1,1,1}
      # however little is left.
      it "floors every phase at or below 1.5s and not before" do
        expect(budgets_at(1.51)[:read]).to be > described_class::MIN_PHASE_SECONDS
        expect(budgets_at(1.5)).to eq(connect: 1.0, write: 1.0, read: 1.0)
        expect(budgets_at(0.01)).to eq(connect: 1.0, write: 1.0, read: 1.0)
        expect(socket_spend(budgets_at(0.01))).to eq(described_class::MIN_ATTEMPT_SOCKET_SECONDS)
      end
    end

    # The floor window, stated honestly. At or below a 1.5s remainder an
    # admitted attempt is floored to {1,1,1}, so it CAN outlive the budget --
    # but by at most MIN_ATTEMPT_SOCKET_SECONDS in the allocation model, which
    # is the number the docs advertise. Wall clock is a different question;
    # see http_timeouts_spec.rb.
    it "bounds a floored attempt's overshoot by the documented floor" do
      Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
        advance(14.9)
        left = Hyperon::Wiki::Mcp::DispatchDeadline.remaining
        budgets = described_class.effective_budgets

        expect(budgets).to eq(connect: 1, write: 1, read: 1)
        expect(socket_spend(budgets)).to eq(described_class::MIN_ATTEMPT_SOCKET_SECONDS)
        expect(socket_spend(budgets) - left).to be <= described_class::MIN_ATTEMPT_SOCKET_SECONDS
      end
    end
  end

  # B2 at the seam. A spent budget must REFUSE, not shrink: floor budgets for
  # expired work were how a paginated walk stayed unbounded, since each page
  # was individually quick and nothing ever retried.
  describe "once the budget is spent" do
    it "refuses to build a client at all" do
      Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
        advance(15.1)

        expect { described_class.client }.to raise_error(
          described_class::BudgetExhaustedError, /refusing to start another outbound request/
        )
      end
    end

    it "refuses rather than granting a floor budget" do
      Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
        advance(60)

        expect { described_class.effective_budgets }.to raise_error(described_class::BudgetExhaustedError)
      end
    end

    # The refusal has to reach callers through the rescue clauses that already
    # exist. A fresh StandardError would escape Client#request's `rescue
    # HTTP::Error`, Auth#fetch_jwks's, and Auth#fetch_token's alike, turning a
    # bounded refusal into an unhandled crash inside whatever tool was running.
    it "refuses with an HTTP::Error, so existing rescues already map it" do
      expect(described_class::BudgetExhaustedError.ancestors).to include(HTTP::TimeoutError, HTTP::Error)
    end

    it "says how far past the deadline it is, so the refusal is diagnosable" do
      Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
        advance(20)

        expect { described_class.client }.to raise_error(/exhausted 5\.0s ago/)
      end
    end

    # Unarmed is not expired: the CLI/stdio contract, asserted at the seam that
    # would break it.
    it "refuses nothing when no budget is armed" do
      expect { described_class.client }.not_to raise_error
    end
  end

  # C2: the time-of-check/time-of-use hole the gate left behind.
  #
  # The gate used to read the clock TWICE -- once via .expired?, then again for
  # .remaining to allocate against -- with nothing making the two reads
  # coherent. A thread descheduled between them (GC pause, a Puma worker losing
  # its slice) passed the gate on a live budget and then allocated against a
  # DEAD one: `left` went negative, every phase floored to MIN_PHASE_SECONDS,
  # and already-expired work was handed a fresh socket allowance. That is
  # exactly the behavior the refusal exists to remove, reachable without any
  # injection under ordinary scheduler pressure.
  #
  # The fix is one clock read per decision. These specs drive the clock so the
  # SECOND read would be fatal, which is what makes them fail against the
  # two-read version rather than merely pass against the fixed one.
  describe "when the budget dies between clock reads" do
    # The precise statement of the defect: the value the gate approved and the
    # value the allocator spent must be the SAME observation. With two reads
    # they were not, and the allocator could be handed a negative budget the
    # gate had never seen -- which floors to {1,1,1} and hands dead work a live
    # socket allowance.
    #
    # The clock here is healthy for arming AND for a second read, then dead
    # from the third on. Under the two-read version that is exactly fatal:
    # .expired? sampled the healthy second read and waved it through, then
    # .remaining sampled the dead third and allocated on -100s. Under one read
    # the allocator sees the same +0.1s the gate did.
    it "never allocates against a budget the gate did not approve" do
      reads = 0
      allow(Hyperon::Wiki::Mcp::DispatchDeadline).to receive(:now) do
        reads += 1
        reads <= 2 ? 1000.0 : 1100.1
      end

      seen = []
      allow(described_class).to receive(:phase_budgets).and_wrap_original do |original, left|
        seen << left
        original.call(left)
      end

      Hyperon::Wiki::Mcp::DispatchDeadline.arm(0.1) do
        described_class.effective_budgets
      rescue described_class::BudgetExhaustedError
        nil # refusing is also a correct outcome; allocating on a corpse is not
      end

      expect(seen).to all(be > 0)
    end

    # The same invariant one layer out: a client may only be built on a budget
    # that was observed alive. Under the two-read version this built a working
    # client on a budget 100s overspent -- Codex completed a real mocked GET
    # that way.
    it "builds no client on a budget that was observed dead" do
      reads = 0
      allow(Hyperon::Wiki::Mcp::DispatchDeadline).to receive(:now) do
        reads += 1
        reads <= 2 ? 1000.0 : 1100.1
      end

      observed = []
      allow(described_class).to receive(:phase_budgets).and_wrap_original do |original, left|
        observed << left
        original.call(left)
      end

      Hyperon::Wiki::Mcp::DispatchDeadline.arm(0.1) do
        described_class.client
      rescue described_class::BudgetExhaustedError
        nil
      end

      expect(observed.reject(&:positive?)).to be_empty
    end

    # And when the single read IS dead, the refusal happens and nothing is
    # allocated at all.
    it "refuses outright when the one clock read is already past the deadline" do
      reads = 0
      allow(Hyperon::Wiki::Mcp::DispatchDeadline).to receive(:now) do
        reads += 1
        reads <= 1 ? 1000.0 : 1100.1
      end

      Hyperon::Wiki::Mcp::DispatchDeadline.arm(0.1) do
        expect { described_class.effective_budgets }.to raise_error(
          described_class::BudgetExhaustedError, /exhausted 100\.0s ago/
        )
      end
    end

    # The structural guarantee behind all of the above: one read cannot
    # disagree with itself. Asserted directly, because an implementation that
    # happened to agree today could silently reintroduce the race tomorrow.
    it "reads the clock exactly once per decision" do
      reads = 0
      allow(Hyperon::Wiki::Mcp::DispatchDeadline).to receive(:now) do
        reads += 1
        1000.0
      end

      Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
        reads = 0
        described_class.effective_budgets

        expect(reads).to eq(1)
      end
    end

    # And the refusal path must be just as frugal: re-reading the clock to
    # format the error message is the same bug wearing a diagnostic hat.
    it "reads the clock exactly once when it refuses, too" do
      reads = 0
      allow(Hyperon::Wiki::Mcp::DispatchDeadline).to receive(:now) do
        reads += 1
        1000.0
      end

      Hyperon::Wiki::Mcp::DispatchDeadline.arm(-5) do
        reads = 0

        expect { described_class.effective_budgets }.to raise_error(described_class::BudgetExhaustedError)
        expect(reads).to eq(1)
      end
    end

    # A non-positive allocation input must be REFUSED, not floored. This is the
    # invariant the race violated, stated without reference to any clock: there
    # is no budget value at or below zero for which an attempt may start.
    it "refuses a non-positive budget rather than flooring it to a live allowance" do
      [0, -0.001, -100].each do |left|
        Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
          advance(15 - left)

          expect { described_class.effective_budgets }.to raise_error(
            described_class::BudgetExhaustedError
          )
        end
      end
    end
  end

  it "does not mutate the shared policy while splitting the budget" do
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

    # The retry gate must charge the backoff AND the attempt it authorizes.
    # Charging the backoff alone let a chain sleep itself to the edge of the
    # deadline and then start an attempt with nothing left to spend.
    it "refuses a backoff it could sleep but could not act on" do
      stub_always_failing

      # 1.5s left: the 1s backoff fits, the attempt after it does not.
      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(1.5) { client.get("/cards/Test") }
        end.to output(/Dispatch budget exhausted before backoff/).to_stderr
      end.to raise_error(described_class::ServerError)

      expect(slept).to be_empty
      expect(WebMock).to have_requested(:get, cards_url).times(1)
    end

    # The post-backoff recheck. The pre-check is a prediction; a real sleep(1)
    # can take considerably longer under load, and only the clock afterwards
    # knows what it cost. Here the sleep overruns by 10x and the chain must
    # stop rather than start the attempt the pre-check authorized.
    it "re-checks the budget after the backoff and stops if the sleep overran" do
      stub_always_failing
      allow(client).to receive(:sleep) do |seconds|
        slept << seconds
        clock[:now] += seconds * 10 # the sleep took far longer than requested
      end

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(5) { client.get("/cards/Test") }
        end.to output(/Dispatch budget exhausted after 1s backoff/).to_stderr
      end.to raise_error(described_class::ServerError)

      # The 1s backoff was authorized and slept; it cost 10s, so the attempt it
      # was taken for is abandoned rather than started.
      expect(slept).to eq([1])
      expect(WebMock).to have_requested(:get, cards_url).times(1)
    end

    it "re-checks the budget after a transport-failure backoff too" do
      stub_request(:get, cards_url).to_timeout
      allow(client).to receive(:sleep) do |seconds|
        slept << seconds
        clock[:now] += seconds * 10
      end

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(5) { client.get("/cards/Test") }
        end.to output(/Dispatch budget exhausted after 1s backoff/).to_stderr
      end.to raise_error(described_class::APIError, /HTTP request failed/)

      expect(slept).to eq([1])
      expect(WebMock).to have_requested(:get, cards_url).times(1)
    end

    # The post-backoff recheck used to ask only "expired?", which is the wrong
    # question: a chain waking with 0 < remaining < MIN_ATTEMPT_SECONDS is not
    # expired, so it started an attempt the seam then floored to a 4s socket
    # allowance -- live-budget overshoot bought for no useful work. The recheck
    # now asks the same question the pre-check asked.
    #
    # 2.5s budget: the pre-check passes (2.5 > 1s backoff + 1s attempt), the
    # sleep overruns to 2s, and the chain wakes with 0.5s -- positive, so the
    # old `expired?` recheck waved it through, but below the minimum, so no
    # attempt worth making fits. This example FAILS against that version.
    it "stops after a backoff that leaves a positive but sub-minimum remainder" do
      stub_always_failing
      allow(client).to receive(:sleep) do |seconds|
        slept << seconds
        clock[:now] += 2.0 # the 1s sleep actually took 2s
      end

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(2.5) { client.get("/cards/Test") }
        end.to output(/Dispatch budget exhausted after 1s backoff/).to_stderr
      end.to raise_error(described_class::ServerError)

      expect(slept).to eq([1])
      # The backoff was authorized and slept; the attempt it was taken for is
      # abandoned rather than started on 0.5s.
      expect(WebMock).to have_requested(:get, cards_url).times(1)
      expect(Hyperon::Wiki::Mcp::DispatchDeadline.armed?).to be(false)
    end

    # The boundary from the other side: a remainder comfortably above the
    # minimum still retries, so the stricter recheck has not become a blanket
    # refusal.
    it "still makes the attempt when the backoff leaves more than the minimum" do
      stub_request(:get, cards_url).to_return(
        { status: 503, body: '{"error":"unavailable"}' },
        { status: 200, body: '{"name":"Test"}', headers: { "Content-Type" => "application/json" } }
      )

      result = nil
      expect do
        Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) { result = client.get("/cards/Test") }
      end.to output(/Retrying request after 1s/).to_stderr

      expect(result).to eq("name" => "Test")
      expect(WebMock).to have_requested(:get, cards_url).times(2)
    end
  end

  # B2's headline case: a dispatch whose cost is the NUMBER of requests, none
  # of which ever retries. The retry gate cannot see this at all -- every call
  # succeeds, nothing backs off -- so the bound has to live at the shared HTTP
  # seam, and this is the spec that proves it does.
  describe "new outbound work once the budget is spent" do
    let(:cards_url) { "https://test.example.com/api/mcp/cards" }

    it "refuses a brand-new request rather than starting it with a floor budget" do
      stub_request(:get, cards_url).to_return(status: 200, body: "{}")

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
            clock[:now] += 20
            client.get("/cards")
          end
        end.to output(/dispatch budget exhausted/).to_stderr
      end.to raise_error(described_class::APIError, /HTTP request failed/)

      expect(WebMock).not_to have_requested(:get, cards_url)
    end

    # Before this gate existed, an expired budget still allowed request after
    # request: each got MIN_ATTEMPT_SECONDS per phase and completed fine.
    it "refuses every subsequent request, not just the first" do
      stub_request(:get, cards_url).to_return(status: 200, body: "{}")

      expect do
        Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
          clock[:now] += 20

          3.times do
            expect { client.get("/cards") }.to raise_error(described_class::APIError)
          end
        end
      end.to output(/dispatch budget exhausted/).to_stderr

      expect(WebMock).not_to have_requested(:get, cards_url)
    end

    # The refusal must not be retried: the budget that refused this attempt
    # cannot have grown, so a retry would sleep the backoff only to be refused
    # again at the same seam.
    it "does not sleep a backoff for a refusal it cannot retry past" do
      stub_request(:get, cards_url).to_return(status: 200, body: "{}")

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
            clock[:now] += 20
            client.get("/cards")
          end
        end.to raise_error(described_class::APIError)
      end.to output(/dispatch budget exhausted/).to_stderr

      expect(slept).to be_empty
    end

    # A paginated walk: each page is individually quick, so nothing retries and
    # no per-attempt timeout is ever hit. The budget running out mid-walk is the
    # only thing that can stop it, and the walk must RAISE rather than return a
    # truncated list that looks complete.
    it "stops a paginated walk at the deadline instead of walking forever" do
      page = { "cards" => [{ "name" => "A" }], "next_offset" => 50 }.to_json
      stub_request(:get, cards_url).with(query: hash_including({})).to_return(
        status: 200, body: page, headers: { "Content-Type" => "application/json" }
      )

      pages = 0

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
            client.each_page("/cards") do |_items|
              pages += 1
              clock[:now] += 4 # each page spends real budget
            end
          end
        end.to output(/dispatch budget exhausted/).to_stderr
      end.to raise_error(described_class::APIError)

      # 15s of budget at 4s a page: four pages, then refused. The endpoint
      # advertises next_offset forever, so without the gate this never ends.
      expect(pages).to eq(4)
      expect(WebMock).to have_requested(:get, cards_url).with(query: hash_including({})).times(4)
    end

    # Externally enumerated, the walk runs on a Fiber. Thread-scoped state is
    # why the budget is visible there at all; this pins that the GATE is too.
    it "stops an externally enumerated walk at the deadline as well" do
      page = { "cards" => [{ "name" => "A" }], "next_offset" => 50 }.to_json
      stub_request(:get, cards_url).with(query: hash_including({})).to_return(
        status: 200, body: page, headers: { "Content-Type" => "application/json" }
      )

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
            enumerator = client.each_page("/cards")
            10.times do
              enumerator.next
              clock[:now] += 4
            end
          end
        end.to output(/dispatch budget exhausted/).to_stderr
      end.to raise_error(described_class::APIError)

      expect(WebMock).to have_requested(:get, cards_url).with(query: hash_including({})).times(4)
    end

    # Off the server path a long walk is exactly what CLI and batch callers
    # want, and nothing may refuse it.
    it "refuses nothing when no budget is armed" do
      stub_request(:get, cards_url).to_return(status: 200, body: "{}")

      clock[:now] += 1000

      expect { client.get("/cards") }.not_to raise_error
      expect(WebMock).to have_requested(:get, cards_url).times(1)
    end

    # #health_check and #ping were two of the three originally-unbounded sites,
    # so the gate has to cover them -- but they are also the two call sites that
    # do NOT map the refusal. Neither has a `rescue HTTP::Error`, so the raw
    # BudgetExhaustedError escapes rather than becoming an APIError.
    #
    # Asserted as the actual behavior rather than the behavior the docs used to
    # claim: the refusal is bounded and named (the MCP tool wrapper catches
    # StandardError), but a caller matching on APIError will not see it, and
    # pretending otherwise is the kind of overclaim this slice is correcting.
    describe "health and ping on a spent budget" do
      let(:health_url) { "https://test.example.com/api/mcp/health" }
      let(:ping_url) { "https://test.example.com/api/mcp/health/ping" }

      it "refuses a health check without opening a socket" do
        stub_request(:get, health_url).to_return(status: 200, body: '{"status":"healthy"}')

        Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
          clock[:now] += 20

          expect { client.health_check }.to raise_error(
            Hyperon::Wiki::Mcp::HttpTimeouts::BudgetExhaustedError
          )
        end

        expect(WebMock).not_to have_requested(:get, health_url)
      end

      it "refuses a ping without opening a socket" do
        stub_request(:get, ping_url).to_return(status: 200, body: '{"status":"ok"}')

        Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
          clock[:now] += 20

          expect { client.ping }.to raise_error(
            Hyperon::Wiki::Mcp::HttpTimeouts::BudgetExhaustedError
          )
        end

        expect(WebMock).not_to have_requested(:get, ping_url)
      end

      # The honest scope statement: bounded, but not mapped to APIError the way
      # #request and #get_raw are. Pinned so the asymmetry stays visible.
      it "surfaces the refusal unmapped, unlike #request and #get_raw" do
        Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
          clock[:now] += 20

          expect { client.health_check }.not_to raise_error(described_class::APIError)
          expect { client.health_check }.to raise_error(StandardError)
        end
      end
    end
  end

  # The transport give-up path raised APIError in silence while the response
  # path logged, so an exhausted chain, a refused dispatch, and a single
  # unretryable failure were indistinguishable from outside.
  describe "the transport give-up diagnostic" do
    it "names an exhausted retry chain" do
      stub_request(:get, cards_url).to_timeout

      expect do
        expect { client.get("/cards/Test") }.to raise_error(described_class::APIError)
      end.to output(/Giving up after 4 attempt\(s\) \(retries exhausted\)/).to_stderr
    end

    it "names a refused dispatch rather than letting it read as a network fault" do
      stub_request(:get, cards_url).to_return(status: 200, body: "{}")

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(15) do
            clock[:now] += 20
            client.get("/cards/Test")
          end
        end.to raise_error(described_class::APIError)
      end.to output(/Giving up after 1 attempt\(s\) \(dispatch budget exhausted\)/).to_stderr
    end

    it "names a budget too small to retry" do
      stub_request(:get, cards_url).to_timeout

      expect do
        expect do
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(1.5) { client.get("/cards/Test") }
        end.to raise_error(described_class::APIError)
      end.to output(/Giving up after 1 attempt\(s\) \(dispatch budget too small to retry/).to_stderr
    end
  end
end
