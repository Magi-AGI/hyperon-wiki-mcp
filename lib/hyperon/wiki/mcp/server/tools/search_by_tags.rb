# frozen_string_literal: true

require "mcp"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for searching cards by tags
          class SearchByTags < ::MCP::Tool
            description "Search for cards by tags with AND or OR logic"

            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                tags: {
                  type: "array",
                  items: { type: "string" },
                  description: "List of tags to search for"
                },
                match_mode: {
                  type: "string",
                  enum: ["all", "any"],
                  description: "Match mode: 'all' (AND logic) or 'any' (OR logic)",
                  default: "all"
                },
                limit: {
                  type: "integer",
                  description: "Maximum number of results",
                  default: 50,
                  minimum: 1,
                  maximum: 100
                }
              },
              required: ["tags"]
            )

            class << self
              def call(tags:, match_mode: "all", limit: 50, server_context:)
                tools = server_context[:magi_tools]

                results = if match_mode == "any"
                           tools.search_by_tags_any(tags, limit: limit)
                         else
                           tools.search_by_tags(tags, limit: limit)
                         end

                # Build hybrid JSON response
                response = build_response(tags, match_mode, results)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(response)
                }])
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: "Error searching by tags: #{e.message}"
                }], error: true)
              end

              private

              def build_response(tags, match_mode, results)
                cards = results["cards"] || []
                total = results["total"] || 0

                # Transform to ChatGPT-compatible results array
                result_items = cards.map do |card|
                  card_url = "https://wiki.hyperon.dev/#{card['name'].to_s.gsub(' ', '_')}"
                  {
                    id: card['name'],
                    title: card['name'],
                    snippet: card['type'],
                    source: card_url,
                    url: card_url
                  }
                end

                {
                  results: result_items,
                  total: total,
                  text: format_results(tags, match_mode, results),
                  metadata: {
                    tags: tags,
                    match_mode: match_mode
                  }
                }
              end

              def format_results(tags, match_mode, results)
                cards = results["cards"] || []
                total = results["total"] || 0

                parts = []
                parts << "# Search Results by Tags"
                parts << ""
                parts << "**Tags:** #{tags.join(', ')}"
                parts << "**Match Mode:** #{match_mode == 'any' ? 'ANY (OR)' : 'ALL (AND)'}"
                parts << "**Found:** #{total} cards"
                parts << ""

                if cards.any?
                  cards.each_with_index do |card, idx|
                    parts << "#{idx + 1}. **#{card['name']}** (#{card['type']})"
                  end
                else
                  parts << "No cards found with the specified tags."
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
