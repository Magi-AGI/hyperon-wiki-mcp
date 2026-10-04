# frozen_string_literal: true

require_relative "query_atoms"
require_relative "get_card_atom"
require_relative "get_card_provenance"
require_relative "list_references"
require_relative "list_atoms_by_type"
require_relative "atom_types"
require_relative "atom_count_by_type"
require_relative "space_stats"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          module Atomspace
            # The dedicated AtomSpace toolset. Two-layer enforcement:
            #   - visible_for(scopes): hide tools from tools/list when the scope is absent.
            #   - gate!(tool, scopes): enforce the scope at INVOCATION (visibility != enforcement,
            #     Gemini 1.1) -- resolve by the registered tool object's required_scope, NOT a
            #     free-form request name (Codex 3).
            #
            # Both entry points ask one question -- is this tool's required scope among the
            # granted ones? -- so a requirement the registry cannot read makes the question
            # meaningless, and answering "nothing is required" is how a gate that exists stops
            # gating. Each resolves the requirement first and fails closed when it cannot, in the
            # direction that costs least: gate! guards a single invocation, so it denies that
            # invocation; visible_for builds the list handed to every caller, so it drops the one
            # entry rather than raising and denying tools/list to everybody. Registration
            # integrity itself is a separate assertion (TOOLS requires exactly one real scope).
            module Registry
              TOOLS = [
                QueryAtoms, GetCardAtom, GetCardProvenance, ListReferences,
                ListAtomsByType, AtomTypes, AtomCountByType, SpaceStats
              ].freeze

              module_function

              def visible_for(scopes)
                TOOLS.select do |tool|
                  required = resolve_required_scope(tool)
                  required && scopes.include?(required)
                end
              end

              def gate!(tool, scopes)
                required = resolve_required_scope(tool)
                unless required
                  raise Client::AuthorizationError,
                        "unresolved required scope for #{tool.inspect}; refusing invocation"
                end
                return if scopes.include?(required)

                raise Client::AuthorizationError, "#{required} scope required"
              end

              # The same two entry points, asking a RequestContext instead of a bare granted-scope
              # array.
              #
              # A bare array leaves every caller to decide for itself whether that array may be
              # trusted, and the array cannot say: a verified grant's scope list keeps naming its
              # scopes after the grant's authorization deadline has passed. Asking the context
              # routes the question through RequestContext#authorizes_scope? -> GrantReadResult
              # #authorization_valid_now?, so the freshness half of the fail-closed rule cannot be
              # dropped by a caller that happens to hold a scope list.
              #
              # Each keeps its array-taking twin's direction, and for the same reason: gate guards
              # one invocation so it denies that invocation; visible builds the list handed to
              # every caller so it drops the one entry.
              #
              # A nil context -- what rack_app's #build_request_context returns when no grant backs
              # the request -- is denial, not an exception to handle: absence of a context means
              # nothing was authorized. Anything that cannot answer an authorization question at
              # all is treated identically, rather than inspected for a scope list to fall back on.
              def visible_for_context(context, now: Time.now)
                TOOLS.select do |tool|
                  required = resolve_required_scope(tool)
                  required && context_authorizes?(context, required, now)
                end
              end

              def gate_for_context!(tool, context, now: Time.now)
                required = resolve_required_scope(tool)
                unless required
                  raise Client::AuthorizationError,
                        "unresolved required scope for #{tool.inspect}; refusing invocation"
                end
                unless authorizing_context?(context)
                  raise Client::AuthorizationError,
                        "no request context can authorize #{required}; refusing invocation"
                end
                return if context.authorizes_scope?(required, now: now)

                raise Client::AuthorizationError, "#{required} scope required"
              end

              # The scope a tool actually names, or nil when it names none the granted-scope list
              # could legitimately contain. Unresolvable is defined by what a membership check
              # can act on rather than by nil alone: a missing method, nil, a non-String, and an
              # empty String are all equally unusable, and a granted list arrives unvalidated
              # (Auth#scopes passes a verified `scope` claim through as-is, nil elements
              # included), so a nil requirement must never be matchable by a nil grant.
              def resolve_required_scope(tool)
                return nil unless tool.respond_to?(:required_scope)

                required = tool.required_scope
                return nil unless required.is_a?(String) && !required.empty?

                required
              end

              # A context that can answer an authorization question at all. The capability check
              # is deliberately the whole test: RequestContext#authorizes_scope? already applies
              # the fail-closed rule, so anything answering it is trusted to answer, and anything
              # not answering it authorizes nothing. No duck-typed scope list is read as a
              # substitute -- that is exactly the shortcut these entry points exist to close.
              def authorizing_context?(context)
                !context.nil? && context.respond_to?(:authorizes_scope?)
              end

              def context_authorizes?(context, required, now)
                authorizing_context?(context) && context.authorizes_scope?(required, now: now)
              end
            end
          end
        end
      end
    end
  end
end
