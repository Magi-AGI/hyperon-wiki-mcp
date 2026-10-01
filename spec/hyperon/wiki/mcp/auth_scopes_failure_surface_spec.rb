# frozen_string_literal: true

# S6 characterization spec -- the failure surface around Auth#scopes and the
# Registry helpers it is expected to feed, Registry.visible_for and
# Registry.gate!.
#
# This file RECORDS current behavior; it does not assert desired behavior and
# it must not drive a change to lib/. It is a sibling of auth_scopes_spec.rb,
# auth_verify_token_spec.rb and auth_trust_boundary_spec.rb, not a replacement
# for any of them, and it deliberately does not re-cover ground already
# recorded there (the happy-path array/string scope shapes, the two
# verification-failure-yields-[] cases, or the absent/uninterpretable-claim
# fail-closed cases already in auth_scopes_spec.rb; the eight-tool
# required_scope invariant and the plain visible_for/gate! membership checks
# already in registry_spec.rb).
#
# Framing corrected during CP037 review, and characterized here rather than
# asserted as a defect:
#   * Auth#scopes calls #token internally (auth.rb:339), and #token raises
#     Auth::AuthenticationError when the auth endpoint cannot provide one.
#     #scopes only rescues VerificationError and JWKSError, so an
#     AuthenticationError from that inner #token call propagates unwrapped.
#     This is an undecided policy surface for whatever future consumer calls
#     #scopes directly, not a defect being fixed here.
#   * The same narrow two-class rescue in #scopes sits downstream of
#     #verify_token, which itself lets ArgumentError (malformed base64url
#     modulus) and NoMethodError (absent modulus) escape unwrapped from
#     #jwk_to_public_key / #decode_base64url (already characterized for
#     #verify_token directly in auth_verify_token_spec.rb). Neither exception
#     class is VerificationError or JWKSError, so both propagate through
#     #scopes too.
#   * A verified Array claim passes through #scopes unvalidated -- non-string
#     elements are not filtered, deduplicated, or rejected. Registry.gate! and
#     Registry.visible_for both use Array#include?, a plain membership check
#     against the exact required_scope string. A mixed array that happens to
#     contain that exact string grants/exposes access because of the matching
#     element, not because "the whole array" is treated as valid; a mixed or
#     malformed array that does NOT contain it is hidden/denied by the same
#     membership check. Neither case is escalation on its own.
#   * Registry.gate!'s `req = tool.respond_to?(:required_scope) && tool.required_scope`
#     permits (returns, does not raise) whenever `required_scope` is nil,
#     false, or the method is absent altogether. This is recorded as a latent
#     fail-open hazard in an as-yet-unused helper path -- no current TOOLS
#     entry has a nil/absent required_scope (registry_spec.rb already covers
#     that invariant) -- not as an intended contract or a currently reachable
#     escalation.
#
# Sources under characterization:
#   lib/hyperon/wiki/mcp/auth.rb:338-351                          Auth#scopes
#   lib/hyperon/wiki/mcp/server/tools/atomspace/registry.rb:31-40 Registry.visible_for / .gate!

require "spec_helper"
require "webmock/rspec"
require "base64"
require "json"
require "jwt"
require "openssl"
require "hyperon/wiki/mcp/config"
require "hyperon/wiki/mcp/auth"
require_relative "../../../../lib/hyperon/wiki/mcp/server/tools/atomspace/registry"

# Client is a CLASS in the gem (not a module). spec_helper's `require
# "hyperon/wiki/mcp"` already loads the real Hyperon::Wiki::Mcp::Client, so
# this guard -- mirrored from registry_spec.rb -- is inert here and exists
# only so this file stays runnable standalone without redefining the real
# constant as the wrong kind (Codex Finding 6 in registry_spec.rb).
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

# Synthetic, in-memory key material. Generated once per process; never written
# to disk and never shared with any endpoint.
AUTH_SCOPES_FAILURE_SURFACE_SIGNING_KEY = OpenSSL::PKey::RSA.generate(2048)

RSpec.describe "Auth#scopes failure surface" do
  let(:base_url) { "https://test.example.com/api/mcp" }
  let(:auth_url) { "https://test.example.com/api/mcp/auth" }
  let(:jwks_url) { "https://test.example.com/api/mcp/.well-known/jwks.json" }
  let(:expected_issuer) { "test-issuer" }
  let(:kid) { "spec-key-001" }
  let(:now) { Time.now.to_i }
  let(:signing_key) { AUTH_SCOPES_FAILURE_SURFACE_SIGNING_KEY }
  let(:registry) { Hyperon::Wiki::Mcp::Server::Tools::Atomspace::Registry }

  let(:config) do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["DECKO_API_BASE_URL"] = base_url
    ENV["MCP_ROLE"] = "user"
    ENV["JWT_ISSUER"] = expected_issuer
    Hyperon::Wiki::Mcp::Config.new
  end

  let(:auth) { Hyperon::Wiki::Mcp::Auth.new(config) }

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

  # NOTE: callers must brace the document hash, same caveat as the sibling
  # specs -- a brace-less `"keys" => [...]` argument parses as keyword
  # arguments under Ruby 3.
  def stub_jwks(document)
    stub_request(:get, jwks_url).to_return(
      status: 200,
      body: JSON.generate(document),
      headers: { "Content-Type" => "application/json" }
    )
  end

  def stub_auth_success(token)
    stub_request(:post, auth_url).to_return(
      status: 201,
      body: JSON.generate({ "token" => token, "role" => "user", "expires_in" => 3600 }),
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

  describe "propagation through the inner #token call" do
    it "propagates AuthenticationError when the auth endpoint cannot provide a token" do
      stub_auth_failure

      # An undecided policy surface for a future consumer, not a defect
      # asserted here: #scopes' rescue clause names only VerificationError and
      # JWKSError, so #token's AuthenticationError is not one of them.
      expect { auth.scopes }.to raise_error(Hyperon::Wiki::Mcp::Auth::AuthenticationError)
      expect(WebMock).not_to have_requested(:get, jwks_url)
    end
  end

  describe "propagation through #verify_token's narrow rescue" do
    it "propagates ArgumentError from a malformed JWK modulus" do
      token = JWT.encode(base_payload, signing_key, "RS256", { kid: kid })
      stub_auth_success(token)
      stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid).merge("n" => "!!!!")] })

      # decode_base64url delegates to Base64.strict_decode64; the resulting
      # ArgumentError is not a JWT::DecodeError, so verify_token does not wrap
      # it, and it is not one of #scopes' two rescued classes either.
      expect { auth.scopes }.to raise_error(ArgumentError, /invalid base64/)
      expect(WebMock).to have_requested(:get, jwks_url)
    end

    it "propagates NoMethodError from a JWK with no modulus at all" do
      token = JWT.encode(base_payload, signing_key, "RS256", { kid: kid })
      stub_auth_success(token)
      stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid).except("n")] })

      expect { auth.scopes }.to raise_error(NoMethodError, /undefined method/)
      expect(WebMock).to have_requested(:get, jwks_url)
    end
  end

  describe "unvalidated array claim shapes, composed with Registry" do
    it "returns a mixed array unchanged, and Registry.gate! permits only because the " \
       "matching signed scope string is present" do
      mixed_scopes = ["mcp:atomspace:read", { "bad" => "shape" }, 1, nil]
      token = JWT.encode(base_payload.merge("scope" => mixed_scopes), signing_key, "RS256", { kid: kid })
      stub_auth_success(token)
      stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

      scopes = auth.scopes

      expect(scopes).to eq(mixed_scopes)
      # Membership, not shape validation: the non-string elements are inert
      # passengers, and it is the exact matching string that grants here.
      expect { registry.gate!(registry::TOOLS.first, scopes) }.not_to raise_error
    end

    it "returns a pure malformed array unchanged, and current registry membership checks " \
       "hide/deny it for AtomSpace tools" do
      malformed_scopes = [{ "bad" => "shape" }, 1, nil]
      token = JWT.encode(base_payload.merge("scope" => malformed_scopes), signing_key, "RS256", { kid: kid })
      stub_auth_success(token)
      stub_jwks({ "keys" => [jwk_for(signing_key, key_id: kid)] })

      scopes = auth.scopes

      expect(scopes).to eq(malformed_scopes)
      # Shape hygiene, not immediate escalation: none of these elements equal
      # the required_scope string, so both membership checks reject it.
      expect(registry.visible_for(scopes)).to be_empty
      expect { registry.gate!(registry::TOOLS.first, scopes) }
        .to raise_error(Hyperon::Wiki::Mcp::Client::AuthorizationError)
    end
  end

  describe "Registry.gate! fail-open hazard for nil/absent required_scope" do
    it "permit-returns for a synthetic tool whose required_scope is nil" do
      nil_scope_tool = Class.new do
        def self.required_scope
          nil
        end
      end

      # Latent fail-open hazard, not an intended contract: `req && ...` short-
      # circuits false, so gate! returns without raising regardless of scopes.
      expect { registry.gate!(nil_scope_tool, []) }.not_to raise_error
      expect { registry.gate!(nil_scope_tool, %w[anything]) }.not_to raise_error
    end

    it "permit-returns for a synthetic tool with no required_scope method at all" do
      no_scope_method_tool = Class.new

      # `tool.respond_to?(:required_scope)` is false, so `req` is false and the
      # same short-circuit applies. Not added to Registry::TOOLS.
      expect { registry.gate!(no_scope_method_tool, []) }.not_to raise_error
    end
  end

  describe "minimal Registry check for [] (approved overlap with registry_spec.rb)" do
    it "hides everything via visible_for([]) and gate! raises for the actual [] result shape" do
      # Records Registry's own behavior for the empty-array shape that
      # Auth#scopes can return, not a production Auth-to-Registry composition
      # path; this overlaps registry_spec.rb by design and is not a
      # replacement for it.
      expect(registry.visible_for([])).to eq([])
      expect { registry.gate!(registry::TOOLS.first, []) }
        .to raise_error(Hyperon::Wiki::Mcp::Client::AuthorizationError)
    end
  end
end
