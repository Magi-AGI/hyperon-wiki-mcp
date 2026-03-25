# frozen_string_literal: true

require "mcp"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for getting tags (all tags or tags for a specific card)
          class GetTags < ::MCP::Tool
            description "Get all tags in the system or tags for a specific card"

            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                card_name: {
                  type: "string",
                  description: "Card name to get tags for (omit to get all tags)"
                },
                limit: {
                  type: "integer",
                  description: "Maximum number of tags to return (only for all tags)",
                  default: 100,
                  minimum: 1,
                  maximum: 500
                }
              },
              required: []
            )

            class << self
              def call(card_name: nil, limit: 100, server_context:)
                tools = server_context[:magi_tools]

                if card_name
                  tags = tools.get_card_tags(card_name)
                  response = build_card_tags_response(card_name, tags)
                  ::MCP::Tool::Response.new([{
                    type: "text",
                    text: JSON.generate(response)
                  }])
                else
                  tags = tools.get_all_tags(limit: limit)
                  response = build_all_tags_response(tags)
                  ::MCP::Tool::Response.new([{
                    type: "text",
                    text: JSON.generate(response)
                  }])
                end
              rescue Client::NotFoundError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.not_found("Card", card_name, operation: "get tags for")
                }], error: true)
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: "Error getting tags: #{e.message}"
                }], error: true)
              end

              private

              def build_card_tags_response(card_name, tags)
                card_url = "https://wiki.hyperon.dev/#{card_name.to_s.gsub(' ', '_')}"

                {
                  id: card_name,
                  title: "Tags for #{card_name}",
                  source: card_url,
                  url: card_url,
                  results: tags.map { |tag| { id: tag, title: tag } },
                  total: tags.size,
                  text: format_card_tags(card_name, tags)
                }
              end

              def build_all_tags_response(tags)
                result_items = (tags || []).map do |tag|
                  tag_name = tag.is_a?(Hash) ? tag['name'] : tag
                  { id: tag_name, title: tag_name }
                end

                {
                  id: "all_tags",
                  title: "All Tags",
                  results: result_items,
                  total: result_items.size,
                  text: format_all_tags(tags)
                }
              end

              def format_card_tags(card_name, tags)
                parts = []
                parts << "# Tags for #{card_name}"
                parts << ""

                if tags.any?
                  parts << "**#{tags.size} tags:**"
                  parts << ""
                  tags.each { |tag| parts << "- #{tag}" }
                else
                  parts << "No tags found for this card."
                end

                parts.join("\n")
              end

              def format_all_tags(tags)
                cards = tags || []

                parts = []
                parts << "# All Tags"
                parts << ""

                if cards.any?
                  parts << "**#{cards.size} tags found:**"
                  parts << ""
                  cards.each_with_index do |tag, idx|
                    parts << "#{idx + 1}. #{tag['name']}"
                  end
                else
                  parts << "No tags found in the system."
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
