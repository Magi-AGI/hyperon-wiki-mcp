# frozen_string_literal: true

# RackApp dispatch arms the total outbound budget, and arms it in the right
# place.
#
# The deadline only does its job if it is armed where the lock is taken. The
# previous spec file (dispatch_deadline_spec.rb) pins what the budget DOES once
# armed; this one pins that server dispatch arms it at all -- the seam that
# makes the whole thing server-dispatch-only rather than a behavior change for
# every Client caller in the gem.
#
# Three properties, each of which has a plausible wrong implementation:
#
#   * armed INSIDE the lock, not around it. Armed outside, a request that
#     queued behind a slow one would spend its budget waiting and then fail
#     without making a single call -- punishing the victim of the stall rather
#     than bounding its cause.
#   * armed on BOTH dispatch paths. The per-user swap and the default-identity
#     path take the same lock, so a budget on only one leaves the lock just as
#     exposed through the other.
#   * disarmed afterward, including when handle(...) raises. Puma reuses worker
#     threads, so a leaked budget would silently apply to whatever that thread
#     served next.
#
# Local and offline: a stateful MCP::Server double records what the deadline
# looked like while handle(...) ran. No sockets, no sleeps, no real clock.

require "spec_helper"
require "hyperon/wiki/mcp"
require "hyperon/wiki/mcp/rack_app"

RSpec.describe Hyperon::Wiki::Mcp::RackApp, "dispatch deadline" do
  let(:app) { described_class.new }
  let(:mcp_server) { instance_double("MCP::Server") }
  let(:request_data) { { jsonrpc: "2.0", id: 1, method: "tools/list" } }
  let(:per_user_tools) { instance_double(Hyperon::Wiki::Mcp::Tools, "per-user Tools") }
  let(:server_own_context) do
    { magi_tools: instance_double(Hyperon::Wiki::Mcp::Tools, "default Tools"),
      working_directory: "/srv/hyperon-mcp" }.freeze
  end

  # What the deadline looked like from inside handle(...).
  let(:observed) { { armed: nil, remaining: nil, held_lock: nil } }

  around do |example|
    server_before = described_class.mcp_server_instance
    example.run
  ensure
    described_class.mcp_server_instance = server_before
  end

  before do
    context_holder = { installed: server_own_context }
    allow(mcp_server).to receive(:server_context) { context_holder[:installed] }
    allow(mcp_server).to receive(:server_context=) { |ctx| context_holder[:installed] = ctx }
    allow(mcp_server).to receive(:handle) do |_incoming|
      observed[:armed] = Hyperon::Wiki::Mcp::DispatchDeadline.armed?
      observed[:remaining] = Hyperon::Wiki::Mcp::DispatchDeadline.remaining
      observed[:held_lock] = described_class::DISPATCH_LOCK.owned?
      { jsonrpc: "2.0", id: 1, result: { tools: [] } }
    end
    described_class.mcp_server_instance = mcp_server
  end

  shared_examples "a budgeted dispatch" do
    it "runs the tool under an armed total budget" do
      dispatch

      expect(observed[:armed]).to be(true)
      expect(observed[:remaining]).to be > 0
      expect(observed[:remaining]).to be <= Hyperon::Wiki::Mcp::DispatchDeadline::SERVER_DISPATCH_BUDGET_SECONDS
    end

    # Armed outside the lock, the budget would be spent by queueing rather than
    # by work -- so the clock must start only once this request owns the lock.
    it "arms the budget while holding the dispatch lock, not before acquiring it" do
      dispatch

      expect(observed[:held_lock]).to be(true)
    end

    # Puma reuses worker threads across requests.
    it "disarms the budget once dispatch returns" do
      dispatch

      expect(Hyperon::Wiki::Mcp::DispatchDeadline).not_to be_armed
    end

    it "disarms the budget even when handle(...) raises" do
      allow(mcp_server).to receive(:handle).and_raise("tool exploded mid-dispatch")

      expect { dispatch }.to raise_error(RuntimeError, "tool exploded mid-dispatch")
      expect(Hyperon::Wiki::Mcp::DispatchDeadline).not_to be_armed
    end
  end

  describe "#handle_with_user_tools" do
    def dispatch
      app.send(:handle_with_user_tools, request_data, per_user_tools)
    end

    include_examples "a budgeted dispatch"
  end

  # The default-identity path takes the SAME lock, so leaving it unbudgeted
  # would leave the lock just as exposed.
  describe "#handle_with_default_context" do
    def dispatch
      app.send(:handle_with_default_context, request_data)
    end

    include_examples "a budgeted dispatch"
  end

  it "arms the documented budget rather than an ad hoc number" do
    app.send(:handle_with_default_context, request_data)

    expect(observed[:remaining]).to be_within(1).of(
      Hyperon::Wiki::Mcp::DispatchDeadline::SERVER_DISPATCH_BUDGET_SECONDS
    )
  end

  # The scope boundary, stated as a test rather than left to the comments: the
  # gem's own Client/Auth/Tools are shared verbatim with the stdio entrypoints
  # and every CLI and batch caller. Nothing outside RackApp dispatch may arm
  # this, or CLI long-tail retries would start failing at 15s.
  #
  # Textual, and honestly so: this proves no SHIPPED file arms the budget
  # outside RackApp, not that none ever could. It cannot see an arm reached
  # through metaprogramming, nor one in a host application that loads this gem.
  # bin/ is scanned alongside lib/ because the stdio entrypoints are precisely
  # the callers that must stay unbudgeted, and a direct thread_variable_set of
  # DispatchDeadline::VARIABLE is treated as arming too -- it would bypass #arm
  # entirely, including the ensure that disarms it.
  #
  # Matched against the whole file with comments stripped rather than line by
  # line. The earlier line-scoped version required the lowercase literal
  # `dispatch_deadline` on the SAME line as thread_variable_set, so the
  # idiomatic form it was added to catch --
  # `thread_variable_set(DispatchDeadline::VARIABLE, v)` -- slipped past it,
  # and so did any call split across two lines. A guard its own target evades
  # is worse than none.
  #
  # dispatch_deadline.rb is excluded because it DEFINES the variable: its
  # private #deadline_at= is the one legitimate writer, and #arm is the only
  # caller of it, with the ensure that disarms. Everything else writing that
  # thread variable is bypassing #arm, which is what this guard is for.
  def self.deadline_owner
    "lib/hyperon/wiki/mcp/dispatch_deadline.rb"
  end

  # THE guard predicate, defined exactly once.
  #
  # It used to be written twice -- once in .arming_sources, once again as a
  # copy inside the self-test block below -- which meant the seven examples
  # that test the guard tested a DUPLICATE of it. Editing the real one alone
  # would have left all seven green. Both callers now share this.
  #
  # @param code [String] Ruby source
  # @return [Boolean] whether it arms the dispatch deadline
  def self.arms_deadline?(code)
    stripped = code.lines.map(&:chomp).reject { |line| line.strip.start_with?("#") }.join("\n")
    variable = Regexp.escape(Hyperon::Wiki::Mcp::DispatchDeadline::VARIABLE.to_s)

    stripped.match?(/DispatchDeadline\.arm\b/) ||
      # thread_variable_set reaching the deadline's key, however it is spelled
      # and across however many lines: the constant, the namespaced constant,
      # or the raw symbol.
      stripped.match?(/thread_variable_set\s*\(?\s*(?:[\w:]*DispatchDeadline::)?VARIABLE\b/m) ||
      stripped.match?(/thread_variable_set\s*\(?\s*:?#{variable}\b/m)
  end

  def self.arming_sources
    gem_root = File.expand_path("../../../..", __dir__)
    candidates = Dir.glob("#{gem_root}/lib/**/*.rb") + Dir.glob("#{gem_root}/bin/*")

    arming = candidates.select { |path| File.file?(path) }.select do |path|
      arms_deadline?(File.read(path))
    end

    arming.map { |path| path.delete_prefix("#{gem_root}/") } - [deadline_owner]
  end

  it "is armed only from RackApp dispatch, so CLI and stdio callers stay unbudgeted" do
    expect(self.class.arming_sources).to contain_exactly("lib/hyperon/wiki/mcp/rack_app.rb")
  end

  # The exclusion must stay narrow: the owner is excluded because it is the
  # owner, not because the guard cannot see it. If it ever stopped matching,
  # the guard would have been widened into uselessness without anyone noticing.
  it "still recognizes the deadline module's own writer, and excludes it deliberately" do
    gem_root = File.expand_path("../../../..", __dir__)
    owner = File.read("#{gem_root}/#{self.class.deadline_owner}")

    expect(owner).to match(/thread_variable_set\s*\(?\s*VARIABLE\b/)
  end

  # The guard tested against itself. Each of these is a real way to arm the
  # budget outside #arm, and each one the previous guard would have missed.
  #
  # These call .arms_deadline? -- the SAME predicate .arming_sources uses, not
  # a transcription of it. The previous version of this block re-typed the
  # three regexes, so editing the real guard alone left every example here
  # green: a self-test that could not fail on the thing it tests.
  describe "the arming guard itself" do
    def guard_matches?(code)
      self.class.arms_deadline?(code)
    end

    # The copy that used to live here is what this example rules out: the
    # predicate these seven exercise must be the one .arming_sources calls,
    # inherited from the same example group rather than re-typed in this one.
    it "is the same predicate the file scan uses, not a copy of it" do
      scan_owner = self.class.method(:arming_sources).owner
      guard_owner = self.class.method(:arms_deadline?).owner

      expect(guard_owner).to eq(scan_owner)
      # A re-typed copy would be a `def self.arms_deadline?` in THIS group,
      # which is what this rules out.
      expect(self.class.singleton_class.instance_methods(false)).not_to include(:arms_deadline?)
    end

    it "catches DispatchDeadline.arm" do
      expect(guard_matches?("DispatchDeadline.arm(15) { work }")).to be(true)
    end

    # The exact form Codex found slipping through: the constant reference.
    it "catches a thread_variable_set of the namespaced constant" do
      expect(
        guard_matches?("Thread.current.thread_variable_set(DispatchDeadline::VARIABLE, value)")
      ).to be(true)
    end

    it "catches the fully qualified constant" do
      expect(
        guard_matches?(
          "Thread.current.thread_variable_set(Hyperon::Wiki::Mcp::DispatchDeadline::VARIABLE, v)"
        )
      ).to be(true)
    end

    it "catches the raw symbol" do
      expect(
        guard_matches?("Thread.current.thread_variable_set(:hyperon_wiki_mcp_dispatch_deadline, v)")
      ).to be(true)
    end

    # The other half of the miss: a call split across lines.
    it "catches a multiline thread_variable_set" do
      expect(
        guard_matches?(<<~RUBY)
          Thread.current.thread_variable_set(
            DispatchDeadline::VARIABLE, value
          )
        RUBY
      ).to be(true)
    end

    # And it must not fire on prose, or nobody keeps it.
    it "ignores commented-out arming" do
      expect(guard_matches?("# DispatchDeadline.arm(15) { work }")).to be(false)
    end

    it "ignores an unrelated thread variable" do
      expect(guard_matches?("Thread.current.thread_variable_set(:some_other_key, value)")).to be(false)
    end
  end
end
