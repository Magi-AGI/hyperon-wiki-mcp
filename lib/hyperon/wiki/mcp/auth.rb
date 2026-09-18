# frozen_string_literal: true

require "jwt"
require "http"
require "json"
require "time"
require "base64"
require "openssl"

module Hyperon
  module Wiki
    module Mcp
      # JWT authentication and token management for Hyperon Wiki MCP
      #
      # Handles:
      # - Token acquisition from the auth endpoint
      # - JWKS fetching and caching
      # - Token verification using RS256 public keys
      # - Automatic token refresh before expiry
      #
      # @example Basic usage
      #   config = Hyperon::Wiki::Mcp::Config.new
      #   auth = Hyperon::Wiki::Mcp::Auth.new(config)
      #   token = auth.token # Automatically fetches and caches token
      #   auth.verify_token(token) # Verifies token signature and claims
      class Auth
        # Authentication error raised when token operations fail
        class AuthenticationError < StandardError; end

        # Token verification error
        class VerificationError < StandardError; end

        # JWKS fetch error
        class JWKSError < StandardError; end

        # Refresh buffer: refresh token this many seconds before expiry
        REFRESH_BUFFER_SECONDS = 300

        attr_reader :config, :username, :resolved_role

        # Initialize auth handler with configuration
        #
        # @param config [Config] the configuration object
        def initialize(config)
          @config = config
          @token = nil
          @token_expires_at = nil
          @username = nil
          @resolved_role = nil
          @jwks_cache = nil
          @jwks_cached_at = nil
        end

        # Get current valid token, fetching new one if needed
        #
        # @return [String] the JWT token
        # @raise [AuthenticationError] if token fetch fails
        def token
          return @token if token_valid?

          fetch_token
          @token
        end

        # Check if current token is still valid
        #
        # @return [Boolean] true if token exists and not expired
        def token_valid?
          return false if @token.nil? || @token_expires_at.nil?

          Time.now < (@token_expires_at - REFRESH_BUFFER_SECONDS)
        end

        # Fetch JWKS from the server
        #
        # @param force [Boolean] force refresh even if cache is valid
        # @return [Array<Hash>] array of JWK public keys
        # @raise [JWKSError] if JWKS fetch fails
        def fetch_jwks(force: false)
          return @jwks_cache if jwks_cache_valid? && !force

          url = config.url_for("/.well-known/jwks.json")

          response = HTTP.get(url, ssl_context: ssl_context)

          unless response.status.success?
            raise JWKSError,
                  "JWKS fetch failed: HTTP #{response.code}"
          end

          data = JSON.parse(response.body.to_s)
          @jwks_cache = data["keys"]
          @jwks_cached_at = Time.now

          @jwks_cache
        rescue HTTP::Error => e
          raise JWKSError, "JWKS fetch failed: #{e.message}"
        rescue JSON::ParserError => e
          raise JWKSError, "JWKS parse failed: #{e.message}"
        end

        # Verify a JWT token
        #
        # @param token [String] the JWT token to verify
        # @return [Hash] the decoded token payload
        # @raise [VerificationError] if verification fails
        def verify_token(token)
          # Decode header to get kid (key ID)
          header = JWT.decode(token, nil, false)[1]
          kid = header["kid"]

          raise VerificationError, "Token missing kid claim" unless kid

          # Find matching public key in JWKS
          jwks = fetch_jwks
          jwk = jwks.find { |k| k["kid"] == kid }

          raise VerificationError, "No matching key found for kid: #{kid}" unless jwk

          # Convert JWK to public key
          public_key = jwk_to_public_key(jwk)

          # Verify token
          payload, = JWT.decode(
            token,
            public_key,
            true,
            {
              algorithm: "RS256",
              iss: config.issuer,
              verify_iss: true,
              verify_iat: true,
              verify_exp: true
            }
          )

          payload
        rescue JWT::DecodeError => e
          raise VerificationError, "Token verification failed: #{e.message}"
        end

        # Scopes carried by the current token, read from a VERIFIED payload.
        #
        # A scope is an authorization input, so it is deliberately NOT read from
        # the auth response body and never from an unverified decode -- either
        # would let a caller self-assert a grant. The claim is decided and signed
        # deck-side (POLICY REV4); this only reads what the signature covers.
        #
        # Stateless: it verifies on demand rather than caching at fetch time, so
        # there is no @scopes ivar for #clear_cache! or #refresh_token! to reason
        # about. That only rules out staleness from an internal cache -- it does
        # not guarantee the scopes returned here still match whatever token a
        # caller sends outbound afterward; #refresh_token! or a concurrent caller
        # can still rotate the token between this call and that later use.
        #
        # Both the array shape and the space-delimited string shape the deck emits
        # are recognized. Anything that is neither an array nor a string yields no
        # scopes rather than a guess, and a token that fails verification also
        # yields no scopes rather than propagating the error -- both fail closed.
        #
        # @return [Array] scopes from the verified token, or [] when the claim is
        #   absent, is neither an array nor a string, or the token fails
        #   verification
        def scopes
          claim = verify_token(token)["scope"]

          case claim
          when Array
            claim
          when String
            claim.split
          else
            []
          end
        rescue VerificationError, JWKSError
          []
        end

        # Force token refresh
        #
        # @return [String] the new token
        def refresh_token!
          @token = nil
          @token_expires_at = nil
          token
        end

        # Clear all cached data
        def clear_cache!
          @token = nil
          @token_expires_at = nil
          @username = nil
          @resolved_role = nil
          @jwks_cache = nil
          @jwks_cached_at = nil
        end

        private

        # Check if JWKS cache is still valid
        def jwks_cache_valid?
          return false if @jwks_cache.nil? || @jwks_cached_at.nil?

          Time.now < (@jwks_cached_at + config.jwks_cache_ttl)
        end

        # Fetch new token from auth endpoint
        # rubocop:disable Metrics/AbcSize
        def fetch_token
          url = config.url_for("/auth")
          payload = config.auth_payload

          response = HTTP.post(
            url,
            json: payload,
            headers: { "Content-Type" => "application/json" },
            ssl_context: ssl_context
          )

          unless response.status.success?
            error_msg = parse_error_response(response)
            raise AuthenticationError,
                  "Token fetch failed (HTTP #{response.code}): #{error_msg}"
          end

          data = JSON.parse(response.body.to_s)

          @token = data["token"]
          @username = data["username"] # Store Decko username from auth response
          @resolved_role = data["role"] # Store role as determined by Decko
          expires_in = data["expires_in"] || 3600
          @token_expires_at = Time.now + expires_in

          @token
        rescue HTTP::Error => e
          raise AuthenticationError, "Token fetch failed: #{e.message}"
        rescue JSON::ParserError => e
          raise AuthenticationError, "Token response parse failed: #{e.message}"
        end
        # rubocop:enable Metrics/AbcSize

        # Parse error response from API
        def parse_error_response(response)
          data = JSON.parse(response.body.to_s)
          data["error"] || data["message"] || "Unknown error"
        rescue JSON::ParserError
          response.body.to_s
        end

        # Convert JWK hash to OpenSSL public key
        #
        # Builds a PKCS#1 RSAPublicKey DER from the JWK's modulus and exponent and
        # lets OpenSSL parse it. The previous construction -- allocate an empty
        # OpenSSL::PKey::RSA and populate it with #set_key -- raises on OpenSSL 3.x
        # ("rsa#set_key= is incompatible with OpenSSL 3.0"), where pkeys are
        # immutable after allocation, so no token could reach signature
        # verification at all. Parsing a DER is the supported route and works on
        # both OpenSSL 1.1 and 3.x.
        def jwk_to_public_key(jwk)
          # Extract modulus (n) and exponent (e) from JWK
          n = decode_base64url(jwk["n"])
          e = decode_base64url(jwk["e"])

          der = OpenSSL::ASN1::Sequence.new(
            [
              OpenSSL::ASN1::Integer.new(OpenSSL::BN.new(n, 2)),
              OpenSSL::ASN1::Integer.new(OpenSSL::BN.new(e, 2))
            ]
          ).to_der

          OpenSSL::PKey::RSA.new(der)
        end

        # Decode base64url-encoded string to binary
        def decode_base64url(str)
          # Add padding if needed
          str += "=" * (4 - (str.length % 4)) unless (str.length % 4).zero?

          # Replace URL-safe characters
          str = str.tr("-_", "+/")

          # Decode
          Base64.strict_decode64(str)
        end

        # Build SSL context for HTTP requests (nil = default verification)
        def ssl_context
          return nil unless config.ssl_verify_mode == :none

          require "openssl"
          ctx = OpenSSL::SSL::SSLContext.new
          ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
          ctx
        end
      end
    end
  end
end
