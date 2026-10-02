# frozen_string_literal: true

require_relative "../../lib/hyperon/wiki/mcp/server/atomspace_json_rpc"

# The JSON-RPC ENVELOPE layer for the dedicated AtomSpace path.
#
# AtomspaceEntrypoint.handle answers one request object and says so explicitly: batching,
# notification suppression, and request-shape validation "belong to whichever slice mounts
# this". This module is that slice's envelope half, and it exists so the mount can own those
# rules in ONE testable place instead of growing them inside rack_app's dispatch case.
#
# WHY THE RULES ARE INHERITED RATHER THAN CHOSEN. The public path reaches
# JsonRpcHandler.handle through MCP::Server#handle, so the public surface already answers an
# empty batch, a wrong `jsonrpc`, an unusable id, a non-object `params`, and an id-less
# notification in a particular way. A second path answering any of them differently would be
# a new protocol dialect on the same host, so every structural answer below is produced by
# JsonRpcHandler's OWN predicates, codes, and response builders -- not re-derived. The
# examples in "structural answers match the gem" assert that equivalence directly against
# JsonRpcHandler.handle, so a future divergence fails here rather than in production.
#
# WHY THE ENTRYPOINT IS NOT REPLACED BY JsonRpcHandler. JsonRpcHandler builds the response
# envelope itself and can only express the five standard JSON-RPC error codes (its
# RequestHandlerError mapping covers :invalid_request, :invalid_params, :parse_error and
# :internal_error). The authorization denial this toolset exists to make is -32002, which
# that mapping cannot carry at all, so the entrypoint keeps producing whole envelopes and
# this module supplies only the structure around them.
#
# ONE DELIBERATE DIFFERENCE, stated because it is a difference: a non-Hash element inside a
# batch. JsonRpcHandler maps process_request over the array unguarded, so a String element
# raises TypeError out of `request[:id]`. Answering Invalid Request -- the same code, message
# and id the gem itself uses for a non-Hash request at top level -- is a strict improvement
# that introduces no new vocabulary.
#
# Local and offline: in-process grant results and a stubbed magi_tools; no client, no token
# fetch, no network.

RSpec.describe Hyperon::Wiki::Mcp::Server::AtomspaceJsonRpc do
  let(:dispatcher) { described_class }
  let(:entrypoint) { Hyperon::Wiki::Mcp::Server::AtomspaceEntrypoint }
  let(:registry) { Hyperon::Wiki::Mcp::Server::Tools::Atomspace::Registry }
  let(:scope) { "mcp:atomspace:read" }
  let(:now) { Time.utc(2026, 10, 1, 12, 0, 0) }

  let(:magi_tools) { instance_double("Hyperon::Wiki::Mcp::Tools") }
  let(:server_context) { { magi_tools: magi_tools, working_directory: "/tmp" } }

  def grant_result(grant_scopes: [scope].freeze)
    Hyperon::Wiki::Mcp::Auth::GrantReadResult.new(
      verification_status: :verified, verification_error_class: nil,
      grant_scopes: grant_scopes, token_version: "fingerprint",
      credential_ref: "cred-abc", signed_exp_status: :present_numeric,
      signed_exp_value: Time.utc(2026, 10, 1, 13, 0, 0), token_refresh_deadline: nil,
      token_hard_expiry: nil, grant_read_at: Time.utc(2026, 10, 1, 11, 59, 0),
      authorization_valid_until: Time.utc(2026, 10, 1, 13, 0, 0),
      authorization_bound_kind: :signed_exp
    )
  end

  def session_context(grant)
    Hyperon::Wiki::Mcp::RequestContext.new(
      principal_kind: :authenticated_session, session_id: "sess-abc",
      verified_inbound_claims: { "sub" => "user:Alice" },
      grant_read_result: grant, outbound_credential_ref: grant.credential_ref,
      grant_source: :deck_verified_token, local_trusted: false, request_id: "req-0001"
    )
  end

  let(:granted) { session_context(grant_result) }
  let(:ungranted) { session_context(grant_result(grant_scopes: ["mcp:read"].freeze)) }

  def dispatch(request, context: granted)
    dispatcher.dispatch(request, context: context, server_context: server_context, now: now)
  end

  def listing(id: 1)
    { jsonrpc: "2.0", id: id, method: "tools/list" }
  end

  # The gem's own answer to the same request, with a trivial method table. Structural
  # answers must agree with this exactly; only the `result` payload may differ.
  def gem_answer(request)
    JsonRpcHandler.handle(request) { |_method, _id| ->(_params) { { ok: true } } }
  end

  describe "a single request object" do
    it "answers one request by delegating to the dedicated entrypoint" do
      response = dispatch(listing)

      expect(response[:jsonrpc]).to eq("2.0")
      expect(response[:id]).to eq(1)
      expect(response[:result][:tools].map { |tool| tool[:name] })
        .to eq(registry::TOOLS.map(&:name_value))
    end

    it "carries the entrypoint's own authorization denial through unchanged" do
      allow(magi_tools).to receive(:atomspace_space_stats).and_return({ "atoms" => 1 })

      response = dispatch({ jsonrpc: "2.0", id: 2, method: "tools/call",
                            params: { name: "space_stats", arguments: {} } },
                          context: ungranted)

      expect(response[:error][:code]).to eq(entrypoint::AUTHORIZATION_DENIED)
      expect(magi_tools).not_to have_received(:atomspace_space_stats)
    end

    it "reads a string-keyed request object, as an in-process caller may supply one" do
      response = dispatch({ "jsonrpc" => "2.0", "id" => 3, "method" => "tools/list" })

      expect(response[:id]).to eq(3)
      expect(response[:result][:tools]).not_to be_empty
    end
  end

  # Notification suppression, inherited: JsonRpcHandler's success_response and
  # error_response both answer nil when the id is nil, so an id-less request gets no
  # response at all.
  describe "an id-less notification" do
    it "produces no response" do
      expect(dispatch({ jsonrpc: "2.0", method: "tools/list" })).to be_nil
    end

    it "agrees with the gem that no response is produced" do
      request = { jsonrpc: "2.0", method: "tools/list" }

      expect(dispatch(request)).to eq(gem_answer(request))
    end

    # The work still happens -- only the answer is dropped. Same as the gem, which calls
    # the method and then discards the envelope.
    it "still performs the call it was asked to perform" do
      allow(magi_tools).to receive(:atomspace_space_stats).and_return({ "atoms" => 7 })

      dispatch({ jsonrpc: "2.0", method: "tools/call", params: { name: "space_stats", arguments: {} } })

      expect(magi_tools).to have_received(:atomspace_space_stats)
    end
  end

  describe "a batch" do
    it "answers each member in order" do
      responses = dispatch([listing(id: 1), listing(id: 2)])

      expect(responses).to be_an(Array)
      expect(responses.map { |response| response[:id] }).to eq([1, 2])
    end

    # The gem hoists a single-element batch out of its array; a mount that returned a
    # one-element array instead would be a second dialect.
    it "hoists a single-element batch out of its array" do
      response = dispatch([listing(id: 9)])

      expect(response).to be_a(Hash)
      expect(response[:id]).to eq(9)
    end

    it "drops notifications from the batch" do
      responses = dispatch([listing(id: 1), { jsonrpc: "2.0", method: "tools/list" }])

      expect(responses).to be_a(Hash)
      expect(responses[:id]).to eq(1)
    end

    it "answers nothing at all when every member is a notification" do
      expect(dispatch([{ jsonrpc: "2.0", method: "tools/list" },
                       { jsonrpc: "2.0", method: "tools/list" }])).to be_nil
    end

    # The one documented divergence: the gem raises TypeError here. The ANSWER is asserted in
    # full, not just its code -- without the guard, a String member still reaches
    # structural_refusal and falls out as Invalid Request for the wrong reason ("version must
    # be 2.0", read off a nil field), which would look identical if only the code were checked.
    it "answers Invalid Request for a non-Hash batch member rather than raising" do
      response = dispatch(["not a request"])

      expect(response).to eq(gem_answer("not a request"))
      expect(response[:error][:code]).to eq(JsonRpcHandler::ErrorCode::INVALID_REQUEST)
      expect(response[:error][:data]).to eq(described_class::NOT_A_REQUEST)
      expect { gem_answer(["not a request"]) }.to raise_error(TypeError)
    end
  end

  # Equivalence, not imitation: each of these is compared to what JsonRpcHandler itself
  # answers for the same input.
  describe "structural answers match the gem" do
    {
      "a request that is neither an array nor a hash" => "nope",
      "an empty batch" => [],
      "a wrong jsonrpc version" => { jsonrpc: "1.0", id: 1, method: "tools/list" },
      "an id that fails the id-character pattern" => { jsonrpc: "2.0", id: "bad id!", method: "tools/list" },
      "a non-string method name" => { jsonrpc: "2.0", id: 1, method: 42 },
      "a reserved rpc. method name" => { jsonrpc: "2.0", id: 1, method: "rpc.internal" },
      "params that are neither an object nor an array" =>
        { jsonrpc: "2.0", id: 1, method: "tools/list", params: "bad" }
    }.each do |label, request|
      it "answers #{label} exactly as JsonRpcHandler does" do
        expect(dispatch(request)).to eq(gem_answer(request))
      end
    end

    it "uses the gem's own id-character pattern rather than a private copy" do
      expect(described_class::ID_VALIDATION_PATTERN)
        .to equal(JsonRpcHandler::DEFAULT_ALLOWED_ID_CHARACTERS)
    end

    # ORDER, not just outcome. The gem reports only the FIRST complaint it finds, so a request
    # with two faults gets one answer -- and which one depends on the order the predicates run
    # in. Reordering them keeps every single-fault example above green while changing the answer
    # to every multi-fault request, so the ordering needs its own witness.
    {
      "a wrong version beats an unusable id" => [
        { jsonrpc: "1.0", id: "bad id!", method: "tools/list" },
        described_class::WRONG_VERSION
      ],
      "an unusable id beats an unusable method" => [
        { jsonrpc: "2.0", id: "bad id!", method: 42 },
        described_class::UNUSABLE_ID
      ],
      "an unusable method beats unusable params" => [
        { jsonrpc: "2.0", id: 1, method: "rpc.internal", params: "bad" },
        described_class::UNUSABLE_METHOD
      ]
    }.each do |label, (request, expected_data)|
      it "reports the same first complaint as the gem when #{label}" do
        response = dispatch(request)

        expect(response[:error][:data]).to eq(expected_data)
        expect(response).to eq(gem_answer(request))
      end
    end
  end

  # A structural refusal must not reach the tool table, and above all must not reach the deck.
  describe "a refused request" do
    before { allow(magi_tools).to receive(:atomspace_space_stats).and_return({ "atoms" => 1 }) }

    it "never invokes a tool" do
      dispatch({ jsonrpc: "1.0", id: 1, method: "tools/call",
                 params: { name: "space_stats", arguments: {} } })

      expect(magi_tools).not_to have_received(:atomspace_space_stats)
    end
  end
end
