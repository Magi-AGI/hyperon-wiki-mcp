# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for appending content to a card
          class AppendContent < ::MCP::Tool
            Client = Hyperon::Wiki::Mcp::Client
            description "Append content to the end of an existing card. Works on any content format (HTML, markdown, plain text). More efficient than get_card + update_card for adding content."
            annotations(
              read_only_hint: false,
              destructive_hint: false
            )

            input_schema(
              properties: {
                name: {
                  type: "string",
                  description: "The name of the card to append to"
                },
                content: {
                  type: "string",
                  description: "Content to append to the end of the card"
                },
                separator: {
                  type: "string",
                  description: "Separator between existing and new content (default: empty string). Use '\\n' for newline, '<br>' for HTML line break, etc.",
                  default: ""
                }
              },
              required: %w[name content]
            )

            class << self
              def call(name:, content:, separator: "", server_context:)
                tools = server_context[:magi_tools]
                card = tools.append_content(name, content: content, separator: separator)
                response = build_response(card)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(response)
                }])
              rescue Client::NotFoundError
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.not_found("Card", name)
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
                  text: ErrorFormatter.generic_error("appending to card '#{name}'", e)
                }], error: true)
              end

              private

              def build_response(card)
                {
                  status: "success",
                  id: card["name"],
                  title: card["name"],
                  text: "Content appended to '#{card['name']}' successfully.",
                  metadata: {
                    type: card["type"],
                    card_id: card["id"]
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
