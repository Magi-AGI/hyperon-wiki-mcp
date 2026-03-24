# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Magi
  module Archive
    module Mcp
      module Server
        module Tools
          # MCP Tool for fetching card revision history
          class GetCardHistory < ::MCP::Tool
            # Alias Client for cleaner error handling
            Client = Magi::Archive::Mcp::Client

            DESCRIPTION = <<~DESC.strip
              Get revision history for a card from the Magi Archive wiki.

              Returns a chronological list of all changes made to the card,
              including creates, updates, and deletes. Each revision includes:
              - Who made the change (actor)
              - When it was made (acted_at)
              - What type of change (action: create, update, delete)
              - Which fields were modified (changes)

              Use this to:
              - Audit who changed a card and when
              - Find a previous version to restore
              - Check if a card was recently modified
              - Verify the history of deleted/restored cards

              Related tools:
              - get_revision: Get content from a specific revision
              - restore_card: Restore card to a previous state (admin only)
              - list_trash: Find deleted cards (admin only)
            DESC

            description DESCRIPTION

            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                name: {
                  type: "string",
                  description: "The name of the card to get history for"
                },
                limit: {
                  type: "integer",
                  description: "Maximum number of revisions to return (default: 20, max: 100)",
                  default: 20,
                  minimum: 1,
                  maximum: 100
                }
              },
              required: ["name"]
            )

            class << self
              def call(name:, limit: 20, server_context:)
                tools = server_context[:magi_tools]

                history = tools.get_card_history(name, limit: limit)

                # Build hybrid JSON response
                response = build_response(name, history)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(response)
                }])
              rescue Client::NotFoundError
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.not_found("Card", name)
                }], error: true)
              rescue Client::AuthorizationError => e
                required_role = e.details&.dig("required_role") || "gm"
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authorization_error(
                    "view history for", name,
                    required_role: required_role,
                    api_message: e.message,
                    api_details: e.details
                  )
                }], error: true)
              rescue Client::AuthenticationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authentication_error(e.message)
                }], error: true)
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.generic_error("fetching history for '#{name}'", e)
                }], error: true)
              end

              private

              def build_response(name, history)
                revisions = history["revisions"] || []
                card_url = "https://wiki.hyperon.dev/#{name.to_s.gsub(' ', '_')}"

                result_items = revisions.map do |rev|
                  {
                    id: rev['act_id'].to_s,
                    title: "#{rev['action'].capitalize} by #{rev['actor'] || 'Unknown'}",
                    snippet: "#{rev['acted_at']}#{rev['changes']&.any? ? " - Changed: #{rev['changes'].join(', ')}" : ''}",
                    act_id: rev['act_id']
                  }
                end

                {
                  id: name,
                  title: "Card History: #{name}",
                  source: card_url,
                  url: card_url,
                  results: result_items,
                  total: history['total'] || revisions.size,
                  text: format_history(history),
                  metadata: {
                    card_name: history['card'],
                    in_trash: history['in_trash']
                  }.compact
                }
              end

              def format_history(history)
                parts = []
                parts << "# Card History: #{history['card']}"
                parts << ""

                # Show trash status prominently
                if history["in_trash"]
                  parts << "**Status:** ⚠️ DELETED (in trash)"
                  parts << ""
                  parts << "This card is currently in the trash. Use `restore_card` with"
                  parts << "`from_trash: true` to restore it (requires admin role)."
                  parts << ""
                end

                parts << "**Total Revisions:** #{history['total']}"
                parts << ""

                revisions = history["revisions"] || []
                if revisions.empty?
                  parts << "(No revision history available)"
                else
                  parts << "## Revisions"
                  parts << ""

                  revisions.each_with_index do |rev, idx|
                    parts << format_revision_summary(rev, idx)
                  end

                  if revisions.size < (history["total"] || 0)
                    parts << ""
                    parts << "*(Showing #{revisions.size} of #{history['total']} revisions)*"
                  end
                end

                parts << ""
                parts << "---"
                parts << "**Tip:** Use `get_revision` with an `act_id` to see the content at that point."

                parts.join("\n")
              end

              def format_revision_summary(rev, index)
                parts = []

                # Format: ### 1. update by Username (2025-12-24)
                action_icon = action_icon_for(rev["action"])
                parts << "### #{index + 1}. #{action_icon} #{rev['action'].capitalize}"
                parts << ""
                parts << "- **Act ID:** #{rev['act_id']}"
                parts << "- **Actor:** #{rev['actor'] || 'Unknown'}"
                parts << "- **Date:** #{rev['acted_at']}"

                if rev["changes"]&.any?
                  parts << "- **Changed:** #{rev['changes'].join(', ')}"
                end

                if rev["comment"]
                  parts << "- **Comment:** #{rev['comment']}"
                end

                parts << ""
                parts.join("\n")
              end

              def action_icon_for(action)
                case action&.downcase
                when "create" then "🆕"
                when "update" then "✏️"
                when "delete" then "🗑️"
                else "📝"
                end
              end
            end
          end
        end
      end
    end
  end
end
