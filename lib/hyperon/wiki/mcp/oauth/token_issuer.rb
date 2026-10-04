# frozen_string_literal: true

require "jwt"
require "openssl"
require "securerandom"

module Hyperon
  module Wiki
    module Mcp
      module OAuth
        # Issues and verifies self-signed JWT access tokens for OAuth 2.1 flow
        #
        # Generates an RSA key pair on boot (or loads from OAUTH_SIGNING_KEY env var)
        # and uses it to sign short-lived access tokens for authenticated users.
        #
        # Also derives an AES-256 encryption key from the RSA private key for
        # encrypting stored Decko passwords in OAuth client cards.
        class TokenIssuer
          class TokenError < StandardError; end

          DEFAULT_TTL = 3600 # 1 hour
          DEFAULT_ISSUER = "mcp.hyperon.dev"
          KEY_SIZE = 2048

          attr_reader :issuer, :ttl

          # Initialize with optional RSA key and configuration
          #
          # @param signing_key [OpenSSL::PKey::RSA, nil] RSA private key (generates new if nil)
          # @param issuer [String] JWT issuer claim
          # @param ttl [Integer] token time-to-live in seconds
          def initialize(signing_key: nil, issuer: nil, ttl: nil)
            @issuer = issuer || ENV.fetch("OAUTH_ISSUER_URL", DEFAULT_ISSUER)
            @ttl = ttl || ENV.fetch("OAUTH_TOKEN_TTL", DEFAULT_TTL).to_i
            @signing_key = signing_key || load_or_generate_key
            @kid = generate_kid
          end

          # Issue a new access token
          #
          # The `scope` claim is SIGNED rather than left to the OAuth token
          # response body (INTEGRATION.md step 1). A scope is an authorization
          # input, so a resource server must be able to read it from material the
          # signature covers; a scope that travelled only in the response body was
          # unverifiable, and the body and the credential could disagree about the
          # same grant.
          #
          # The scope is taken, not derived. Mapping role -> scope in here would
          # put an authorization decision behind a signing key, invisible to both
          # the deck (which owns grants, POLICY REV4) and to a reader of the
          # caller. The caller decides; this signs what it is given.
          #
          # @param sub [String] subject (username)
          # @param role [String] user role (user/gm/admin)
          # @param session_id [String] unique session identifier
          # @param scope [String, Array, nil] the scopes this credential is being
          #   granted. Normalized to the space-delimited string RFC 6749 puts on
          #   the wire -- the shape the deck emits too -- so a reader never has to
          #   handle two shapes for one claim. Omitted entirely when nothing
          #   usable is supplied; see #normalize_scope_claim.
          # @return [String] signed JWT token
          def issue(sub:, role:, session_id:, scope: nil)
            now = Time.now.to_i
            payload = {
              sub: sub,
              role: role,
              jti: session_id,
              iss: @issuer,
              iat: now,
              exp: now + @ttl
            }
            normalized = normalize_scope_claim(scope)
            payload[:scope] = normalized if normalized

            JWT.encode(payload, @signing_key, "RS256", { kid: @kid })
          end

          # Verify and decode an access token
          #
          # @param token [String] JWT token to verify
          # @return [Hash] decoded claims
          # @raise [TokenError] if verification fails
          def verify(token)
            payload, = JWT.decode(
              token,
              @signing_key.public_key,
              true,
              {
                algorithm: "RS256",
                iss: @issuer,
                verify_iss: true,
                verify_iat: true,
                verify_exp: true
              }
            )

            payload
          rescue JWT::DecodeError => e
            raise TokenError, "Token verification failed: #{e.message}"
          end

          # Derive AES-256 key from the RSA private key for password encryption
          #
          # Uses SHA-256 hash of the private key's DER representation to produce
          # a deterministic 32-byte key suitable for AES-256-GCM encryption.
          #
          # @return [String] 32-byte binary AES key
          def encryption_key
            @encryption_key ||= OpenSSL::Digest::SHA256.digest(@signing_key.to_der)
          end

          # Get the public key for external verification
          #
          # @return [OpenSSL::PKey::RSA] the public key
          def public_key
            @signing_key.public_key
          end

          private

          # The space-delimited scope claim to sign, or nil when nothing usable
          # was supplied.
          #
          # nil, NOT an empty string, for the unusable cases. An empty claim is an
          # assertion -- "this credential was granted nothing" -- while an omitted
          # one is the honest "no scope was decided for this token". Both fail
          # closed for a reader (Auth#scopes answers [] either way), but only
          # absence stays truthful about what the signer actually knew.
          #
          # Unusable is defined by what a membership check can act on rather than
          # by nil alone -- the same definition Registry.resolve_required_scope and
          # RequestContext#authorizes_scope? already use. A nil or non-String
          # element joined blindly would sign an empty scope between two
          # separators: a scope nobody granted, sitting inside a signature.
          def normalize_scope_claim(scope)
            entries = case scope
                      when String then scope.split
                      when Array then scope.select { |entry| entry.is_a?(String) && !entry.strip.empty? }
                      else return nil
                      end

            usable = entries.flat_map(&:split)
            usable.empty? ? nil : usable.join(" ")
          end

          # Load RSA key from env var or generate a new one
          def load_or_generate_key
            pem = ENV.fetch("OAUTH_SIGNING_KEY", nil)
            if pem && !pem.empty?
              OpenSSL::PKey::RSA.new(pem)
            else
              OpenSSL::PKey::RSA.generate(KEY_SIZE)
            end
          end

          # Generate a key ID from the public key for JWT header
          def generate_kid
            digest = OpenSSL::Digest::SHA256.hexdigest(@signing_key.public_key.to_der)
            digest[0..15]
          end
        end
      end
    end
  end
end
