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

              def self.respond
                ::MCP::Tool::Response.new([{ type: "text", text: JSON.generate(yield) }])
              rescue Client::AuthorizationError => e
                error_response(ErrorFormatter.authorization_error("read", "atomspace", api_message: e.message))
              rescue Client::ValidationError, Client::NotFoundError => e
                error_response("AtomSpace read error: #{e.message}")
              rescue Client::ServerError, Client::APIError, *TRANSPORT_ERRORS
                # 5xx, exhausted-retry transport failures (the client wraps these as APIError),
                # and raw socket errors. NARROW: schema / JSON / programming errors are NOT
                # rescued and fail loud in tests (Codex Finding 2).
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
