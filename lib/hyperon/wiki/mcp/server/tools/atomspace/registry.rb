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
            end
          end
        end
      end
    end
  end
end
