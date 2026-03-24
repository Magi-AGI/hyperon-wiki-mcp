# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Magi
  module Archive
    module Mcp
      module Server
        module Tools
          # MCP Tool for fetching a single card from the wiki
          class GetCard < ::MCP::Tool
            description "Get a single card by name from the Magi Archive wiki. Note: Pointer cards contain references to other cards (use list_children to see them). Search cards contain dynamic queries (content shows query, not results). Use underscores for exact name matches."

            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                name: {
                  type: "string",
                  description: "The name of the card to fetch (e.g., 'Main Page' or 'Business Plan+Executive Summary')"
                },
                with_children: {
                  type: "boolean",
                  description: "Include child cards in the response",
                  default: false
                },
                max_content_length: {
                  type: "integer",
                  description: "Maximum content length to return (default: 8000 chars). Set to 0 for unlimited. Larger values may cause issues with some AI clients.",
                  default: 8000,
                  minimum: 0
                },
                content_offset: {
                  type: "integer",
                  description: "Character offset to start content from (default: 0). Use with max_content_length to paginate through large cards.",
                  default: 0,
                  minimum: 0
                }
              },
              required: ["name"]
            )

            class << self
              def call(name:, with_children: false, max_content_length: 8000, content_offset: 0, server_context:)
                tools = server_context[:magi_tools]

                card = tools.get_card(name, with_children: with_children)

                # Build hybrid JSON response with text field for markdown
                result = build_response(card, max_content_length: max_content_length, content_offset: content_offset)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(result)
                }])
              rescue Client::NotFoundError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.not_found("Card", name)
                }], error: true)
              rescue Client::AuthorizationError => e
                # Extract actual error details from API response
                required_role = e.details&.dig("required_role") || "gm"
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authorization_error(
                    "view", name,
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
                  text: ErrorFormatter.generic_error("fetching card '#{name}'", e)
                }], error: true)
              end

              private

              def build_response(card, max_content_length:, content_offset:)
                is_virtual = virtual_card?(card)
                full_content = card['content'].to_s.strip
                total_length = full_content.length

                # Calculate pagination
                truncated = false
                next_offset = nil
                if content_offset < total_length && max_content_length > 0
                  remaining = full_content[content_offset..]
                  if remaining && remaining.length > max_content_length
                    truncated = true
                    next_offset = content_offset + max_content_length
                  end
                end

                card_url = "https://wiki.hyperon.dev/#{card['name'].to_s.gsub(' ', '_')}"

                {
                  id: card['name'],
                  title: card['name'],
                  text: format_card(card, max_content_length: max_content_length, content_offset: content_offset),
                  source: card_url,
                  url: card_url,
                  metadata: {
                    type: card['type'],
                    card_id: card['id'],
                    updated_at: card['updated_at'],
                    virtual_card: is_virtual,
                    total_length: total_length,
                    content_offset: content_offset,
                    truncated: truncated,
                    next_offset: next_offset,
                    children_count: card['children']&.size
                  }.compact
                }
              end

              # Detect if a card is a virtual/junction card
              # Virtual cards are empty compound cards that serve as hierarchy parents
              def virtual_card?(card)
                # If API explicitly tells us, use that
                return card['virtual_card'] if card.key?('virtual_card')

                # Otherwise detect: compound name + empty content
                name = card['name'] || ''
                content = card['content'] || ''

                # Must be a compound card (contains +)
                return false unless name.include?('+')

                # Content must be empty or whitespace only
                content.strip.empty?
              end

              def format_card(card, max_content_length: 8000, content_offset: 0)
                parts = []
                parts << "# #{card['name']}"
                parts << ""

                # Determine and display virtual card status prominently
                is_virtual = virtual_card?(card)

                parts << "**Type:** #{card['type']}"
                parts << "**ID:** #{card['id']}" if card['id']
                parts << "**Updated:** #{card['updated_at']}" if card['updated_at']
                parts << "**URL:** #{card['url']}" if card['url']

                # Add virtual card indicator
                if is_virtual
                  parts << "**Virtual Card:** YES - This is a structural hierarchy card, DO NOT DELETE"
                else
                  parts << "**Virtual Card:** No"
                end

                parts << ""
                parts << "## Content"
                parts << ""

                full_content = card['content'].to_s.strip
                total_length = full_content.length

                if full_content.empty?
                  parts << '(empty)'
                elsif content_offset >= total_length
                  parts << "(offset #{content_offset} exceeds content length #{total_length})"
                else
                  # Apply offset first, then limit
                  remaining_content = full_content[content_offset..]

                  if max_content_length > 0 && remaining_content.length > max_content_length
                    parts << remaining_content[0...max_content_length]

                    # Calculate pagination info
                    chars_shown_end = content_offset + max_content_length
                    chars_remaining = total_length - chars_shown_end
                    next_offset = chars_shown_end

                    parts << ""
                    parts << "---"
                    parts << "**[Content paginated]** Showing characters #{content_offset + 1}-#{chars_shown_end} of #{total_length} (#{chars_remaining} remaining)."
                    parts << "To get next chunk: `get_card(name: \"#{card['name']}\", content_offset: #{next_offset})`"
                  else
                    parts << remaining_content

                    # Show offset info if we started mid-content
                    if content_offset > 0
                      parts << ""
                      parts << "---"
                      parts << "**[Content offset]** Showing characters #{content_offset + 1}-#{total_length} of #{total_length}."
                    end
                  end
                end

                # Add special note for Pointer and Search cards
                if card['type'] == 'Pointer'
                  parts << ""
                  parts << "**Note:** This is a Pointer card. Use list_children to see referenced cards, or get_card with with_children=true."
                elsif card['type'] == 'Search'
                  parts << ""
                  parts << "**Note:** This is a Search card. Content shows the search query. Results are dynamically generated when viewed on wiki."
                end

                # Add detailed warning for virtual cards
                if is_virtual
                  parts << ""
                  parts << "---"
                  parts << "## ⚠️ Virtual Card Warning"
                  parts << ""
                  parts << "This is a **virtual/junction card** - an empty compound card that exists"
                  parts << "as a structural parent in the wiki hierarchy. It has no content because"
                  parts << "actual content lives in child cards beneath it."
                  parts << ""
                  parts << "**DO NOT DELETE** - Deleting virtual cards breaks the wiki structure."
                  parts << ""
                  parts << "Use `list_children` to see child cards under this parent."
                end

                if card['children']&.any?
                  parts << ""
                  parts << "## Children (#{card['children'].size})"
                  parts << ""
                  card['children'].each do |child|
                    parts << "- #{child['name']} (#{child['type']})"
                  end
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
