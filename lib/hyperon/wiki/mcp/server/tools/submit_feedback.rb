# frozen_string_literal: true

require "mcp"
require_relative "../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for AI agents to submit feedback
          class SubmitFeedback < ::MCP::Tool
            Client = Hyperon::Wiki::Mcp::Client
            description "Submit feedback about the MCP tools or wiki. Logs feedback to a card on the wiki for developers to review. Use this to report bugs, suggest improvements, or note usability issues you encounter."
            annotations(
              read_only_hint: false,
              destructive_hint: false
            )

            input_schema(
              properties: {
                category: {
                  type: "string",
                  description: "Feedback category",
                  enum: %w[bug feature_request usability performance other]
                },
                message: {
                  type: "string",
                  description: "The feedback message describing the issue or suggestion"
                },
                tool_name: {
                  type: "string",
                  description: "Which MCP tool prompted this feedback (optional)"
                }
              },
              required: %w[category message]
            )

            output_schema(
              properties: {
                status: { type: "string" },
                text: { type: "string" },
                metadata: { type: "object" }
              }
            )

            class << self
              def call(category:, message:, tool_name: nil, server_context:)
                tools = server_context[:magi_tools]
                tools.submit_feedback(category: category, message: message, tool_name: tool_name)

                feedback_result = {
                  status: "success",
                  text: "Feedback submitted. Thank you for helping improve the MCP tools.",
                  metadata: { category: category, tool_name: tool_name }.compact
                }
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(feedback_result)
                }], structured_content: feedback_result)
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: ErrorFormatter.generic_error("submitting feedback", e)
                }], error: true)
              end
            end
          end
        end
      end
    end
  end
end
