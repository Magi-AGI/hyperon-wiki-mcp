# frozen_string_literal: true

require "mcp"
require "json"

module Magi
  module Archive
    module Mcp
      module Server
        module Tools
          # MCP Tool for getting wiki site context
          class GetSiteContext < ::MCP::Tool
            description "Get Magi Archive wiki structure, hierarchy, and content placement guidelines. Call this FIRST when starting work to understand where content belongs and how the wiki is organized. Essential for AI agents to navigate the wiki effectively."

            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {},
              required: []
            )

            class << self
              def call(server_context:)
                tools = server_context[:magi_tools]

                context = tools.get_site_context

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: format_context(context)
                }])
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: "Error getting site context: #{e.message}"
                }], error: true)
              end

              private

              def format_context(context)
                parts = []
                parts << "# #{context[:wiki_name]} - Site Context"
                parts << ""
                parts << "**URL:** #{context[:wiki_url]}"
                parts << "**Description:** #{context[:description]}"
                parts << ""

                # Hierarchy
                parts << "## Wiki Hierarchy"
                parts << ""
                context[:hierarchy].each do |section_name, section_data|
                  parts << "### #{section_name}"
                  parts << ""
                  parts << section_data[:description]
                  parts << ""

                  if section_data[:sections]
                    parts << "**Main Sections:**"
                    section_data[:sections].each do |subsection|
                      parts << "- #{subsection}"
                    end
                    parts << ""
                  end

                  if section_data[:games]
                    section_data[:games].each do |game|
                      parts << "#### #{game[:name]}"
                      parts << "- **Path:** `#{game[:path]}`"
                      parts << "- **Description:** #{game[:description]}"

                      if game[:sections]
                        parts << "- **Sections:** #{game[:sections].join(', ')}"
                      end

                      if game[:key_areas]
                        parts << "- **Key Areas:**"
                        game[:key_areas].each do |area_name, area_path|
                          parts << "  - #{area_name}: `#{area_path}`"
                        end
                      end
                      parts << ""
                    end
                  end

                  if section_data[:path]
                    parts << "**Path:** `#{section_data[:path]}`"
                    parts << ""
                  end
                end

                # Guidelines
                parts << "## Content Guidelines"
                parts << ""

                parts << "### Naming Conventions"
                context[:guidelines][:naming_conventions].each do |guideline|
                  parts << "- #{guideline}"
                end
                parts << ""

                parts << "### Content Placement"
                context[:guidelines][:content_placement].each do |guideline|
                  parts << "- #{guideline}"
                end
                parts << ""

                parts << "### Content Structure"
                context[:guidelines][:content_structure].each do |guideline|
                  parts << "- #{guideline}"
                end
                parts << ""

                parts << "### Special Card Types"
                context[:guidelines][:special_cards].each do |guideline|
                  parts << "- #{guideline}"
                end
                parts << ""

                parts << "### Best Practices"
                context[:guidelines][:best_practices].each do |practice|
                  parts << "- #{practice}"
                end
                parts << ""

                # Common Patterns
                parts << "## Common Naming Patterns"
                parts << ""
                context[:common_patterns].each do |pattern_name, pattern|
                  parts << "- **#{pattern_name.to_s.capitalize}:** `#{pattern}`"
                end
                parts << ""

                # Helpful Cards
                parts << "## Helpful Navigation Cards"
                parts << ""
                parts << "Start with these cards to understand the wiki structure:"
                parts << ""
                context[:helpful_cards].each do |card|
                  parts << "- `#{card}`"
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
