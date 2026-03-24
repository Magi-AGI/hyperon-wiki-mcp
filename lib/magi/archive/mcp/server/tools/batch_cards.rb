# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Magi
  module Archive
    module Mcp
      module Server
        module Tools
          # MCP Tool for batch card operations (bulk create/update)
          class BatchCards < ::MCP::Tool
            # Alias Client for cleaner error handling
            Client = Magi::Archive::Mcp::Client

            description "Perform bulk create/update operations on multiple cards in a single request. Supports partial failure handling - some operations may succeed while others fail."

            annotations(
              read_only_hint: true,
              destructive_hint: true
            )

            input_schema(
              properties: {
                operations: {
                  type: "array",
                  description: "Array of card operations to perform",
                  items: {
                    type: "object",
                    properties: {
                      action: {
                        type: "string",
                        enum: ["create", "update"],
                        description: "Operation type: 'create' or 'update'"
                      },
                      name: {
                        type: "string",
                        description: "Card name (e.g., 'MyCard' or 'Parent+Child')"
                      },
                      type: {
                        type: "string",
                        description: "Card type (required for create, optional for update)"
                      },
                      content: {
                        type: "string",
                        description: "Card content (HTML or plain text)"
                      },
                      fetch_or_initialize: {
                        type: "boolean",
                        description: "For create: create if doesn't exist, update if it does (upsert behavior)"
                      }
                    },
                    required: ["action", "name"]
                  }
                },
                mode: {
                  type: "string",
                  enum: ["per_item", "transactional"],
                  description: "Execution mode: 'per_item' (default, continues on errors) or 'transactional' (all-or-nothing)",
                  default: "per_item"
                }
              },
              required: ["operations"]
            )

            class << self
              def call(operations:, mode: "per_item", server_context:)
                tools = server_context[:magi_tools]

                # Validate operations array
                return error_response("Operations array cannot be empty") if operations.empty?
                return error_response("Too many operations (max 100)") if operations.size > 100

                # Perform batch operation
                result = tools.batch_operations(operations, mode: mode)

                # Build hybrid JSON response
                response = build_response(result, mode)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(response)
                }])
              rescue Client::ValidationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.validation_error(e.message)
                }], error: true)
              rescue Client::AuthorizationError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.authorization_error("batch operations", "multiple cards", required_role: "user")
                }], error: true)
              rescue StandardError => e
                $stderr.puts "ERROR in batch_cards: #{e.class}: #{e.message}"
                $stderr.puts e.backtrace.first(5).join("\n")

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.generic_error("batch card operations", e)
                }], error: true)
              end

              private

              def build_response(result, mode)
                results = result["results"] || []
                successful = results.count { |r| r["status"] == "ok" }
                failed = results.count { |r| r["status"] == "error" }

                # Transform results to ChatGPT-compatible format
                result_items = results.map do |r|
                  card_url = r['name'] ? "https://wiki.hyperon.dev/#{r['name'].to_s.gsub(' ', '_')}" : nil
                  {
                    id: r['name'],
                    title: r['name'],
                    status: r['status'],
                    source: card_url,
                    url: card_url,
                    error: r['status'] == 'error' ? r['message'] : nil
                  }.compact
                end

                {
                  status: failed == 0 ? "success" : (successful == 0 ? "error" : "partial"),
                  results: result_items,
                  text: format_batch_result(result, mode),
                  metadata: {
                    mode: mode,
                    total: results.size,
                    successful: successful,
                    failed: failed
                  }
                }
              end

              def error_response(message)
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: "Error: #{message}"
                }], error: true)
              end

              def format_batch_result(result, mode)
                results = result["results"] || []
                successful = results.count { |r| r["status"] == "ok" }
                failed = results.count { |r| r["status"] == "error" }

                parts = []
                parts << "# Batch Operation Results"
                parts << ""
                parts << "**Mode:** #{mode}"
                parts << "**Total Operations:** #{results.size}"
                parts << "**Successful:** #{successful}"
                parts << "**Failed:** #{failed}"
                parts << ""

                if failed > 0
                  parts << "## Failed Operations"
                  parts << ""
                  results.each_with_index do |r, idx|
                    if r["status"] == "error"
                      parts << "#{idx + 1}. **#{r['name']}**"
                      parts << "   - Error: #{r['message']}"
                      parts << ""
                    end
                  end
                end

                if successful > 0
                  parts << "## Successful Operations"
                  parts << ""
                  results.each_with_index do |r, idx|
                    if r["status"] == "ok"
                      parts << "#{idx + 1}. ✓ **#{r['name']}**"
                      parts << "   - ID: #{r['id']}" if r['id']
                      parts << ""
                    end
                  end
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
