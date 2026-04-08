# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for getting card statistics without full content
          class GetCardStats < ::MCP::Tool
            Client = Hyperon::Wiki::Mcp::Client
            description "Get statistics about a card without fetching full content. Returns word count, character count, section count, paragraph count, link count (wiki and external), and image count. Useful for assessing card size and complexity before deciding how to work with it."
            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                name: {
                  type: "string",
                  description: "The card name to get statistics for"
                }
              },
              required: ["name"]
            )

            class << self
              def call(name:, server_context:)
                tools = server_context[:magi_tools]
                result = tools.get_card_stats(name)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(format_result(result))
                }])
              rescue Client::NotFoundError
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.not_found("Card", name)
                }], error: true)
              rescue Client::AuthorizationError
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authorization_error("view", name, required_role: "user")
                }], error: true)
              rescue Client::AuthenticationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authentication_error(e.message)
                }], error: true)
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.generic_error("getting stats for card '#{name}'", e)
                }], error: true)
              end

              private

              def format_result(result)
                stats = result["stats"]
                text_parts = []
                text_parts << "# Card Stats: #{result['card']}"
                text_parts << ""
                text_parts << "**Type:** #{result['type']} | **Updated:** #{result['updated_at'] || 'unknown'}"
                text_parts << ""
                text_parts << "## Size"
                text_parts << "- **Words:** #{stats['word_count']}"
                text_parts << "- **Characters:** #{stats['char_count']}"
                text_parts << "- **Sections:** #{stats['section_count']}"
                text_parts << "- **Paragraphs:** #{stats['paragraph_count']}"
                text_parts << ""
                text_parts << "## Links & Media"
                text_parts << "- **Total links:** #{stats['link_count']}"
                text_parts << "  - Wiki links: #{stats['wiki_links']}"
                text_parts << "  - External links: #{stats['external_links']}"
                text_parts << "- **Images:** #{stats['image_count']}"

                {
                  id: result["card"],
                  title: "Stats: #{result['card']}",
                  text: text_parts.join("\n"),
                  metadata: {
                    type: result["type"],
                    updated_at: result["updated_at"],
                    word_count: stats["word_count"],
                    char_count: stats["char_count"],
                    section_count: stats["section_count"],
                    paragraph_count: stats["paragraph_count"],
                    link_count: stats["link_count"],
                    image_count: stats["image_count"]
                  }
                }
              end
            end
          end
        end
      end
    end
  end
end
