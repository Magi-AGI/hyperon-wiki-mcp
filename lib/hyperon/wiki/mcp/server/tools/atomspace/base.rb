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
              rescue Client::ServerError, *TRANSPORT_ERRORS
                # Upstream 5xx + raw socket errors only. Deliberately NOT rescuing the
                # Client::APIError base: the client also wraps JSON-parse failures and
                # unexpected HTTP statuses as APIError, so catching it would mask schema/JSON
                # defects as transient mirror outages (Codex). If the client wraps raw
                # transport failures as a bare APIError, add a dedicated Client::TransportError
                # (shared infra, coordinate with Chris) and rescue that here instead.
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
