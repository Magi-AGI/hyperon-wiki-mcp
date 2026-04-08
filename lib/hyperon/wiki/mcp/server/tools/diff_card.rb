# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for showing differences between card revisions
          class DiffCard < ::MCP::Tool
            # Alias Client for cleaner error handling
            Client = Hyperon::Wiki::Mcp::Client

            DESCRIPTION = <<~DESC.strip
              Show differences between card revisions.

              Compares two specific revisions, or a revision with the current
              version. Returns a unified diff with added/removed line counts.

              Use `get_card_history` first to find revision act_ids, then use
              this tool to see exactly what changed between versions.

              Typical workflow:
              1. Use `get_card_history` to list revisions and their act_ids
              2. Use `diff_card` with from_revision and/or to_revision act_ids
              3. Review the diff to understand what changed

              This is useful for:
              - Understanding what changed between two versions of a card
              - Reviewing recent edits before deciding to restore
              - Auditing content changes over time
              - Comparing a historical version with the current content

              Related tools:
              - get_card_history: List all revisions with act_ids
              - get_revision: Get full content at a specific revision
              - restore_card: Restore card to a previous state (admin only)
            DESC

            description DESCRIPTION

            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                name: {
                  type: "string",
                  description: "The name of the card to diff"
                },
                from_revision: {
                  type: "integer",
                  description: "Act ID of the earlier revision. If omitted with to_revision, " \
                               "compares oldest available revision."
                },
                to_revision: {
                  type: "integer",
                  description: "Act ID of the later revision. If omitted, compares with current content."
                }
              },
              required: ["name"]
            )

            class << self
              def call(name:, server_context:, from_revision: nil, to_revision: nil)
                tools = server_context[:magi_tools]

                result = tools.diff_card(
                  name,
                  from_revision: from_revision,
                  to_revision: to_revision
                )

                response = build_response(name, result)

                ::MCP::Tool::Response.new([{
                                            type: "text",
                                            text: JSON.generate(response)
                                          }])
              rescue Client::NotFoundError
                ::MCP::Tool::Response.new([{
                                            type: "text",
                                            text: ErrorFormatter.not_found("Card or revision", name)
                                          }], error: true)
              rescue Client::ValidationError => e
                ::MCP::Tool::Response.new([{
                                            type: "text",
                                            text: ErrorFormatter.validation_error(e.message)
                                          }], error: true)
              rescue Client::AuthorizationError => e
                required_role = e.details&.dig("required_role") || "gm"
                ::MCP::Tool::Response.new([{
                                            type: "text",
                                            text: ErrorFormatter.authorization_error(
                                              "diff revisions for", name,
                                              required_role: required_role,
                                              api_message: e.message,
                                              api_details: e.details
                                            )
                                          }], error: true)
              rescue Client::AuthenticationError => e
                ::MCP::Tool::Response.new([{
                                            type: "text",
                                            text: ErrorFormatter.authentication_error(e.message)
                                          }], error: true)
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                                            type: "text",
                                            text: ErrorFormatter.generic_error("computing diff for '#{name}'", e)
                                          }], error: true)
              end

              private

              def build_response(name, result)
                card_url = "https://wiki.hyperon.dev/#{name.to_s.gsub(" ", "_")}"

                {
                  id: name,
                  title: "Diff: #{name}",
                  source: card_url,
                  url: card_url,
                  text: format_diff(result),
                  metadata: {
                    card_name: name,
                    from: result["from"],
                    to: result["to"],
                    lines_added: result.dig("summary", "lines_added"),
                    lines_removed: result.dig("summary", "lines_removed"),
                    total_changes: result.dig("summary", "total_changes")
                  }
                }
              end

              def format_diff(result)
                parts = []
                parts << "# Diff: #{result["card"]}"
                parts << ""
                parts << "**From:** #{result["from"]}"
                parts << "**To:** #{result["to"]}"
                parts << ""

                summary = result["summary"]
                parts << "## Summary"
                parts << ""
                parts << "- **Lines added:** #{summary["lines_added"]}"
                parts << "- **Lines removed:** #{summary["lines_removed"]}"
                parts << "- **Total changes:** #{summary["total_changes"]}"
                parts << ""

                parts << "## Diff"
                parts << ""
                parts << "```diff"
                parts << result["diff"]
                parts << "```"
                parts << ""
                parts << "---"
                parts << "**Tip:** Use `get_revision` with an act_id to see the full content at that point."
                parts << "Use `restore_card` with an act_id to restore a previous version (admin only)."

                parts.join("\n")
              end
            end
          end
        end
      end
    end
  end
end
