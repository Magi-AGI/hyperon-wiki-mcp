# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Magi
  module Archive
    module Mcp
      module Server
        module Tools
          # MCP Tool for listing deleted cards in trash (admin only)
          class ListTrash < ::MCP::Tool
            # Alias Client for cleaner error handling
            Client = Magi::Archive::Mcp::Client

            DESCRIPTION = <<~DESC.strip
              List deleted cards in the trash (requires admin role).

              Returns cards that have been deleted but not permanently removed.
              Each entry shows:
              - Card name and type
              - When it was deleted
              - Who deleted it

              Use this to:
              - Find accidentally deleted cards
              - Review what cards were recently removed
              - Check if a specific card is in trash before recreating it

              To restore a card from trash, use `restore_card` with `from_trash: true`.

              **Note:** Cards in trash are not visible in normal searches or listings.
              If you're looking for a card that seems to have disappeared, check here first.
            DESC

            description DESCRIPTION

            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                limit: {
                  type: "integer",
                  description: "Maximum number of cards to return (default: 50, max: 100)",
                  default: 50,
                  minimum: 1,
                  maximum: 100
                },
                offset: {
                  type: "integer",
                  description: "Starting offset for pagination (default: 0)",
                  default: 0,
                  minimum: 0
                }
              },
              required: []
            )

            class << self
              def call(limit: 50, offset: 0, server_context:)
                tools = server_context[:magi_tools]

                trash = tools.list_trash(limit: limit, offset: offset)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: format_trash_list(trash, offset)
                }])
              rescue Client::AuthorizationError
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authorization_error("view trash", "trash listing", required_role: "admin")
                }], error: true)
              rescue Client::AuthenticationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authentication_error(e.message)
                }], error: true)
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.generic_error("listing trash", e)
                }], error: true)
              end

              private

              def format_trash_list(trash, offset)
                parts = []
                parts << "# 🗑️ Trash"
                parts << ""

                total = trash["total"] || 0
                cards = trash["cards"] || []

                parts << "**Total deleted cards:** #{total}"
                parts << ""

                if cards.empty?
                  if offset > 0
                    parts << "(No more cards at this offset)"
                  else
                    parts << "✨ The trash is empty! No deleted cards found."
                  end
                else
                  parts << "## Deleted Cards"
                  parts << ""

                  cards.each_with_index do |card, idx|
                    parts << format_trash_entry(card, offset + idx + 1)
                  end

                  # Pagination info
                  if cards.size < total
                    remaining = total - (offset + cards.size)
                    if remaining > 0
                      parts << ""
                      parts << "*(Showing #{offset + 1}-#{offset + cards.size} of #{total}. " \
                               "Use offset: #{offset + cards.size} to see more)*"
                    end
                  end
                end

                parts << ""
                parts << "---"
                parts << ""
                parts << "**To restore a card:** Use `restore_card` with"
                parts << '`name: "CardName", from_trash: true`'

                parts.join("\n")
              end

              def format_trash_entry(card, number)
                parts = []
                parts << "### #{number}. #{card['name']}"
                parts << ""
                parts << "- **Type:** #{card['type'] || 'Unknown'}"

                if card["deleted_at"]
                  parts << "- **Deleted:** #{card['deleted_at']}"
                end

                if card["deleted_by"]
                  parts << "- **By:** #{card['deleted_by']}"
                end

                parts << ""
                parts.join("\n")
              end
            end
          end
        end
      end
    end
  end
end
