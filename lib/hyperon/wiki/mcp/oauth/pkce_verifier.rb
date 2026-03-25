# frozen_string_literal: true

require "digest"
require "base64"
require "openssl"

module Hyperon
  module Wiki
    module Mcp
      module OAuth
        # PKCE (Proof Key for Code Exchange) verification for OAuth 2.1
        #
        # Implements S256 code challenge method as required by the MCP Authorization spec.
        # Uses constant-time comparison to prevent timing attacks.
        module PkceVerifier
          module_function

          # Verify a PKCE code_verifier against a stored code_challenge
          #
          # @param code_verifier [String] the plain-text verifier from the token request
          # @param code_challenge [String] the challenge stored during authorization
          # @param method [String] challenge method (only "S256" supported)
          # @return [Boolean] true if verification passes
          def verify(code_verifier:, code_challenge:, method: "S256")
            return false unless method == "S256"
            return false if code_verifier.nil? || code_verifier.empty?
            return false if code_challenge.nil? || code_challenge.empty?

            expected = generate_challenge(code_verifier)
            constant_time_compare(expected, code_challenge)
          end

          # Generate an S256 code_challenge from a code_verifier
          #
          # @param code_verifier [String] the plain-text verifier
          # @return [String] Base64url-encoded SHA-256 hash (no padding)
          def generate_challenge(code_verifier)
            digest = Digest::SHA256.digest(code_verifier)
            Base64.urlsafe_encode64(digest, padding: false)
          end

          # Constant-time string comparison to prevent timing attacks
          #
          # @param str_a [String] first string
          # @param str_b [String] second string
          # @return [Boolean] true if strings are equal
          def constant_time_compare(str_a, str_b)
            return false if str_a.bytesize != str_b.bytesize

            OpenSSL.fixed_length_secure_compare(str_a, str_b)
          rescue StandardError
            false
          end
        end
      end
    end
  end
end
