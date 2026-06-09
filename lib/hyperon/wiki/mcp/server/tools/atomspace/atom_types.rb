# frozen_string_literal: true

require_relative "base"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          module Atomspace
            # Aggregate / global: returns no card-scoped payload, not card-filtered; gated only
            # by mcp:atomspace:read. No wait_for_event_id.
            class AtomTypes < Base
              description "List the TypeName values present in the AtomSpace mirror (aggregate; requires mcp:atomspace:read)."
              annotations(read_only_hint: true, destructive_hint: false)
              input_schema(properties: {}, required: [])
              class << self
                def call(server_context:)
                  respond { server_context[:magi_tools].atomspace_atom_types }
                end
              end
            end
          end
        end
      end
    end
  end
end
