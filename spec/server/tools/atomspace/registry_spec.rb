# frozen_string_literal: true

require_relative "../../../../lib/hyperon/wiki/mcp/server/tools/atomspace/registry"

# Client is a CLASS in the gem (not a module). Only define a stand-in -- as a class -- when the
# gem's real Hyperon::Wiki::Mcp::Client isn't already loaded, so we never reopen it with the
# wrong constant kind (Codex Finding 6). In-app the real Client::AuthorizationError is used.
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

RSpec.describe Hyperon::Wiki::Mcp::Server::Tools::Atomspace::Registry do
  Reg = described_class

  it "registers exactly the 8 locked tools, all requiring mcp:atomspace:read" do
    expect(Reg::TOOLS.size).to eq(8)
    expect(Reg::TOOLS.map(&:required_scope).uniq).to eq(["mcp:atomspace:read"])
  end

  describe ".visible_for" do
    it "hides every AtomSpace tool when the scope is absent" do
      expect(Reg.visible_for(%w[mcp:read])).to be_empty
    end

    it "exposes all 8 when the scope is present" do
      expect(Reg.visible_for(%w[mcp:read mcp:atomspace:read]).size).to eq(8)
    end
  end

  describe ".gate! (invocation-boundary enforcement, not just visibility)" do
    it "raises for a gated tool when the scope is absent" do
      expect { Reg.gate!(Reg::TOOLS.first, %w[mcp:read]) }
        .to raise_error(Hyperon::Wiki::Mcp::Client::AuthorizationError)
    end

    it "permits invocation when the scope is present" do
      expect { Reg.gate!(Reg::TOOLS.first, %w[mcp:atomspace:read]) }.not_to raise_error
    end
  end
end
