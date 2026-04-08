# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for getting or setting default content templates for card types
          class TemplateCard < ::MCP::Tool
            # Alias Client for cleaner error handling
            Client = Hyperon::Wiki::Mcp::Client

            description "Get or set the default content template for a card type. Templates define the starting content for new cards of a given type (stored in Decko's +*type+*default rule cards). Use 'get' to view current template, 'set' to create or update it. Requires appropriate write permissions for 'set' operation."

            annotations(
              read_only_hint: false,
              destructive_hint: false
            )

            input_schema(
              properties: {
                operation: {
                  type: "string",
                  enum: %w[get set],
                  description: "Operation: 'get' retrieves the current template, 'set' creates or updates it"
                },
                type_name: {
                  type: "string",
                  description: "The card type name (e.g., 'Article', 'Species', 'Draft Article')"
                },
                content: {
                  type: "string",
                  description: "Template content (required for 'set' operation). Use Markdown or HTML."
                }
              },
              required: %w[operation type_name]
            )

            class << self
              def call(operation:, type_name:, server_context:, content: nil)
                tools = server_context[:magi_tools]

                result = case operation
                         when "get"
                           handle_get(tools, type_name)
                         when "set"
                           handle_set(tools, type_name, content)
                         end

                ::MCP::Tool::Response.new([{
                                            type: "text",
                                            text: result
                                          }])
              rescue Client::AuthorizationError => e
                ::MCP::Tool::Response.new([{
                                            type: "text",
                                            text: ErrorFormatter.authorization_error(
                                              operation, "template for #{type_name}",
                                              required_role: "admin",
                                              api_message: e.message
                                            )
                                          }], error: true)
              rescue Client::AuthenticationError => e
                ::MCP::Tool::Response.new([{
                                            type: "text",
                                            text: ErrorFormatter.authentication_error(e.message)
                                          }], error: true)
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                                            type: "text",
                                            text: ErrorFormatter.generic_error(
                                              "template_card #{operation} for '#{type_name}'", e
                                            )
                                          }], error: true)
              end

              private

              def handle_get(tools, type_name)
                template = tools.get_template(type_name)
                format_get_result(template)
              end

              def handle_set(tools, type_name, content)
                return error_text("Content is required for 'set' operation") unless content && !content.strip.empty?

                tools.set_template(type_name, content: content)
                format_set_result(type_name, content)
              end

              def error_text(message)
                "Error: #{message}"
              end

              def format_get_result(template)
                parts = []
                parts << "# Template for #{template["type"]}"
                parts << ""
                parts << "**Template card:** `#{template["template_card"]}`"
                parts << "**Exists:** #{template["exists"] ? "Yes" : "No"}"
                parts << ""
                parts.concat(format_template_content(template))
                parts.join("\n")
              end

              def format_template_content(template)
                unless template["exists"]
                  return ["No template is defined for this card type.",
                          "Use the 'set' operation to create one."]
                end
                return ["Template exists but has no content."] if template["content"].strip.empty?

                ["## Content", "", template["content"]]
              end

              def format_set_result(type_name, content)
                parts = []
                parts << "# Template Updated"
                parts << ""
                parts << "**Type:** #{type_name}"
                parts << "**Template card:** `#{type_name}+*type+*default`"
                parts << "**Status:** Success"
                parts << ""
                parts << "New cards of type '#{type_name}' will now start with this template content."
                parts << ""
                parts << "## Content Set"
                parts << ""
                parts << content

                parts.join("\n")
              end
            end
          end
        end
      end
    end
  end
end
