# frozen_string_literal: true

require "spec_helper"
require "hyperon/wiki/mcp"

# The authorization question a RequestContext can answer about ITSELF, which is
# the half of enforcement the registry cannot supply: the registry owns what a
# tool REQUIRES, the context owns what its own grant read actually AUTHORIZES.
#
# Why the context answers rather than a caller reading grant_scopes directly:
# membership in grant_scopes is not an authorization decision. The committed
# Auth::GrantReadResult#authorization_valid_now? already states the fail-closed
# rule -- verified, carrying a trustworthy deadline, read strictly before that
# deadline, AND granted the scope -- and RequestContext's own class comment
# already says consumers ask grant_read_result.authorization_valid_now?, never
# principal_kind or grant_source. A caller that reached past that into
# grant_scopes would drop the freshness half of the rule and authorize an
# expired grant whose scope list still names the scope.
#
# Two fail-closed cases that membership-reading would get wrong, and that this
# pins down:
#
#   * A grant result that CANNOT answer the question. RequestContext snapshots
#     a non-immutable grant into GrantSnapshot, which carries
#     verification_status/grant_scopes/credential_ref and no decision method at
#     all. Such a context must authorize nothing rather than fall back to the
#     scope list the snapshot does carry.
#   * A required scope the granted list could match by accident. Auth#scopes
#     passes a verified `scope` claim through unvalidated (nil elements
#     included), so a nil or non-String requirement must never be matchable --
#     the same definition of unresolvable the committed registry scope
#     resolution already uses.
#
# What this does NOT decide: which principals are granted which scope (owned by
# McpApi::AtomspaceGrants in the deck repo), any token/JWT issuance semantics,
# or any HTTP/JSON-RPC status. It reads the grant this context already captured
# and nothing else.
#
# Local and offline: grant results are built in-process, no client, no token
# fetch, no network.

RSpec.describe Hyperon::Wiki::Mcp::RequestContext, "#authorizes_scope?" do
  let(:scope) { "mcp:atomspace:read" }
  let(:now) { Time.utc(2026, 10, 1, 12, 0, 0) }

  # A real Auth::GrantReadResult, which is a frozen Data with deeply frozen
  # scopes and credential -- so RequestContext keeps it WHOLE and the decision
  # method survives into the context.
  def grant_result(verification_status: :verified,
                   grant_scopes: ["mcp:atomspace:read"].freeze,
                   credential_ref: "cred-abc",
                   authorization_valid_until: Time.utc(2026, 10, 1, 13, 0, 0),
                   authorization_bound_kind: :signed_exp)
    Hyperon::Wiki::Mcp::Auth::GrantReadResult.new(
      verification_status: verification_status,
      verification_error_class: nil,
      grant_scopes: grant_scopes,
      token_version: "fingerprint",
      credential_ref: credential_ref.freeze,
      signed_exp_status: :present_numeric,
      signed_exp_value: authorization_valid_until,
      token_refresh_deadline: nil,
      token_hard_expiry: nil,
      grant_read_at: Time.utc(2026, 10, 1, 11, 59, 0),
      authorization_valid_until: authorization_valid_until,
      authorization_bound_kind: authorization_bound_kind
    )
  end

  def authenticated_context(grant)
    described_class.new(
      principal_kind: :authenticated_session,
      session_id: "sess-abc",
      verified_inbound_claims: { "sub" => "user:Alice" },
      grant_read_result: grant,
      outbound_credential_ref: grant.credential_ref,
      grant_source: :deck_verified_token,
      local_trusted: false,
      request_id: "req-0001"
    )
  end

  describe "a verified, in-deadline grant" do
    it "authorizes a scope its own grant read captured" do
      context = authenticated_context(grant_result)

      expect(context.authorizes_scope?(scope, now: now)).to be(true)
    end

    it "refuses a scope the grant read did not capture" do
      context = authenticated_context(grant_result(grant_scopes: ["mcp:read"].freeze))

      expect(context.authorizes_scope?(scope, now: now)).to be(false)
    end
  end

  # Membership alone is not authorization. Each of these grants NAMES the scope
  # and must still be refused.
  describe "a grant that names the scope but cannot back it" do
    it "refuses once the authorization deadline has passed" do
      expired = grant_result(authorization_valid_until: Time.utc(2026, 10, 1, 11, 0, 0))
      context = authenticated_context(expired)

      expect(expired.grant_scopes).to include(scope)
      expect(context.authorizes_scope?(scope, now: now)).to be(false)
    end

    it "refuses exactly AT the deadline, not merely after it" do
      at_deadline = grant_result(authorization_valid_until: now)

      expect(authenticated_context(at_deadline).authorizes_scope?(scope, now: now)).to be(false)
    end

    it "refuses when no deadline could be trusted at all" do
      undeadlined = grant_result(authorization_valid_until: nil, authorization_bound_kind: nil)
      context = authenticated_context(undeadlined)

      expect(undeadlined.grant_scopes).to include(scope)
      expect(context.authorizes_scope?(scope, now: now)).to be(false)
    end
  end

  # A trusted-local caller is trusted by DEPLOYMENT, not by a grant: its shape
  # carries no granted scopes, so it authorizes no scope here. This invents no
  # policy -- it is what the captured grant says -- and grants such a caller
  # nothing it was not already granted.
  describe "a trusted-local context" do
    it "authorizes no scope, because its grant read captured none" do
      context = described_class.new(
        principal_kind: :trusted_local,
        grant_read_result: Hyperon::Wiki::Mcp::Auth::GrantReadResult.not_applicable(
          grant_read_at: Time.utc(2026, 10, 1, 11, 59, 0)
        ),
        grant_source: :trusted_local_default,
        local_trusted: true,
        request_id: "req-local"
      )

      expect(context.authorizes_scope?(scope, now: now)).to be(false)
      expect(context.authorizes_scope?("mcp:read", now: now)).to be(false)
    end
  end

  # The snapshot path: a grant result that is not immutable all the way down is
  # copied into GrantSnapshot, which has no decision method. The scope list
  # survives the copy, so a membership-reading consumer would authorize here.
  describe "a context whose grant result cannot answer the question" do
    # An anonymous Struct, not a named constant: the shape matters, the name
    # does not, and a constant defined inside a block leaks into the suite.
    def mutable_grant(verification_status:, grant_scopes:, credential_ref:)
      Struct.new(:verification_status, :grant_scopes, :credential_ref, keyword_init: true)
            .new(verification_status: verification_status, grant_scopes: grant_scopes,
                 credential_ref: credential_ref)
    end

    it "refuses rather than falling back to the scope list the snapshot still carries" do
      mutable = mutable_grant(
        verification_status: :verified,
        grant_scopes: ["mcp:atomspace:read"],
        credential_ref: "cred-abc"
      )
      context = authenticated_context(mutable)

      expect(context.grant_read_result).not_to respond_to(:authorization_valid_now?)
      expect(context.grant_read_result.grant_scopes).to include(scope)
      expect(context.authorizes_scope?(scope, now: now)).to be(false)
    end
  end

  # Unresolvable is defined the same way the committed registry scope
  # resolution defines it: by what a membership check can act on, not by nil
  # alone. A granted list arrives unvalidated, so a nil requirement must never
  # be matchable by a nil grant.
  describe "a required scope that names nothing usable" do
    [nil, "", :"mcp:atomspace:read", 1, ["mcp:atomspace:read"]].each do |unusable|
      it "refuses #{unusable.inspect}, whatever the grant happens to list" do
        context = authenticated_context(
          grant_result(grant_scopes: ["mcp:atomspace:read", nil, "", :"mcp:atomspace:read", 1].freeze)
        )

        expect(context.authorizes_scope?(unusable, now: now)).to be(false)
      end
    end

    it "still authorizes the real scope standing beside those passengers" do
      context = authenticated_context(
        grant_result(grant_scopes: ["mcp:atomspace:read", nil, 1].freeze)
      )

      expect(context.authorizes_scope?(scope, now: now)).to be(true)
    end
  end

  describe "the default clock" do
    it "reads the current time when no clock is supplied" do
      live = grant_result(authorization_valid_until: Time.now + 3600)

      expect(authenticated_context(live).authorizes_scope?(scope)).to be(true)
    end

    it "refuses an already-expired grant when no clock is supplied" do
      stale = grant_result(authorization_valid_until: Time.now - 3600)

      expect(authenticated_context(stale).authorizes_scope?(scope)).to be(false)
    end
  end
end
