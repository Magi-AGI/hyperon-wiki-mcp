# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Magi
  module Archive
    module Mcp
      module Server
        module Tools
          # MCP Tool for restoring cards (admin only)
          class RestoreCard < ::MCP::Tool
            # Alias Client for cleaner error handling
            Client = Magi::Archive::Mcp::Client

            DESCRIPTION = <<~DESC.strip
              Restore a card to a previous state or recover from trash (requires admin role).

              This tool can be used in two ways:

              **1. Restore to a specific revision (rollback)**
              Use `act_id` to restore the card's content to a previous version.
              The current content will be replaced with the content from that revision.
              A new revision is created recording the restore action.

              **2. Recover from trash (undelete)**
              Use `from_trash: true` to restore a deleted card.
              The card will be restored with its last content before deletion.

              **Workflow for content rollback:**
              1. Use `get_card_history` to find the revision to restore
              2. Use `get_revision` to verify it has the correct content
              3. Use `restore_card` with the act_id

              **Workflow for trash recovery:**
              1. Use `list_trash` to find the deleted card
              2. Use `restore_card` with `from_trash: true`

              **Important:**
              - This action cannot be undone directly (but creates a new revision)
              - Restoring from trash may fail if a new card with the same name exists
              - Admin role is required for all restore operations
            DESC

            description DESCRIPTION

            annotations(
              read_only_hint: false,
              destructive_hint: false # Restore is constructive, not destructive
            )

            input_schema(
              properties: {
                name: {
                  type: "string",
                  description: "The name of the card to restore"
                },
                act_id: {
                  type: "integer",
                  description: "Revision ID to restore to (from get_card_history). " \
                               "Omit this if using from_trash."
                },
                from_trash: {
                  type: "boolean",
                  description: "Set to true to restore a deleted card from trash. " \
                               "Omit act_id when using this option.",
                  default: false
                }
              },
              required: ["name"]
            )

            class << self
              def call(name:, act_id: nil, from_trash: false, server_context:)
                tools = server_context[:magi_tools]

                # Validate that at least one option is specified
                if act_id.nil? && !from_trash
                  return ::MCP::Tool::Response.new([{
                    type: "text",
                    text: format_usage_error
                  }], error: true)
                end

                result = tools.restore_card(name, act_id: act_id, from_trash: from_trash)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: format_restore_result(result, from_trash)
                }])
              rescue ArgumentError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: format_usage_error
                }], error: true)
              rescue Client::NotFoundError
                error_text = if from_trash
                               "Card '#{name}' was not found in trash. " \
                               "Use `list_trash` to see available cards."
                             else
                               "Card '#{name}' or revision #{act_id} was not found. " \
                               "Use `get_card_history` to see available revisions."
                             end
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.not_found("Card/Revision", error_text)
                }], error: true)
              rescue Client::AuthorizationError
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authorization_error("restore", name, required_role: "admin")
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
                  text: ErrorFormatter.generic_error("restoring card '#{name}'", e)
                }], error: true)
              end

              private

              def format_usage_error
                parts = []
                parts << "# ❌ Invalid Parameters"
                parts << ""
                parts << "You must specify either:"
                parts << ""
                parts << "**1. Restore to a specific revision:**"
                parts << "```"
                parts << 'restore_card(name: "CardName", act_id: 12345)'
                parts << "```"
                parts << ""
                parts << "**2. Restore from trash:**"
                parts << "```"
                parts << 'restore_card(name: "CardName", from_trash: true)'
                parts << "```"
                parts << ""
                parts << "Use `get_card_history` to find revision act_ids, or"
                parts << "`list_trash` to find deleted cards."

                parts.join("\n")
              end

              def format_restore_result(result, from_trash)
                parts = []

                if result["success"]
                  parts << "# ✅ Card Restored Successfully"
                  parts << ""
                  parts << "**Card:** #{result['card']}"
                  parts << ""

                  if from_trash
                    parts << "The card has been recovered from trash and is now active."
                  else
                    restored_from = result["restored_from"]
                    if restored_from
                      parts << "**Restored from:**"
                      parts << "- Act ID: #{restored_from['act_id']}"
                      parts << "- Date: #{restored_from['acted_at']}"
                    end
                  end

                  if result["message"]
                    parts << ""
                    parts << "**Details:** #{result['message']}"
                  end

                  parts << ""
                  parts << "---"
                  parts << ""
                  parts << "The card has been restored. A new revision has been created"
                  parts << "recording this restore action. Use `get_card` to view the"
                  parts << "restored content."
                else
                  parts << "# ⚠️ Restore May Have Issues"
                  parts << ""
                  parts << "**Card:** #{result['card']}"
                  parts << ""
                  parts << "**Message:** #{result['message'] || 'Unknown issue'}"
                  parts << ""
                  parts << "Please verify the card content with `get_card`."
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
