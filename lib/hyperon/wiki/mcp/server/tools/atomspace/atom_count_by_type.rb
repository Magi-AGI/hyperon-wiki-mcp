# frozen_string_literal: true

require_relative "base"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          module Atomspace
            # Aggregate / global. Returns Space-global counts (acceptable only inside this
            # scope-gated toolset; never surfaced via the public wiki MCP tools).
            class AtomCountByType < Base
              description "Return {TypeName: count} across the AtomSpace mirror (aggregate; requires mcp:atomspace:read)."
              annotations(read_only_hint: true, destructive_hint: false)
              input_schema(properties: {}, required: [])
              class << self
                def call(server_context:)
                  respond { server_context[:magi_tools].atomspace_atom_count_by_type }
                end
              end
            end
          end
        end
      end
    end
  end
end
