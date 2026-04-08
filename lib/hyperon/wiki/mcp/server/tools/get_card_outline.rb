# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for getting a card's heading structure
          class GetCardOutline < ::MCP::Tool
            Client = Hyperon::Wiki::Mcp::Client
            description "Get the heading structure of a card without fetching full content. Returns all headings (HTML h1-h6 and Markdown #) with their level, text, and character position. Use this to understand a card's structure before deciding which section to read (via get_card with content_offset) or edit (via find_and_replace). Also reports content_length and card type."
            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                name: {
                  type: "string",
                  description: "The name of the card to get the outline for"
                }
              },
              required: ["name"]
            )

            class << self
              def call(name:, server_context:)
                tools = server_context[:magi_tools]
                result = tools.get_card_outline(name)

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
                  text: ErrorFormatter.generic_error("getting outline for card '#{name}'", e)
                }], error: true)
              end

              private

              def format_result(result)
                headings = result["headings"] || []
                text_parts = []
                text_parts << "# Outline: #{result['card']}"
                text_parts << ""
                text_parts << "**Type:** #{result['type']} | **Content length:** #{result['content_length']} chars | **Headings:** #{headings.size}"
                text_parts << ""

                if headings.empty?
                  text_parts << "No headings found in this card."
                else
                  headings.each do |heading|
                    indent = "  " * (heading["level"] - 1)
                    text_parts << "#{indent}- **h#{heading['level']}:** #{heading['text']} (#{heading['format']}, pos #{heading['position']})"
                  end
                end

                {
                  id: result["card"],
                  title: "Outline: #{result['card']}",
                  text: text_parts.join("\n"),
                  metadata: {
                    type: result["type"],
                    content_length: result["content_length"],
                    heading_count: headings.size
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
