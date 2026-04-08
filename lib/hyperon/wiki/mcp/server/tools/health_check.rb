# frozen_string_literal: true

require "mcp"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          # MCP Tool for checking wiki health status
          class HealthCheck < ::MCP::Tool
            description "Check if the Hyperon Wiki wiki is operational and responsive. Lightweight health check that doesn't require authentication."

            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                detailed: {
                  type: "boolean",
                  description: "Get detailed health information (default: true for full check, false for quick ping)",
                  default: true
                }
              }
            )

            class << self
              def call(detailed: true, server_context:)
                tools = server_context[:magi_tools]

                if detailed
                  health_info = tools.client.health_check
                else
                  health_info = tools.client.ping
                end

                # Build hybrid JSON response
                response = build_response(health_info, detailed)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(response)
                }])
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: format_error(e)
                }], error: true)
              end

              private

              def build_response(info, detailed)
                status = info["status"]
                is_healthy = status == "healthy" || status == "ok"

                {
                  id: "health_check",
                  title: "Wiki Health Status",
                  status: is_healthy ? "healthy" : status,
                  text: format_health_info(info, detailed),
                  metadata: {
                    timestamp: info["timestamp"],
                    version: info["version"],
                    checks: info["checks"],
                    detailed: detailed
                  }.compact
                }
              end

              def format_health_info(info, detailed)
                parts = []
                status = info["status"]

                if status == "healthy" || status == "ok"
                  parts << "✅ **Wiki Status: HEALTHY**"
                elsif status == "degraded"
                  parts << "⚠️  **Wiki Status: DEGRADED**"
                else
                  parts << "❌ **Wiki Status: UNHEALTHY**"
                end

                parts << ""
                parts << "**Checked at:** #{info['timestamp']}"

                if detailed && info["checks"]
                  parts << ""
                  parts << "**Component Status:**"
                  info["checks"].each do |component, status|
                    icon = status == "ok" ? "✓" : "✗"
                    parts << "  #{icon} #{component.capitalize}: #{status}"
                  end
                end

                if info["version"]
                  parts << ""
                  parts << "**API Version:** #{info['version']}"
                end

                parts.join("\n")
              end

              def format_error(error)
                parts = []
                parts << "❌ **Wiki Health Check Failed**"
                parts << ""
                parts << "**Error:** #{error.message}"
                parts << ""
                parts << "**Possible Causes:**"
                parts << "- Wiki server is down or unreachable"
                parts << "- Network connectivity issues"
                parts << "- Server is under maintenance"
                parts << ""
                parts << "**Troubleshooting:**"
                parts << "1. Check if https://wiki.hyperon.dev is accessible in a browser"
                parts << "2. Verify your network connection"
                parts << "3. Try again in a few moments"

                parts.join("\n")
              end
            end
          end
        end
      end
    end
  end
end
