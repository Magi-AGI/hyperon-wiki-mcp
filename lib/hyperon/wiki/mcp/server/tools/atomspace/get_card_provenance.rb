# frozen_string_literal: true

require_relative "base"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          module Atomspace
            class GetCardProvenance < Base
              description "List DeckoProvenance atoms for a card / event / action range (post auth-filter; requires mcp:atomspace:read)."
              annotations(read_only_hint: true, destructive_hint: false)
              input_schema(
                properties: {
                  card_id: { type: "integer" },
                  event_id: { type: "string" },
                  action_id_range: { type: "string", description: "e.g. '1000-2000'" },
                  wait_for_event_id: { type: "string", description: "decko:action:<id> for read-your-writes" }
                },
                required: []
              )
              class << self
                def call(card_id: nil, event_id: nil, action_id_range: nil, wait_for_event_id: nil, server_context:)
                  respond do
                    server_context[:magi_tools].atomspace_get_card_provenance(
                      card_id: card_id, event_id: event_id, action_id_range: action_id_range,
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
