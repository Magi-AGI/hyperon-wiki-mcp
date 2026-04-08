# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for prepending content to a card
          class PrependContent < ::MCP::Tool
            Client = Hyperon::Wiki::Mcp::Client
            description "Prepend content to the beginning of an existing card without fetching it first. Works on raw stored content (HTML, markdown, plain text, wiki links). Use separator='\\n' for newline or '<br>' for HTML break between new and old content. Prefer this over get_card + update_card when adding to the start of a card."
            annotations(
              read_only_hint: false,
              destructive_hint: false
            )

            input_schema(
              properties: {
                name: {
                  type: "string",
                  description: "The name of the card to prepend to"
                },
                content: {
                  type: "string",
                  description: "Content to prepend to the beginning of the card"
                },
                separator: {
                  type: "string",
                  description: "Separator between new and existing content (default: empty string). Use '\\n' for newline, '<br>' for HTML line break, etc.",
                  default: ""
                }
              },
              required: %w[name content]
            )

            class << self
              def call(name:, content:, separator: "", server_context:)
                tools = server_context[:magi_tools]
                card = tools.prepend_content(name, content: content, separator: separator)
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
                  text: ErrorFormatter.generic_error("prepending to card '#{name}'", e)
                }], error: true)
              end

              private

              def build_response(card)
                {
                  status: "success",
                  id: card["name"],
                  title: card["name"],
                  text: "Content prepended to '#{card['name']}' successfully.",
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
