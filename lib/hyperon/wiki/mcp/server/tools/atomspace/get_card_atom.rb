# frozen_string_literal: true

require_relative "base"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          module Atomspace
            class GetCardAtom < Base
              description "Get the DeckoCard atom for a card_id (post auth-filter; requires mcp:atomspace:read)."
              annotations(read_only_hint: true, destructive_hint: false)
              input_schema(
                properties: {
                  card_id: { type: "integer", description: "Decko card id" },
                  include_trash: { type: "boolean", default: false },
                  wait_for_event_id: { type: "string", description: "decko:action:<id> for read-your-writes" }
                },
                required: ["card_id"]
              )
              class << self
                def call(card_id:, include_trash: false, wait_for_event_id: nil, server_context:)
                  respond do
                    server_context[:magi_tools].atomspace_get_card_atom(
                      card_id: card_id, include_trash: include_trash, wait_for_event_id: wait_for_event_id
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
