# frozen_string_literal: true

require_relative "base"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          module Atomspace
            class ListAtomsByType < Base
              description "List atoms of a given TypeName (post auth-filter; requires mcp:atomspace:read)."
              annotations(read_only_hint: true, destructive_hint: false)
              input_schema(
                properties: {
                  type_name: { type: "string", description: "DeckoCard | DeckoReference | DeckoProvenance" },
                  limit: { type: "integer", description: "Pre-auth best-effort cap" },
                  include_trash: { type: "boolean", default: false },
                  wait_for_event_id: { type: "string", description: "decko:action:<id> for read-your-writes" }
                },
                required: ["type_name"]
              )
              class << self
                def call(type_name:, limit: nil, include_trash: false, wait_for_event_id: nil, server_context:)
                  respond do
                    server_context[:magi_tools].atomspace_list_atoms_by_type(
                      type_name: type_name, limit: limit, include_trash: include_trash,
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
