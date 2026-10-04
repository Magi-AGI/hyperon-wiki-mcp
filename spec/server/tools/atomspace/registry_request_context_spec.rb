# frozen_string_literal: true

require_relative "../../../../lib/hyperon/wiki/mcp/server/tools/atomspace/registry"

# The join between a request's captured grant and the AtomSpace registry's own
# scope metadata: the context-taking halves of the hide + invoke-gate predicate.
#
# The two existing entry points take a bare granted-scope ARRAY, which leaves
# every caller to decide for itself whether that array may be trusted. These
# take the RequestContext instead and ask IT, so the freshness half of the
# fail-closed rule (verified, deadlined, read before the deadline) cannot be
# skipped by a caller that happens to have a scope list in hand.
#
# Each entry point keeps the direction its array-taking twin already
# established, for the same reason the committed scope-resolution work records:
#   * gate_for_context! guards ONE invocation, so it denies that invocation.
#   * visible_for_context builds the list handed to every caller, so it drops
#     the entry rather than raising and denying tools/list to everybody.
#
# A nil context is the fail-closed answer, not a bug: rack_app's
# #build_request_context returns nil when no grant backs the request, and its
# own comment states that a consumer reads that ABSENCE as "nothing was
# authorized" -- never as permission.
#
# The denial error is the committed Client::AuthorizationError that gate!
# already raises, with the same "<scope> scope required" message, so the
# existing Atomspace::Base rescue chain maps it exactly as it maps today's
# denial. No new error class, no new status surface.
#
# What this does NOT do: it introduces no scope, changes no tool's declared
# scope, decides nothing about which principals are granted mcp:atomspace:read
# (owned by McpApi::AtomspaceGrants in the deck repo, per INTEGRATION.md),
# touches no token issuance, and wires nothing into any dispatch path.
#
# Local and offline: in-process grant results and synthetic tool classes, no
# client, no token fetch, no network.

RSpec.describe Hyperon::Wiki::Mcp::Server::Tools::Atomspace::Registry, "request-context entry points" do
  let(:registry) { described_class }
  let(:authorization_error) { Hyperon::Wiki::Mcp::Client::AuthorizationError }
  let(:scope) { "mcp:atomspace:read" }
  let(:now) { Time.utc(2026, 10, 1, 12, 0, 0) }

  def grant_result(grant_scopes: ["mcp:atomspace:read"].freeze,
                   authorization_valid_until: Time.utc(2026, 10, 1, 13, 0, 0))
    Hyperon::Wiki::Mcp::Auth::GrantReadResult.new(
      verification_status: :verified, verification_error_class: nil,
      grant_scopes: grant_scopes, token_version: "fingerprint",
      credential_ref: "cred-abc", signed_exp_status: :present_numeric,
      signed_exp_value: authorization_valid_until, token_refresh_deadline: nil,
      token_hard_expiry: nil, grant_read_at: Time.utc(2026, 10, 1, 11, 59, 0),
      authorization_valid_until: authorization_valid_until,
      authorization_bound_kind: :signed_exp
    )
  end

  def context_for(grant)
    Hyperon::Wiki::Mcp::RequestContext.new(
      principal_kind: :authenticated_session, session_id: "sess-abc",
      verified_inbound_claims: { "sub" => "user:Alice" },
      grant_read_result: grant, outbound_credential_ref: grant.credential_ref,
      grant_source: :deck_verified_token, local_trusted: false, request_id: "req-0001"
    )
  end

  let(:granted) { context_for(grant_result) }
  let(:ungranted) { context_for(grant_result(grant_scopes: ["mcp:read"].freeze)) }
  let(:expired) { context_for(grant_result(authorization_valid_until: Time.utc(2026, 10, 1, 11, 0, 0))) }

  def tool_declaring(declared)
    Class.new { define_singleton_method(:required_scope) { declared } }
  end

  describe ".gate_for_context!" do
    it "permits an invocation the context's own grant read authorizes" do
      expect { registry.gate_for_context!(described_class::TOOLS.first, granted, now: now) }
        .not_to raise_error
    end

    it "denies an invocation whose scope the grant read did not capture" do
      expect { registry.gate_for_context!(described_class::TOOLS.first, ungranted, now: now) }
        .to raise_error(authorization_error, /#{Regexp.escape(scope)} scope required/)
    end

    # The whole point of going through the context: the scope list still names
    # the scope, and the answer is still no.
    it "denies an invocation whose grant has passed its authorization deadline" do
      expect(expired.grant_read_result.grant_scopes).to include(scope)

      expect { registry.gate_for_context!(described_class::TOOLS.first, expired, now: now) }
        .to raise_error(authorization_error)
    end

    it "denies when no context backs the request at all" do
      expect { registry.gate_for_context!(described_class::TOOLS.first, nil, now: now) }
        .to raise_error(authorization_error, /no request context|request context/i)
    end

    it "denies when the supplied context cannot answer an authorization question" do
      expect { registry.gate_for_context!(described_class::TOOLS.first, Object.new, now: now) }
        .to raise_error(authorization_error)
    end

    # Resolution stays exactly where the committed work put it: a requirement
    # the registry cannot read denies the invocation, whatever the context holds.
    it "denies a tool whose own required scope is unresolvable, even for an authorized context" do
      [nil, "", :"mcp:atomspace:read", 1].each do |unresolvable|
        expect { registry.gate_for_context!(tool_declaring(unresolvable), granted, now: now) }
          .to raise_error(authorization_error, /unresolved|unresolvable/i)
      end

      expect { registry.gate_for_context!(Class.new, granted, now: now) }
        .to raise_error(authorization_error, /unresolved|unresolvable/i)
    end
  end

  describe ".visible_for_context" do
    it "advertises every locked tool to a context its grant read authorizes" do
      expect(registry.visible_for_context(granted, now: now)).to eq(described_class::TOOLS)
    end

    it "advertises nothing to a context lacking the scope" do
      expect(registry.visible_for_context(ungranted, now: now)).to be_empty
    end

    it "advertises nothing to a context whose grant has passed its deadline" do
      expect(registry.visible_for_context(expired, now: now)).to be_empty
    end

    it "advertises nothing when no context backs the request" do
      expect(registry.visible_for_context(nil, now: now)).to be_empty
    end

    it "advertises nothing when the supplied context cannot answer an authorization question" do
      expect(registry.visible_for_context(Object.new, now: now)).to be_empty
    end

    it "drops only the unresolvable entry, leaving its resolvable neighbour advertised" do
      resolvable = tool_declaring(scope)
      stub_const("#{described_class}::TOOLS", [tool_declaring(nil), resolvable].freeze)

      expect(registry.visible_for_context(granted, now: now)).to eq([resolvable])
    end
  end

  # The array-taking entry points are untouched: this slice adds a seam beside
  # them rather than changing what they answer.
  describe "the existing array-taking entry points, unchanged" do
    it "still hides and shows the locked tools by bare scope membership" do
      expect(registry.visible_for(%w[mcp:read])).to be_empty
      expect(registry.visible_for(%w[mcp:atomspace:read]).size).to eq(8)
    end

    it "still gates invocation on bare scope membership" do
      expect { registry.gate!(described_class::TOOLS.first, %w[mcp:read]) }
        .to raise_error(authorization_error)
      expect { registry.gate!(described_class::TOOLS.first, %w[mcp:atomspace:read]) }
        .not_to raise_error
    end
  end

  describe "the default clock" do
    it "reads the current time when none is supplied" do
      live = context_for(grant_result(authorization_valid_until: Time.now + 3600))
      stale = context_for(grant_result(authorization_valid_until: Time.now - 3600))

      expect { registry.gate_for_context!(described_class::TOOLS.first, live) }.not_to raise_error
      expect(registry.visible_for_context(live)).to eq(described_class::TOOLS)

      expect { registry.gate_for_context!(described_class::TOOLS.first, stale) }
        .to raise_error(authorization_error)
      expect(registry.visible_for_context(stale)).to be_empty
    end
  end
end
