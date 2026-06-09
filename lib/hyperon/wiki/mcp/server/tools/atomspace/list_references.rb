# frozen_string_literal: true

require_relative "base"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          module Atomspace
            class ListReferences < Base
              description "List DeckoReference atoms for a card (post auth-filter on referer AND referee; requires mcp:atomspace:read)."
              annotations(read_only_hint: true, destructive_hint: false)
              input_schema(
                properties: {
                  card_id: { type: "integer" },
                  ref_type: { type: "string", description: "I | L | Q | P" },
                  include_trash: { type: "boolean", default: false },
                  wait_for_event_id: { type: "string", description: "decko:action:<id> for read-your-writes" }
                },
                required: ["card_id"]
              )
              class << self
                def call(card_id:, ref_type: nil, include_trash: false, wait_for_event_id: nil, server_context:)
                  respond do
                    server_context[:magi_tools].atomspace_list_references(
                      card_id: card_id, ref_type: ref_type, include_trash: include_trash,
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
