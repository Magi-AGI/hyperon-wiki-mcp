# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for searching cards in the wiki
          class SearchCards < ::MCP::Tool
            # Alias Client for cleaner error handling
            Client = Hyperon::Wiki::Mcp::Client
            description "Search for cards in the Hyperon Wiki wiki by query, type, or other filters. Supports searching in card names, content, or both."

            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                query: {
                  type: "string",
                  description: "Search query (substring match, case-insensitive). Example: 'Butterfly' finds 'Games+Butterfly Galaxii', 'neural lace' finds cards containing that term."
                },
                type: {
                  type: "string",
                  description: "Filter by card type (e.g., 'Article', 'Basic', 'Species')"
                },
                search_in: {
                  type: "string",
                  description: "Where to search: 'name' (default, fastest - searches card names only), 'content' (slower - searches card content only), or 'both' (comprehensive - searches both names and content)",
                  enum: ["name", "content", "both"],
                  default: "name"
                },
                limit: {
                  type: "integer",
                  description: "Maximum number of results to return (default: 20 for faster responses)",
                  default: 20,
                  minimum: 1,
                  maximum: 100
                },
                offset: {
                  type: "integer",
                  description: "Number of results to skip (for pagination)",
                  default: 0,
                  minimum: 0
                },
                include_virtual: {
                  type: "boolean",
                  description: "Include virtual cards (empty junction cards with no content) in results. Default: false (filters them out).",
                  default: false
                }
              }
            )

            class << self
              def call(query: nil, type: nil, search_in: nil, limit: 20, offset: 0, include_virtual: false, server_context:)
                tools = server_context[:magi_tools]

                params = { limit: limit, offset: offset, include_virtual: include_virtual }
                params[:q] = query if query
                params[:type] = type if type
                params[:search_in] = search_in if search_in

                # Log search parameters for debugging
                $stderr.puts "search_cards: q=#{query.inspect}, type=#{type.inspect}, search_in=#{search_in.inspect}, limit=#{limit}, offset=#{offset}, include_virtual=#{include_virtual}"

                results = tools.search_cards(**params)

                # Log result count
                total = results["total"] || 0
                returned = (results["cards"] || []).size
                $stderr.puts "search_cards results: returned #{returned} of #{total} total"

                # Build hybrid JSON response
                response = build_response(results)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(response)
                }])
              rescue Client::AuthorizationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authorization_error("search", "cards", required_role: "user")
                }], error: true)
              rescue Client::AuthenticationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authentication_error(e.message)
                }], error: true)
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.generic_error("searching cards", e)
                }], error: true)
              end

              private

              def build_response(results)
                cards = results["cards"] || []
                total = results["total"] || 0
                offset = results["offset"] || 0
                next_offset = results["next_offset"]

                # Transform to ChatGPT-compatible results array
                result_items = cards.map do |card|
                  card_url = "https://wiki.hyperon.dev/#{card['name'].to_s.gsub(' ', '_')}"
                  {
                    id: card['name'],
                    title: card['name'],
                    snippet: "#{card['type']} card#{card['updated_at'] ? " - Updated: #{card['updated_at']}" : ''}",
                    source: card_url,
                    url: card_url
                  }
                end

                {
                  results: result_items,
                  total: total,
                  offset: offset,
                  next_offset: next_offset,
                  text: format_results(results)
                }.compact
              end

              def format_results(results)
                cards = results["cards"] || []
                total = results["total"] || 0
                offset = results["offset"] || 0
                next_offset = results["next_offset"]

                parts = []
                parts << "# Search Results"
                parts << ""
                parts << "Found #{total} total cards, showing #{cards.size} starting at offset #{offset}"
                parts << ""

                if cards.any?
                  cards.each_with_index do |card, idx|
                    parts << "#{offset + idx + 1}. **#{card['name']}** (#{card['type']})"
                    parts << "   ID: #{card['id']}, Updated: #{card['updated_at']}" if card['updated_at']
                  end
                else
                  parts << "No cards found matching the search criteria."
                end

                if next_offset
                  parts << ""
                  parts << "---"
                  parts << "More results available. Use offset: #{next_offset} to fetch next page."
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
