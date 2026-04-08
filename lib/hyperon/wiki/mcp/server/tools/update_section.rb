# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for updating content within a specific heading section of a card
          class UpdateSection < ::MCP::Tool
            Client = Hyperon::Wiki::Mcp::Client
            description "Update content within a specific heading section of a card. Finds the section by heading text (case-insensitive match) and replaces its body content while preserving the heading. Use get_card_outline first to see available sections. The section body extends from after the heading to the next heading at the same or higher level."
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
                section: {
                  type: "string",
                  description: "The heading text of the section to update"
                },
                content: {
                  type: "string",
                  description: "New content for the section body"
                }
              },
              required: %w[name section content]
            )

            class << self
              def call(name:, section:, content:, server_context:)
                tools = server_context[:magi_tools]
                card = tools.update_section(name, section: section, content: content)
                response = build_response(card, section)

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
                                            text: ErrorFormatter.authorization_error("update", name,
                                                                                     required_role: "user")
                                          }], error: true)
              rescue Client::AuthenticationError => e
                ::MCP::Tool::Response.new([{
                                            type: "text",
                                            text: ErrorFormatter.authentication_error(e.message)
                                          }], error: true)
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                                            type: "text",
                                            text: ErrorFormatter.generic_error(
                                              "updating section '#{section}' in card '#{name}'", e
                                            )
                                          }], error: true)
              end

              private

              def build_response(card, section)
                {
                  status: "success",
                  id: card["name"],
                  title: card["name"],
                  text: "Section '#{section}' updated in '#{card["name"]}' successfully.",
                  metadata: {
                    type: card["type"],
                    card_id: card["id"],
                    section: section
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
