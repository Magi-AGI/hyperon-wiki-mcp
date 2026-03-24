# frozen_string_literal: true

require "mcp"

module Magi
  module Archive
    module Mcp
      module Server
        module Tools
          # MCP Tool for suggesting tags based on card content and type
          class SuggestTags < ::MCP::Tool
            description "Suggest relevant tags for a card based on its content, name, and type. Useful for maintaining consistent tagging across the wiki."

            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                card_name: {
                  type: "string",
                  description: "Name of an existing card to analyze (will read its content)"
                },
                content: {
                  type: "string",
                  description: "Card content to analyze (alternative to card_name)"
                },
                type: {
                  type: "string",
                  description: "Card type for context-aware suggestions"
                },
                limit: {
                  type: "integer",
                  description: "Maximum number of tag suggestions",
                  default: 10,
                  minimum: 1,
                  maximum: 20
                }
              },
              required: []
            )

            class << self
              def call(card_name: nil, content: nil, type: nil, limit: 10, server_context:)
                tools = server_context[:magi_tools]

                # Get card content if card_name provided
                if card_name
                  card = tools.get_card(card_name)
                  content ||= card["content"]
                  type ||= card["type"]
                end

                return error_response("Either card_name or content must be provided") unless content

                # Extract keywords and suggest tags
                suggestions = analyze_content_for_tags(content, card_name, type, limit, tools)

                # Get existing tags for comparison if card_name provided
                existing_tags = card_name ? tools.get_card_tags(card_name) : []

                # Build hybrid JSON response
                response = build_response(suggestions, existing_tags, card_name)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(response)
                }])
              rescue Client::NotFoundError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.not_found("Card", card_name, operation: "suggest tags for")
                }], error: true)
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: "Error suggesting tags: #{e.message}"
                }], error: true)
              end

              private

              def build_response(suggestions, existing_tags, card_name)
                result_items = suggestions.map do |tag|
                  {
                    id: tag,
                    title: tag,
                    status: existing_tags.include?(tag) ? "already_tagged" : "suggested"
                  }
                end

                card_url = card_name ? "https://wiki.hyperon.dev/#{card_name.to_s.gsub(' ', '_')}" : nil

                {
                  id: card_name || "tag_suggestions",
                  title: card_name ? "Tag Suggestions for #{card_name}" : "Tag Suggestions",
                  source: card_url,
                  url: card_url,
                  results: result_items,
                  total: suggestions.size,
                  text: format_suggestions(suggestions, existing_tags, card_name),
                  metadata: {
                    existing_tags: existing_tags
                  }.compact
                }.compact
              end

              def error_response(message)
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: "Error: #{message}"
                }], error: true)
              end

              def analyze_content_for_tags(content, name, type, limit, tools)
                suggestions = []

                # Get all existing tags from the wiki for matching
                begin
                  all_tags = tools.get_all_tags(limit: 500)
                  existing_tag_names = all_tags.map { |t| t["name"] || t }.uniq
                rescue StandardError => e
                  # If we can't get tags, fall back to keyword extraction
                  $stderr.puts "Warning: Could not fetch existing tags: #{e.message}"
                  existing_tag_names = []
                end

                # Extract keywords from content
                keywords = extract_keywords(content)

                # Match keywords against existing tags (case-insensitive)
                matched_tags = []
                keywords.each do |keyword|
                  matching = existing_tag_names.find { |tag| tag.downcase.include?(keyword.downcase) || keyword.downcase.include?(tag.downcase) }
                  matched_tags << matching if matching
                end

                suggestions.concat(matched_tags.compact.uniq)

                # Add hierarchy-based tags from name
                if name && name.include?("+")
                  parts = name.split("+")
                  # Check if parent card name matches existing tags
                  parts.each do |part|
                    matching = existing_tag_names.find { |tag| tag.downcase == part.downcase }
                    suggestions << matching if matching
                  end
                end

                # Add the card type name itself if it exists as a tag
                if type
                  type_match = existing_tag_names.find { |tag| tag.downcase == type.downcase }
                  suggestions << type_match if type_match
                end

                # If we still don't have enough suggestions, try exact keyword matches
                if suggestions.size < limit
                  remaining = limit - suggestions.size
                  keyword_matches = keywords.map { |kw|
                    existing_tag_names.find { |tag| tag.downcase == kw.downcase }
                  }.compact
                  suggestions.concat(keyword_matches.first(remaining))
                end

                # Return unique suggestions up to limit
                suggestions.uniq.first(limit)
              end

              def extract_keywords(content)
                # Extract capitalized words and phrases (likely proper nouns/concepts)
                words = content.to_s.scan(/\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)*\b/)
                                    .map(&:strip)
                                    .select { |w| w.length > 2 }
                                    .uniq

                # Score words by frequency
                word_freq = words.group_by(&:itself).transform_values(&:count)
                word_freq.sort_by { |_, count| -count }.map(&:first)
              end

              def format_suggestions(suggestions, existing_tags, card_name)
                parts = []

                if card_name
                  parts << "# Tag Suggestions for '#{card_name}'"
                else
                  parts << "# Tag Suggestions"
                end
                parts << ""

                if existing_tags.any?
                  parts << "**Current Tags:** #{existing_tags.join(', ')}"
                  parts << ""
                end

                parts << "**Suggested Tags:**"
                parts << ""

                if suggestions.any?
                  suggestions.each_with_index do |tag, idx|
                    status = existing_tags.include?(tag) ? "✓ (already tagged)" : "+"
                    parts << "#{idx + 1}. #{tag} #{status}"
                  end
                else
                  parts << "No tag suggestions generated."
                  parts << ""
                  parts << "**Tip:** Content may need more specific terminology or the card type may benefit from manual tag selection."
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
