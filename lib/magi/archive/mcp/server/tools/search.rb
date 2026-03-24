# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Magi
  module Archive
    module Mcp
      module Server
        module Tools
          # ChatGPT-compatible search tool that wraps search_cards
          # Returns results in the format expected by ChatGPT connectors
          class Search < ::MCP::Tool
            description "Search the Magi Archive wiki for relevant cards. Returns a list of search results with IDs, titles, and URLs for citation."

            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                query: {
                  type: "string",
                  description: "Search query string. Searches card names and content."
                }
              },
              required: ["query"]
            )

            class << self
              def call(query:, server_context:)
                tools = server_context[:magi_tools]

                # Use search_cards to find matching cards
                search_result = tools.search_cards(
                  q: query,
                  search_in: "both", # Search names and content
                  limit: 10
                )

                # Transform to ChatGPT connector format
                # ChatGPT is fussy about response shape:
                # - id and title are REQUIRED
                # - source is preferred over url (use both for compatibility)
                # - snippet provides context for search results
                results = search_result['cards'].map do |card|
                  card_url = "https://wiki.hyperon.dev/#{card['name'].gsub(' ', '_')}"
                  {
                    id: card['name'],
                    title: card['name'],
                    snippet: "#{card['type']} card#{card['updated_at'] ? " - Updated: #{card['updated_at']}" : ''}",
                    source: card_url,
                    url: card_url
                  }
                end

                # Return as MCP Tool Response with JSON-encoded text
                # This is the format ChatGPT connectors expect
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate({ results: results })
                }])
              rescue Client::AuthenticationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authentication_error(e.message)
                }], error: true)
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.generic_error("searching cards with query '#{query}'", e)
                }], error: true)
              end
            end
          end
        end
      end
    end
  end
end
