# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for listing child cards
          class ListChildren < ::MCP::Tool
            # Alias Client for cleaner error handling
            Client = Hyperon::Wiki::Mcp::Client
            description "List child cards of a parent card with pagination. Returns the true total count of all children (child_count) regardless of limit, plus truncated flag and next_offset for paginating through large sets. Always check total vs returned count — cards can have hundreds of children."

            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                parent_name: {
                  type: "string",
                  description: "The name of the parent card"
                },
                limit: {
                  type: "integer",
                  description: "Maximum number of children to return (default: 20, max: 100). Use offset to paginate through large sets.",
                  default: 20,
                  minimum: 1,
                  maximum: 100
                },
                offset: {
                  type: "integer",
                  description: "Number of children to skip for pagination (default: 0). Use with limit to page through cards with many children.",
                  default: 0,
                  minimum: 0
                },
                depth: {
                  type: "integer",
                  description: "How many levels deep to fetch (default: 3). depth=1 returns only direct children, depth=2 includes grandchildren, depth=3 includes great-grandchildren.",
                  default: 3,
                  minimum: 1,
                  maximum: 5
                },
                include_virtual: {
                  type: "boolean",
                  description: "Include virtual cards (empty junction cards with no content) in results. Default: false (filters them out).",
                  default: false
                }
              },
              required: ["parent_name"]
            )

            class << self
              def call(parent_name:, limit: 20, offset: 0, depth: 3, include_virtual: false, server_context:)
                tools = server_context[:magi_tools]

                children = tools.list_children(parent_name, limit: limit, offset: offset, include_virtual: include_virtual, depth: depth)

                # Build hybrid JSON response
                response = build_response(parent_name, children)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(response)
                }])
              rescue Client::NotFoundError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.not_found("Card", parent_name)
                }], error: true)
              rescue Client::AuthorizationError => e
                required_role = e.details&.dig("required_role") || "gm"
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authorization_error(
                    "view children of", parent_name,
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
                  text: ErrorFormatter.generic_error("listing children of '#{parent_name}'", e)
                }], error: true)
              end

              private

              def build_response(parent_name, children)
                child_cards = children["children"] || []
                total = children["child_count"] || child_cards.size
                limit = children["limit"] || child_cards.size
                offset = children["offset"] || 0
                truncated = child_cards.size < total - offset
                next_offset = truncated ? offset + limit : nil

                result_items = child_cards.map do |card|
                  card_url = "https://wiki.hyperon.dev/#{card['name'].to_s.gsub(' ', '_')}"
                  {
                    id: card['name'],
                    title: card['name'],
                    snippet: "#{card['type']} card#{card['updated_at'] ? " - Updated: #{card['updated_at']}" : ''}",
                    source: card_url,
                    url: card_url
                  }
                end

                parent_url = "https://wiki.hyperon.dev/#{parent_name.to_s.gsub(' ', '_')}"

                {
                  id: parent_name,
                  title: "Children of #{parent_name}",
                  source: parent_url,
                  url: parent_url,
                  results: result_items,
                  total: total,
                  returned: child_cards.size,
                  offset: offset,
                  truncated: truncated,
                  next_offset: next_offset,
                  text: format_children(parent_name, children)
                }
              end

              def format_children(parent_name, children)
                child_cards = children["children"] || []
                total = children["child_count"] || child_cards.size
                offset = children["offset"] || 0
                limit = children["limit"] || child_cards.size

                parts = []
                parts << "# Children of #{parent_name}"
                parts << ""

                if child_cards.any?
                  parts << "**Showing #{child_cards.size} of #{total} total children** (offset: #{offset})"
                  parts << ""

                  child_cards.each_with_index do |child, idx|
                    parts << "#{offset + idx + 1}. **#{child['name']}** (#{child['type']})"
                    parts << "   ID: #{child['id']}, Updated: #{child['updated_at']}" if child['updated_at']
                  end

                  if child_cards.size + offset < total
                    remaining = total - offset - child_cards.size
                    next_off = offset + limit
                    parts << ""
                    parts << "**#{remaining} more children available.** Use `list_children(parent_name: \"#{parent_name}\", offset: #{next_off})` to get the next page."
                  end
                else
                  parts << "No child cards found."
                end

                parts.join("\n")
              end
            end
          end
        end
      end
    end
  end
end
