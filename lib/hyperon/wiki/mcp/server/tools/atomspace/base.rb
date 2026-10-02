# frozen_string_literal: true

require "mcp"
require "http"
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
              # The transport faults this toolset degrades to a clean error, named as classes
              # the gem's OWN client can raise. Client is built on the `http` gem, so
              # Errno::ECONNREFUSED / Net::OpenTimeout / Net::ReadTimeout / SocketError -- the
              # four this list used to hold -- cannot reach this file on any path. They read as
              # coverage and were none.
              #
              # Two entries cover the surface by inheritance: HTTP::ConnectionError is the
              # parent of SocketReadError / SocketWriteError / ResponseHeaderError, and
              # HTTP::TimeoutError is the parent of ConnectTimeoutError AND of
              # HttpTimeouts::BudgetExhaustedError (named there as a subclass precisely so the
              # call sites that already rescue HTTP::Error keep working).
              #
              # Deliberately NOT HTTP::Error itself. HTTP::RequestError (unsupported
              # scheme/method) and HTTP::ResponseError (state errors, redirect loops) are
              # construction and protocol bugs in our own code, and widening to the parent
              # would convert every one of them into a soothing "retry shortly".
              TRANSPORT_ERRORS = [HTTP::ConnectionError, HTTP::TimeoutError].freeze

              # One message for two different causes: the mirror failing, and this process
              # declining to START outbound work a spent dispatch budget cannot pay for
              # (BudgetExhaustedError). They are not the same event, but the agent's move is
              # the same -- retry; the next dispatch arrives with a fresh budget -- and the
              # wording says "unavailable" rather than "the mirror is down" so it does not
              # claim a remote fault we may never have observed.
              MIRROR_UNAVAILABLE = "AtomSpace mirror service unavailable; retry shortly."

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
                # Three distinct failures arrive here wearing the same class, and only two may
                # be answered. The deck puts its error code in the response's top-level
                # "error", which the client exposes as e.error_code (NOT e.details, which is
                # data["details"] and nil here); a transport fault arrives as the client's
                # WRAPPER, carrying no code at all. Surface the KNOWN Lane C terminal codes
                # structurally and a wrapped transport fault as an availability error;
                # RE-RAISE anything else (unexpected status, JSON-parse-wrapped failure,
                # genuine 5xx without our code) so JSON/schema/programming bugs fail loud
                # (Codex).
                code = e.respond_to?(:error_code) ? e.error_code : nil
                raise unless KNOWN_READ_ERRORS.include?(code) || transport_wrapped?(e)

                error_response(read_error_text(e, code))
              rescue *TRANSPORT_ERRORS
                # The UNWRAPPED form, for a caller that reaches a transport error without
                # passing through Client#request's rescue (Client#health_check and #ping have
                # no `rescue HTTP::Error`). No tool in this toolset calls those today, so this
                # is defense in depth rather than a path under test pressure from production.
                error_response(MIRROR_UNAVAILABLE)
              end

              # Whether an APIError is the client's wrapper around a transport fault.
              #
              # Client#request and #get_raw both `rescue HTTP::Error => e` and re-raise
              # `APIError, "HTTP request failed: #{e.message}"`, which keeps the original only
              # as Exception#cause: the wrapper has no status and no error_code, so by its own
              # attributes it is indistinguishable from a deck failure. Matching the cause
              # rather than the message is the point -- rewording that string must not quietly
              # turn every transport fault back into an unhandled raise.
              def self.transport_wrapped?(error)
                cause = error.cause
                TRANSPORT_ERRORS.any? { |klass| cause.is_a?(klass) }
              end

              # The body for a failure already judged answerable by .respond.
              def self.read_error_text(error, code)
                return MIRROR_UNAVAILABLE unless KNOWN_READ_ERRORS.include?(code)

                JSON.generate({ error: code, status: (error.respond_to?(:status) ? error.status : nil) }.compact)
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
