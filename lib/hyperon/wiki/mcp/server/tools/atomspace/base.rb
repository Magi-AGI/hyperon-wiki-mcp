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
                # Client::ServerError (503) and plain APIError (e.g. 409) both arrive here. Surface
                # the KNOWN structured Lane C terminal codes; RE-RAISE anything else (unexpected
                # status, JSON-parse-wrapped failure, genuine upstream 5xx without our code) so
                # JSON / schema / programming bugs fail loud (Codex Finding 1).
                code = e.respond_to?(:details) && e.details.is_a?(Hash) ? e.details["error"] : nil
                raise unless KNOWN_READ_ERRORS.include?(code)

                error_response(JSON.generate({ error: code, event_id: e.details["event_id"],
                                               reason: e.details["reason"], _meta: e.details["_meta"] }.compact))
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
