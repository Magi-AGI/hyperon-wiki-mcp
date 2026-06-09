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
            module Registry
              TOOLS = [
                QueryAtoms, GetCardAtom, GetCardProvenance, ListReferences,
                ListAtomsByType, AtomTypes, AtomCountByType, SpaceStats
              ].freeze

              module_function

              def visible_for(scopes)
                TOOLS.select { |tool| scopes.include?(tool.required_scope) }
              end

              def gate!(tool, scopes)
                req = tool.respond_to?(:required_scope) && tool.required_scope
                return unless req && !scopes.include?(req)

                raise Client::AuthorizationError, "#{req} scope required"
              end
            end
          end
        end
      end
    end
  end
end
