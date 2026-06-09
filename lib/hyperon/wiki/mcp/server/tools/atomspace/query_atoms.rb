# frozen_string_literal: true

require_relative "base"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          module Atomspace
            class QueryAtoms < Base
              description "Query AtomSpace mirror atoms by MeTTa pattern (dedicated AtomSpace toolset; requires mcp:atomspace:read)."
              annotations(read_only_hint: true, destructive_hint: false)
              input_schema(
                properties: {
                  pattern: { type: "string", description: "MeTTa pattern to match" },
                  limit: { type: "integer", description: "Pre-auth best-effort cap; result may be smaller after the read-time auth filter" },
                  include_trash: { type: "boolean", default: false },
                  wait_for_event_id: { type: "string", description: "decko:action:<id> for read-your-writes" }
                },
                required: ["pattern"]
              )
              class << self
                def call(pattern:, limit: nil, include_trash: false, wait_for_event_id: nil, server_context:)
                  respond do
                    server_context[:magi_tools].atomspace_query_atoms(
                      pattern: pattern, limit: limit, include_trash: include_trash,
                      wait_for_event_id: wait_for_event_id
                    )
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
