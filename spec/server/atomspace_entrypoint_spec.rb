# frozen_string_literal: true

require_relative "../../lib/hyperon/wiki/mcp/server/atomspace_entrypoint"
require_relative "../../lib/hyperon/wiki/mcp/server/tools/get_card"
require_relative "../../lib/hyperon/wiki/mcp/server/tools/search_cards"

# The dedicated AtomSpace MCP entrypoint: the first place the registry's
# context-taking seams (visible_for_context / gate_for_context!) actually decide a
# list and a call.
#
# WHY A DEDICATED ENTRYPOINT AT ALL. INTEGRATION.md step 2 (Card 17184, decision
# 2026-06-08, an acceptance criterion) says the eight AtomSpace tools are registered
# ONLY in the dedicated AtomSpace toolset and NEVER in the public Hyperon Wiki MCP
# tool list -- "not filtered or otherwise". So this is not a filter bolted onto the
# public server; it is a separate list/call path whose whole tool table is the
# registry's own TOOLS.
#
# THE DENIAL SURFACE, and why it is not a 401. A request that reaches here has
# already authenticated -- rack_app's gate turned an unauthenticated request into
# HTTP 401 long before dispatch. What can still fail here is AUTHORIZATION: the
# grant this request captured may not name mcp:atomspace:read, or may have been read
# past its own deadline. Re-presenting the credential cannot fix either, so
# answering 401 ("authenticate, then retry") would be a lie. The answer is a
# JSON-RPC error inside a successful transport exchange, with a code distinct from
# the -32001 rack_app already spends on "Authentication required".
#
# THE ASYMMETRY between list and call is deliberate and inherited, not an
# oversight: Registry.visible_for_context builds the list handed to EVERY caller, so
# it drops the entry; Registry.gate_for_context! guards ONE invocation, so it denies
# that invocation. tools/list therefore filters to empty and tools/call returns the
# authorization error. Both are asserted below.
#
# WHAT THIS SPEC DOES NOT CLAIM: nothing about which principals the deck grants
# mcp:atomspace:read (owned by McpApi::AtomspaceGrants, deck repo), nothing about
# token issuance carrying a scope claim (INTEGRATION.md step 1, still open), and
# nothing about HTTP mounting. Local and offline: in-process grant results and a
# stubbed magi_tools, no client, no token fetch, no network.

RSpec.describe Hyperon::Wiki::Mcp::Server::AtomspaceEntrypoint do
  let(:entrypoint) { described_class }
  let(:registry) { Hyperon::Wiki::Mcp::Server::Tools::Atomspace::Registry }
  let(:scope) { "mcp:atomspace:read" }
  let(:now) { Time.utc(2026, 10, 1, 12, 0, 0) }

  # A magi_tools stand-in that records whether it was reached at all. A denied call
  # must not merely return an error -- it must not touch the deck.
  let(:magi_tools) { instance_double("Hyperon::Wiki::Mcp::Tools") }
  let(:server_context) { { magi_tools: magi_tools, working_directory: "/tmp" } }

  def grant_result(grant_scopes: [scope].freeze,
                   authorization_valid_until: Time.utc(2026, 10, 1, 13, 0, 0))
    Hyperon::Wiki::Mcp::Auth::GrantReadResult.new(
      verification_status: :verified, verification_error_class: nil,
      grant_scopes: grant_scopes, token_version: "fingerprint",
      credential_ref: "cred-abc", signed_exp_status: :present_numeric,
      signed_exp_value: authorization_valid_until, token_refresh_deadline: nil,
      token_hard_expiry: nil, grant_read_at: Time.utc(2026, 10, 1, 11, 59, 0),
      authorization_valid_until: authorization_valid_until,
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
  let(:expired) { session_context(grant_result(authorization_valid_until: Time.utc(2026, 10, 1, 11, 0, 0))) }

  # The local-convenience principal: trusted by deployment, holding nothing a deck
  # read produced. It is the shape rack_app's trusted_local_caller? path represents.
  let(:trusted_local) do
    Hyperon::Wiki::Mcp::RequestContext.new(
      principal_kind: :trusted_local,
      grant_read_result: Hyperon::Wiki::Mcp::Auth::GrantReadResult.not_applicable(
        grant_read_at: Time.utc(2026, 10, 1, 11, 59, 0)
      ),
      grant_source: :trusted_local_default, local_trusted: true
    )
  end

  def rpc(method, params = nil, id: 7)
    request = { jsonrpc: "2.0", id: id, method: method }
    request[:params] = params if params
    request
  end

  def handle(method, params = nil, context:, id: 7)
    entrypoint.handle(rpc(method, params, id: id), context: context,
                                                   server_context: server_context, now: now)
  end

  describe "the error contract this entrypoint introduces" do
    it "names an authorization-denied code in the JSON-RPC implementation-defined range" do
      expect(described_class::AUTHORIZATION_DENIED).to be_between(-32_099, -32_000)
    end

    # The distinction this slice exists to make: authenticated-but-unauthorized is a
    # different answer from unauthenticated, so it cannot reuse rack_app's code.
    it "keeps that code distinct from the authentication-required code rack_app returns" do
      expect(described_class::AUTHORIZATION_DENIED).not_to eq(-32_001)
    end
  end

  describe "an authenticated context whose own grant read authorizes the scope" do
    it "advertises every AtomSpace tool on tools/list" do
      response = handle("tools/list", context: granted)

      expect(response[:jsonrpc]).to eq("2.0")
      expect(response[:id]).to eq(7)
      expect(response).not_to have_key(:error)
      expect(response[:result][:tools].map { |tool| tool[:name] })
        .to eq(registry::TOOLS.map(&:name_value))
    end

    it "invokes an AtomSpace tool on tools/call and returns its content" do
      allow(magi_tools).to receive(:atomspace_space_stats).and_return({ "atoms" => 42 })

      response = handle("tools/call", { name: "space_stats", arguments: {} }, context: granted)

      expect(response[:error]).to be_nil
      expect(response[:result][:isError]).to be(false)
      expect(JSON.parse(response[:result][:content].first[:text])).to eq({ "atoms" => 42 })
      expect(magi_tools).to have_received(:atomspace_space_stats)
    end

    it "passes the call's own arguments through to the tool" do
      allow(magi_tools).to receive(:atomspace_query_atoms).and_return({ "results" => [] })

      handle("tools/call",
             { name: "query_atoms", arguments: { pattern: "(Card $x)", limit: 5 } },
             context: granted)

      expect(magi_tools).to have_received(:atomspace_query_atoms)
        .with(pattern: "(Card $x)", limit: 5, include_trash: false, wait_for_event_id: nil)
    end

    it "accepts string-keyed JSON-RPC params, as a parsed HTTP body supplies them" do
      allow(magi_tools).to receive(:atomspace_atom_types).and_return({ "types" => [] })

      response = entrypoint.handle(
        { "jsonrpc" => "2.0", "id" => 11, "method" => "tools/call",
          "params" => { "name" => "atom_types", "arguments" => {} } },
        context: granted, server_context: server_context, now: now
      )

      expect(response[:id]).to eq(11)
      expect(response[:error]).to be_nil
      expect(magi_tools).to have_received(:atomspace_atom_types)
    end
  end

  # Every shape that is not an authorized grant gets the same two answers, because
  # none of them authorizes anything.
  describe "a context that does not authorize the scope" do
    {
      "an authenticated grant that does not name the scope" => :ungranted,
      "an authenticated grant read past its authorization deadline" => :expired,
      "a trusted-local principal, which holds no granted scopes at all" => :trusted_local
    }.each do |label, context_name|
      context "with #{label}" do
        let(:denying_context) { public_send(context_name) }

        # The double is made WILLING to answer, so "never reached the deck" below is
        # a statement about the gate rather than about an unstubbed method.
        before { allow(magi_tools).to receive(:atomspace_space_stats).and_return({ "atoms" => 1 }) }

        it "advertises nothing on tools/list rather than denying the list to everybody" do
          response = handle("tools/list", context: denying_context)

          expect(response[:error]).to be_nil
          expect(response[:result][:tools]).to be_empty
        end

        it "denies tools/call with the documented authorization error" do
          response = handle("tools/call", { name: "space_stats", arguments: {} }, context: denying_context)

          expect(response[:jsonrpc]).to eq("2.0")
          expect(response[:id]).to eq(7)
          expect(response).not_to have_key(:result)
          expect(response[:error][:code]).to eq(described_class::AUTHORIZATION_DENIED)
          expect(response[:error][:message]).to eq(described_class::AUTHORIZATION_DENIED_MESSAGE)
          expect(response[:error][:data][:tool]).to eq("space_stats")
          expect(response[:error][:data][:reason]).to match(/#{Regexp.escape(scope)}/)
        end

        # A denial that still reached the deck would have leaked the read it denied.
        it "never reaches the deck on a denied call" do
          handle("tools/call", { name: "space_stats", arguments: {} }, context: denying_context)

          expect(magi_tools).not_to have_received(:atomspace_space_stats)
        end
      end
    end

    # The grant's scope list still names the scope here; the answer is still no.
    it "denies an expired grant whose scope list has not changed" do
      expect(expired.grant_read_result.grant_scopes).to include(scope)

      response = handle("tools/call", { name: "space_stats" }, context: expired)
      expect(response[:error][:code]).to eq(described_class::AUTHORIZATION_DENIED)
    end
  end

  describe "a request no context backs at all" do
    it "advertises nothing and denies the call" do
      expect(handle("tools/list", context: nil)[:result][:tools]).to be_empty

      denied = handle("tools/call", { name: "space_stats" }, context: nil)
      expect(denied[:error][:code]).to eq(described_class::AUTHORIZATION_DENIED)
      expect(denied[:error][:data][:reason]).to match(/request context/i)
    end

    it "denies a context that cannot answer an authorization question" do
      response = handle("tools/call", { name: "space_stats" }, context: Object.new)

      expect(response[:error][:code]).to eq(described_class::AUTHORIZATION_DENIED)
    end
  end

  # The other half of the dedicated-toolset decision: this entrypoint serves the
  # registry's tools and ONLY those. A public Deck tool cannot be reached through it
  # even by a fully authorized AtomSpace caller, and declares no scope of its own.
  describe "public Deck tools" do
    let(:deck_tools) do
      [Hyperon::Wiki::Mcp::Server::Tools::GetCard, Hyperon::Wiki::Mcp::Server::Tools::SearchCards]
    end

    it "declare no required scope, so nothing here can gate them" do
      deck_tools.each do |tool|
        expect(tool).not_to respond_to(:required_scope)
        expect(registry.resolve_required_scope(tool)).to be_nil
      end
    end

    it "are never advertised by the dedicated entrypoint" do
      advertised = handle("tools/list", context: granted)[:result][:tools].map { |tool| tool[:name] }

      expect(advertised).not_to include(*deck_tools.map(&:name_value))
    end

    # Unknown-tool, NOT authorization-denied: refusing to dispatch a Deck tool here
    # is a routing fact about this entrypoint's table, not a statement about what
    # the caller holds.
    it "are refused as unknown rather than denied, even for an authorized caller" do
      response = handle("tools/call", { name: "get_card", arguments: { name: "Main Page" } },
                        context: granted)

      expect(response[:error][:code]).to eq(described_class::UNKNOWN_TOOL)
      expect(response[:error][:code]).not_to eq(described_class::AUTHORIZATION_DENIED)
    end
  end

  describe "requests outside the two tool methods" do
    it "answers method-not-found" do
      response = handle("resources/list", context: granted)

      expect(response[:error][:code]).to eq(described_class::METHOD_NOT_FOUND)
    end

    it "refuses a tool name that is neither an AtomSpace tool nor anything else" do
      response = handle("tools/call", { name: "no_such_tool" }, context: granted)

      expect(response[:error][:code]).to eq(described_class::UNKNOWN_TOOL)
    end

    it "refuses a missing tool name without consulting the gate" do
      response = handle("tools/call", {}, context: granted)

      expect(response[:error][:code]).to eq(described_class::UNKNOWN_TOOL)
    end

    it "answers invalid-params for an authorized call missing a required argument" do
      response = handle("tools/call", { name: "query_atoms", arguments: {} }, context: granted)

      expect(response[:error][:code]).to eq(described_class::INVALID_PARAMS)
      expect(response[:error][:data][:missing]).to include("pattern")
    end

    # Ordering, not just outcome. An unauthorized caller must learn that it is
    # unauthorized -- not which arguments the tool it may not call would require.
    it "denies an unauthorized call before validating its arguments" do
      response = handle("tools/call", { name: "query_atoms", arguments: {} }, context: ungranted)

      expect(response[:error][:code]).to eq(described_class::AUTHORIZATION_DENIED)
      expect(response[:error][:data]).not_to have_key(:missing)
    end
  end

  describe "the default clock" do
    it "reads the current time when none is supplied" do
      live = session_context(grant_result(authorization_valid_until: Time.now + 3600))
      stale = session_context(grant_result(authorization_valid_until: Time.now - 3600))

      expect(entrypoint.handle(rpc("tools/list"), context: live, server_context: server_context)
        .dig(:result, :tools).size).to eq(registry::TOOLS.size)
      expect(entrypoint.handle(rpc("tools/list"), context: stale, server_context: server_context)
        .dig(:result, :tools)).to be_empty
    end
  end
end
