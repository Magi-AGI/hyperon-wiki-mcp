# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Magi
  module Archive
    module Mcp
      module Server
        module Tools
          # MCP Tool for deleting cards (admin only)
          class DeleteCard < ::MCP::Tool
            # Alias Client for cleaner error handling
            Client = Magi::Archive::Mcp::Client

            DESCRIPTION = <<~DESC.strip
              Delete a card from the Magi Archive wiki (requires admin role).

              ⚠️ IMPORTANT: Before deleting, verify the card is NOT a virtual card!

              **Virtual cards** are empty junction cards that serve as hierarchy parents.
              They appear empty but are essential structure. Examples:
              - "Games+Butterfly Galaxii" (parent for game content)
              - "Business Plan+Overview" (section container)

              **Signs a card is virtual (DO NOT DELETE):**
              - Card has no content but HAS children (use list_children to check)
              - Card name contains "+" (compound/junction card)
              - Card serves as a parent in the wiki hierarchy

              **When deletion IS appropriate:**
              - Test cards created during development
              - Duplicate cards that should be consolidated
              - Cards explicitly requested for deletion by the user

              If accidentally deleted, cards can be recovered via the wiki's History tab.
            DESC

            description DESCRIPTION

            annotations(
              read_only_hint: false,
              destructive_hint: true
            )

            input_schema(
              properties: {
                name: {
                  type: "string",
                  description: "The name of the card to delete"
                },
                force: {
                  type: "boolean",
                  description: "Force delete even if card has children (DANGEROUS - may orphan child cards)",
                  default: false
                },
                i_verified_not_virtual: {
                  type: "boolean",
                  description: "Confirmation that you checked this is NOT a virtual/junction card. Set to true only after verifying the card has no children and is not part of the wiki hierarchy.",
                  default: false
                }
              },
              required: ["name"]
            )

            class << self
              def call(name:, force: false, i_verified_not_virtual: false, server_context:)
                tools = server_context[:magi_tools]

                # Check if this looks like a virtual card and warn if not confirmed
                if !i_verified_not_virtual && name.include?("+")
                  return ::MCP::Tool::Response.new([{
                    type: "text",
                    text: JSON.generate({
                      status: "blocked",
                      id: name,
                      title: "Deletion Blocked - Possible Virtual Card",
                      text: format_virtual_warning(name),
                      metadata: { reason: "virtual_card_check" }
                    })
                  }], error: true)
                end

                result = tools.delete_card(name, force: force)

                # Build hybrid JSON response
                response = build_response(name, result)

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
                  text: ErrorFormatter.authorization_error("delete", name, required_role: "admin")
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
                  text: ErrorFormatter.generic_error("deleting card '#{name}'", e)
                }], error: true)
              end

              private

              def build_response(name, _result)
                {
                  status: "success",
                  id: name,
                  title: "Card Deleted",
                  text: format_deletion(name, _result),
                  metadata: { action: "deleted" }
                }
              end

              def format_virtual_warning(name)
                parts = []
                parts << "# ⚠️ Deletion Blocked - Possible Virtual Card"
                parts << ""
                parts << "**Card:** `#{name}`"
                parts << ""
                parts << "This card name contains `+` which indicates it may be a **virtual/junction card**."
                parts << "Virtual cards are essential hierarchy parents that appear empty but structure the wiki."
                parts << ""
                parts << "## Before deleting, please verify:"
                parts << ""
                parts << "1. Use `list_children` on this card to check for child cards"
                parts << "2. If it has children, it's likely a virtual card - **DO NOT DELETE**"
                parts << "3. Check if it's part of a table-of-contents structure"
                parts << ""
                parts << "## If you're certain this should be deleted:"
                parts << ""
                parts << "Call delete_card again with `i_verified_not_virtual: true`"
                parts << ""
                parts << "```"
                parts << "delete_card(name: \"#{name}\", i_verified_not_virtual: true)"
                parts << "```"

                parts.join("\n")
              end

              def format_deletion(name, result)
                parts = []
                parts << "# Card Deleted"
                parts << ""
                parts << "**Card:** #{name}"
                parts << ""
                parts << "The card has been moved to trash."
                parts << ""
                parts << "## Recovery"
                parts << ""
                parts << "If this was a mistake, the card can be recovered:"
                parts << ""
                parts << "1. Create a new card with the same name: `#{name}`"
                parts << "2. Visit the card on the wiki"
                parts << "3. Click the **History** tab to access previous versions"
                parts << "4. Restore the desired content from history"

                parts.join("\n")
              end
            end
          end
        end
      end
    end
  end
end
