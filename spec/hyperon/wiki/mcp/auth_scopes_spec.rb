# frozen_string_literal: true

# S5 GREEN -- characterizes current behavior now that Auth#scopes exists.
#
# Like auth_verify_token_spec.rb and auth_trust_boundary_spec.rb, this file now
# RECORDS what Auth does today. It drove the change to lib/ during RED, and now
# documents the resulting Auth#scopes behavior.
#
# Tracer bullet: Auth#scopes returns the scope claim of a VERIFIED token.
#
# "Verified" is the point of this first example, and it is why the JWKS endpoint
# is stubbed and the real #verify_token -> #fetch_jwks -> #jwk_to_public_key path
# is allowed to run, rather than decoding the token here or stubbing
# #verify_token. A scope is an AUTHORIZATION input: reading one out of a token
# whose signature was never checked would let a caller self-assert any grant, and
# would invert the deck-side POLICY REV4 design in which grants are decided
# upstream and signed. An implementation that satisfied a weaker assertion by
# unverified decoding would be wrong even while the assertion passed -- so the
# example also asserts that the JWKS document was actually fetched.
#
# Scope-shape coverage here is TWO cases: the array form and the space-delimited
# string that McpApi::JwtService also emits, plus two verification-failure cases
# -- an unverifiable token (bad signature) and an unfetchable JWKS document --
# plus coverage of the fail-closed `else []` branch for absent claims and
# uninterpretable claim values (scalar and structured). All of these are
# intended to fail closed to [].
#
# NOTE from the GREEN step: auth_trust_boundary_spec.rb:231-267 previously
# asserted that Auth exposes no scope reader and holds no scope state. Those
# characterizations became false once Auth#scopes landed, and were revised
# deliberately at that point (see "holds no scope state, though the token it
# stored carries a scope claim" in that file) -- not silently, and not by
# pre-emptively editing them from here.

require "spec_helper"
require "webmock/rspec"
require "base64"
require "json"
require "jwt"
require "openssl"
require "hyperon/wiki/mcp/config"
require "hyperon/wiki/mcp/auth"

# Synthetic, in-memory key material. Generated once per process; never written to
# disk and never shared with any endpoint.
AUTH_SCOPES_SIGNING_KEY = OpenSSL::PKey::RSA.generate(2048)

RSpec.describe Hyperon::Wiki::Mcp::Auth do
  let(:base_url) { "https://test.example.com/api/mcp" }
  let(:auth_url) { "https://test.example.com/api/mcp/auth" }
  let(:jwks_url) { "https://test.example.com/api/mcp/.well-known/jwks.json" }
  let(:expected_issuer) { "test-issuer" }
  let(:kid) { "spec-key-001" }
  let(:now) { Time.now.to_i }

  # Shaped like a REV4 grant: the AtomSpace read scope alongside an ordinary one,
  # so a naive "first element" implementation would not pass.
  let(:granted_scopes) { %w[mcp:atomspace:read cards:read] }

  # spec_helper deletes these before each example, so Config is built lazily here
  # rather than in a before hook.
  let(:config) do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["DECKO_API_BASE_URL"] = base_url
    ENV["MCP_ROLE"] = "user"
    ENV["JWT_ISSUER"] = expected_issuer
    Hyperon::Wiki::Mcp::Config.new
  end

  let(:auth) { described_class.new(config) }

  let(:payload) do
    {
      "sub" => "user:Alice",
      "role" => "user",
      "scope" => granted_scopes,
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

  # NOTE: callers must brace the document hash. A brace-less `"keys" => [...]`
  # argument is parsed as keyword arguments under Ruby 3.
  def stub_jwks(document)
    stub_request(:get, jwks_url).to_return(
      status: 200,
      body: JSON.generate(document),
      headers: { "Content-Type" => "application/json" }
    )
  end

  def stub_auth(token)
    stub_request(:post, auth_url).to_return(
      status: 201,
      body: JSON.generate({ "token" => token, "role" => "user", "expires_in" => 3600 }),
      headers: { "Content-Type" => "application/json" }
    )
  end

  describe "#scopes" do
    it "returns an array-shaped scope claim from a verified token" do
      token = JWT.encode(payload, AUTH_SCOPES_SIGNING_KEY, "RS256", { kid: kid })
      stub_auth(token)
      stub_jwks({ "keys" => [jwk_for(AUTH_SCOPES_SIGNING_KEY, key_id: kid)] })

      expect(auth.scopes).to eq(granted_scopes)

      # The scopes must come from a token that was actually verified. Without this
      # second expectation, an implementation that decoded the stored token
      # unverified would satisfy the first one.
      expect(WebMock).to have_requested(:get, jwks_url)
    end

    it "normalizes a space-delimited scope string from a verified token to an array of strings" do
      string_scope_payload = payload.merge("scope" => "mcp:atomspace:read cards:read", "jti" => "spec-jti-0002")
      token = JWT.encode(string_scope_payload, AUTH_SCOPES_SIGNING_KEY, "RS256", { kid: kid })
      stub_auth(token)
      stub_jwks({ "keys" => [jwk_for(AUTH_SCOPES_SIGNING_KEY, key_id: kid)] })

      expect(auth.scopes).to eq(%w[mcp:atomspace:read cards:read])

      # Same rationale as the array-shaped example above: the normalization must
      # operate on a verified claim, not a decoded-in-place string.
      expect(WebMock).to have_requested(:get, jwks_url)
    end

    it "returns [] when the stored token is unverifiable" do
      wrong_signing_key = OpenSSL::PKey::RSA.generate(2048)
      token = JWT.encode(payload, wrong_signing_key, "RS256", { kid: kid })
      stub_auth(token)
      # JWKS advertises the expected key under the token's kid, so verification
      # selects it and rejects the mismatched signature -- this proves the token
      # is unverifiable, not merely unfetched.
      stub_jwks({ "keys" => [jwk_for(AUTH_SCOPES_SIGNING_KEY, key_id: kid)] })

      expect(auth.scopes).to eq([])

      # The rejection must come from actual verification, not an unverified
      # decode path that never consulted JWKS.
      expect(WebMock).to have_requested(:get, jwks_url)
    end

    it "returns [] when JWKS cannot be fetched, because the token cannot be verified" do
      token = JWT.encode(payload, AUTH_SCOPES_SIGNING_KEY, "RS256", { kid: kid })
      stub_auth(token)
      stub_request(:get, jwks_url).to_return(
        status: 503,
        body: JSON.generate({ "error" => "jwks unavailable" }),
        headers: { "Content-Type" => "application/json" }
      )

      expect(auth.scopes).to eq([])

      # Fail-closed must follow an actual verification attempt, not skip it.
      expect(WebMock).to have_requested(:get, jwks_url)
    end

    it "returns [] when a verified token has no scope claim" do
      no_scope_payload = payload.except("scope")
      token = JWT.encode(no_scope_payload, AUTH_SCOPES_SIGNING_KEY, "RS256", { kid: kid })
      stub_auth(token)
      stub_jwks({ "keys" => [jwk_for(AUTH_SCOPES_SIGNING_KEY, key_id: kid)] })

      expect(auth.scopes).to eq([])

      # The absent-claim result must come from a verified token, not a skipped
      # verification path.
      expect(WebMock).to have_requested(:get, jwks_url)
    end

    it "returns [] when a verified token has an uninterpretable scalar scope claim" do
      scalar_scope_payload = payload.merge("scope" => 42, "jti" => "spec-jti-0003")
      token = JWT.encode(scalar_scope_payload, AUTH_SCOPES_SIGNING_KEY, "RS256", { kid: kid })
      stub_auth(token)
      stub_jwks({ "keys" => [jwk_for(AUTH_SCOPES_SIGNING_KEY, key_id: kid)] })

      expect(auth.scopes).to eq([])

      # Same rationale: fail-closed on an uninterpretable claim must still be
      # verification-gated.
      expect(WebMock).to have_requested(:get, jwks_url)
    end

    it "returns [] when a verified token has an uninterpretable structured scope claim" do
      structured_scope_payload = payload.merge(
        "scope" => { "mcp" => "atomspace:read" },
        "jti" => "spec-jti-0004"
      )
      token = JWT.encode(structured_scope_payload, AUTH_SCOPES_SIGNING_KEY, "RS256", { kid: kid })
      stub_auth(token)
      stub_jwks({ "keys" => [jwk_for(AUTH_SCOPES_SIGNING_KEY, key_id: kid)] })

      expect(auth.scopes).to eq([])

      # Same rationale: fail-closed on an uninterpretable structured claim must
      # still be verification-gated.
      expect(WebMock).to have_requested(:get, jwks_url)
    end
  end
end
