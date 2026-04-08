# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for renaming cards (admin only)
          class RenameCard < ::MCP::Tool
            description "Rename a card in the Hyperon Wiki (requires admin role). Best practice: after renaming, check if the parent card or a sibling card has a table of contents (TOC) and update the old name to the new name. TOCs are typically on the parent card itself or a sibling like Parent+table-of-contents."

            annotations(
              read_only_hint: true,
              destructive_hint: true
            )

            input_schema(
              properties: {
                name: {
                  type: "string",
                  description: "The current name of the card to rename"
                },
                new_name: {
                  type: "string",
                  description: "The new name for the card"
                },
                update_referers: {
                  type: "boolean",
                  description: "Whether to update all references to this card in other cards (default: true)",
                  default: true
                }
              },
              required: ["name", "new_name"]
            )

            class << self
              def call(name:, new_name:, update_referers: true, server_context:)
                tools = server_context[:magi_tools]

                result = tools.rename_card(name, new_name, update_referers: update_referers)

                # Build hybrid JSON response
                response = build_response(result)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(response)
                }])
              rescue Client::NotFoundError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.not_found("Card", name)
                }], error: true)
              rescue Client::AuthorizationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authorization_error("rename", name, required_role: "admin")
                }], error: true)
              rescue Client::ValidationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.validation_error(e.message)
                }], error: true)
              rescue Client::AuthenticationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authentication_error(e.message)
                }], error: true)
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.generic_error("renaming card '#{name}'", e)
                }], error: true)
              end

              private

              def build_response(result)
                new_url = "https://wiki.hyperon.dev/#{result['new_name'].to_s.gsub(' ', '_')}"

                {
                  status: "success",
                  id: result['new_name'],
                  title: "Card Renamed",
                  source: new_url,
                  url: new_url,
                  text: format_rename(result),
                  metadata: {
                    old_name: result['old_name'],
                    new_name: result['new_name'],
                    updated_referers: result['updated_referers']
                  }
                }
              end

              def format_rename(result)
                parts = []
                parts << "# Card Renamed Successfully"
                parts << ""
                parts << "**Old Name:** #{result['old_name']}"
                parts << "**New Name:** #{result['new_name']}"
                parts << ""
                parts << "The card has been successfully renamed in the wiki."
                parts << ""

                if result['updated_referers']
                  parts << "**References Updated:** All references to the old card name in other cards have been automatically updated."
                else
                  parts << "**References Not Updated:** References to the old name in other cards were NOT updated. You may need to update them manually."
                end

                parts.join("\n")
              end
            end
          end
        end
      end
    end
  end
end
