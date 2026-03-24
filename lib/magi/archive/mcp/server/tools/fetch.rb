# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Magi
  module Archive
    module Mcp
      module Server
        module Tools
          # ChatGPT-compatible fetch tool that wraps get_card
          # Returns full document content in the format expected by ChatGPT connectors
          class Fetch < ::MCP::Tool
            description "Retrieve complete card content by ID (card name) for detailed analysis and citation. Returns the full text, title, and URL."

            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                id: {
                  type: "string",
                  description: "Card name/ID from search results (e.g., 'Main Page' or 'Business Plan+Executive Summary')"
                },
                max_content_length: {
                  type: "integer",
                  description: "Maximum content length to return (default: 8000 chars). Set to 0 for unlimited.",
                  default: 8000,
                  minimum: 0
                },
                content_offset: {
                  type: "integer",
                  description: "Character offset to start content from (default: 0). Use for pagination.",
                  default: 0,
                  minimum: 0
                }
              },
              required: ["id"]
            )

            class << self
              def call(id:, max_content_length: 8000, content_offset: 0, server_context:)
                tools = server_context[:magi_tools]

                # Use get_card to fetch the full card
                card = tools.get_card(id)

                # Apply content truncation/pagination
                full_content = card['content'] || ""
                total_length = full_content.length
                truncated = false
                next_offset = nil

                text_content = if full_content.empty?
                                 "No content available"
                               elsif content_offset >= total_length
                                 "(offset #{content_offset} exceeds content length #{total_length})"
                               else
                                 remaining = full_content[content_offset..]
                                 if max_content_length > 0 && remaining.length > max_content_length
                                   truncated = true
                                   next_offset = content_offset + max_content_length
                                   remaining[0...max_content_length]
                                 else
                                   remaining
                                 end
                               end

                # Transform to ChatGPT connector format
                # ChatGPT expects: id, title, text, url/source, metadata
                # source is preferred over url - include both for compatibility
                card_url = "https://wiki.hyperon.dev/#{card['name'].gsub(' ', '_')}"
                result = {
                  id: card['name'],
                  title: card['name'],
                  text: text_content,
                  source: card_url,
                  url: card_url,
                  metadata: {
                    type: card['type'],
                    created_at: card['created_at'],
                    updated_at: card['updated_at'],
                    total_length: total_length,
                    content_offset: content_offset,
                    truncated: truncated,
                    next_offset: next_offset
                  }.compact
                }

                # Return as MCP Tool Response with JSON-encoded text
                # This is the format ChatGPT connectors expect
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(result)
                }])
              rescue Client::NotFoundError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.not_found("Card", id)
                }], error: true)
              rescue Client::AuthorizationError => e
                required_role = e.details&.dig("required_role") || "gm"
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authorization_error(
                    "view", id,
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
                  text: ErrorFormatter.generic_error("fetching card '#{id}'", e)
                }], error: true)
              end
            end
          end
        end
      end
    end
  end
end
