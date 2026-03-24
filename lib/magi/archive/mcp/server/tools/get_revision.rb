# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Magi
  module Archive
    module Mcp
      module Server
        module Tools
          # MCP Tool for fetching content from a specific card revision
          class GetRevision < ::MCP::Tool
            # Alias Client for cleaner error handling
            Client = Magi::Archive::Mcp::Client

            DESCRIPTION = <<~DESC.strip
              Get content from a specific revision of a card.

              Retrieves the full card state at a specific point in time,
              identified by the act_id from the revision history. This includes:
              - Card name, type, and content at that revision
              - When the revision was created
              - Who made the change

              Typical workflow:
              1. Use `get_card_history` to see all revisions and their act_ids
              2. Use `get_revision` with the desired act_id to see the content
              3. Use `restore_card` with the act_id to restore (admin only)

              This is useful for:
              - Comparing current content with a previous version
              - Recovering lost content without a full restore
              - Reviewing what content looked like at a specific date
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
                  description: "The name of the card"
                },
                act_id: {
                  type: "integer",
                  description: "The revision act ID (from get_card_history)"
                },
                max_content_length: {
                  type: "integer",
                  description: "Maximum content length to return (default: 8000 chars). Set to 0 for unlimited.",
                  default: 8000,
                  minimum: 0
                },
                content_offset: {
                  type: "integer",
                  description: "Character offset to start content from (default: 0). Use for pagination.",
                  default: 0,
                  minimum: 0
                }
              },
              required: %w[name act_id]
            )

            class << self
              def call(name:, act_id:, max_content_length: 8000, content_offset: 0, server_context:)
                tools = server_context[:magi_tools]

                revision = tools.get_revision(name, act_id: act_id)

                # Build hybrid JSON response
                response = build_response(name, act_id, revision, max_content_length: max_content_length, content_offset: content_offset)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(response)
                }])
              rescue Client::NotFoundError
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.not_found("Revision", "#{name} (act_id: #{act_id})")
                }], error: true)
              rescue Client::AuthorizationError => e
                required_role = e.details&.dig("required_role") || "gm"
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authorization_error(
                    "view revision for", name,
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
                  text: ErrorFormatter.generic_error("fetching revision #{act_id} for '#{name}'", e)
                }], error: true)
              end

              private

              def build_response(name, act_id, revision, max_content_length:, content_offset:)
                card_url = "https://wiki.hyperon.dev/#{name.to_s.gsub(' ', '_')}"
                snapshot = revision["snapshot"] || {}
                full_content = (snapshot["content"] || "").to_s.strip
                total_length = full_content.length

                # Calculate pagination
                truncated = false
                next_offset = nil
                if content_offset < total_length && max_content_length > 0
                  remaining = full_content[content_offset..]
                  if remaining && remaining.length > max_content_length
                    truncated = true
                    next_offset = content_offset + max_content_length
                  end
                end

                {
                  id: "#{name}@#{act_id}",
                  title: "Revision #{act_id}: #{name}",
                  source: card_url,
                  url: card_url,
                  text: format_revision(revision, max_content_length: max_content_length, content_offset: content_offset),
                  metadata: {
                    act_id: revision['act_id'],
                    acted_at: revision['acted_at'],
                    actor: revision['actor'],
                    card_name: revision['card'],
                    snapshot_type: snapshot['type'],
                    total_length: total_length,
                    content_offset: content_offset,
                    truncated: truncated,
                    next_offset: next_offset
                  }.compact
                }
              end

              def format_revision(revision, max_content_length: 8000, content_offset: 0)
                parts = []
                parts << "# Revision: #{revision['card']}"
                parts << ""
                parts << "**Act ID:** #{revision['act_id']}"
                parts << "**Date:** #{revision['acted_at']}"
                parts << "**Actor:** #{revision['actor'] || 'Unknown'}"
                parts << ""

                snapshot = revision["snapshot"] || {}

                parts << "## Snapshot at this Revision"
                parts << ""
                parts << "**Name:** #{snapshot['name']}"
                parts << "**Type:** #{snapshot['type']}"
                parts << ""
                parts << "### Content"
                parts << ""

                full_content = (snapshot["content"] || "").to_s.strip
                total_length = full_content.length

                if full_content.empty?
                  parts << "(empty)"
                elsif content_offset >= total_length
                  parts << "(offset #{content_offset} exceeds content length #{total_length})"
                else
                  remaining = full_content[content_offset..]

                  if max_content_length > 0 && remaining.length > max_content_length
                    parts << remaining[0...max_content_length]
                    chars_shown_end = content_offset + max_content_length
                    next_offset = chars_shown_end

                    parts << ""
                    parts << "---"
                    parts << "**[Content paginated]** Showing characters #{content_offset + 1}-#{chars_shown_end} of #{total_length}."
                    parts << "To get next chunk: `get_revision(name: \"#{revision['card']}\", act_id: #{revision['act_id']}, content_offset: #{next_offset})`"
                  else
                    parts << remaining

                    if content_offset > 0
                      parts << ""
                      parts << "---"
                      parts << "**[Content offset]** Showing characters #{content_offset + 1}-#{total_length} of #{total_length}."
                    end
                  end
                end

                parts << ""
                parts << "---"
                parts << ""
                parts << "**To restore to this revision:** Use `restore_card` with"
                parts << "`name: \"#{revision['card']}\", act_id: #{revision['act_id']}`"
                parts << "(Requires admin role)"

                parts.join("\n")
              end
            end
          end
        end
      end
    end
  end
end
