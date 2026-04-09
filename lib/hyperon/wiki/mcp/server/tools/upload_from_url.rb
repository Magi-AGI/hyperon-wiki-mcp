# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for creating file/image cards from a remote URL
          class UploadFromUrl < ::MCP::Tool
            Client = Hyperon::Wiki::Mcp::Client
            description "Create a file or image card from a remote URL. Downloads the file server-side and stores it on the wiki. WARNING: This blocks the single-threaded Decko server during download — prefer upload_file with base64-encoded data for reliability. Only use this for small files from fast, reliable URLs."
            annotations(
              read_only_hint: false,
              destructive_hint: false
            )

            input_schema(
              properties: {
                name: {
                  type: "string",
                  description: "Card name for the file/image"
                },
                type: {
                  type: "string",
                  description: "Card type",
                  enum: %w[File Image]
                },
                url: {
                  type: "string",
                  description: "URL to download the file from"
                }
              },
              required: %w[name type url]
            )

            class << self
              def call(name:, type:, url:, server_context:)
                tools = server_context[:magi_tools]
                result = tools.upload_from_url(name, type: type, url: url)
                response = build_response(result, name, type, url)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(response)
                }])
              rescue Client::NotFoundError
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.not_found("Card", name)
                }], error: true)
              rescue Client::ValidationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.validation_error(e.message)
                }], error: true)
              rescue Client::AuthorizationError
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authorization_error("upload", name, required_role: "user")
                }], error: true)
              rescue Client::AuthenticationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authentication_error(e.message)
                }], error: true)
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.generic_error("uploading file from URL to card '#{name}'", e)
                }], error: true)
              end

              private

              def build_response(result, name, type, source_url)
                card_url = "https://wiki.hyperon.dev/#{name.to_s.gsub(' ', '_')}"

                text_parts = []
                text_parts << "# File Uploaded from URL Successfully"
                text_parts << ""
                text_parts << "**Card:** #{result['name'] || name}"
                text_parts << "**Type:** #{type}"
                text_parts << "**Source URL:** #{source_url}"
                text_parts << "**File URL:** #{result['file_url']}" if result["file_url"]

                if result["image_urls"]
                  text_parts << ""
                  text_parts << "**Image Variants:**"
                  result["image_urls"].each do |size, url|
                    text_parts << "- #{size}: #{url}"
                  end
                end

                {
                  status: "success",
                  id: result["name"] || name,
                  title: result["name"] || name,
                  source: card_url,
                  url: card_url,
                  text: text_parts.join("\n"),
                  metadata: {
                    type: type,
                    card_id: result["id"],
                    file_url: result["file_url"],
                    image_urls: result["image_urls"],
                    source_url: source_url
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
