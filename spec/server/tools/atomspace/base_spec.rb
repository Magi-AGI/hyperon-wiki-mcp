# frozen_string_literal: true

require_relative "../../../../lib/hyperon/wiki/mcp/server/tools/atomspace/base"

# Client errors as CLASSES (matching the gem) when the full gem isn't loaded standalone.
# The real Hyperon::Wiki::Mcp::Client::APIError exposes status/error_code/details.
unless defined?(Hyperon::Wiki::Mcp::Client)
  module Hyperon
    module Wiki
      module Mcp
        class Client
          class APIError < StandardError
            attr_reader :status, :error_code, :details
            def initialize(msg, status: nil, error_code: nil, details: nil)
              super(msg)
              @status = status
              @error_code = error_code
              @details = details
            end
          end
          class ServerError < APIError; end
          class AuthorizationError < APIError; end
          class ValidationError < APIError; end
          class NotFoundError < APIError; end
        end
      end
    end
  end
end

RSpec.describe Hyperon::Wiki::Mcp::Server::Tools::Atomspace::Base do
  client = Hyperon::Wiki::Mcp::Client

  def raise_api(klass, code, status)
    klass.new(code, status: status, error_code: code)
  end

  describe ".respond error mapping (Codex: classify on e.error_code, not e.details)" do
    it "surfaces KNOWN Lane C terminal codes as structured tool errors (never re-raised)" do
      {
        "mirror_integrity"     => [client::APIError, 409],
        "staleness_timeout"    => [client::ServerError, 503],
        "event_failed"         => [client::ServerError, 503],
        "atomspace_unavailable" => [client::ServerError, 503]
      }.each do |code, (klass, status)|
        resp = described_class.respond { raise raise_api(klass, code, status) }
        expect(resp.error?).to be(true), "#{code} should be an error response"
        body = JSON.parse(resp.content.first[:text])
        expect(body["error"]).to eq(code)
        expect(body["status"]).to eq(status)
      end
    end

    it "RE-RAISES unknown APIError/ServerError so JSON/schema/programming bugs fail loud" do
      expect { described_class.respond { raise raise_api(client::ServerError, "kaboom", 500) } }
        .to raise_error(client::APIError)
      expect { described_class.respond { raise raise_api(client::APIError, "weird", 418) } }
        .to raise_error(client::APIError)
    end

    it "returns successful payloads as a normal (non-error) response" do
      resp = described_class.respond { { ok: 1 } }
      expect(resp.error?).to be(false)
      expect(JSON.parse(resp.content.first[:text])).to eq("ok" => 1)
    end
  end

  # The transport taxonomy has to be stated against what the CLIENT actually raises, not
  # against what a plausible HTTP stack would. Client#request and #get_raw both
  # `rescue HTTP::Error => e; raise APIError, "HTTP request failed: ..."`, so no
  # connection or timeout class ever reaches a `rescue *TRANSPORT_ERRORS` on this path --
  # it arrives as an APIError carrying a nil error_code, which the KNOWN_READ_ERRORS
  # branch re-raises. These examples pin the wrapped shape, because that is the one a
  # dead AtomSpace mirror produces in production.
  describe ".respond transport failures (the client wraps every HTTP::Error as APIError)" do
    unavailable = "AtomSpace mirror service unavailable; retry shortly."

    # Raise THROUGH a rescue so Exception#cause is actually set -- constructing the
    # APIError and raising it later would attach whatever $! happened to be, i.e. nil,
    # and would not reproduce the production shape at all.
    def raise_wrapped(inner)
      raise inner
    rescue HTTP::Error => e
      raise Hyperon::Wiki::Mcp::Client::APIError, "HTTP request failed: #{e.message}"
    end

    def budget_error
      Hyperon::Wiki::Mcp::HttpTimeouts::BudgetExhaustedError
    end

    it "surfaces a wrapped connection failure as a clean error instead of propagating" do
      resp = described_class.respond { raise_wrapped(HTTP::ConnectionError.new("refused")) }

      expect(resp.error?).to be(true)
      expect(resp.content.first[:text]).to eq(unavailable)
    end

    it "surfaces a wrapped socket read failure as a clean error" do
      resp = described_class.respond { raise_wrapped(HTTP::SocketReadError.new("reset")) }

      expect(resp.error?).to be(true)
      expect(resp.content.first[:text]).to eq(unavailable)
    end

    it "surfaces a wrapped read timeout as a clean error" do
      resp = described_class.respond { raise_wrapped(HTTP::TimeoutError.new("read timed out")) }

      expect(resp.error?).to be(true)
      expect(resp.content.first[:text]).to eq(unavailable)
    end

    # BudgetExhaustedError is the dispatch deadline refusing to START outbound work, so
    # the read is unavailable to this caller even though the mirror may be perfectly
    # healthy. It takes the same response because the agent's options are the same --
    # the next dispatch carries a fresh budget -- not because we are claiming the remote
    # failed. It is an HTTP::TimeoutError subclass, so Client#request wraps it exactly
    # like any other transport fault.
    it "surfaces a wrapped dispatch-budget refusal as a clean error, not an unhandled raise" do
      resp = described_class.respond { raise_wrapped(budget_error.new("budget exhausted")) }

      expect(resp.error?).to be(true)
      expect(resp.content.first[:text]).to eq(unavailable)
    end

    it "still handles a RAW transport error, for the call sites that do not wrap" do
      [HTTP::ConnectionError.new("refused"), budget_error.new("budget exhausted")].each do |raw|
        resp = described_class.respond { raise raw }

        expect(resp.error?).to be(true), "#{raw.class} should be an error response"
        expect(resp.content.first[:text]).to eq(unavailable)
      end
    end

    it "keeps every TRANSPORT_ERRORS entry a class the client can actually raise" do
      expect(described_class::TRANSPORT_ERRORS).to all(be < HTTP::Error)
      expect(described_class::TRANSPORT_ERRORS).to include(a_kind_of(Class))
      expect(budget_error.ancestors & described_class::TRANSPORT_ERRORS).not_to be_empty
    end

    it "RE-RAISES a JSON-parse-wrapped APIError, which is a bug and not a transport fault" do
      expect do
        described_class.respond do
          JSON.parse("not json{")
        rescue JSON::ParserError => e
          raise Hyperon::Wiki::Mcp::Client::APIError, "Response parse failed: #{e.message}"
        end
      end.to raise_error(Hyperon::Wiki::Mcp::Client::APIError, /parse failed/)
    end

    it "RE-RAISES a wrapped request-construction bug (unsupported scheme), which is loud by design" do
      expect { described_class.respond { raise_wrapped(HTTP::RequestError.new("unknown scheme")) } }
        .to raise_error(Hyperon::Wiki::Mcp::Client::APIError, /unknown scheme/)
    end

    it "RE-RAISES an uncaused APIError with no error code, which is not a transport fault either" do
      expect { described_class.respond { raise Hyperon::Wiki::Mcp::Client::APIError, "Unexpected HTTP status: 399" } }
        .to raise_error(Hyperon::Wiki::Mcp::Client::APIError, /Unexpected HTTP status/)
    end

    it "still prefers the deck's structured code over the transport branch" do
      resp = described_class.respond do
        raise_wrapped(HTTP::ConnectionError.new("refused"))
      rescue Hyperon::Wiki::Mcp::Client::APIError
        raise client::ServerError.new("down", status: 503, error_code: "atomspace_unavailable")
      end

      expect(resp.error?).to be(true)
      expect(JSON.parse(resp.content.first[:text])).to eq("error" => "atomspace_unavailable", "status" => 503)
    end
  end
end
