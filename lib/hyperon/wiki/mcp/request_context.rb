# frozen_string_literal: true

module Hyperon
  module Wiki
    module Mcp
      # Who a single request is acting as, and what that identity is allowed to
      # carry outbound.
      #
      # Gem-level on purpose (decoupled from the Rack adapter), and a captured
      # value object rather than live authorization state: everything it holds
      # describes one request at one moment, and nothing a caller does
      # afterward can change what it reports.
      #
      # Two principal shapes exist, and they are kept strictly apart because
      # conflating them is how a local convenience default turns into an
      # unauthenticated remote grant:
      #
      #   :authenticated_session -- a session identity backed by a verified
      #     deck grant (:deck_verified_token), bound to the exact credential
      #     that grant read captured.
      #   :trusted_local -- a local caller trusted by deployment
      #     (:trusted_local_default). Its shape is exhaustive, not merely
      #     "anything but a verified grant": a grant read that never consulted
      #     the deck, no granted scopes, no inbound claims, and neither a
      #     captured nor an outbound credential.
      #
      # Every mismatch between those shapes raises ArgumentError at
      # construction: an invalid context must not exist at all, rather than
      # exist and be checked for validity later.
      #
      # Neither shape is itself an authorization decision. A verified grant
      # can still lack the scope a call needs, or be read past its deadline,
      # so consumers ask grant_read_result.authorization_valid_now? -- never
      # principal_kind or grant_source.
      class RequestContext
        PRINCIPAL_KINDS = %i[authenticated_session trusted_local].freeze

        # Each principal kind has exactly one legitimate grant source. Anything
        # else -- including an unrecognized source -- is rejected.
        GRANT_SOURCE_BY_PRINCIPAL = {
          authenticated_session: :deck_verified_token,
          trusted_local: :trusted_local_default
        }.freeze

        # The only grant results a trusted-local principal may present: reads
        # that never consulted the deck at all. Rejecting just :verified is
        # not enough -- a post-capture :verification_failed result still
        # carries the credential its read captured, so admitting one would let
        # a credential-bearing context in through the local-convenience door.
        TRUSTED_LOCAL_GRANT_STATUSES = %i[not_applicable trusted_local_default].freeze

        # The captured grant fields this context's own contract covers, used
        # when the supplied grant result is not already immutable.
        GrantSnapshot = Struct.new(:verification_status, :grant_scopes, :credential_ref, keyword_init: true)

        attr_reader :principal_kind, :session_id, :verified_inbound_claims, :grant_read_result,
                    :outbound_credential_ref, :grant_source, :local_trusted, :request_id

        # rubocop:disable Metrics/ParameterLists
        def initialize(principal_kind:, grant_read_result:, grant_source:, local_trusted:,
                       session_id: nil, verified_inbound_claims: nil,
                       outbound_credential_ref: nil, request_id: nil)
          @principal_kind = principal_kind
          @session_id = deep_frozen_copy(session_id)
          @verified_inbound_claims = deep_frozen_copy(verified_inbound_claims)
          @grant_read_result = snapshot_grant(grant_read_result)
          @outbound_credential_ref = deep_frozen_copy(outbound_credential_ref)
          @grant_source = grant_source
          @local_trusted = local_trusted
          @request_id = deep_frozen_copy(request_id)

          validate!
          freeze
        end
        # rubocop:enable Metrics/ParameterLists

        private

        # The context holds a snapshot, not a live reference: a caller that
        # mutates the grant result it passed in must not be able to change what
        # this context reports afterward. An already-immutable grant result is
        # kept whole, so a real Auth::GrantReadResult keeps its full result
        # table; anything else is copied field by field.
        def snapshot_grant(grant)
          return grant if immutable_grant?(grant)

          GrantSnapshot.new(
            verification_status: grant.verification_status,
            grant_scopes: deep_frozen_copy(grant.grant_scopes),
            credential_ref: deep_frozen_copy(grant.credential_ref)
          ).freeze
        end

        # A supplied result may be kept whole only if it is immutable all the
        # way down over the fields this contract covers. A frozen result whose
        # grant_scopes ARRAY is frozen still lets a caller rewrite an
        # individual scope string in place, which would change what the
        # context reports about an authorization decision already made.
        def immutable_grant?(grant)
          grant.frozen? && deeply_frozen?(grant.grant_scopes) && deeply_frozen?(grant.credential_ref)
        end

        # Anything not frozen in its own right fails here, so a value whose
        # immutability cannot be established is copied rather than kept --
        # the conservative direction for a captured snapshot.
        def deeply_frozen?(value)
          return false unless value.frozen?

          case value
          when Array then value.all? { |element| deeply_frozen?(element) }
          when Hash then deeply_frozen_pairs?(value)
          else true
          end
        end

        def deeply_frozen_pairs?(hash)
          hash.all? { |key, value| deeply_frozen?(key) && deeply_frozen?(value) }
        end

        # Copy-and-freeze a captured value as deeply as this contract covers.
        # Identity strings, claims, and credential references are JSON-shaped
        # or plain strings, so String/Array/Hash are the shapes a caller can
        # still edit in place after construction; an already-frozen string is
        # reused, and anything else (Symbol, Numeric, nil, a credential
        # handle) is left to its own immutability rather than duped blindly.
        def deep_frozen_copy(value)
          case value
          when String then value.frozen? ? value : value.dup.freeze
          when Array then value.map { |element| deep_frozen_copy(element) }.freeze
          when Hash then value.to_h { |k, v| [deep_frozen_copy(k), deep_frozen_copy(v)] }.freeze
          else value
          end
        end

        def validate!
          unless PRINCIPAL_KINDS.include?(principal_kind)
            raise ArgumentError, "unknown principal_kind: #{principal_kind.inspect}"
          end

          expected_source = GRANT_SOURCE_BY_PRINCIPAL.fetch(principal_kind)
          unless grant_source == expected_source
            raise ArgumentError,
                  "#{principal_kind} requires grant_source #{expected_source.inspect}, " \
                  "got #{grant_source.inspect}"
          end

          validate_principal_shape!
          validate_credential_binding!
        end

        def validate_principal_shape!
          if principal_kind == :authenticated_session
            validate_authenticated_session_shape!
          else
            validate_trusted_local_shape!
          end
        end

        # A session identity backed by a VERIFIED deck grant and bound to the
        # credential that read captured -- not merely a session id beside two
        # credential references that happen to agree. A :not_applicable read
        # with no credential satisfies nil == nil, and a :verification_failed
        # read still carries the credential it captured, so neither the
        # binding check nor the grant-source marker can stand in for
        # verification.
        def validate_authenticated_session_shape!
          raise ArgumentError, "authenticated_session requires a session_id" if session_id.nil?
          raise ArgumentError, "authenticated_session cannot be local_trusted" unless local_trusted == false

          status = grant_read_result.verification_status
          unless status == :verified
            raise ArgumentError, "authenticated_session requires a verified grant, got #{status.inspect}"
          end
          return if grant_read_result.credential_ref

          raise ArgumentError, "authenticated_session requires the credential its verified grant captured"
        end

        def validate_trusted_local_shape!
          raise ArgumentError, "trusted_local must not carry a session_id" unless session_id.nil?
          raise ArgumentError, "trusted_local must be local_trusted" unless local_trusted == true

          validate_trusted_local_grant!
        end

        # The whole trusted-local shape, not just "not verified". A local
        # caller is trusted by deployment rather than by a grant, so it has
        # nothing a deck read produced: no grant status beyond
        # never-consulted, no scopes, no inbound claims, and no credential to
        # send anywhere.
        def validate_trusted_local_grant!
          unless TRUSTED_LOCAL_GRANT_STATUSES.include?(grant_read_result.verification_status)
            raise ArgumentError,
                  "trusted_local requires a grant result of " \
                  "#{TRUSTED_LOCAL_GRANT_STATUSES.inspect}, " \
                  "got #{grant_read_result.verification_status.inspect}"
          end
          raise ArgumentError, "trusted_local must not present granted scopes" unless trusted_local_scopes_empty?
          raise ArgumentError, "trusted_local must not carry inbound claims" unless trusted_local_claims_absent?
          return if grant_read_result.credential_ref.nil? && outbound_credential_ref.nil?

          raise ArgumentError, "trusted_local must not carry a captured or outbound credential"
        end

        def trusted_local_scopes_empty?
          scopes = grant_read_result.grant_scopes
          scopes.nil? || scopes.empty?
        end

        def trusted_local_claims_absent?
          verified_inbound_claims.nil? || verified_inbound_claims.empty?
        end

        # The credential a context may send outbound is the one its own grant
        # read captured -- never another. A trusted-local context captured
        # none, so it may carry none.
        def validate_credential_binding!
          return if outbound_credential_ref == grant_read_result.credential_ref

          raise ArgumentError,
                "outbound_credential_ref must match the credential the grant read captured"
        end
      end
    end
  end
end
