# frozen_string_literal: true

require "jwt"
require "http"
require "json"
require "time"
require "base64"
require "openssl"
require_relative "http_timeouts"

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
      #
      # ClassLength is disabled for this class alone. Most of the excess is
      # the two captured value objects it defines -- CredentialRef and
      # GrantReadResult -- and the comments that justify their fail-closed
      # rules. Moving them out would mean new files and new constant paths
      # for interfaces this slice only just corrected; that extraction
      # belongs to its own change, not to a review-blocker fix.
      # rubocop:disable Metrics/ClassLength
      class Auth
        # Authentication error raised when token operations fail
        class AuthenticationError < StandardError; end

        # Token verification error
        class VerificationError < StandardError; end

        # JWKS fetch error
        class JWKSError < StandardError; end

        # Refresh buffer: refresh token this many seconds before expiry
        REFRESH_BUFFER_SECONDS = 300

        # Per-operation timeouts for this class's outbound calls -- the JWKS
        # fetch and the token fetch.
        #
        # Not a second budget: this IS HttpTimeouts::OUTBOUND, the one policy
        # shared with Client, kept reachable under the name callers and specs
        # already use. Aliasing rather than redeclaring is the point -- two
        # literal copies of the same three numbers can drift, and the parity
        # between Auth and Client could then only be checked by scraping one
        # file's source from the other's spec. See HttpTimeouts for why the
        # bound exists at all (unbounded http.rb + RackApp::DISPATCH_LOCK =
        # one hung socket stalls every session) and why these values are not
        # tightened.
        HTTP_TIMEOUTS = HttpTimeouts::OUTBOUND

        # Captured-credential fields for a grant read that never got a token.
        NO_CAPTURED_CREDENTIAL = {
          token_version: nil, credential_ref: nil, token_hard_expiry: nil, token_refresh_deadline: nil
        }.freeze

        # An immutable handle onto the credential a single grant read captured.
        #
        # A gated outbound call binds to this handle rather than to Auth's
        # current token, so a later #refresh_token! cannot silently swap the
        # credential a caller already made an authorization decision about.
        #
        # #captured_token is credential-bearing internal access: it is
        # deliberately kept out of #inspect/#to_s and out of every ordinary
        # serialization surface, so the token cannot leak into diagnostics,
        # log lines, an enclosing object's inspect output, a YAML fixture, or
        # a Marshal'd cache entry. Never log it.
        class CredentialRef
          # Stand-in emitted wherever the captured credential would otherwise
          # be serialized.
          REDACTED = "[REDACTED]"

          attr_reader :captured_token

          # Non-reversible digest of the captured credential, safe for audit
          # and rotation-detection use. Computed eagerly: the handle is frozen,
          # so it cannot memoize later.
          #
          # Frozen in its own right, like the credential beside it: freezing
          # the handle leaves the digest STRING writable, and this is the
          # audit record of which credential a read saw. A record an audit or
          # rotation-detection consumer can rewrite in place is not a record.
          attr_reader :fingerprint

          def initialize(token)
            @captured_token = token.dup.freeze
            @fingerprint = OpenSSL::Digest::SHA256.hexdigest(@captured_token)[0, 16].freeze
            freeze
          end

          def ==(other)
            other.is_a?(CredentialRef) && other.captured_token == captured_token
          end
          alias eql? ==

          def hash
            [self.class, @captured_token].hash
          end

          def inspect
            "#<#{self.class} fingerprint=#{fingerprint}>"
          end
          alias to_s inspect

          # Serialization hooks. #inspect/#to_s keep the credential out of
          # diagnostics, but Psych, Marshal, and ActiveSupport-style #as_json
          # all read instance variables directly and would otherwise write
          # @captured_token verbatim into a YAML dump, a Marshal'd cache
          # entry, or a serialized log payload. Each surface is given the same
          # redacted view #inspect shows: the fingerprint identifies the
          # credential for audit and rotation-detection without carrying it.
          def encode_with(coder)
            coder.map = redacted_view
          end

          def as_json(*)
            redacted_view
          end

          def to_json(*)
            redacted_view.to_json(*)
          end

          def marshal_dump
            redacted_view
          end

          # Deliberately not revivable, on either surface. A handle is only
          # meaningful while it holds the credential it captured, so reviving
          # one from a redacted dump would hand a caller a handle that looks
          # bindable -- and that compares equal to another revival of the same
          # dump -- while carrying no credential at all. Fail loudly instead.
          def marshal_load(_dumped)
            raise TypeError, not_revivable
          end

          def init_with(_coder)
            raise TypeError, not_revivable
          end

          private

          def redacted_view
            { "fingerprint" => fingerprint, "captured_token" => REDACTED }
          end

          def not_revivable
            "#{self.class} cannot be deserialized: the captured credential is never serialized"
          end
        end

        # The per-read result table for Auth#read_grant: what a single grant
        # read saw, as a frozen snapshot rather than live authorization state.
        #
        # authorization_valid_until is the TIGHTER of the token's signed `exp`
        # and the auth response's cache deadline; authorization_bound_kind
        # labels which one is binding (:signed_exp, :cache, or :cache_only).
        # Both are nil whenever no deadline can be trusted -- verification
        # failed, or the signed exp was present but :unusable -- so that no
        # read ever falls back to a still-live cache deadline it cannot back
        # with a verified claim.
        GrantReadResult = Data.define(
          :verification_status, :verification_error_class, :grant_scopes, :token_version,
          :credential_ref, :signed_exp_status, :signed_exp_value, :token_refresh_deadline,
          :token_hard_expiry, :grant_read_at, :authorization_valid_until, :authorization_bound_kind
        ) do
          # A read that never consulted the deck at all: nothing was captured,
          # nothing verified, and nothing is authorized.
          def self.not_applicable(grant_read_at:)
            new(
              verification_status: :not_applicable, verification_error_class: nil,
              grant_scopes: [].freeze, token_version: nil, credential_ref: nil,
              signed_exp_status: nil, signed_exp_value: nil, token_refresh_deadline: nil,
              token_hard_expiry: nil, grant_read_at: grant_read_at,
              authorization_valid_until: nil, authorization_bound_kind: nil
            )
          end

          # Fail-closed: a grant authorizes a scope only when it verified, carries a
          # trustworthy deadline, is read strictly before that deadline, and was
          # actually granted the scope.
          def authorization_valid_now?(required_scope, now: Time.now)
            return false unless verification_status == :verified
            return false if authorization_valid_until.nil?
            return false unless now < authorization_valid_until

            Array(grant_scopes).include?(required_scope)
          end
        end

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
          # Guards the (@token, @token_expires_at) PAIR, not either half: a
          # credential and the deadline that belongs to it are published and
          # captured together, never observed half-rotated. See
          # #capture_credential.
          @credential_lock = Mutex.new
        end

        # Get current valid token, fetching new one if needed
        #
        # @return [String] the JWT token -- frozen, since it is the cached
        #   credential itself
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

          response = http_client.get(url, ssl_context: ssl_context)

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

        # Read the current grant as a single, self-consistent snapshot.
        #
        # Unlike #scopes, which answers one question and drops everything else,
        # this captures the whole result table for ONE credential: which token
        # was read, whether it verified, what it granted, and how long that
        # grant can be relied on. Every field describes that one capture, so a
        # caller that later acts on the result binds to the credential the read
        # verified (result.credential_ref) rather than to whatever token Auth
        # holds by then.
        #
        # Fail-closed in every failure mode: authentication failure, JWKS
        # outage, signature/claim rejection, and malformed JWK key material all
        # yield verification_status :verification_failed with no authorization
        # deadline, never a fallback to the (possibly still-live) cache
        # deadline. verification_error_class preserves the native error class
        # so a JWKS outage stays distinguishable from a rejected signature.
        #
        # @param required_scope [String] the scope this read is being performed
        #   for. Recorded by the caller's intent only: the capture itself is
        #   scope-agnostic, and the scope decision is applied by
        #   GrantReadResult#authorization_valid_now?.
        # @param now [Time] when the read is being made
        # @return [GrantReadResult] the frozen per-read result table
        # rubocop:disable Lint/UnusedMethodArgument
        def read_grant(required_scope:, now: Time.now)
          begin
            captured_token, cache_expiry = capture_credential
          rescue AuthenticationError => e
            return unverified_grant_result(NO_CAPTURED_CREDENTIAL, e.class, now)
          end

          # A concurrent #clear_cache! can empty the credential state between
          # the fetch and the capture. Nothing was captured, so nothing is
          # authorized -- the same fail-closed answer as a failed fetch.
          return unverified_grant_result(NO_CAPTURED_CREDENTIAL, AuthenticationError, now) if captured_token.nil?

          captured = captured_credential_fields(captured_token, cache_expiry)

          # Verify the EXACT bytes the handle captured, not the mutable token
          # string Auth is still holding: a caller acts on this result by
          # binding to result.credential_ref, so the credential that verified
          # and the credential that goes outbound must be the same object.
          begin
            payload = verify_token(captured[:credential_ref].captured_token)
          rescue StandardError => e
            return unverified_grant_result(captured, e.class, now)
          end

          verified_grant_result(captured, payload, now)
        end
        # rubocop:enable Lint/UnusedMethodArgument

        # Force token refresh
        #
        # @return [String] the new token
        def refresh_token!
          publish_credential(nil, nil)
          token
        end

        # Clear all cached data
        def clear_cache!
          publish_credential(nil, nil)
          @username = nil
          @resolved_role = nil
          @jwks_cache = nil
          @jwks_cached_at = nil
        end

        private

        # Capture the current credential together with ITS OWN deadline, in
        # one step that no refresh can interleave with.
        #
        # Reading the token and then reading @token_expires_at as a separate
        # step leaves a window: a #refresh_token! landing in between pairs the
        # already-captured token A with token B's later expiry, and the read
        # would then report -- and authorize against -- a deadline that
        # belongs to a credential it never captured. Under the lock the two
        # are always one credential's own pair, so a refresh is observed
        # whole (B with B's deadline) or not at all (A with A's).
        #
        # #token runs OUTSIDE the lock on purpose: it may fetch, and every
        # writer -- #fetch_token's successful publication included -- goes
        # through #publish_credential, which takes this same non-reentrant
        # lock. Calling #token while holding it would deadlock.
        def capture_credential
          token
          @credential_lock.synchronize { [@token, @token_expires_at] }
        end

        # Publish a credential and its deadline as one pair, so a concurrent
        # #capture_credential can never observe a new token beside the
        # previous token's deadline.
        def publish_credential(new_token, expires_at)
          @credential_lock.synchronize do
            @token = new_token
            @token_expires_at = expires_at
          end
        end

        # Captured-credential and cache-deadline fields for one grant read.
        # These come from the auth response and are independent of JWT
        # verification, so they stay populated even when verification fails.
        # Both arguments come from the SAME #capture_credential snapshot.
        def captured_credential_fields(captured_token, hard_expiry)
          credential = CredentialRef.new(captured_token)

          {
            token_version: credential.fingerprint,
            credential_ref: credential,
            token_hard_expiry: hard_expiry,
            token_refresh_deadline: hard_expiry && (hard_expiry - REFRESH_BUFFER_SECONDS)
          }
        end

        # A token was captured but could not be verified -- or, with
        # NO_CAPTURED_CREDENTIAL, authentication failed before any token was
        # captured at all. Either way the claims -- scopes and signed exp
        # alike -- are left nil rather than read from an untrusted payload.
        def unverified_grant_result(captured, error_class, now)
          GrantReadResult.new(
            verification_status: :verification_failed, verification_error_class: error_class,
            grant_scopes: nil, signed_exp_status: nil, signed_exp_value: nil,
            grant_read_at: now, authorization_valid_until: nil, authorization_bound_kind: nil,
            **captured
          )
        end

        def verified_grant_result(captured, payload, now)
          signed_exp_status, signed_exp_value = classify_signed_exp(payload["exp"])
          valid_until, bound_kind =
            bind_authorization(signed_exp_status, signed_exp_value, captured[:token_hard_expiry])

          GrantReadResult.new(
            verification_status: :verified, verification_error_class: nil,
            grant_scopes: normalize_scopes(payload["scope"]),
            signed_exp_status: signed_exp_status, signed_exp_value: signed_exp_value,
            grant_read_at: now, authorization_valid_until: valid_until,
            authorization_bound_kind: bound_kind, **captured
          )
        end

        # Classify the verified payload's exp claim. An exp that is present but
        # cannot be read as a deadline is :unusable rather than :absent: the
        # two are handled differently downstream, since only :absent may fall
        # back to the cache deadline.
        # A numeric exp is truncated for the same reason a string one is: the
        # locked verifier compares `context.payload['exp'].to_i <=
        # (Time.now.to_i - leeway)`, so a credential signed with exp T+0.9 is
        # already rejected at T. Binding to Time.at(T+0.9) would authorize a
        # fractional sliver of time the signature no longer covers -- the
        # Numeric twin of the String defect #coerce_string_exp documents.
        # Integer claims, the ordinary case, are unchanged by the truncation.
        def classify_signed_exp(claim)
          case claim
          when nil then [:absent, nil]
          when Numeric then [:present_numeric, Time.at(claim.to_i)]
          when String then coerce_string_exp(claim)
          else [:unusable, nil]
          end
        end

        # A string exp is bound with the SAME coercion the locked verifier
        # uses to reject an expired token -- String#to_i, per
        # JWT::Claims::Expiration#verify!: `context.payload['exp'].to_i <=
        # (Time.now.to_i - leeway)`. Reading it as a Float instead would take
        # "1700000000.9" as 1700000000.9 and place authorization_valid_until
        # after the cutoff the verifier actually enforced, authorizing a
        # sliver of time the signature never covered. Truncating to the same
        # integer keeps this read at or inside that cutoff, never past it.
        #
        # to_i alone cannot tell a deadline from junk -- it answers 0 for
        # "garbage" -- so a string with no leading integer is :unusable and
        # binds nothing. Such a token cannot reach here in any case: the
        # verifier reads that same 0 and rejects it as expired first.
        def coerce_string_exp(claim)
          return [:unusable, nil] unless /\A\s*[+-]?\d/.match?(claim)

          [:present_string_coercible, Time.at(claim.to_i)]
        end

        # Bind authorization to the tighter of the signed exp and the cache
        # deadline, labelling which one binds. An :unusable signed exp binds
        # nothing at all -- it must not silently degrade into a cache-only
        # grant the way an absent claim does.
        def bind_authorization(signed_exp_status, signed_exp_value, cache_expiry)
          case signed_exp_status
          when :unusable then [nil, nil]
          when :absent then cache_expiry ? [cache_expiry, :cache_only] : [nil, nil]
          else
            signed_exp_binds = cache_expiry.nil? || signed_exp_value <= cache_expiry
            signed_exp_binds ? [signed_exp_value, :signed_exp] : [cache_expiry, :cache]
          end
        end

        # Both the array shape and the space-delimited string shape the deck
        # emits are recognized; anything else yields no scopes rather than a
        # guess. Mirrors #scopes, frozen for the captured snapshot.
        #
        # Frozen ALL THE WAY DOWN, not just the array: freezing the array
        # alone leaves each scope string writable, and rewriting one in place
        # changes what #authorization_valid_now? answers for a grant that
        # already verified -- silently widening or revoking a decision the
        # signature covered. The split shape needs the same treatment: the
        # substrings String#split returns are fresh but unfrozen.
        def normalize_scopes(claim)
          case claim
          when Array then deep_frozen_copy(claim)
          when String then deep_frozen_copy(claim.split)
          else [].freeze
          end
        end

        # Copy-and-freeze a claim value as deeply as the captured snapshot
        # contract covers. The deck's claims are JSON, so String/Array/Hash
        # are the shapes that can be edited in place after the read; an
        # already-frozen string is reused rather than re-copied, and anything
        # else (Symbol, Numeric, nil, a credential handle) is left to its own
        # immutability rather than duped blindly.
        def deep_frozen_copy(value)
          case value
          when String then value.frozen? ? value : value.dup.freeze
          when Array then value.map { |element| deep_frozen_copy(element) }.freeze
          when Hash then value.to_h { |k, v| [deep_frozen_copy(k), deep_frozen_copy(v)] }.freeze
          else value
          end
        end

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

          response = http_client.post(
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

          # Held as locals and published as ONE pair. Assigning @token and
          # then, as a separate step, @token_expires_at leaves a writer-side
          # window: a second fetch completing in between publishes its whole
          # pair, and this fetch's trailing deadline assignment then lands on
          # top of it, leaving that fetch's token beside this fetch's
          # deadline. A cache-only grant reading that pair is authorized
          # until a deadline that was never its credential's own. The return
          # value comes from the local for the same reason.
          #
          # The token is published as an owned, frozen copy for the same
          # reason on the reader's side: #token hands callers this very
          # object, and one rewritten in place -- token A into token B --
          # would leave A's deadline cached beside B.
          fetched_token = data["token"].dup.freeze
          @username = data["username"] # Store Decko username from auth response
          @resolved_role = data["role"] # Store role as determined by Decko
          expires_in = data["expires_in"] || 3600

          publish_credential(fetched_token, Time.now + expires_in)

          fetched_token
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

        # Timeout-bounded HTTP client for this class's outbound calls.
        #
        # Delegates to the shared policy rather than applying its own, so Auth
        # cannot be left bounded differently from Client. See
        # HttpTimeouts.client for why it is built per call rather than
        # memoized, and why callers need no new rescue clause -- an expired
        # budget descends from HTTP::Error and so already surfaces as
        # JWKSError / AuthenticationError.
        def http_client
          HttpTimeouts.client
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end
