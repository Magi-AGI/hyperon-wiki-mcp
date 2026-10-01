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
  it "is armed only from RackApp dispatch, so CLI and stdio callers stay unbudgeted" do
    gem_root = File.expand_path("../../../..", __dir__)
    candidates = Dir.glob("#{gem_root}/lib/**/*.rb") + Dir.glob("#{gem_root}/bin/*")

    arming = candidates.select { |path| File.file?(path) }.select do |path|
      code = File.readlines(path, chomp: true).reject { |line| line.strip.start_with?("#") }
      code.any? do |line|
        line.match?(/DispatchDeadline\.arm\b/) ||
          (line.include?("thread_variable_set") && line.include?("dispatch_deadline"))
      end
    end

    expect(arming.map { |path| path.delete_prefix("#{gem_root}/") })
      .to contain_exactly("lib/hyperon/wiki/mcp/rack_app.rb")
  end
end
