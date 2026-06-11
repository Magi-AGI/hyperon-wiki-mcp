# frozen_string_literal: true

require "mcp"
require "net/http"
require_relative "../../error_formatter"

module Hyperon
  module Wiki
    module Mcp
      module Server
        module Tools
          module Atomspace
            # Base for the dedicated AtomSpace read toolset. Declares the required JWT scope
            # (enforced at the gem invocation boundary AND the deck controller -- visibility
            # filtering alone is not enforcement, Gemini 1.1) and wraps each call in a NARROW
            # rescue: only auth + known transport errors degrade to a clean MCP error;
            # schema/JSON/programming bugs fail loud (Codex Finding 2).
            class Base < ::MCP::Tool
              # Extend with the gem's Client transport taxonomy during integration.
              TRANSPORT_ERRORS = [Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, SocketError].freeze

              def self.required_scope
                "mcp:atomspace:read"
              end

              # Structured Lane C terminal responses the deck controller returns by design
              # (L7/L9 contract): mirror_integrity (409), staleness_timeout / event_failed /
              # atomspace_unavailable (503). These must surface to the agent as clean errors.
              KNOWN_READ_ERRORS = %w[staleness_timeout event_failed mirror_integrity atomspace_unavailable].freeze

              def self.respond
                ::MCP::Tool::Response.new([{ type: "text", text: JSON.generate(yield) }])
              rescue Client::AuthorizationError => e
                error_response(ErrorFormatter.authorization_error("read", "atomspace", api_message: e.message))
              rescue Client::ValidationError, Client::NotFoundError => e
                error_response("AtomSpace read error: #{e.message}")
              rescue Client::APIError => e
                # ServerError (5xx) and bare APIError (e.g. 409) both arrive here. The deck puts its
                # error code in the response's top-level "error", which the client exposes as
                # e.error_code (NOT e.details, which is data["details"] and nil here). Surface the
                # KNOWN Lane C terminal codes structurally; RE-RAISE anything else (unexpected status,
                # JSON-parse-wrapped failure, genuine 5xx without our code) so JSON/schema/programming
                # bugs fail loud (Codex).
                code = e.respond_to?(:error_code) ? e.error_code : nil
                raise unless KNOWN_READ_ERRORS.include?(code)

                error_response(JSON.generate({ error: code, status: (e.respond_to?(:status) ? e.status : nil) }.compact))
              rescue *TRANSPORT_ERRORS
                error_response("AtomSpace mirror service unavailable; retry shortly.")
              end

              def self.error_response(text)
                ::MCP::Tool::Response.new([{ type: "text", text: text }], error: true)
              end
            end
          end
        end
      end
    end
  end
end
