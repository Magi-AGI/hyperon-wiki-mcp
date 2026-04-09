# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for getting download URLs for File/Image cards
          class GetFileUrl < ::MCP::Tool
            Client = Hyperon::Wiki::Mcp::Client
            description "Get the download URL for a File or Image card. For images, returns URLs for all size variants (icon, small, medium, large, original). Use this to get direct links to uploaded files for embedding or sharing."
            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                name: {
                  type: "string",
                  description: "Card name of the File or Image card"
                },
                size: {
                  type: "string",
                  description: "For Image cards: which size variant URL to highlight (all variants are always returned)",
                  enum: %w[icon small medium large original]
                }
              },
              required: ["name"]
            )

            class << self
              def call(name:, size: nil, server_context:)
                tools = server_context[:magi_tools]
                result = tools.get_file_url(name, size: size)
                response = build_response(result, name, size)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(response)
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
                  text: ErrorFormatter.generic_error("getting file URL for card '#{name}'", e)
                }], error: true)
              end

              private

              def build_response(result, name, size)
                text_parts = []
                text_parts << "# File URL: #{result['name'] || name}"
                text_parts << ""
                text_parts << "**File URL:** #{result['file_url']}" if result["file_url"]

                if result["image_urls"]
                  text_parts << ""
                  text_parts << "**Image Variants:**"
                  result["image_urls"].each do |variant, url|
                    marker = (size && variant == size) ? " <-- selected" : ""
                    text_parts << "- #{variant}: #{url}#{marker}"
                  end
                end

                if result["selected_url"]
                  text_parts << ""
                  text_parts << "**Selected (#{size}):** #{result['selected_url']}"
                end

                {
                  id: result["name"] || name,
                  title: "File URL: #{result['name'] || name}",
                  text: text_parts.join("\n"),
                  metadata: {
                    file_url: result["file_url"],
                    image_urls: result["image_urls"],
                    selected_url: result["selected_url"],
                    size: size
                  }.compact
                }
              end
            end
          end
        end
      end
    end
  end
end
