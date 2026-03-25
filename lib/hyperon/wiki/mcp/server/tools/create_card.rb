# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for creating new cards
          class CreateCard < ::MCP::Tool
            # Alias Client for cleaner error handling
            Client = Hyperon::Wiki::Mcp::Client
            description "Create a new card in the Hyperon Wiki wiki"

            annotations(
              read_only_hint: true,
              destructive_hint: true
            )

            input_schema(
              properties: {
                name: {
                  type: "string",
                  description: "The name of the card to create (e.g., 'New Article' or 'Parent+Child')"
                },
                content: {
                  type: "string",
                  description: "The card content (HTML or plain text)"
                },
                type: {
                  type: "string",
                  description: "The card type (e.g., 'Article', 'Basic', 'RichText')",
                  default: "Basic"
                }
              },
              required: ["name"]
            )

            class << self
              def call(name:, content: nil, type: "Basic", server_context:)
                tools = server_context[:magi_tools]

                params = { type: type }
                params[:content] = content if content

                card = tools.create_card(name, **params)

                # Build hybrid JSON response
                response = build_response(card)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(response)
                }])
              rescue Client::ValidationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.validation_error(e.message)
                }], error: true)
              rescue Client::AuthorizationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authorization_error("create", name, required_role: "user")
                }], error: true)
              rescue Client::AuthenticationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authentication_error(e.message)
                }], error: true)
              rescue StandardError => e
                # Log to stderr for debugging
                $stderr.puts "ERROR in create_card: #{e.class}: #{e.message}"
                $stderr.puts e.backtrace.first(5).join("\n")

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.generic_error("creating card '#{name}'", e)
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
                  text: format_created_card(card),
                  metadata: {
                    type: card['type'],
                    card_id: card['id']
                  }.compact
                }
              end

              def format_created_card(card)
                parts = []
                parts << "# Card Created Successfully"
                parts << ""
                parts << "**Name:** #{card['name']}"
                parts << "**Type:** #{card['type']}"
                parts << "**ID:** #{card['id']}" if card['id']
                parts << "**URL:** #{card['url']}" if card['url']
                parts << ""
                parts << "The card has been created and is now available on the wiki."

                parts.join("\n")
              end
            end
          end
        end
      end
    end
  end
end
