# frozen_string_literal: true

require_relative "base"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          module Atomspace
            # Aggregate / global. Atom counts, types, and a mirror-lag indicator.
            class SpaceStats < Base
              description "AtomSpace mirror stats: atom counts, types, mirror-lag indicator (aggregate; requires mcp:atomspace:read)."
              annotations(read_only_hint: true, destructive_hint: false)
              input_schema(properties: {}, required: [])
              class << self
                def call(server_context:)
                  respond { server_context[:magi_tools].atomspace_space_stats }
                end
              end
            end
          end
        end
      end
    end
  end
end
