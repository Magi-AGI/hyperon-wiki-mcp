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
end
