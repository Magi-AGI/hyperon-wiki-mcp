# frozen_string_literal: true

# S7a' RED spec (Rev2) -- asserts DESIRED behavior for the gem-level
# Hyperon::Wiki::Mcp::RequestContext value object, per the S7a' closeout
# (Gate S7a' Rev3, Card 17184): both reviewers converged on a gem-level
# namespace (decoupled from the Rack adapter) as the next-step interface, as
# tightened by the Codex B1-B4 review pass.
#
# The target file (lib/hyperon/wiki/mcp/request_context.rb) does not exist
# yet, so resolving Hyperon::Wiki::Mcp::RequestContext inside each example is
# expected to raise NameError -- the intended RED failure for a
# not-yet-authored interface, not a spec-authoring mistake. This file must
# not drive a change to lib/ as part of this authoring step.
#
# Deliberately decoupled from RackApp and the real Auth/JWKS pipeline: the
# grant_read_result field is filled with a synthetic double/struct shaped
# like Auth::GrantReadResult (see auth_grant_read_result_spec.rb), not a real
# captured token, so this spec exercises only the RequestContext data
# contract itself.
#
# Every negative (ArgumentError) example below starts from a full, mutually
# consistent baseline attribute hash (valid_authenticated_attrs or
# valid_trusted_local_attrs) and overrides exactly ONE field. This matters:
# an earlier revision of this file had negative fixtures that changed two
# fields at once (a nil grant-result credential alongside a non-nil outbound
# credential), so a constructor that only checked the unrelated credential
# mismatch could satisfy a test aimed at a completely different invariant
# (missing session_id, or a conflicting local_trusted flag). Isolating the
# changed field to exactly one makes each example actually pin down the
# invariant its description claims.

require "spec_helper"
require "hyperon/wiki/mcp"

# Minimal stand-in for Auth::GrantReadResult, shaped only as far as this
# spec's assertions need. It intentionally does not require the real
# GrantReadResult (also not yet implemented -- see
# auth_grant_read_result_spec.rb) to exist.
SyntheticGrantResult = Struct.new(:verification_status, :grant_scopes, :credential_ref, keyword_init: true)

RSpec.describe "Hyperon::Wiki::Mcp::RequestContext" do
  def described_class
    Hyperon::Wiki::Mcp::RequestContext
  end

  def synthetic_grant_result(verification_status:, grant_scopes:, credential_ref: nil)
    SyntheticGrantResult.new(
      verification_status: verification_status,
      grant_scopes: grant_scopes,
      credential_ref: credential_ref
    )
  end

  # Full, self-consistent authenticated-session attribute set: outbound
  # credential matches the grant's own credential_ref, principal_kind and
  # local_trusted/grant_source agree. Every negative example below should
  # override exactly one key of this hash.
  def valid_authenticated_attrs(overrides = {})
    grant_result = overrides[:grant_read_result] || synthetic_grant_result(
      verification_status: :verified,
      grant_scopes: %w[mcp:atomspace:read],
      credential_ref: "cred-abc"
    )

    {
      principal_kind: :authenticated_session,
      session_id: "sess-abc",
      verified_inbound_claims: { "sub" => "user:Alice" },
      grant_read_result: grant_result,
      outbound_credential_ref: "cred-abc",
      grant_source: :deck_verified_token,
      local_trusted: false,
      request_id: "req-auth-baseline"
    }.merge(overrides)
  end

  # Full, self-consistent trusted-local attribute set: no session identity,
  # no outbound credential, a not_applicable grant result, and the
  # trusted-local grant source/local_trusted pairing.
  def valid_trusted_local_attrs(overrides = {})
    grant_result = overrides[:grant_read_result] || synthetic_grant_result(
      verification_status: :not_applicable,
      grant_scopes: [],
      credential_ref: nil
    )

    {
      principal_kind: :trusted_local,
      session_id: nil,
      verified_inbound_claims: nil,
      grant_read_result: grant_result,
      outbound_credential_ref: nil,
      grant_source: :trusted_local_default,
      local_trusted: true,
      request_id: "req-local-baseline"
    }.merge(overrides)
  end

  describe "an authenticated-session context" do
    it "requires and carries session identity, the verified grant read result, and the " \
       "outbound credential it is bound to" do
      context = described_class.new(**valid_authenticated_attrs(request_id: "req-0001"))

      expect(context.principal_kind).to eq(:authenticated_session)
      expect(context.session_id).to eq("sess-abc")
      expect(context.verified_inbound_claims).to eq({ "sub" => "user:Alice" })
      expect(context.grant_read_result.credential_ref).to eq("cred-abc")
      expect(context.outbound_credential_ref).to eq("cred-abc")
      expect(context.grant_source).to eq(:deck_verified_token)
      expect(context.local_trusted).to be(false)
      expect(context.request_id).to eq("req-0001")
    end
  end

  describe "a trusted-local context" do
    it "carries no session identity or inbound claims, and uses the trusted-local grant " \
       "source with local_trusted true" do
      context = described_class.new(**valid_trusted_local_attrs(request_id: "req-0002"))

      expect(context.principal_kind).to eq(:trusted_local)
      expect(context.session_id).to be_nil
      expect(context.verified_inbound_claims).to be_nil
      expect(context.grant_read_result.verification_status).to eq(:not_applicable)
      expect(context.grant_read_result.grant_scopes).to eq([])
      expect(context.grant_source).to eq(:trusted_local_default)
      expect(context.local_trusted).to be(true)
    end
  end

  describe "invalid or mixed principal shapes" do
    it "rejects a trusted_local principal that also carries a session_id" do
      expect do
        described_class.new(**valid_trusted_local_attrs(
          session_id: "sess-should-not-be-here", request_id: "req-0003"
        ))
      end.to raise_error(ArgumentError)
    end

    it "rejects an authenticated_session principal with no session_id" do
      expect do
        described_class.new(**valid_authenticated_attrs(session_id: nil, request_id: "req-0004"))
      end.to raise_error(ArgumentError)
    end

    it "rejects local_trusted: true paired with principal_kind: :authenticated_session" do
      expect do
        described_class.new(**valid_authenticated_attrs(local_trusted: true, request_id: "req-0005"))
      end.to raise_error(ArgumentError)
    end
  end

  describe "credential binding consistency" do
    it "rejects an authenticated_session context whose outbound_credential_ref does not " \
       "match the grant_read_result's own credential_ref" do
      expect do
        described_class.new(**valid_authenticated_attrs(
          outbound_credential_ref: "cred-does-not-match", request_id: "req-0007"
        ))
      end.to raise_error(ArgumentError)
    end
  end

  describe "trusted-local grant/source policy" do
    it "rejects a trusted_local context whose grant_source is :deck_verified_token" do
      expect do
        described_class.new(**valid_trusted_local_attrs(
          grant_source: :deck_verified_token, request_id: "req-0008"
        ))
      end.to raise_error(ArgumentError)
    end

    it "rejects an authenticated_session context whose grant_source is :trusted_local_default" do
      expect do
        described_class.new(**valid_authenticated_attrs(
          grant_source: :trusted_local_default, request_id: "req-0009"
        ))
      end.to raise_error(ArgumentError)
    end

    it "rejects a trusted_local context whose grant_read_result reports a verified Deck " \
       "grant" do
      verified_grant = synthetic_grant_result(
        verification_status: :verified, grant_scopes: [], credential_ref: nil
      )

      expect do
        described_class.new(**valid_trusted_local_attrs(
          grant_read_result: verified_grant, request_id: "req-0010"
        ))
      end.to raise_error(ArgumentError)
    end
  end

  describe "isolation of the context's own mutable inputs" do
    it "does not reflect a later mutation of the claims hash the caller passed in" do
      claims = { "sub" => "user:Alice" }
      context = described_class.new(**valid_authenticated_attrs(
        verified_inbound_claims: claims, request_id: "req-0011"
      ))

      claims["sub"] = "user:Mallory"
      claims["injected"] = "true"

      expect(context.verified_inbound_claims).to eq({ "sub" => "user:Alice" })
    end

    it "returns a verified_inbound_claims hash the caller cannot mutate to affect later reads" do
      context = described_class.new(**valid_authenticated_attrs(request_id: "req-0012"))

      expect(context.verified_inbound_claims).to be_frozen
    end
  end

  describe "isolation of the supplied grant read result" do
    # The approved contract is a captured value object, not mutable
    # authorization state (Codex Rev4, B4): a later mutation of the
    # grant_scopes array on the object originally passed in to the
    # constructor must NOT become visible through the context afterward.
    # This replaces an earlier, contract-violating expectation that treated
    # RequestContext as retaining a live, mutable reference.
    it "keeps the context's grant_read_result snapshot unchanged after a later mutation " \
       "of the grant_scopes array on the object originally passed in" do
      grant_result = synthetic_grant_result(
        verification_status: :verified,
        grant_scopes: %w[mcp:atomspace:read],
        credential_ref: "cred-abc"
      )

      context = described_class.new(**valid_authenticated_attrs(
        grant_read_result: grant_result, request_id: "req-0013"
      ))

      grant_result.grant_scopes << "cards:read"

      expect(context.grant_read_result.grant_scopes).to eq(%w[mcp:atomspace:read])
    end
  end

  # Codex G3: a snapshot that is only shallowly immutable is not a snapshot.
  # Freezing the claims hash still leaves its nested values writable, keeping
  # a supplied result "whole" still shares its scope strings, and the
  # identity/credential strings a context reports are the caller's own
  # objects -- so a later in-place edit can change what an already-validated
  # context says about its principal, its grant, or the credential it is
  # bound to.
  describe "deep isolation of captured identity and authorization values" do
    it "does not reflect a later mutation of a value nested inside the claims hash" do
      claims = { "sub" => +"user:Alice", "roles" => [+"reader"], "profile" => { "org" => +"magi" } }
      context = described_class.new(**valid_authenticated_attrs(
        verified_inbound_claims: claims, request_id: "req-0014"
      ))

      claims["sub"] << ":Mallory"
      claims["roles"] << "admin"
      claims["profile"]["org"] << "-elsewhere"

      expect(context.verified_inbound_claims["sub"]).to eq("user:Alice")
      expect(context.verified_inbound_claims["roles"]).to eq(%w[reader])
      expect(context.verified_inbound_claims["profile"]).to eq({ "org" => "magi" })
    end

    it "captures identity strings the caller cannot rewrite afterward" do
      session_id = +"sess-abc"
      request_id = +"req-0015"
      context = described_class.new(**valid_authenticated_attrs(
        session_id: session_id, request_id: request_id
      ))

      session_id << "-hijacked"
      request_id << "-hijacked"

      expect(context.session_id).to eq("sess-abc")
      expect(context.request_id).to eq("req-0015")
      expect(context.session_id).to be_frozen
      expect(context.request_id).to be_frozen
    end

    it "captures the grant's scope and credential strings so a later in-place edit cannot " \
       "change the grant or the credential the context is bound to" do
      scope = +"mcp:atomspace:read"
      credential = +"cred-abc"
      grant_result = synthetic_grant_result(
        verification_status: :verified, grant_scopes: [scope], credential_ref: credential
      )

      context = described_class.new(**valid_authenticated_attrs(
        grant_read_result: grant_result, outbound_credential_ref: credential, request_id: "req-0016"
      ))

      scope << ":widened"
      credential << "-rotated"

      expect(context.grant_read_result.grant_scopes).to eq(%w[mcp:atomspace:read])
      expect(context.grant_read_result.credential_ref).to eq("cred-abc")
      expect(context.outbound_credential_ref).to eq("cred-abc")
    end

    it "does not keep a frozen grant result whole when its scope strings are still mutable" do
      scope = +"mcp:atomspace:read"
      shallowly_frozen_grant = synthetic_grant_result(
        verification_status: :verified, grant_scopes: [scope].freeze, credential_ref: "cred-abc"
      ).freeze

      context = described_class.new(**valid_authenticated_attrs(
        grant_read_result: shallowly_frozen_grant, request_id: "req-0017"
      ))

      scope << ":widened"

      expect(context.grant_read_result.grant_scopes).to eq(%w[mcp:atomspace:read])
      expect(context.grant_read_result.grant_scopes).to all(be_frozen)
    end
  end

  # Codex G4: the approved trusted-local shape is :not_applicable, empty
  # scopes, no inbound claims, and no captured or outbound credential.
  # Rejecting only a :verified grant leaves a credential-bearing local
  # context constructible -- a post-capture :verification_failed result,
  # its matching outbound credential, and inbound claims all pass a
  # :verified-only check while carrying exactly what trusted-local must not.
  describe "trusted-local shape strictness" do
    it "rejects the full forbidden shape: a verification_failed grant carrying its matching " \
       "outbound credential alongside inbound claims" do
      failed_with_credential = synthetic_grant_result(
        verification_status: :verification_failed, grant_scopes: nil, credential_ref: "cred-local"
      )

      expect do
        described_class.new(**valid_trusted_local_attrs(
          grant_read_result: failed_with_credential,
          outbound_credential_ref: "cred-local",
          verified_inbound_claims: { "sub" => "user:Alice" },
          request_id: "req-0018"
        ))
      end.to raise_error(ArgumentError)
    end

    it "rejects a trusted_local context whose grant_read_result reports verification_failed" do
      failed_grant = synthetic_grant_result(
        verification_status: :verification_failed, grant_scopes: nil, credential_ref: nil
      )

      expect do
        described_class.new(**valid_trusted_local_attrs(
          grant_read_result: failed_grant, request_id: "req-0019"
        ))
      end.to raise_error(ArgumentError)
    end

    it "rejects a trusted_local context that carries a captured and outbound credential" do
      # Two keys move together here on purpose: a MISMATCHED credential pair
      # would trip the credential-binding rule instead, so the pair is kept
      # self-consistent and only the trusted-local shape rule can reject it.
      credentialed_grant = synthetic_grant_result(
        verification_status: :not_applicable, grant_scopes: [], credential_ref: "cred-local"
      )

      expect do
        described_class.new(**valid_trusted_local_attrs(
          grant_read_result: credentialed_grant,
          outbound_credential_ref: "cred-local",
          request_id: "req-0020"
        ))
      end.to raise_error(ArgumentError)
    end

    it "rejects a trusted_local context that carries verified inbound claims" do
      expect do
        described_class.new(**valid_trusted_local_attrs(
          verified_inbound_claims: { "sub" => "user:Alice" }, request_id: "req-0021"
        ))
      end.to raise_error(ArgumentError)
    end

    it "rejects a trusted_local context whose grant result carries granted scopes" do
      scoped_grant = synthetic_grant_result(
        verification_status: :not_applicable, grant_scopes: %w[mcp:atomspace:read], credential_ref: nil
      )

      expect do
        described_class.new(**valid_trusted_local_attrs(
          grant_read_result: scoped_grant, request_id: "req-0022"
        ))
      end.to raise_error(ArgumentError)
    end
  end
end
