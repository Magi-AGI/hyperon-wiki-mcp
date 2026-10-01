# frozen_string_literal: true

require_relative "../../../../lib/hyperon/wiki/mcp/server/tools/atomspace/registry"

# How Registry resolves the scope a tool REQUIRES, which is the half of the
# hide + invoke-gate predicate that decides what the membership check is even
# asked about.
#
# Both Registry entry points answer a question of the form "is this tool's
# required scope among the granted ones?", so an unresolvable requirement
# makes the question meaningless. Treating it as "nothing is required" is how
# a gate that exists stops gating: registry.rb's own comment names
# required_scope as the thing to resolve by ("NOT a free-form request name"),
# and INTEGRATION.md step 3 states that visibility filtering alone is not
# enforcement -- neither is an invocation gate that permits whatever it cannot
# resolve.
#
# The shape this pins down, in both directions:
#   * gate! DENIES an unresolvable requirement. It guards one invocation, so
#     refusing that invocation is the fail-closed answer and costs nobody
#     else anything.
#   * visible_for EXCLUDES one. It builds the list handed to every caller, so
#     an unadvertised tool is the fail-closed answer there; raising would turn
#     one malformed registration into a denial of tools/list for everyone.
#     Registration integrity is covered separately by registry_spec.rb's
#     "exactly the 8 locked tools, all requiring mcp:atomspace:read".
#
# Unresolvable is defined by what the registry can act on, not by nil alone:
# no required_scope method, nil, a non-String, and an empty String all name
# no scope that a granted-scope list could legitimately contain.
#
# What this does NOT do: it introduces no scope, changes no tool's declared
# scope, and says nothing about which principals are granted
# mcp:atomspace:read (owned by McpApi::AtomspaceGrants in the deck repo, per
# INTEGRATION.md). The eight registered tools keep the one scope they already
# declare; only the resolution of a requirement the registry cannot read
# changes.
#
# Local and offline: synthetic tool classes built here, never added to
# Registry::TOOLS, and no client, token, or network.

# Client is a CLASS in the gem, so a stand-in is only defined -- as a class --
# when the real one is not already loaded, never reopening it with the wrong
# constant kind. Mirrors registry_spec.rb.
unless defined?(Hyperon::Wiki::Mcp::Client)
  module Hyperon
    module Wiki
      module Mcp
        class Client
          class AuthorizationError < StandardError; end
        end
      end
    end
  end
end

RSpec.describe Hyperon::Wiki::Mcp::Server::Tools::Atomspace::Registry, "scope resolution" do
  let(:registry) { described_class }
  let(:authorization_error) { Hyperon::Wiki::Mcp::Client::AuthorizationError }

  # A tool whose declared scope is whatever the registry cannot act on. Kept
  # out of Registry::TOOLS deliberately: these examples are about resolution,
  # not about the locked eight.
  def tool_declaring(scope)
    Class.new do
      define_singleton_method(:required_scope) { scope }
    end
  end

  def tool_declaring_nothing
    Class.new
  end

  # Each unresolvable shape, named so a failure says which one regressed.
  unresolvable_shapes = {
    "no required_scope method at all" => :none,
    "nil" => nil,
    "an empty String" => "",
    "a Symbol rather than a String" => :"mcp:atomspace:read",
    "a non-String, non-Symbol value" => 1
  }.freeze

  def unresolvable_tool(shape)
    shape == :none ? tool_declaring_nothing : tool_declaring(shape)
  end

  describe ".gate! with a requirement it cannot resolve" do
    unresolvable_shapes.each do |label, shape|
      it "denies a tool declaring #{label}, whatever scopes the caller holds" do
        tool = unresolvable_tool(shape)

        # No granted list can satisfy a requirement that names no scope, so
        # the widest plausible grant must not change the answer.
        expect { registry.gate!(tool, []) }.to raise_error(authorization_error)
        expect { registry.gate!(tool, %w[mcp:atomspace:read]) }.to raise_error(authorization_error)
        expect { registry.gate!(tool, %w[mcp:admin mcp:read mcp:write]) }.to raise_error(authorization_error)
      end
    end

    it "says the requirement was unresolvable rather than naming a scope it never read" do
      expect { registry.gate!(unresolvable_tool(nil), %w[mcp:atomspace:read]) }
        .to raise_error(authorization_error, /unresolved|unresolvable/i)
    end
  end

  describe ".visible_for with a requirement it cannot resolve" do
    unresolvable_shapes.each do |label, shape|
      it "excludes a tool declaring #{label} instead of raising or advertising it" do
        tool = unresolvable_tool(shape)
        stub_const("#{described_class}::TOOLS", [tool].freeze)

        expect(registry.visible_for([])).to be_empty
        expect(registry.visible_for(%w[mcp:atomspace:read])).to be_empty
      end
    end

    it "still advertises a resolvable neighbour standing beside an unresolvable one, so the \
exclusion is one entry rather than the whole list" do
      resolvable = tool_declaring("mcp:atomspace:read")
      stub_const("#{described_class}::TOOLS", [unresolvable_tool(nil), resolvable].freeze)

      expect(registry.visible_for(%w[mcp:atomspace:read])).to eq([resolvable])
    end
  end

  # The composition the committed failure-surface characterization records:
  # Auth#scopes passes a verified `scope` claim through unvalidated, so a
  # granted list really can contain nil. Membership alone would then pair a
  # nil requirement with a nil grant and permit.
  describe "an unvalidated granted-scope list carrying nil" do
    it "grants nothing to a tool whose own requirement is nil" do
      tool = unresolvable_tool(nil)
      stub_const("#{described_class}::TOOLS", [tool].freeze)

      expect { registry.gate!(tool, [nil]) }.to raise_error(authorization_error)
      expect(registry.visible_for([nil])).to be_empty
    end

    it "leaves the locked tools' own answer unchanged: inert non-String passengers neither \
grant nor revoke" do
      mixed = ["mcp:atomspace:read", { "bad" => "shape" }, 1, nil]

      expect(registry.visible_for(mixed).size).to eq(described_class::TOOLS.size)
      expect { registry.gate!(described_class::TOOLS.first, mixed) }.not_to raise_error
    end

    it "denies the locked tools when only malformed passengers are present" do
      malformed = [{ "bad" => "shape" }, 1, nil]

      expect(registry.visible_for(malformed)).to be_empty
      expect { registry.gate!(described_class::TOOLS.first, malformed) }
        .to raise_error(authorization_error)
    end
  end

  # The eight registered tools are untouched by this change: the scope they
  # require and the answers they give for it are exactly what registry_spec
  # already locks.
  describe "the locked eight, unchanged" do
    it "still resolves mcp:atomspace:read for every registered tool" do
      expect(described_class::TOOLS.map(&:required_scope).uniq).to eq(["mcp:atomspace:read"])
    end

    it "still hides all of them without the scope and shows all of them with it" do
      expect(registry.visible_for(%w[mcp:read])).to be_empty
      expect(registry.visible_for(%w[mcp:read mcp:atomspace:read]).size).to eq(8)
    end

    it "still gates invocation on that scope" do
      expect { registry.gate!(described_class::TOOLS.first, %w[mcp:read]) }
        .to raise_error(authorization_error)
      expect { registry.gate!(described_class::TOOLS.first, %w[mcp:atomspace:read]) }
        .not_to raise_error
    end
  end
end
