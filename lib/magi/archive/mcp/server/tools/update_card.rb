# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Magi
  module Archive
    module Mcp
      module Server
        module Tools
          # MCP Tool for updating existing cards
          class UpdateCard < ::MCP::Tool
            # Alias Client for cleaner error handling
            Client = Magi::Archive::Mcp::Client
            description "Update an existing card in the Magi Archive wiki"
            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                name: {
                  type: "string",
                  description: "The name of the card to update"
                },
                content: {
                  type: "string",
                  description: "New content for the card (optional)"
                },
                type: {
                  type: "string",
                  description: "New type for the card (optional)"
                }
              },
              required: ["name"]
            )

            class << self
              def call(name:, content: nil, type: nil, server_context:)
                tools = server_context[:magi_tools]

                params = {}
                params[:content] = content if content
                params[:type] = type if type

                card = tools.update_card(name, **params)

                # Build hybrid JSON response
                response = build_response(card)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(response)
                }])
              rescue Client::NotFoundError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.not_found("Card", name)
                }], error: true)
              rescue Client::ValidationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.validation_error(e.message)
                }], error: true)
              rescue Client::AuthorizationError => e
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
                  text: ErrorFormatter.generic_error("updating card '#{name}'", e)
                }], error: true)
              end

              private

              def build_response(card)
                card_url = "https://wiki.hyperon.dev/#{card['name'].to_s.gsub(' ', '_')}"

                {
                  status: "success",
                  id: card['name'],
                  title: card['name'],
                  source: card_url,
                  url: card_url,
                  text: format_updated_card(card),
                  metadata: {
                    type: card['type'],
                    card_id: card['id']
                  }.compact
                }
              end

              def format_updated_card(card)
                parts = []
                parts << "# Card Updated Successfully"
                parts << ""
                parts << "**Name:** #{card['name']}"
                parts << "**Type:** #{card['type']}"
                parts << "**ID:** #{card['id']}" if card['id']
                parts << "**URL:** #{card['url']}" if card['url']
                parts << ""
                parts << "The card has been updated on the wiki."

                parts.join("\n")
              end
            end
          end
        end
      end
    end
  end
end
