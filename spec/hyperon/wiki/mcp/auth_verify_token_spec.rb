# frozen_string_literal: true

# Offline characterization spec for Hyperon::Wiki::Mcp::Auth#verify_token.
#
# This file RECORDS current behavior; it does not assert desired behavior and it
# must not drive a change to lib/. Where the implementation accepts something
# surprising (see "ACCEPTS" notes below), the surprise is written down as-is.
#
# Source under characterization: lib/hyperon/wiki/mcp/auth.rb:107 (#verify_token)
# and its private collaborators #fetch_jwks, #jwk_to_public_key, #decode_base64url.
#
# Verification pipeline as implemented:
#   1. JWT.decode(token, nil, false)[1]  -> header, unverified
#   2. header["kid"] must be present     -> else VerificationError
#   3. fetch_jwks                        -> JWKSError propagates UNWRAPPED
#   4. jwks.find { kid match }           -> else VerificationError
#   5. jwk_to_public_key(jwk)            -> OpenSSL/Base64 errors propagate UNWRAPPED
#   6. JWT.decode(token, key, true, algorithm: "RS256", iss:, verify_iss:,
#                                        verify_iat:, verify_exp:)
#   Only JWT::DecodeError descendants are rescued and re-raised as
#   Auth::VerificationError with the prefix "Token verification failed: ".
#
# Locked gem: jwt (2.10.2). Two details of that version matter here and are
# reflected in the expectations below:
#   * JWT.decode merges JWT.configuration.decode defaults, which already set
#     verify_expiration: true and verify_not_before: true.
#   * JWT::Claims::DecodeVerifier only consults a fixed key set; the
#     `verify_exp: true` option passed by auth.rb is NOT one of them and is
#     silently ignored. Expiration is still checked, via the default
#     verify_expiration, so the ignored option is inert rather than unsafe.
#
# Token construction: JWT.encode cannot mint a token whose exp/iat/nbf is not
# Numeric -- JWT::Encode runs JWT::Claims.verify_payload!(payload, :numeric) and
# raises JWT::InvalidPayload first. Since the verifier's handling of such claims
# is precisely what is being characterized, those cases build the compact JWS by
# hand (see #rs256_token) and sign it for real with the synthetic RSA key. The
# method under test is never bypassed.
#
# Former OpenSSL blocker, resolved in S4. #jwk_to_public_key used to build the
# RSA key by allocating an empty OpenSSL::PKey::RSA and populating it with
# #set_key, which raises on OpenSSL 3.x -- on such a runtime NO token reached
# step 6 at all. It now builds a PKCS#1 RSAPublicKey DER and lets OpenSSL parse
# it, which works on both OpenSSL generations.
#
# Three pieces of machinery existed only to work around that blocker and have
# been removed, deliberately rather than by attrition:
#   * the AUTH_VERIFY_TOKEN_JWK_IMPORT_ERROR probe, which ran its OWN copy of the
#     old set_key construction instead of calling the method under test. A repair
#     could not change what the probe reported, so it would have kept selecting
#     the import-error branch.
#   * the two conditionals keyed on that probe. Their import-error expectations
#     would NOT have passed silently against a repaired method -- verify_token
#     returns a payload instead of raising, so `raise_error` fails. They were
#     unusable as a GREEN acceptance mechanism for the opposite reason: they fail
#     noisily until someone replaces them by hand. Replacing them explicitly was
#     therefore part of S4, not an afterthought, and a repair could never have
#     been accepted by letting a branch "flip" on its own.
#   * the context that bridged the import seam by stubbing #jwk_to_public_key.
#     Its signature, algorithm, issuer, expiry and scope recordings now run
#     through the real importer instead, so they assert the shipped pipeline
#     rather than a stand-in.
#
# Everything else in this file still RECORDS current behavior and must not drive
# a change to lib/.

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
AUTH_VERIFY_TOKEN_SIGNING_KEY = OpenSSL::PKey::RSA.generate(2048)
AUTH_VERIFY_TOKEN_OTHER_KEY = OpenSSL::PKey::RSA.generate(2048)

RSpec.describe Hyperon::Wiki::Mcp::Auth do
  let(:expected_issuer) { "test-issuer" }
  let(:base_url) { "https://test.example.com/api/mcp" }
  let(:jwks_url) { "https://test.example.com/api/mcp/.well-known/jwks.json" }
  let(:kid) { "spec-key-001" }
  let(:now) { Time.now.to_i }

  let(:config) do
    ENV["MCP_API_KEY"] = "test-api-key"
    ENV["DECKO_API_BASE_URL"] = base_url
    ENV["MCP_ROLE"] = "user"
    ENV["JWT_ISSUER"] = expected_issuer
    Hyperon::Wiki::Mcp::Config.new
  end

  let(:auth) { described_class.new(config) }

  let(:signing_key) { AUTH_VERIFY_TOKEN_SIGNING_KEY }
  let(:other_key) { AUTH_VERIFY_TOKEN_OTHER_KEY }

  let(:jwk) { jwk_for(signing_key, key_id: kid) }
  let(:jwks_document) { { "keys" => [jwk] } }

  let(:base_payload) do
    {
      "sub" => "spec-user",
      "role" => "user",
      "scope" => %w[cards:read cards:write],
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

  def signed_token(payload, key: signing_key, header_kid: kid, alg: "RS256")
    headers = header_kid.nil? ? {} : { kid: header_kid }
    JWT.encode(payload, key, alg, headers)
  end

  # Builds a compact RS256 JWS over exactly the header and payload given, without
  # routing through JWT.encode. JWT::Encode runs JWT::Claims.verify_payload!(payload,
  # :numeric), which raises JWT::InvalidPayload ("exp claim must be a Numeric value
  # but it is a String") at *construction* time. The malformed-claim examples below
  # characterize what Auth#verify_token does with such a token, so they must be able
  # to build one. The signature is real and is produced the same way
  # JWT::JWA::Rsa#sign produces it: sign the "header.payload" bytes with SHA256.
  def rs256_token(payload, key: signing_key, header_kid: kid)
    signing_input = [
      b64url(JSON.generate({ "alg" => "RS256", "kid" => header_kid })),
      b64url(JSON.generate(payload))
    ].join(".")
    [signing_input, b64url(key.sign(OpenSSL::Digest.new("SHA256"), signing_input))].join(".")
  end

  # Builds a token with a syntactically valid but empty signature segment,
  # without going through JWT.encode's signing path.
  def unsigned_token(header, payload)
    [b64url(JSON.generate(header)), b64url(JSON.generate(payload)), ""].join(".")
  end

  def error_raised_by
    yield
    nil
  rescue StandardError => e
    e
  end

  # NOTE: callers must brace the document hash. A brace-less `"keys" => [...]`
  # argument is parsed as keyword arguments under Ruby 3 and this signature rejects
  # it. JSON.generate is used rather than Hash#to_json so that serialization does
  # not depend on which json core extensions happen to be loaded.
  def stub_jwks(document, status: 200, body: nil)
    stub_request(:get, jwks_url).to_return(
      status: status,
      body: body || JSON.generate(document),
      headers: { "Content-Type" => "application/json" }
    )
  end

  describe "#verify_token" do
    context "with a token that never reaches JWKS lookup" do
      it "wraps a non-JWT string as VerificationError without contacting JWKS" do
        expect { auth.verify_token("not-a-jwt") }.to raise_error(
          described_class::VerificationError,
          "Token verification failed: Not enough or too many segments"
        )
        expect(WebMock).not_to have_requested(:get, jwks_url)
      end

      it "wraps a token whose segments are not base64url-encoded JSON" do
        expect { auth.verify_token("aaa.bbb.ccc") }.to raise_error(
          described_class::VerificationError,
          /Token verification failed:/
        )
        expect(WebMock).not_to have_requested(:get, jwks_url)
      end

      it "rejects a signed token whose header carries no kid, before any JWKS call" do
        token = signed_token(base_payload, header_kid: nil)

        expect { auth.verify_token(token) }.to raise_error(
          described_class::VerificationError,
          "Token missing kid claim"
        )
        expect(WebMock).not_to have_requested(:get, jwks_url)
      end
    end

    context "with JWKS retrieval and key selection" do
      let(:token) { signed_token(base_payload) }

      it "requests the JWKS document derived from the configured base URL" do
        stub_jwks({ "keys" => [] })

        expect { auth.verify_token(token) }.to raise_error(described_class::VerificationError)
        expect(WebMock).to have_requested(:get, jwks_url).once
      end

      it "lets a JWKS HTTP failure escape as JWKSError rather than VerificationError" do
        stub_jwks(nil, status: 500, body: "Internal Server Error")

        # JWKSError is not a JWT::DecodeError, so auth.rb's rescue does not wrap it.
        expect { auth.verify_token(token) }.to raise_error(
          described_class::JWKSError,
          "JWKS fetch failed: HTTP 500"
        )
      end

      it "lets an unparseable JWKS body escape as JWKSError rather than VerificationError" do
        stub_jwks(nil, status: 200, body: "not json at all")

        expect { auth.verify_token(token) }.to raise_error(
          described_class::JWKSError,
          /JWKS parse failed/
        )
      end

      it "wraps an HTTP::Error transport failure as JWKSError" do
        stub_request(:get, jwks_url).to_raise(HTTP::ConnectionError.new("socket closed"))

        expect { auth.fetch_jwks }.to raise_error(
          described_class::JWKSError,
          "JWKS fetch failed: socket closed"
        )
      end

      it "raises NoMethodError when the JWKS body has no keys member" do
        # ACCEPTS-BADLY: fetch_jwks stores data["keys"] unchecked, so a well-formed
        # JSON document without "keys" caches nil and verify_token calls find on it.
        stub_jwks({})

        expect { auth.verify_token(token) }.to raise_error(NoMethodError, /undefined method/)
      end

      it "reports a kid that is absent from the JWKS" do
        stub_jwks({ "keys" => [jwk_for(other_key, key_id: "some-other-kid")] })

        expect { auth.verify_token(token) }.to raise_error(
          described_class::VerificationError,
          "No matching key found for kid: #{kid}"
        )
      end

      it "selects the exact JWK whose kid matches before importing it" do
        matching_jwk = jwk
        stub_jwks({ "keys" => [jwk_for(other_key, key_id: "unused-kid"), matching_jwk] })

        expect(auth).to receive(:jwk_to_public_key)
          .with(hash_including(
                  "kid" => matching_jwk["kid"],
                  "n" => matching_jwk["n"],
                  "e" => matching_jwk["e"]
                ))
          .and_call_original

        expect(auth.verify_token(token)).to include("sub" => "spec-user")
      end

      it "reuses the cached JWKS across repeated verifications" do
        stub_jwks({ "keys" => [] })

        2.times do
          expect { auth.verify_token(token) }.to raise_error(described_class::VerificationError)
        end

        expect(WebMock).to have_requested(:get, jwks_url).once
      end

      it "refreshes cached JWKS when forced" do
        first_jwks = { "keys" => [jwk_for(other_key, key_id: "first-kid")] }
        second_jwks = { "keys" => [jwk] }

        stub_request(:get, jwks_url).to_return(
          {
            status: 200,
            body: JSON.generate(first_jwks),
            headers: { "Content-Type" => "application/json" }
          },
          {
            status: 200,
            body: JSON.generate(second_jwks),
            headers: { "Content-Type" => "application/json" }
          }
        )

        expect(auth.fetch_jwks).to eq(first_jwks["keys"])
        expect(auth.fetch_jwks(force: true)).to eq(second_jwks["keys"])
        expect(auth.instance_variable_get(:@jwks_cache)).to eq(second_jwks["keys"])
        expect(WebMock).to have_requested(:get, jwks_url).twice
      end
    end

    context "with JWK to RSA public key import" do
      let(:token) { signed_token(base_payload) }

      it "raises ArgumentError when the JWK modulus is not valid base64url" do
        # decode_base64url delegates to Base64.strict_decode64; the ArgumentError
        # is not a JWT::DecodeError, so it escapes verify_token unwrapped.
        stub_jwks({ "keys" => [jwk.merge("n" => "!!!!")] })

        expect { auth.verify_token(token) }.to raise_error(ArgumentError, /invalid base64/)
      end

      it "raises NoMethodError when the JWK has no modulus at all" do
        stub_jwks({ "keys" => [jwk.except("n")] })

        expect { auth.verify_token(token) }.to raise_error(NoMethodError, /undefined method/)
      end

      # Unconditional and unbridged: this calls the real #jwk_to_public_key. It was
      # the S4 RED example and failed before the DER repair with a raw
      # OpenSSL::PKey::PKeyError. It replaces the pair of probe-keyed branches that
      # previously stood here, which could not serve as the GREEN acceptance check:
      # the probe kept selecting the import-error branch, whose expectation then
      # failed against the repaired method until the branches were replaced by hand.
      it "imports a well-formed JWK through the real implementation and verifies the token" do
        stub_jwks(jwks_document)

        expect(auth.verify_token(token)).to include(
          "sub" => "spec-user",
          "role" => "user",
          "iss" => expected_issuer,
          "scope" => %w[cards:read cards:write]
        )
      end
    end

    # Claim and signature semantics of the real JWT.decode call at auth.rb:124.
    #
    # These examples used to stub #jwk_to_public_key with the public half of the
    # synthetic key, because the old set_key construction made step 5 impassable on
    # OpenSSL 3.x. The DER repair removed that need, so the stub is gone: every
    # example below now runs the real importer against the advertised JWK, which
    # means signature rejection, algorithm pinning, issuer mismatch and expiry are
    # recorded against the shipped pipeline end to end rather than against a
    # stand-in key.
    context "with the real JWK-to-RSA import" do
      before do
        stub_jwks(jwks_document)
      end

      describe "signature handling" do
        it "returns the payload for a correctly signed token" do
          payload = auth.verify_token(signed_token(base_payload))

          expect(payload).to include("sub" => "spec-user", "role" => "user")
        end

        it "returns only the payload, never the header" do
          payload = auth.verify_token(signed_token(base_payload))

          expect(payload).not_to have_key("kid")
          expect(payload).not_to have_key("alg")
        end

        it "rejects a token whose signature segment was replaced" do
          valid = signed_token(base_payload)
          foreign_signature = signed_token(base_payload, key: other_key).split(".").last
          tampered = [valid.split(".")[0], valid.split(".")[1], foreign_signature].join(".")

          expect { auth.verify_token(tampered) }.to raise_error(
            described_class::VerificationError,
            "Token verification failed: Signature verification failed"
          )
        end

        it "rejects a token signed with a key other than the advertised JWK" do
          token = signed_token(base_payload, key: other_key)

          expect { auth.verify_token(token) }.to raise_error(
            described_class::VerificationError,
            "Token verification failed: Signature verification failed"
          )
        end

        it "pins the algorithm to RS256 and rejects an HS256 token" do
          token = JWT.encode(base_payload, "shared-secret", "HS256", { kid: kid })

          expect { auth.verify_token(token) }.to raise_error(
            described_class::VerificationError,
            "Token verification failed: Expected a different algorithm"
          )
        end

        it "rejects an alg=none token before looking at the empty signature" do
          token = unsigned_token({ "alg" => "none", "kid" => kid }, base_payload)

          expect { auth.verify_token(token) }.to raise_error(
            described_class::VerificationError,
            "Token verification failed: Expected a different algorithm"
          )
        end
      end

      describe "issuer handling" do
        it "accepts an issuer matching the configured JWT_ISSUER" do
          payload = auth.verify_token(signed_token(base_payload))

          expect(payload["iss"]).to eq(expected_issuer)
        end

        it "rejects a mismatched issuer" do
          token = signed_token(base_payload.merge("iss" => "someone-else"))

          expect { auth.verify_token(token) }.to raise_error(
            described_class::VerificationError,
            /Token verification failed: Invalid issuer\. Expected \["#{expected_issuer}"\], received someone-else/
          )
        end

        it "rejects a token with no iss claim" do
          token = signed_token(base_payload.except("iss"))

          expect { auth.verify_token(token) }.to raise_error(
            described_class::VerificationError,
            /Token verification failed: Invalid issuer\..*received <none>/
          )
        end
      end

      describe "exp handling" do
        it "accepts an exp in the future" do
          payload = auth.verify_token(signed_token(base_payload.merge("exp" => now + 3600)))

          expect(payload["exp"]).to eq(now + 3600)
        end

        it "rejects an exp in the past" do
          token = signed_token(base_payload.merge("exp" => now - 1))

          expect { auth.verify_token(token) }.to raise_error(
            described_class::VerificationError,
            "Token verification failed: Signature has expired"
          )
        end

        it "ACCEPTS a token with no exp claim at all" do
          # No required_claims are configured, and jwt only checks exp when the
          # claim is present: an unexpiring token verifies cleanly.
          token = signed_token(base_payload.except("exp"))

          expect(auth.verify_token(token)).not_to have_key("exp")
        end

        it "treats a non-numeric exp as already expired rather than malformed" do
          # jwt coerces with String#to_i on the verify side, so "whenever" becomes 0.
          # Built with rs256_token because JWT.encode refuses to mint this token.
          token = rs256_token(base_payload.merge("exp" => "whenever"))

          expect { auth.verify_token(token) }.to raise_error(
            described_class::VerificationError,
            "Token verification failed: Signature has expired"
          )
        end

        it "treats a null exp as already expired" do
          token = rs256_token(base_payload.merge("exp" => nil))

          expect { auth.verify_token(token) }.to raise_error(
            described_class::VerificationError,
            "Token verification failed: Signature has expired"
          )
        end

        it "ACCEPTS a string exp whose to_i lands in the future" do
          future = (now + 3600).to_s
          token = rs256_token(base_payload.merge("exp" => future))

          expect(auth.verify_token(token)["exp"]).to eq(future)
        end

        it "rejects a non-numeric iat, which auth.rb does verify" do
          token = rs256_token(base_payload.merge("iat" => "yesterday"))

          expect { auth.verify_token(token) }.to raise_error(
            described_class::VerificationError,
            "Token verification failed: Invalid iat"
          )
        end

        it "rejects an iat in the future" do
          token = signed_token(base_payload.merge("iat" => now + 3600))

          expect { auth.verify_token(token) }.to raise_error(
            described_class::VerificationError,
            "Token verification failed: Invalid iat"
          )
        end

        it "ACCEPTS a token with no iat claim" do
          token = signed_token(base_payload.except("iat"))

          expect(auth.verify_token(token)).not_to have_key("iat")
        end
      end

      describe "scope handling" do
        # verify_token never reads the scope claim; it is neither required,
        # type-checked, nor authorized against config.role. These examples record
        # that absence. Any scope enforcement lives outside this method.
        it "passes through an array-shaped scope claim verbatim" do
          payload = auth.verify_token(signed_token(base_payload))

          expect(payload["scope"]).to eq(%w[cards:read cards:write])
        end

        it "ACCEPTS a token with no scope claim" do
          token = signed_token(base_payload.except("scope"))

          expect(auth.verify_token(token)).not_to have_key("scope")
        end

        it "ACCEPTS a scope that is a space-delimited string" do
          token = signed_token(base_payload.merge("scope" => "cards:read cards:write"))

          expect(auth.verify_token(token)["scope"]).to eq("cards:read cards:write")
        end

        it "ACCEPTS a scope of an unexpected scalar type" do
          token = signed_token(base_payload.merge("scope" => 42))

          expect(auth.verify_token(token)["scope"]).to eq(42)
        end

        it "ACCEPTS a structurally unexpected scope" do
          token = signed_token(base_payload.merge("scope" => { "cards" => %w[read write] }))

          expect(auth.verify_token(token)["scope"]).to eq("cards" => %w[read write])
        end

        it "ACCEPTS a scope claiming privileges the configured role does not have" do
          # config.role is "user"; verify_token does not compare the two.
          token = signed_token(base_payload.merge("role" => "admin", "scope" => ["admin:*"]))
          payload = auth.verify_token(token)

          expect(payload["scope"]).to eq(["admin:*"])
          expect(config.role).to eq("user")
        end
      end
    end
  end
end
