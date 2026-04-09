# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for uploading files or images to create/update File/Image cards
          class UploadFile < ::MCP::Tool
            Client = Hyperon::Wiki::Mcp::Client
            description "Upload a file or image to create or update a File/Image card. Accepts base64-encoded file data. Use this to attach documents, images, or other files to wiki cards. The card is created if it doesn't exist, or updated if it does. For images, multiple size variants (icon, small, medium, large, original) are automatically generated. To reference an uploaded image in card content, use the inclusion syntax: {{CardName|size:medium}}"
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
                file_data: {
                  type: "string",
                  description: "Base64-encoded file content"
                },
                filename: {
                  type: "string",
                  description: "Original filename with extension (e.g., 'report.pdf', 'diagram.png')"
                }
              },
              required: %w[name type file_data filename]
            )

            class << self
              def call(name:, type:, file_data:, filename:, server_context:)
                tools = server_context[:magi_tools]
                result = tools.upload_file(name, type: type, file_data: file_data, filename: filename)
                response = build_response(result, name, type, filename)

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
                  text: ErrorFormatter.generic_error("uploading file to card '#{name}'", e)
                }], error: true)
              end

              private

              def build_response(result, name, type, filename)
                card_url = "https://wiki.hyperon.dev/#{name.to_s.gsub(' ', '_')}"

                text_parts = []
                text_parts << "# File Uploaded Successfully"
                text_parts << ""
                text_parts << "**Card:** #{result['name'] || name}"
                text_parts << "**Type:** #{type}"
                text_parts << "**Filename:** #{filename}"
                text_parts << "**File URL:** #{result['file_url']}" if result["file_url"]

                if result["image_urls"]
                  text_parts << ""
                  text_parts << "**Image Variants:**"
                  result["image_urls"].each do |size, url|
                    text_parts << "- #{size}: #{url}"
                  end
                end

                text_parts << ""
                text_parts << "**Inclusion syntax:** `{{#{result['name'] || name}|size:medium}}`"

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
                    filename: filename
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
