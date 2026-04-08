# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for searching within a card's content
          class FindInCard < ::MCP::Tool
            Client = Hyperon::Wiki::Mcp::Client
            description "Search for text within a card's raw stored content and return matching excerpts with surrounding context. Returns match positions and context without fetching the full card. Use this before find_and_replace to locate exact text. Also useful for checking if specific content exists in a large card without reading the whole thing."
            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                name: {
                  type: "string",
                  description: "The name of the card to search in"
                },
                query: {
                  type: "string",
                  description: "The text to search for (exact match)"
                },
                context_chars: {
                  type: "integer",
                  description: "Number of characters of context to show around each match (default: 100)",
                  default: 100,
                  minimum: 0,
                  maximum: 1000
                }
              },
              required: %w[name query]
            )

            class << self
              def call(name:, query:, context_chars: 100, server_context:)
                tools = server_context[:magi_tools]
                result = tools.find_in_card(name, query: query, context_chars: context_chars)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(format_result(result))
                }])
              rescue Client::NotFoundError
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.not_found("Card", name)
                }], error: true)
              rescue Client::AuthorizationError
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authorization_error("view", name, required_role: "user")
                }], error: true)
              rescue Client::AuthenticationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authentication_error(e.message)
                }], error: true)
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.generic_error("searching in card '#{name}'", e)
                }], error: true)
              end

              private

              def format_result(result)
                matches = result["matches"] || []
                text_parts = []
                text_parts << "# Search Results: '#{result['query']}' in #{result['card']}"
                text_parts << ""
                text_parts << "**Matches:** #{result['match_count']} | **Content length:** #{result['content_length']} chars"
                text_parts << ""

                if matches.empty?
                  text_parts << "No matches found."
                else
                  matches.each_with_index do |match, idx|
                    text_parts << "### Match #{idx + 1} (position #{match['position']})"
                    text_parts << "```"
                    text_parts << match["context"]
                    text_parts << "```"
                    text_parts << ""
                  end
                end

                {
                  id: result["card"],
                  title: "Search: '#{result['query']}' in #{result['card']}",
                  text: text_parts.join("\n"),
                  metadata: {
                    match_count: result["match_count"],
                    content_length: result["content_length"]
                  }
                }
              end
            end
          end
        end
      end
    end
  end
end
