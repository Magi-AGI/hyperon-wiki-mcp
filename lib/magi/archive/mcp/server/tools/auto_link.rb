# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Magi
  module Archive
    module Mcp
      module Server
        module Tools
          # MCP Tool for discovering and applying wiki links in card content
          class AutoLink < ::MCP::Tool
            # Alias Client for cleaner error handling
            Client = Magi::Archive::Mcp::Client

            description "Analyze card content and suggest or apply wiki links. Scans content for terms matching existing card names within the same scope (top 2 left parts of the hierarchy). Useful for cross-referencing content and building wiki interconnectedness. GM or Admin role required."

            annotations(
              read_only_hint: false,
              destructive_hint: false
            )

            input_schema(
              properties: {
                card_name: {
                  type: "string",
                  description: "The name of the card to analyze for potential links"
                },
                mode: {
                  type: "string",
                  enum: %w[suggest apply],
                  description: "Mode: 'suggest' to preview potential links without changes, 'apply' to update the card with links",
                  default: "suggest"
                },
                dry_run: {
                  type: "boolean",
                  description: "If true, show preview of changes without saving (applies to 'apply' mode). Default: true",
                  default: true
                },
                scope: {
                  type: "string",
                  description: "Scope for term matching (default: derived from card name's top 2 left parts, e.g., 'Games+Butterfly Galaxii')"
                },
                min_term_length: {
                  type: "integer",
                  description: "Minimum term length to consider as a potential link (default: 3)",
                  default: 3,
                  minimum: 2,
                  maximum: 50
                },
                include_types: {
                  type: "array",
                  items: { type: "string" },
                  description: "Only link to cards of these types (e.g., ['RichText', 'Article']). If not specified, all card types are considered."
                }
              },
              required: ["card_name"]
            )

            class << self
              def call(card_name:, mode: "suggest", dry_run: true, scope: nil, min_term_length: 3, include_types: nil, server_context:)
                tools = server_context[:magi_tools]

                # Build request payload
                payload = {
                  card_name: card_name,
                  mode: mode,
                  dry_run: dry_run,
                  min_term_length: min_term_length
                }
                payload[:scope] = scope if scope
                payload[:include_types] = include_types if include_types

                # Call the auto_link endpoint
                result = tools.client.post("/auto_link", **payload)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: format_result(result, mode, dry_run)
                }])
              rescue Client::AuthorizationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: "**Permission Denied**\n\nAuto-link requires GM or Admin role.\n\nYour current role does not have permission to analyze or modify card links."
                }], error: true)
              rescue Client::NotFoundError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: format_not_found_error(card_name)
                }], error: true)
              rescue Client::ValidationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.validation_error(e.message)
                }], error: true)
              rescue StandardError => e
                $stderr.puts "ERROR in auto_link: #{e.class}: #{e.message}"
                $stderr.puts e.backtrace.first(5).join("\n")

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.generic_error("auto link analysis", e)
                }], error: true)
              end

              private

              def format_not_found_error(card_name)
                parts = []
                parts << "**Card Not Found**"
                parts << ""
                parts << "**Searched for:** `#{card_name}`"
                parts << ""
                parts << "The card does not exist. Please check:"
                parts << "- Card name spelling and case sensitivity"
                parts << "- Full hierarchical path (e.g., 'Parent+Child+CardName')"
                parts << ""
                parts << "Use `search_cards(q: \"keyword\")` to find the correct card name."
                parts.join("\n")
              end

              def format_result(result, mode, dry_run)
                parts = []
                suggestions = result["suggestions"] || []
                stats = result["stats"] || {}
                scope = result["scope"]

                # Header
                if mode == "suggest"
                  parts << "# Auto-Link Suggestions"
                elsif dry_run
                  parts << "# Auto-Link Preview (Dry Run)"
                else
                  parts << "# Auto-Link Applied"
                end

                parts << ""
                parts << "**Card:** `#{result['card_name']}`"
                parts << "**Scope:** `#{scope}`"
                parts << ""

                # Stats
                parts << "## Statistics"
                parts << "- Terms in scope index: #{stats['terms_in_index'] || 0}"
                parts << "- Suggestions found: #{stats['suggestions_found'] || suggestions.size}"
                parts << "- Unique cards referenced: #{stats['unique_cards_referenced'] || 0}"
                parts << ""

                if suggestions.empty?
                  parts << "**No link suggestions found.**"
                  parts << ""
                  parts << "This could mean:"
                  parts << "- The content is already well-linked"
                  parts << "- No matching card names were found in the scope"
                  parts << "- All potential terms are too short (min length: #{result['min_term_length'] || 3})"
                else
                  # List suggestions
                  parts << "## Suggested Links (#{suggestions.size})"
                  parts << ""

                  suggestions.each_with_index do |suggestion, idx|
                    term = suggestion["term"]
                    matching_card = suggestion["matching_card"]
                    context = suggestion["context"]

                    parts << "#{idx + 1}. **#{term}** -> `#{matching_card}`"
                    parts << "   _Context:_ #{truncate_context(context)}" if context
                    parts << ""
                  end

                  # Preview section
                  if result["preview"] && dry_run
                    parts << "---"
                    parts << ""
                    parts << "## Content Preview"
                    parts << ""
                    parts << "```html"
                    parts << truncate_preview(result["preview"])
                    parts << "```"
                    parts << ""
                  end

                  # Next steps
                  parts << "---"
                  parts << ""
                  if mode == "suggest"
                    parts << "## Next Steps"
                    parts << ""
                    parts << "To apply these links, run:"
                    parts << "```"
                    parts << "auto_link(card_name: \"#{result['card_name']}\", mode: \"apply\", dry_run: false)"
                    parts << "```"
                  elsif dry_run
                    parts << "## Apply Changes"
                    parts << ""
                    parts << "This was a dry run. To apply these links, run:"
                    parts << "```"
                    parts << "auto_link(card_name: \"#{result['card_name']}\", mode: \"apply\", dry_run: false)"
                    parts << "```"
                  else
                    parts << "**#{result['applied'] || suggestions.size} links have been applied to the card.**"
                  end
                end

                parts.join("\n")
              end

              def truncate_context(context, max_length = 100)
                return "" unless context

                if context.length > max_length
                  context[0...max_length] + "..."
                else
                  context
                end
              end

              def truncate_preview(preview, max_length = 1000)
                return "" unless preview

                if preview.length > max_length
                  preview[0...max_length] + "\n... (truncated)"
                else
                  preview
                end
              end
            end
          end
        end
      end
    end
  end
end
