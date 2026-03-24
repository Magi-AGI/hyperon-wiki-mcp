# frozen_string_literal: true

require "mcp"

module Magi
  module Archive
    module Mcp
      module Server
        module Tools
          # MCP Tool for creating weekly summary cards
          class CreateWeeklySummary < ::MCP::Tool
            description "Generate a weekly summary preview combining wiki card changes and repository activity. Returns markdown for review by default. Set create_card=true to post directly to wiki."

            annotations(
              read_only_hint: true,
              destructive_hint: true
            )

            input_schema(
              properties: {
                base_path: {
                  type: "string",
                  description: "Root directory to scan for git repositories (default: current directory)"
                },
                days: {
                  type: "integer",
                  description: "Number of days to look back for changes",
                  default: 7,
                  minimum: 1,
                  maximum: 365
                },
                date: {
                  type: "string",
                  description: "Date string for card name in 'YYYY MM DD' format (default: today)"
                },
                executive_summary: {
                  type: "string",
                  description: "Custom executive summary text (auto-generated if not provided)"
                },
                username: {
                  type: "string",
                  description: "Username to include in card name for attribution (default: ENV['USER'] or ENV['USERNAME'])"
                },
                create_card: {
                  type: "boolean",
                  description: "Whether to create the card on the wiki (default: false, returns markdown preview for review first)",
                  default: false
                }
              },
              required: []
            )

            class << self
              def call(base_path: nil, days: 7, date: nil, executive_summary: nil, username: nil, create_card: false, server_context:)
                tools = server_context[:magi_tools]

                # Get base path from server context if not provided
                base_path ||= server_context[:working_directory] || Dir.pwd

                params = {
                  base_path: base_path,
                  days: days,
                  create_card: create_card
                }
                params[:date] = date if date
                params[:executive_summary] = executive_summary if executive_summary
                params[:username] = username if username

                result = tools.create_weekly_summary(**params)

                if create_card
                  # Result is the created card
                  ::MCP::Tool::Response.new([{
                    type: "text",
                    text: format_created_card(result)
                  }])
                else
                  # Result is a preview hash with metadata and instructions
                  ::MCP::Tool::Response.new([{
                    type: "text",
                    text: format_preview(result)
                  }])
                end
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: "Error creating weekly summary: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
                }], error: true)
              end

              private

              def format_preview(preview)
                parts = []
                parts << "# Weekly Summary Preview"
                parts << ""
                parts << "## Card Creation Instructions"
                parts << ""
                parts << "To create this weekly summary on the wiki, use the `create_card` tool with:"
                parts << ""
                parts << "- **Card Name:** `#{preview['card_name']}`"
                parts << "- **Card Type:** `#{preview['card_type']}`"
                parts << "- **Content:** The markdown content below"
                parts << ""
                parts << "## TOC Update Instructions"
                parts << ""
                parts << "After creating the card, update the table of contents card:"
                parts << ""
                parts << "1. Fetch: `#{preview['toc_card']}`"
                parts << "2. Add this entry at the top of the `<ol>` list:"
                parts << "   ```html"
                parts << "   <li>[[#{preview['card_name']}|Weekly Work Summary #{preview['date']} - #{preview['username']}]]</li>"
                parts << "   ```"
                parts << ""
                parts << "---"
                parts << ""
                parts << "## Content Preview"
                parts << ""
                parts << preview["content"]

                parts.join("\n")
              end

              def format_created_card(card)
                parts = []
                parts << "# Weekly Summary Created Successfully"
                parts << ""
                parts << "**Card Name:** #{card['name']}"
                parts << "**Card ID:** #{card['id']}" if card['id']
                parts << "**URL:** #{card['url']}" if card['url']
                parts << ""
                parts << "The weekly summary has been created on the wiki and is ready to view."

                parts.join("\n")
              end
            end
          end
        end
      end
    end
  end
end
