# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for find-and-replace within card content
          class FindAndReplace < ::MCP::Tool
            Client = Hyperon::Wiki::Mcp::Client
            description "Find and replace text in a card's raw stored content server-side, without fetching the card first. Supports first/last/all occurrence modes. Returns error if text not found. Use find_in_card first to locate the exact text with context, then use this tool to replace it. Much more efficient than get_card + update_card for targeted edits."
            annotations(
              read_only_hint: false,
              destructive_hint: false
            )

            input_schema(
              properties: {
                name: {
                  type: "string",
                  description: "The name of the card to edit"
                },
                find: {
                  type: "string",
                  description: "The exact text to find (literal string match, not regex)"
                },
                replace: {
                  type: "string",
                  description: "The replacement text"
                },
                occurrence: {
                  type: "string",
                  description: "Which occurrences to replace: 'first' (default), 'last', or 'all'",
                  enum: %w[first last all],
                  default: "first"
                }
              },
              required: %w[name find replace]
            )

            class << self
              def call(name:, find:, replace:, occurrence: "first", server_context:)
                tools = server_context[:magi_tools]
                card = tools.find_and_replace(name, find: find, replace: replace, occurrence: occurrence)
                response = build_response(card, find, replace, occurrence)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(response)
                }])
              rescue Client::NotFoundError
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.not_found("Card", name)
                }], error: true)
              rescue Client::ValidationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.validation_error(e.message)
                }], error: true)
              rescue Client::AuthorizationError
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authorization_error("update", name, required_role: "user")
                }], error: true)
              rescue Client::AuthenticationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authentication_error(e.message)
                }], error: true)
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.generic_error("find-and-replace on card '#{name}'", e)
                }], error: true)
              end

              private

              def build_response(card, find, replace, occurrence)
                {
                  status: "success",
                  id: card["name"],
                  title: card["name"],
                  text: "Find-and-replace completed on '#{card['name']}'. Replaced #{occurrence == 'all' ? 'all occurrences' : occurrence + ' occurrence'} of the specified text.",
                  metadata: {
                    type: card["type"],
                    card_id: card["id"],
                    find_length: find.length,
                    replace_length: replace.length,
                    occurrence: occurrence
                  }.compact
                }
              end
            end
          end
        end
      end
    end
  end
end
