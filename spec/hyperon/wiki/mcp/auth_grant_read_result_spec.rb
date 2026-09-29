# frozen_string_literal: true

# S7a' RED spec (Rev2) -- asserts DESIRED behavior for Auth#read_grant and
# Auth::GrantReadResult, per the S7a' closeout (Gate S7a' Rev3, Card 17184)
# result table and the authorization_valid_now? deadline predicate, as
# tightened by the Codex B1-B4 review pass.
#
# Neither interface exists yet. This file is expected to fail with
# NoMethodError / NameError against current lib/hyperon/wiki/mcp/auth.rb, not
# because of a spec-authoring mistake. It must not drive a change to lib/ as
# part of this authoring step -- that is a separately gated step.
#
# Modeled on the S5/S4 sibling specs (auth_scopes_spec.rb,
# auth_verify_token_spec.rb): in-memory RSA key material, real signed JWTs,
# stubbed auth/JWKS endpoints via WebMock, no real network.
#
# Two deadlines matter here and are already distinct in Auth today, even
# though nothing yet reads them together:
#   * the token's own signed `exp` claim (verified via JWKS/JWT.decode)
#   * the auth response's `expires_in`-derived cache deadline
#     (Auth#fetch_token sets @token_expires_at = Time.now + expires_in)
# read_grant is expected to expose the TIGHTER of the two as
# authorization_valid_until, and to label which one is binding via
# authorization_bound_kind:
#   * :signed_exp  -- the signed exp is present and at least as tight as the
#                     cache deadline
#   * :cache       -- a signed exp is present but the cache deadline is
#                     tighter (rare, but the API must not silently ignore it)
#   * :cache_only  -- signed exp is absent (signed_exp_status :absent), so
#                     the cache deadline is the only bound available
#
# The full per-read result table exercised below:
#   verification_status, verification_error_class, grant_scopes,
#   token_version, credential_ref, signed_exp_status, signed_exp_value,
#   token_refresh_deadline, token_hard_expiry, grant_read_at,
#   authorization_valid_until, authorization_bound_kind
#
# signed_exp_status is one of :present_numeric, :present_string_coercible,
# :absent, or :unusable when a trusted payload was obtained; it is nil when
# verification_status is anything other than :verified, since an unverified
# claim must never be read as if it were trustworthy.
#   * :absent   -- no exp claim was present at all; the cache deadline is
#                  used as the sole authorization bound (:cache_only).
#   * :unusable -- an exp claim was present but could not be interpreted as
#                  a valid deadline. Unlike :absent, this does NOT fall back
#                  to the cache deadline: authorization_valid_until is nil
#                  and authorization is denied even while the cache
#                  deadline itself remains live.
#
# Fail-closed contract for verification-time errors: ANY exception raised
# while attempting to cryptographically verify a captured token -- a
# JWT::DecodeError subtype, a JWKSError from the JWKS fetch, or a raw error
# from malformed JWK key material -- must surface as verification_status
# :verification_failed and must never fall back to the (possibly still-live)
# cache deadline. verification_error_class distinguishes WHY, per the
# approved result table:
#   * JWKSError is preserved as-is, so JWKS-outage failures remain
#     distinguishable from signature/claim failures.
#   * A JWT::DecodeError subtype (bad signature, bad claims) is wrapped as
#     VerificationError.
#   * A raw error from malformed JWK key material -- an ArgumentError from
#     an unparseable modulus/exponent, a NoMethodError from a missing one --
#     propagates with its OWN native class. It is deliberately NOT wrapped
#     into VerificationError: the approved table keeps these distinguishable
#     outcomes, not one uniform bucket.

require "spec_helper"
require "webmock/rspec"
require "base64"
require "json"
require "jwt"
require "openssl"
require "hyperon/wiki/mcp/config"
require "hyperon/wiki/mcp/auth"

# Synthetic, in-memory key material. Generated once per process; never written
# to disk and never shared with any endpoint.
AUTH_GRANT_READ_RESULT_SIGNING_KEY = OpenSSL::PKey::RSA.generate(2048)
# A second, unrelated key: used only to prove that a matching `kid` is not
# sufficient for verification -- the signature itself must also check out.
AUTH_GRANT_READ_RESULT_OTHER_KEY = OpenSSL::PKey::RSA.generate(2048)

RSpec.describe Hyperon::Wiki::Mcp::Auth do
  let(:base_url) { "https://test.example.com/api/mcp" }
  let(:auth_url) { "https://test.example.com/api/mcp/auth" }
  let(:jwks_url) { "https://test.example.com/api/mcp/.well-known/jwks.json" }
  let(:expected_issuer) { "test-issuer" }
  let(:kid) { "spec-key-001" }
  let(:now) { Time.now.to_i }
  let(:signing_key) { AUTH_GRANT_READ_RESULT_SIGNING_KEY }
  let(:other_signing_key) { AUTH_GRANT_READ_RESULT_OTHER_KEY }

  let(:config) do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["DECKO_API_BASE_URL"] = base_url
    ENV["MCP_ROLE"] = "user"
    ENV["JWT_ISSUER"] = expected_issuer
    Hyperon::Wiki::Mcp::Config.new
  end

  let(:auth) { described_class.new(config) }

  let(:base_payload) do
    {
      "sub" => "user:Alice",
      "role" => "user",
      "scope" => %w[mcp:atomspace:read cards:read],
      "iss" => expected_issuer,
      "iat" => now - 60,
      "exp" => now + 900,
      "jti" => "spec-jti-0001"
    }
  end

  before do
    WebMock.disable_net_connect!(allow_localhost: false)
  end

  after do
    WebMock.reset!
  end

  def b64url(str)
    Base64.urlsafe_encode64(str, padding: false)
  end

  def jwk_for(key, key_id:)
    {
      "kty" => "RSA",
      "kid" => key_id,
      "use" => "sig",
      "alg" => "RS256",
      "n" => b64url(key.n.to_s(2)),
      "e" => b64url(key.e.to_s(2))
    }
  end

  # A JWK entry whose key material cannot be parsed into an RSA public key:
  # "n" is not valid base64 even after urlsafe substitution. Exercises the
  # malformed-JWK reader outcome (B2/B3), distinct from a JWKS request that
  # simply fails to reach the server (JWKSError, exercised separately).
  def malformed_jwk_for(key_id:)
    {
      "kty" => "RSA",
      "kid" => key_id,
      "use" => "sig",
      "alg" => "RS256",
      "n" => "not-valid-base64!!!",
      "e" => "AQAB"
    }
  end

  # A JWK entry with no modulus at all: decode_base64url calls #length on the
  # nil "n" value and raises NoMethodError, distinct from the ArgumentError
  # malformed_jwk_for exercises. The approved result table requires these
  # two remain distinguishable verification_error_class values rather than
  # both being folded into VerificationError.
  def jwk_missing_modulus_for(key_id:)
    {
      "kty" => "RSA",
      "kid" => key_id,
      "use" => "sig",
      "alg" => "RS256",
      "n" => nil,
      "e" => "AQAB"
    }
  end

  # NOTE: callers must brace the document hash. A brace-less `"keys" => [...]`
  # argument is parsed as keyword arguments under Ruby 3.
  def stub_jwks(document)
    stub_request(:get, jwks_url).to_return(
      status: 200,
      body: JSON.generate(document),
      headers: { "Content-Type" => "application/json" }
    )
  end

  def stub_jwks_failure
    stub_request(:get, jwks_url).to_return(
      status: 500,
      body: JSON.generate({ "error" => "jwks unavailable" }),
      headers: { "Content-Type" => "application/json" }
    )
  end

  def stub_auth_success(token, expires_in: 3600)
    stub_request(:post, auth_url).to_return(
      status: 201,
      body: JSON.generate({ "token" => token, "role" => "user", "expires_in" => expires_in }),
      headers: { "Content-Type" => "application/json" }
    )
  end

  def stub_auth_failure
    stub_request(:post, auth_url).to_return(
      status: 401,
      body: JSON.generate({ "error" => "invalid credentials" }),
      headers: { "Content-Type" => "application/json" }
    )
  end

  def sign(payload, key: signing_key, key_id: kid)
    JWT.encode(payload, key, "RS256", { kid: key_id })
  end

  # JWT.encode (jwt gem 2.10.x) unconditionally validates that `exp` is
  # Numeric before signing (JWT::Encode#segments -> Token#verify_claims!),
  # raising JWT::InvalidPayload for a String exp. That encode-time gate would
  # mask the string-coercion behavior this file specifies before a token
  # ever gets built, so the two string-exp examples below construct and sign
  # the JWT by hand -- the same header/payload/signature shape JWT.encode
  # would produce, using the identical RS256 signing call the jwt gem itself
  # uses (OpenSSL::PKey::RSA#sign with a SHA256 digest over the base64url
  # header+payload) -- without going through its claim-shape validation.
  def sign_raw(payload, key: signing_key, key_id: kid)
    header = { "alg" => "RS256", "typ" => "JWT", "kid" => key_id }
    signing_input = [b64url(JSON.generate(header)), b64url(JSON.generate(payload))].join(".")
    signature = key.sign(OpenSSL::Digest.new("SHA256"), signing_input)
    "#{signing_input}.#{b64url(signature)}"
  end

  describe "#read_grant" do
    context "when the grant is verified with scopes present" do
      it "reports a fully-populated verified grant, valid before its signed-exp deadline " \
         "and denied exactly at and after it" do
        signed_exp = now + 900
        token = sign(base_payload)
        stub_auth_success(token, expires_in: 3600)
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

        captured_at = Time.now
        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: captured_at)

        expect(result).to be_a(described_class::GrantReadResult)
        expect(result.verification_status).to eq(:verified)
        expect(result.verification_error_class).to be_nil
        expect(result.grant_scopes).to include("mcp:atomspace:read")

        # token_version is an audit/detection fingerprint only -- it must not
        # double as the credential handle that a gated outbound call binds to.
        expect(result.token_version).not_to be_nil
        expect(result.credential_ref).not_to be_nil
        expect(result.token_version).not_to eq(result.credential_ref)

        expect(result.signed_exp_status).to eq(:present_numeric)
        expect(result.signed_exp_value).to eq(Time.at(signed_exp))
        expect(result.token_hard_expiry).to be_within(2).of(captured_at + 3600)
        expect(result.token_refresh_deadline)
          .to be_within(2).of(captured_at + 3600 - described_class::REFRESH_BUFFER_SECONDS)
        expect(result.grant_read_at).to eq(captured_at)

        expect(result.authorization_bound_kind).to eq(:signed_exp)
        expect(result.authorization_valid_until).to eq(Time.at(signed_exp))

        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: Time.at(signed_exp - 1))
        ).to be(true)
        # Exactly at the deadline is no longer valid -- not just "sometime after".
        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: Time.at(signed_exp))
        ).to be(false)
        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: Time.at(signed_exp + 1))
        ).to be(false)

        # JWKS must actually have been consulted exactly once -- a grant read
        # from an unverified decode would be a trust-boundary violation, and a
        # second, unaccounted-for verification would indicate the credential
        # binding below is not actually pinned to a single capture.
        expect(WebMock).to have_requested(:get, jwks_url).once
      end
    end

    context "when the grant is verified with empty/absent scopes" do
      it "reports a fully-populated verified grant with grant_scopes == [] and denies a " \
         "required scope that was never granted" do
        no_scope_payload = base_payload.except("scope")
        signed_exp = now + 900
        token = sign(no_scope_payload)
        stub_auth_success(token, expires_in: 3600)
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

        captured_at = Time.now
        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: captured_at)

        expect(result.verification_status).to eq(:verified)
        expect(result.verification_error_class).to be_nil
        expect(result.grant_scopes).to eq([])

        expect(result.token_version).not_to be_nil
        expect(result.credential_ref).not_to be_nil
        expect(result.signed_exp_status).to eq(:present_numeric)
        expect(result.signed_exp_value).to eq(Time.at(signed_exp))
        expect(result.token_hard_expiry).to be_within(2).of(captured_at + 3600)
        expect(result.token_refresh_deadline)
          .to be_within(2).of(captured_at + 3600 - described_class::REFRESH_BUFFER_SECONDS)
        expect(result.grant_read_at).to eq(captured_at)

        expect(result.authorization_bound_kind).to eq(:signed_exp)
        expect(result.authorization_valid_until).to eq(Time.at(signed_exp))

        # The grant itself verified and remains within its deadline -- the
        # denial below is solely because the required scope was never
        # granted, not because of a verification or deadline failure.
        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: captured_at)
        ).to be(false)
      end
    end

    context "when authentication fails before a token is captured" do
      it "reports verification_failed with every captured-token and deadline field nil, " \
         "while still recording when the read was attempted, and without ever consulting " \
         "JWKS" do
        stub_auth_failure

        captured_at = Time.now
        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: captured_at)

        expect(result.verification_status).to eq(:verification_failed)
        expect(result.verification_error_class).to eq(described_class::AuthenticationError)
        expect(result.grant_scopes).to be_nil
        expect(result.token_version).to be_nil
        expect(result.credential_ref).to be_nil
        expect(result.signed_exp_status).to be_nil
        expect(result.signed_exp_value).to be_nil
        expect(result.token_refresh_deadline).to be_nil
        expect(result.token_hard_expiry).to be_nil
        expect(result.authorization_valid_until).to be_nil
        expect(result.authorization_bound_kind).to be_nil
        expect(result.grant_read_at).to eq(captured_at)
        expect(result.authorization_valid_now?("mcp:atomspace:read", now: captured_at)).to be(false)

        expect(WebMock).not_to have_requested(:get, jwks_url)
      end
    end

    context "when verification fails after a token is captured" do
      it "reports verification_failed with grant_scopes nil, while still exposing the " \
         "captured-credential and cache-deadline fields from the successful auth response, " \
         "and never falls back to the still-live cache deadline for authorization" do
        token = sign(base_payload)
        # Auth succeeds and a token is captured, but JWKS advertises no key
        # under this token's kid, so verify_token raises VerificationError.
        stub_auth_success(token, expires_in: 3600)
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: "some-other-kid")] })

        captured_at = Time.now
        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: captured_at)

        expect(result.verification_status).to eq(:verification_failed)
        expect(result.verification_error_class).to eq(described_class::VerificationError)
        expect(result.grant_scopes).to be_nil

        # Cache metadata comes from the successful auth response, independent
        # of JWT verification, so it remains present here.
        expect(result.token_version).not_to be_nil
        expect(result.credential_ref).not_to be_nil
        expect(result.token_hard_expiry).to be_within(2).of(captured_at + 3600)
        expect(result.token_refresh_deadline)
          .to be_within(2).of(captured_at + 3600 - described_class::REFRESH_BUFFER_SECONDS)

        # An unverified claim must never be read as trustworthy.
        expect(result.signed_exp_status).to be_nil
        expect(result.signed_exp_value).to be_nil

        # The auth response's cache deadline (3600s out) is nowhere near
        # expired here -- a fallback to cache-only validity on verification
        # failure would incorrectly report this grant as usable.
        expect(result.authorization_valid_until).to be_nil
        expect(result.authorization_bound_kind).to be_nil
        expect(result.authorization_valid_now?("mcp:atomspace:read", now: captured_at)).to be(false)

        expect(WebMock).to have_requested(:get, jwks_url)
      end
    end

    context "when the signature does not verify even though the kid matches" do
      it "rejects the token: a matching kid alone is not sufficient, the signature itself " \
         "must check out" do
        # Signed with signing_key, but JWKS advertises other_signing_key's
        # public part under the SAME kid -- proves signature verification is
        # actually exercised, not merely a kid lookup.
        token = sign(base_payload, key: signing_key, key_id: kid)
        stub_auth_success(token, expires_in: 3600)
        stub_jwks({ "keys" => [jwk_for(other_signing_key, key_id: kid)] })

        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: Time.now)

        expect(result.verification_status).to eq(:verification_failed)
        expect(result.verification_error_class).to eq(described_class::VerificationError)
        expect(result.grant_scopes).to be_nil
        expect(result.authorization_valid_now?("mcp:atomspace:read", now: Time.now)).to be(false)

        expect(WebMock).to have_requested(:get, jwks_url)
      end
    end

    context "when the signed expiry precedes the auth response's cache deadline" do
      it "binds authorization_valid_until to the tighter signed expiry, labels the bound " \
         "kind :signed_exp, and denies exactly at and after that deadline" do
        signed_exp = now + 100
        token = sign(base_payload.merge("exp" => signed_exp))
        # Cache deadline (3600s out) is far later than the signed expiry.
        stub_auth_success(token, expires_in: 3600)
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: Time.now)

        expect(result.authorization_bound_kind).to eq(:signed_exp)
        expect(result.authorization_valid_until).to eq(Time.at(signed_exp))

        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: Time.at(signed_exp - 1))
        ).to be(true)
        # Exactly at the signed deadline is denied, not just strictly after it.
        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: Time.at(signed_exp))
        ).to be(false)
        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: Time.at(signed_exp + 1))
        ).to be(false)
      end
    end

    context "when the cache deadline precedes the signed expiry" do
      it "binds authorization_valid_until to the tighter cache deadline and labels the " \
         "bound kind :cache, even though a signed exp is present" do
        signed_exp = now + 3600
        token = sign(base_payload.merge("exp" => signed_exp))
        # Cache deadline (60s out) is far tighter than the signed expiry.
        stub_auth_success(token, expires_in: 60)
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

        captured_at = Time.now
        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: captured_at)

        expect(result.signed_exp_status).to eq(:present_numeric)
        expect(result.authorization_bound_kind).to eq(:cache)
        expect(result.authorization_valid_until).to be_within(2).of(captured_at + 60)

        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: captured_at + 59)
        ).to be(true)
        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: captured_at + 61)
        ).to be(false)
      end
    end

    context "when the token carries no signed exp, so the bound is cache-only" do
      it "labels authorization_bound_kind as :cache_only, bounds validity by the cache " \
         "deadline alone, and denies exactly at and after it" do
        token = sign(base_payload.except("exp"))
        stub_auth_success(token, expires_in: 1800)
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

        captured_at = Time.now
        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: captured_at)

        expect(result.verification_status).to eq(:verified)
        expect(result.signed_exp_status).to eq(:absent)
        expect(result.signed_exp_value).to be_nil
        expect(result.authorization_bound_kind).to eq(:cache_only)

        # Auth's cache deadline is @token_expires_at = Time.now + expires_in,
        # computed with Auth's OWN later Time.now inside fetch_token -- not
        # captured_at above. captured_at + 1800 can therefore precede the
        # real deadline by however long the fetch/verify round-trip took, so
        # asserting against that arithmetic (rather than the value the
        # result itself reports) would be testing a guess, not the contract.
        # Assert against the returned deadline, and pin cache_only's
        # authorization_valid_until to equal the reported hard expiry.
        deadline = result.authorization_valid_until
        expect(deadline).to eq(result.token_hard_expiry)

        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: deadline - 1)
        ).to be(true)
        # Exactly at the deadline is no longer valid -- not just "sometime after".
        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: deadline)
        ).to be(false)
        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: deadline + 1)
        ).to be(false)
      end
    end

    context "when the signed exp claim is a future numeric string" do
      it "normalizes the string exp, reporting signed_exp_status " \
         ":present_string_coercible with the coerced Time value" do
        signed_exp = now + 500
        token = sign_raw(base_payload.merge("exp" => signed_exp.to_s))
        stub_auth_success(token, expires_in: 3600)
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: Time.now)

        expect(result.verification_status).to eq(:verified)
        expect(result.signed_exp_status).to eq(:present_string_coercible)
        expect(result.signed_exp_value).to eq(Time.at(signed_exp))
        expect(result.authorization_bound_kind).to eq(:signed_exp)
        expect(result.authorization_valid_until).to eq(Time.at(signed_exp))
      end
    end

    context "when the signed exp claim is a fractional numeric value" do
      # Codex G1: the locked verifier truncates before comparing --
      # JWT::Claims::Expiration#verify! raises once
      # `payload['exp'].to_i <= (Time.now.to_i - leeway)`, so a credential
      # signed with exp T+0.9 is already rejected at T. Binding
      # authorization_valid_until to Time.at(T+0.9) would authorize a
      # fractional sliver the signature no longer covers, exactly as the
      # String variant did before it was corrected.
      it "normalizes a fractional numeric exp to the same integer-second cutoff the locked " \
         "verifier enforces, and denies the fractional sliver past claim.to_i" do
        signed_exp = now + 900.9
        cutoff = Time.at(signed_exp.to_i)
        token = sign(base_payload.merge("exp" => signed_exp))
        stub_auth_success(token, expires_in: 3600)
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: Time.now)

        expect(result.verification_status).to eq(:verified)
        expect(result.signed_exp_status).to eq(:present_numeric)
        expect(result.signed_exp_value).to eq(cutoff)
        expect(result.authorization_bound_kind).to eq(:signed_exp)
        expect(result.authorization_valid_until).to eq(cutoff)

        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: cutoff - 1)
        ).to be(true)
        # At and past the verifier's own cutoff the credential is dead, even
        # though the raw claim value is still 0.9s in the future.
        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: cutoff)
        ).to be(false)
        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: cutoff + 0.5)
        ).to be(false)
      end
    end

    context "when the signed exp claim is already expired at capture time" do
      it "fails closed with verification_failed and never falls back to the live cache " \
         "deadline, even though the exp claim is otherwise a coercible value" do
        expired_exp = now - 100
        token = sign_raw(base_payload.merge("exp" => expired_exp.to_s))
        stub_auth_success(token, expires_in: 3600)
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: Time.now)

        expect(result.verification_status).to eq(:verification_failed)
        expect(result.verification_error_class).to eq(described_class::VerificationError)
        expect(result.grant_scopes).to be_nil
        expect(result.signed_exp_status).to be_nil
        expect(result.authorization_valid_until).to be_nil
        expect(result.authorization_bound_kind).to be_nil
        expect(result.authorization_valid_now?("mcp:atomspace:read", now: Time.now)).to be(false)
      end
    end

    context "when JWKS fetch fails after a token is captured" do
      it "reports verification_failed with verification_error_class JWKSError, still " \
         "exposing the captured-credential and cache-deadline fields, and denies " \
         "authorization" do
        token = sign(base_payload)
        stub_auth_success(token, expires_in: 3600)
        stub_jwks_failure

        captured_at = Time.now
        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: captured_at)

        expect(result.verification_status).to eq(:verification_failed)
        expect(result.verification_error_class).to eq(described_class::JWKSError)
        expect(result.grant_scopes).to be_nil
        expect(result.token_version).not_to be_nil
        expect(result.credential_ref).not_to be_nil
        expect(result.token_hard_expiry).to be_within(2).of(captured_at + 3600)
        expect(result.authorization_valid_until).to be_nil
        expect(result.authorization_valid_now?("mcp:atomspace:read", now: captured_at)).to be(false)
      end
    end

    context "when the JWKS document contains unparseable key material for the matching kid" do
      it "reports verification_failed with verification_error_class ArgumentError when the " \
         "modulus is not valid base64 -- NOT wrapped as VerificationError -- while still " \
         "exposing the captured-credential and cache-deadline fields, and denying " \
         "authorization" do
        token = sign(base_payload)
        stub_auth_success(token, expires_in: 3600)
        stub_jwks({ "keys" => [malformed_jwk_for(key_id: kid)] })

        captured_at = Time.now
        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: captured_at)

        expect(result.verification_status).to eq(:verification_failed)
        expect(result.verification_error_class).to eq(ArgumentError)
        expect(result.grant_scopes).to be_nil
        expect(result.token_version).not_to be_nil
        expect(result.credential_ref).not_to be_nil
        expect(result.token_hard_expiry).to be_within(2).of(captured_at + 3600)
        expect(result.authorization_valid_until).to be_nil
        expect(result.authorization_valid_now?("mcp:atomspace:read", now: captured_at)).to be(false)
      end

      it "reports verification_failed with verification_error_class NoMethodError when the " \
         "modulus is missing entirely -- a distinguishable class from the malformed-base64 " \
         "case above, not folded into a shared VerificationError bucket -- while still " \
         "exposing the captured-credential and cache-deadline fields, and denying " \
         "authorization" do
        token = sign(base_payload)
        stub_auth_success(token, expires_in: 3600)
        stub_jwks({ "keys" => [jwk_missing_modulus_for(key_id: kid)] })

        captured_at = Time.now
        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: captured_at)

        expect(result.verification_status).to eq(:verification_failed)
        expect(result.verification_error_class).to eq(NoMethodError)
        expect(result.grant_scopes).to be_nil
        expect(result.token_version).not_to be_nil
        expect(result.credential_ref).not_to be_nil
        expect(result.token_hard_expiry).to be_within(2).of(captured_at + 3600)
        expect(result.authorization_valid_until).to be_nil
        expect(result.authorization_valid_now?("mcp:atomspace:read", now: captured_at)).to be(false)
      end
    end

    context "credential binding contract" do
      # credential_ref is a handle onto the captured token, not the raw
      # token string itself -- but the handle must expose the credential it
      # actually captured, via #captured_token, so binding can be verified
      # against a known value rather than mere object identity. The
      # captured value itself must be frozen: a caller downstream must not
      # be able to mutate the credential a handle was bound to.
      it "binds a handle's #captured_token to the exact credential string that read verified, " \
         "not merely to an opaquely-distinct object, and freezes that captured value against " \
         "mutation" do
        token = sign(base_payload)
        stub_auth_success(token, expires_in: 3600)
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: Time.now)

        expect(result.credential_ref).to respond_to(:captured_token)
        expect(result.credential_ref.captured_token).to eq(token)
        expect(result.credential_ref.captured_token).to be_frozen
        expect { result.credential_ref.captured_token << "tampered" }.to raise_error(FrozenError)
      end

      it "keeps the credential handle captured by a read bound to that capture even after " \
         "Auth's internal token state later rotates to a distinct credential" do
        # Two distinct tokens (distinct jti) so a later read provably
        # captures DIFFERENT Auth state, not the same stubbed response
        # compared against itself.
        first_token = sign(base_payload.merge("jti" => "spec-jti-first"))
        second_token = sign(base_payload.merge("jti" => "spec-jti-second"))
        stub_request(:post, auth_url).to_return(
          {
            status: 201,
            body: JSON.generate({ "token" => first_token, "role" => "user", "expires_in" => 3600 }),
            headers: { "Content-Type" => "application/json" }
          },
          {
            status: 201,
            body: JSON.generate({ "token" => second_token, "role" => "user", "expires_in" => 3600 }),
            headers: { "Content-Type" => "application/json" }
          }
        )
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

        # Spy (with #and_call_original) rather than count JWKS requests:
        # Auth caches JWKS across calls, so an HTTP request count would
        # under-count verifications that hit a warm cache. Asserting the
        # actual verify_token invocation and its argument is what proves
        # each read verified its OWN captured token.
        allow(auth).to receive(:verify_token).and_call_original

        first_result = auth.read_grant(required_scope: "mcp:atomspace:read", now: Time.now)
        first_token_version = first_result.token_version
        first_credential_ref = first_result.credential_ref

        expect(first_token_version).not_to be_nil
        expect(first_credential_ref).not_to be_nil
        expect(auth).to have_received(:verify_token).with(first_token)

        # Bind to the ACTUAL first token value, not merely an object that
        # happens to differ from whatever comes later -- two distinct
        # handles that both resolved Auth's then-current token would also
        # satisfy an identity-only check, so pin the captured value itself.
        expect(first_credential_ref.captured_token).to eq(first_token)

        # Force Auth to rotate its internal token/expiry state, then read
        # again. The second auth response is a DIFFERENT credential, so this
        # proves Auth's state actually changed.
        auth.refresh_token!
        second_result = auth.read_grant(required_scope: "mcp:atomspace:read", now: Time.now)
        second_credential_ref = second_result.credential_ref

        expect(auth).to have_received(:verify_token).with(second_token)
        expect(second_result.token_version).not_to eq(first_token_version)
        expect(second_credential_ref).not_to eq(first_credential_ref)
        expect(second_credential_ref.captured_token).to eq(second_token)
        expect(second_credential_ref.captured_token).not_to eq(first_credential_ref.captured_token)

        # The FIRST result's immutable handle remains bound to its own
        # capture, unaffected by Auth's later rotation -- not proven by
        # comparing a result to itself, but by comparing it against the
        # (now provably different) second capture above, and by re-checking
        # the actual captured value rather than mere object identity.
        expect(first_result.token_version).to eq(first_token_version)
        expect(first_result.credential_ref).to eq(first_credential_ref)
        expect(first_credential_ref.captured_token).to eq(first_token)

        # The captured credential a handle is bound to cannot be mutated out
        # from under it after the fact.
        expect(first_credential_ref.captured_token).to be_frozen
        expect { first_credential_ref.captured_token << "tampered" }.to raise_error(FrozenError)
      end

      # Codex G3: the fingerprint published as token_version is the audit
      # record of WHICH credential this read saw. A mutable one can be
      # rewritten after the fact, so a rotation-detection or audit consumer
      # comparing fingerprints could be made to see the wrong answer.
      it "freezes the audit fingerprint it publishes as token_version, so the recorded " \
         "credential identity cannot be rewritten after the read" do
        token = sign(base_payload)
        stub_auth_success(token, expires_in: 3600)
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: Time.now)

        expect(result.token_version).to be_frozen
        expect(result.credential_ref.fingerprint).to be_frozen
        expect { result.token_version << "tampered" }.to raise_error(FrozenError)
      end
    end

    context "capture atomicity under a concurrent refresh" do
      # Codex G3-review G2: the credential and the deadline that belongs to
      # THAT credential must be captured as one coherent pair. Reading the
      # token first and the cache deadline afterward leaves a window in
      # which a refresh can land, pairing token A with token B's later
      # expiry -- which extends A's cache-only authorization past A's own
      # deadline.
      #
      # The interleaving is simulated deterministically rather than with
      # real threads: the capture constructs a CredentialRef, so rotating
      # Auth's token from inside that constructor call reproduces exactly
      # the window between "which token" and "whose deadline".
      def stub_auth_rotation(first_token, second_token)
        stub_request(:post, auth_url).to_return(
          {
            status: 201,
            body: JSON.generate({ "token" => first_token, "role" => "user", "expires_in" => 3600 }),
            headers: { "Content-Type" => "application/json" }
          },
          {
            status: 201,
            body: JSON.generate({ "token" => second_token, "role" => "user", "expires_in" => 86_400 }),
            headers: { "Content-Type" => "application/json" }
          }
        )
      end

      it "pairs the captured credential with that credential's own deadlines when a refresh " \
         "lands mid-capture, never with the rotated-in credential's later expiry" do
        first_token = sign(base_payload.merge("jti" => "spec-jti-capture-first"))
        second_token = sign(base_payload.merge("jti" => "spec-jti-capture-second"))
        stub_auth_rotation(first_token, second_token)
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

        rotated = false
        allow(described_class::CredentialRef).to receive(:new).and_wrap_original do |original, *args|
          unless rotated
            rotated = true
            auth.refresh_token!
          end
          original.call(*args)
        end

        captured_at = Time.now
        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: captured_at)

        # The simulated refresh really did land inside the capture, and Auth
        # really did move on to the second credential (86_400s deadline).
        expect(rotated).to be(true)
        expect(auth.token).to eq(second_token)

        # ...yet the read reports ONE credential's own pair: the token it
        # captured beside that token's 3600s deadline, not the rotated-in
        # token's far later one.
        expect(result.credential_ref.captured_token).to eq(first_token)
        expect(result.token_hard_expiry).to be_within(60).of(captured_at + 3600)
        expect(result.token_refresh_deadline)
          .to eq(result.token_hard_expiry - described_class::REFRESH_BUFFER_SECONDS)
        expect(result.verification_status).to eq(:verified)
      end

      it "verifies the exact frozen bytes the credential handle captured, not the mutable " \
         "token string Auth is still holding" do
        token = sign(base_payload)
        stub_auth_success(token, expires_in: 3600)
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

        verified_credential = nil
        allow(auth).to receive(:verify_token).and_wrap_original do |original, candidate|
          verified_credential = candidate
          original.call(candidate)
        end

        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: Time.now)

        # Object identity, not value equality: a mutable original that merely
        # compares equal to the captured copy can still be rewritten between
        # the verification and the outbound call the result authorizes.
        expect(verified_credential).to be_frozen
        expect(verified_credential).to equal(result.credential_ref.captured_token)
      end
    end

    context "publication atomicity under a concurrent fetch" do
      # Codex G2 (remaining half): capturing under the credential lock only
      # helps if PUBLICATION is atomic too. A fetch that assigns the token
      # and then, as a separate step, assigns the deadline leaves a window
      # of its own: a second fetch completing in between publishes its whole
      # pair, and the first fetch's trailing deadline assignment then lands
      # on top of it -- leaving the second fetch's token beside the first
      # fetch's deadline. The locked reader faithfully captures that
      # incoherent pair.
      #
      # This is the writer-side window, distinct from the reader-side one
      # the refresh example above covers, and it is exercised deterministically
      # rather than with real threads: fetch_token reads "expires_in" from
      # the parsed auth response AFTER it has taken the token and BEFORE it
      # records the deadline, so a hash that runs a callback on that exact
      # key read reproduces the interleaving precisely. The simulated
      # concurrent fetch publishes its pair atomically, which is the most
      # favorable case for the code under test -- the corruption below comes
      # entirely from the outer fetch's own two-step publication.
      #
      # Both credentials are signed WITHOUT an exp claim, so the grant is
      # cache-only (:cache_only): the cache deadline is the ONLY bound on
      # authorization, which is what makes inheriting another credential's
      # later expiry an actual extension of authorization rather than a
      # cosmetic mismatch.
      def interleave_on_expires_in_read(&interleave)
        allow(JSON).to receive(:parse).and_wrap_original do |original, *args, **kwargs|
          parsed = original.call(*args, **kwargs)
          next parsed unless parsed.is_a?(Hash) && parsed.key?("expires_in")

          hooked = parsed.dup
          hooked.define_singleton_method(:[]) do |key|
            interleave.call if key == "expires_in"
            super(key)
          end
          hooked
        end
      end

      it "publishes the fetched credential beside its own deadline, so a credential can never " \
         "inherit a concurrently-fetched credential's later cache expiry" do
        long_lived_token = sign(base_payload.except("exp").merge("jti" => "spec-jti-publish-long"))
        short_lived_token = sign(base_payload.except("exp").merge("jti" => "spec-jti-publish-short"))
        own_deadline_seconds = { long_lived_token => 86_400, short_lived_token => 60 }

        stub_auth_success(long_lived_token, expires_in: 86_400)
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

        interleaved = false
        interleave_on_expires_in_read do
          next if interleaved

          interleaved = true
          # A second fetch completing mid-publication: a different credential
          # with a far tighter deadline of its own.
          auth.send(:publish_credential, short_lived_token, Time.now + 60)
        end

        captured_at = Time.now
        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: captured_at)

        # The interleaving really did land inside the fetch.
        expect(interleaved).to be(true)

        # Whichever of the two credentials the read ends up capturing, the
        # deadline reported beside it must be THAT credential's own.
        captured = result.credential_ref.captured_token
        expect(own_deadline_seconds).to have_key(captured)
        expect(result.token_hard_expiry)
          .to be_within(30).of(captured_at + own_deadline_seconds[captured])

        # Cache-only, so the pairing above is the whole authorization bound:
        # a credential must not be authorized until the other credential's
        # deadline.
        expect(result.verification_status).to eq(:verified)
        expect(result.authorization_bound_kind).to eq(:cache_only)
        expect(result.authorization_valid_until).to eq(result.token_hard_expiry)

        inherited_deadline = captured_at + (own_deadline_seconds[captured] == 60 ? 86_400 : 60)
        expect(result.authorization_valid_until).not_to be_within(30).of(inherited_deadline)
      end
    end

    context "immutability of the captured grant" do
      # Codex G3: freezing the scopes ARRAY leaves its strings writable.
      # Rewriting one in place after the read changes what
      # #authorization_valid_now? answers for a grant that already verified
      # -- silently revoking (or, with the reverse edit, widening) a decision
      # the signature covered.
      it "keeps the captured scopes unchanged, and its authorization answer stable, when the " \
         "verified payload's own scope strings are mutated afterward" do
        token = sign(base_payload)
        stub_auth_success(token, expires_in: 3600)
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

        verified_payload = nil
        allow(auth).to receive(:verify_token).and_wrap_original do |original, candidate|
          verified_payload = original.call(candidate)
        end

        captured_at = Time.now
        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: captured_at)

        expect(result.authorization_valid_now?("mcp:atomspace:read", now: captured_at)).to be(true)

        verified_payload["scope"].first << ":widened"

        expect(result.grant_scopes).to eq(%w[mcp:atomspace:read cards:read])
        expect(result.grant_scopes).to all(be_frozen)
        expect(result.authorization_valid_now?("mcp:atomspace:read", now: captured_at)).to be(true)
        expect(
          result.authorization_valid_now?("mcp:atomspace:read:widened", now: captured_at)
        ).to be(false)
        expect { result.grant_scopes.first << "tampered" }.to raise_error(FrozenError)
      end

      it "freezes each scope it split out of a space-delimited scope claim, not just the " \
         "array holding them" do
        token = sign(base_payload.merge("scope" => "mcp:atomspace:read cards:read"))
        stub_auth_success(token, expires_in: 3600)
        stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

        result = auth.read_grant(required_scope: "mcp:atomspace:read", now: Time.now)

        expect(result.grant_scopes).to eq(%w[mcp:atomspace:read cards:read])
        expect(result.grant_scopes).to be_frozen
        expect(result.grant_scopes).to all(be_frozen)
      end
    end
  end

  describe "Auth::GrantReadResult" do
    describe ".not_applicable" do
      it "reports the full not-applicable field vector for a grant read that never " \
         "consulted Deck -- no scopes, no captured credential, no deadlines, and " \
         "authorization_valid_now? always false" do
        read_at = Time.now
        result = described_class::GrantReadResult.not_applicable(grant_read_at: read_at)

        expect(result).to be_a(described_class::GrantReadResult)
        expect(result.verification_status).to eq(:not_applicable)
        expect(result.verification_error_class).to be_nil
        expect(result.grant_scopes).to eq([])
        expect(result.token_version).to be_nil
        expect(result.credential_ref).to be_nil
        expect(result.signed_exp_status).to be_nil
        expect(result.signed_exp_value).to be_nil
        expect(result.token_refresh_deadline).to be_nil
        expect(result.token_hard_expiry).to be_nil
        expect(result.grant_read_at).to eq(read_at)
        expect(result.authorization_valid_until).to be_nil
        expect(result.authorization_bound_kind).to be_nil

        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: read_at)
        ).to be(false)
      end
    end

    describe "#authorization_valid_now? against an unusable deadline" do
      it "denies authorization whenever authorization_valid_until is nil because the " \
         "signed exp claim itself was :unusable, even though the cache deadline remains " \
         "live and verification_status is :verified -- distinct from the expired-signed-exp " \
         "example above, which denies because verification FAILED, and distinct from the " \
         "cache-only / :absent case, which DOES fall back to the live cache deadline rather " \
         "than denying" do
        read_at = Time.now
        live_cache_expiry = read_at + 200
        result = described_class::GrantReadResult.new(
          verification_status: :verified,
          verification_error_class: nil,
          grant_scopes: %w[mcp:atomspace:read],
          token_version: "tv-unusable-deadline",
          credential_ref: "cred-unusable-deadline",
          signed_exp_status: :unusable,
          signed_exp_value: nil,
          token_refresh_deadline: read_at + 100,
          token_hard_expiry: live_cache_expiry,
          grant_read_at: read_at,
          authorization_valid_until: nil,
          authorization_bound_kind: nil
        )

        expect(result.signed_exp_status).to eq(:unusable)
        expect(result.authorization_valid_until).to be_nil
        expect(result.authorization_bound_kind).to be_nil

        # The cache deadline is still in the future at both moments checked
        # below. If :unusable silently fell back to the cache deadline the
        # way :cache_only does, the first assertion below would incorrectly
        # report true.
        expect(live_cache_expiry).to be > read_at

        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: read_at)
        ).to be(false)
        expect(
          result.authorization_valid_now?("mcp:atomspace:read", now: read_at + 1000)
        ).to be(false)
      end
    end
  end
end
