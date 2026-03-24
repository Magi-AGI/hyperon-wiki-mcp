# frozen_string_literal: true

require "mcp"

module Magi
  module Archive
    module Mcp
      module Server
        module Tools
          # MCP Tool for content rendering and format conversion
          class RenderContent < ::MCP::Tool
            description "Convert content between HTML and Markdown formats"

            annotations(
              read_only_hint: true,
              destructive_hint: false
            )

            input_schema(
              properties: {
                content: {
                  type: "string",
                  description: "Content to convert"
                },
                from_format: {
                  type: "string",
                  enum: ["html", "markdown"],
                  description: "Source format"
                },
                to_format: {
                  type: "string",
                  enum: ["html", "markdown"],
                  description: "Target format"
                },
                max_output_length: {
                  type: "integer",
                  description: "Maximum converted content length to return (default: 8000 chars). Set to 0 for unlimited.",
                  default: 8000,
                  minimum: 0
                }
              },
              required: ["content", "from_format", "to_format"]
            )

            class << self
              def call(content:, from_format:, to_format:, max_output_length: 8000, server_context:)
                tools = server_context[:magi_tools]

                # Convert format strings to symbols
                from_sym = from_format.to_sym
                to_sym = to_format.to_sym

                result = tools.convert_content(content, from: from_sym, to: to_sym)

                # Build hybrid JSON response
                response = build_response(from_format, to_format, result, max_output_length)

                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: JSON.generate(response)
                }])
              rescue StandardError => e
                ::MCP::Tool::Response.new([{
                  type: "text",
                  text: "Error rendering content: #{e.message}"
                }], error: true)
              end

              private

              def build_response(from_fmt, to_fmt, result, max_output_length)
                converted = extract_converted_content(result).to_s.strip
                total_length = converted.length
                truncated = max_output_length > 0 && converted.length > max_output_length

                output_content = truncated ? converted[0...max_output_length] : converted

                {
                  id: "content_conversion",
                  title: "Content Conversion: #{from_fmt.upcase} to #{to_fmt.upcase}",
                  converted_content: output_content,
                  text: format_result(from_fmt, to_fmt, result, max_output_length),
                  metadata: {
                    from_format: from_fmt,
                    to_format: to_fmt,
                    total_length: total_length,
                    truncated: truncated
                  }
                }
              end

              def format_result(from_fmt, to_fmt, result, max_output_length)
                # Extract the converted content from the API response hash
                converted = extract_converted_content(result).to_s.strip
                total_length = converted.length

                parts = []
                parts << "# Content Conversion"
                parts << ""
                parts << "**From:** #{from_fmt.upcase}"
                parts << "**To:** #{to_fmt.upcase}"
                parts << "**Output length:** #{total_length} characters"
                parts << ""
                # Note: Omitting original content to reduce response size (user already has it)
                parts << "## Converted Content"
                parts << ""
                parts << "```#{to_fmt}"

                if max_output_length > 0 && converted.length > max_output_length
                  parts << converted[0...max_output_length]
                  parts << "```"
                  parts << ""
                  parts << "**[Output truncated]** Showing #{max_output_length} of #{total_length} characters."
                  parts << "Use `max_output_length: 0` for full output."
                else
                  parts << converted
                  parts << "```"
                end

                parts.join("\n")
              end

              def extract_converted_content(result)
                # Handle non-hash results
                return result.to_s unless result.respond_to?(:keys)

                # Try all possible key variations
                %w[markdown html].each do |key|
                  # String key
                  val = result[key]
                  return val if val

                  # Symbol key
                  val = result[key.to_sym]
                  return val if val
                end

                # Fallback: get first non-format value
                result.each do |k, v|
                  next if k.to_s == "format"

                  return v
                end

                # Ultimate fallback
                result.to_s
              end
            end
          end
        end
      end
    end
  end
end
