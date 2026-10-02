# frozen_string_literal: true

# The dedicated AtomSpace toolset, served over HTTP for the first time.
#
# INTEGRATION.md step 6, with the four decisions it was blocked on taken:
#   (a) a new PATH on the existing host -- POST /mcp/atomspace -- not a new host or port, so
#       HostAuthorization::ALLOWED_HOSTS and the nginx story are untouched;
#   (b) served by Server::AtomspaceJsonRpc over Server::AtomspaceEntrypoint, NOT a second
#       MCP::Server. A second server would reintroduce the shared-mutable server_context
#       problem DISPATCH_LOCK exists to solve, for a second server with its own lock;
#   (c) stdio stays out of scope: bin/mcp-server has no Bearer token, no session, and no
#       read_grant, so it has no RequestContext to pass;
#   (d) nothing advertises the path yet -- not handle_root's `endpoints`, not any
#       /.well-known document -- because the deck-side mcp:atomspace:read grant is not real
#       yet and advertising a path no principal can use is an invitation to a 403 loop.
#
# WHAT THIS FILE PINS, and why each has a plausible wrong implementation:
#
#   * The path dispatches to the dedicated entrypoint and NOT to the shared MCP::Server. The
#     wrong implementation routes /mcp/atomspace through handle_mcp_message, which would make
#     the dedicated toolset a filter on the public server's table -- exactly what Card 17184
#     forbids.
#   * An authenticated request's own RequestContext reaches the entrypoint. Without it every
#     call is denied, so the mount would "work" while authorizing nothing; with a context
#     built from the wrong principal it would authorize the wrong credential.
#   * tools/list filters by the grant, tools/call denies by the grant -- the asymmetry the
#     registry established, now observable over HTTP.
#   * An authenticated-but-unauthorized call is HTTP 200 carrying JSON-RPC -32002. 403 would
#     be a transport claim about an exchange that succeeded; 401 would tell a client to
#     re-present a credential that is already valid.
#   * Unauthenticated requests follow the EXISTING gate: 401, -32001, WWW-Authenticate, and
#     no grant read. The new path must not become the hole the 2026-06-14 incident opened.
#   * Public Deck paths are untouched: POST /mcp still reaches the shared server, /health and
#     / still answer exactly as before.
#
# Local and offline: a real Auth::GrantReadResult and Auth::CredentialRef built directly (no
# JWKS, no Decko, no OAuth flow), verifying doubles for the token issuer, credential store,
# Tools, Client and Auth, and a stateful MCP::Server double that records whether the shared
# server was touched at all.

require "spec_helper"
require "hyperon/wiki/mcp"
require "hyperon/wiki/mcp/rack_app"
require "hyperon/wiki/mcp/oauth/token_issuer"
require "hyperon/wiki/mcp/oauth/credential_store"
require "hyperon/wiki/mcp/oauth/client_cards"

RSpec.describe Hyperon::Wiki::Mcp::RackApp, "AtomSpace mount" do
  let(:app) { described_class.new }
  let(:mcp_server) { instance_double("MCP::Server") }
  let(:entrypoint) { Hyperon::Wiki::Mcp::Server::AtomspaceEntrypoint }
  let(:registry) { Hyperon::Wiki::Mcp::Server::Tools::Atomspace::Registry }
  let(:atomspace_path) { "/mcp/atomspace" }
  let(:scope) { "mcp:atomspace:read" }

  let(:session_id) { "session-jti-0001" }
  let(:access_token) { "access-token-not-a-real-jwt" }
  let(:verified_claims) do
    { "sub" => "alice@example.test", "role" => "gm", "jti" => session_id,
      "iss" => "https://mcp.hyperon.dev", "iat" => 1_800_000_000, "exp" => 1_800_003_600 }
  end

  let(:per_user_auth) { instance_double(Hyperon::Wiki::Mcp::Auth, "per-user Auth") }
  let(:per_user_client) { instance_double(Hyperon::Wiki::Mcp::Client, "per-user Client", auth: per_user_auth) }
  let(:per_user_tools) do
    instance_double(Hyperon::Wiki::Mcp::Tools, "per-user Tools", client: per_user_client)
  end

  let(:read_at) { Time.now }
  let(:credential_ref) { Hyperon::Wiki::Mcp::Auth::CredentialRef.new("synthetic-deck-token-not-a-jwt") }

  # A verified deck grant shaped exactly as Auth#read_grant returns one. The deadline is
  # relative to the real clock because the mount reads the live clock: the entrypoint's `now:`
  # default is the only clock an HTTP request has.
  def grant(grant_scopes)
    Hyperon::Wiki::Mcp::Auth::GrantReadResult.new(
      verification_status: :verified, verification_error_class: nil,
      grant_scopes: grant_scopes.freeze, token_version: credential_ref.fingerprint,
      credential_ref: credential_ref, signed_exp_status: :present_numeric,
      signed_exp_value: read_at + 900, token_refresh_deadline: read_at + 3300,
      token_hard_expiry: read_at + 3600, grant_read_at: read_at,
      authorization_valid_until: read_at + 900, authorization_bound_kind: :signed_exp
    )
  end

  let(:atomspace_grant) { grant([scope]) }
  let(:deck_only_grant) { grant(["mcp:read"]) }

  let(:server_own_context) do
    { magi_tools: instance_double(Hyperon::Wiki::Mcp::Tools, "default Tools"),
      working_directory: "/srv/hyperon-mcp" }.freeze
  end

  # What the shared server holds now, and whether it was ever asked to dispatch.
  let(:server_state) { { installed: server_own_context, handled: [] } }

  let(:local_secret) { "spec-local-secret" }

  around do |example|
    saved = {
      server: described_class.mcp_server_instance,
      token_issuer: described_class.token_issuer,
      credential_store: described_class.credential_store,
      client_cards: described_class.client_cards,
      rate_limiter: described_class.rate_limiter
    }
    saved_secret = ENV.fetch("MCP_LOCAL_SECRET", nil)
    ENV["MCP_LOCAL_SECRET"] = local_secret
    example.run
  ensure
    described_class.mcp_server_instance = saved[:server]
    described_class.token_issuer = saved[:token_issuer]
    described_class.credential_store = saved[:credential_store]
    described_class.client_cards = saved[:client_cards]
    described_class.rate_limiter = saved[:rate_limiter]
    if saved_secret
      ENV["MCP_LOCAL_SECRET"] = saved_secret
    else
      ENV.delete("MCP_LOCAL_SECRET")
    end
  end

  before do
    state = server_state
    allow(mcp_server).to receive(:server_context) { state[:installed] }
    allow(mcp_server).to receive(:server_context=) { |context| state[:installed] = context }
    allow(mcp_server).to receive(:handle) do |request_data|
      state[:handled] << request_data
      { jsonrpc: "2.0", id: request_data[:id], result: { tools: [] } }
    end
    allow(mcp_server).to receive(:tools).and_return([])
    described_class.mcp_server_instance = mcp_server

    described_class.token_issuer = instance_double(Hyperon::Wiki::Mcp::OAuth::TokenIssuer, "TokenIssuer")
    described_class.credential_store = instance_double(
      Hyperon::Wiki::Mcp::OAuth::CredentialStore, "CredentialStore"
    )
    described_class.client_cards = instance_double(Hyperon::Wiki::Mcp::OAuth::ClientCards, "ClientCards")
    described_class.rate_limiter = nil

    allow(described_class.token_issuer).to receive(:verify).with(access_token).and_return(verified_claims)
    session = { username: "alice@example.test", role: "gm", tools: per_user_tools }
    allow(described_class.credential_store).to receive(:get_session).with(session_id).and_return(session)
    allow(per_user_auth).to receive(:read_grant).and_return(atomspace_grant)
    allow(per_user_tools).to receive(:atomspace_space_stats).and_return({ "atoms" => 42 })
  end

  # One options hash rather than six keyword parameters: RuboCop's parameter-list limit is
  # the honest signal here that this is a request DESCRIPTION, not six independent knobs.
  def env_for(path, body:, **options)
    token = options.fetch(:token, access_token)
    env = {
      "REQUEST_METHOD" => options.fetch(:method, "POST"),
      "PATH_INFO" => path,
      "HTTP_HOST" => options.fetch(:host, "mcp.hyperon.dev"),
      "CONTENT_TYPE" => "application/json",
      "rack.input" => StringIO.new(body)
    }
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    env["HTTP_X_MCP_LOCAL"] = options[:local_secret_header] if options[:local_secret_header]
    env
  end

  def post_atomspace(payload, path: atomspace_path, **options)
    body = payload.is_a?(String) ? payload : JSON.generate(payload)
    status, headers, response = app.call(env_for(path, body: body, **options))
    parsed = response.first.nil? || response.first.empty? ? nil : JSON.parse(response.first)
    [status, headers, parsed]
  end

  def listing(id: 1)
    { jsonrpc: "2.0", id: id, method: "tools/list" }
  end

  def space_stats_call(id: 2)
    { jsonrpc: "2.0", id: id, method: "tools/call", params: { name: "space_stats", arguments: {} } }
  end

  describe "path dispatch" do
    it "serves the dedicated toolset on POST /mcp/atomspace" do
      status, _headers, body = post_atomspace(listing)

      expect(status).to eq(200)
      expect(body["jsonrpc"]).to eq("2.0")
      expect(body["id"]).to eq(1)
      expect(body.dig("result", "tools").map { |tool| tool["name"] })
        .to eq(registry::TOOLS.map(&:name_value))
    end

    it "accepts the trailing-slash form, as every other MCP path on this host does" do
      status, _headers, body = post_atomspace(listing, path: "#{atomspace_path}/")

      expect(status).to eq(200)
      expect(body.dig("result", "tools")).not_to be_empty
    end

    # The whole point of a dedicated path: the shared server's table is never consulted, and
    # its shared mutable context is never swapped. A mount that routed through
    # handle_mcp_message would fail both.
    it "never dispatches through the shared MCP::Server" do
      post_atomspace(listing)

      expect(server_state[:handled]).to be_empty
      expect(mcp_server).not_to have_received(:server_context=)
      expect(server_state[:installed]).to equal(server_own_context)
    end

    it "answers the AtomSpace tools, not the public server's table" do
      _status, _headers, body = post_atomspace(listing)
      names = body.dig("result", "tools").map { |tool| tool["name"] }

      expect(names).to include("space_stats", "query_atoms")
      expect(names).not_to include("get_card", "search_cards")
    end

    # GET is not a transport this path offers: there is no SSE channel and no advertisement,
    # so an unknown method on it is simply not found.
    it "offers no GET transport on the dedicated path" do
      status, = app.call(env_for(atomspace_path, body: "", method: "GET"))

      expect(status).to eq(404)
    end

    it "still answers the CORS preflight every path on this host answers" do
      status, headers, = app.call(env_for(atomspace_path, body: "", method: "OPTIONS", token: nil))

      expect(status).to eq(204)
      expect(headers["Access-Control-Allow-Origin"]).to eq("*")
    end

    it "returns the MCP protocol and session headers the other MCP paths return" do
      _status, headers, = post_atomspace(listing)

      expect(headers["Content-Type"]).to eq("application/json")
      expect(headers["MCP-Protocol-Version"]).to eq("2025-06-18")
      expect(headers["Mcp-Session-Id"]).not_to be_nil
    end
  end

  describe "the authenticated request's own context" do
    it "reads the grant through the authenticated principal's own Auth, naming no scope" do
      post_atomspace(listing)

      expect(per_user_auth).to have_received(:read_grant).with(required_scope: nil).once
    end

    # The context is what makes the list non-empty, so this is the observable proof it arrived.
    it "authorizes the list from that grant read" do
      _status, _headers, body = post_atomspace(listing)

      expect(body.dig("result", "tools").size).to eq(registry::TOOLS.size)
    end

    it "runs the tool against the authenticated principal's own Tools, not the default identity's" do
      _status, _headers, body = post_atomspace(space_stats_call)

      expect(body["error"]).to be_nil
      expect(per_user_tools).to have_received(:atomspace_space_stats)
      expect(JSON.parse(body.dig("result", "content").first["text"])).to eq({ "atoms" => 42 })
    end

    # A grant read that cannot complete leaves no context, and no context authorizes nothing.
    context "when the grant read itself fails" do
      before { allow(per_user_auth).to receive(:read_grant).and_raise(StandardError, "deck unreachable") }

      it "serves the request with an empty list rather than failing the transport" do
        status, _headers, body = post_atomspace(listing)

        expect(status).to eq(200)
        expect(body.dig("result", "tools")).to be_empty
      end

      it "denies a call" do
        status, _headers, body = post_atomspace(space_stats_call)

        expect(status).to eq(200)
        expect(body.dig("error", "code")).to eq(entrypoint::AUTHORIZATION_DENIED)
      end
    end
  end

  describe "a grant that does not name the AtomSpace scope" do
    before { allow(per_user_auth).to receive(:read_grant).and_return(deck_only_grant) }

    it "advertises nothing rather than denying tools/list to everybody" do
      status, _headers, body = post_atomspace(listing)

      expect(status).to eq(200)
      expect(body["error"]).to be_nil
      expect(body.dig("result", "tools")).to be_empty
    end

    # The contract this slice exists to pin: 200 with a JSON-RPC error, not 401 and not 403.
    it "denies tools/call with HTTP 200 and JSON-RPC -32002" do
      status, _headers, body = post_atomspace(space_stats_call)

      expect(status).to eq(200)
      expect(body).not_to have_key("result")
      expect(body.dig("error", "code")).to eq(-32_002)
      expect(body.dig("error", "code")).to eq(entrypoint::AUTHORIZATION_DENIED)
      expect(body.dig("error", "message")).to eq(entrypoint::AUTHORIZATION_DENIED_MESSAGE)
      expect(body.dig("error", "data", "reason")).to match(/#{Regexp.escape(scope)}/)
    end

    it "sends no WWW-Authenticate header, because the credential is not the problem" do
      _status, headers, = post_atomspace(space_stats_call)

      expect(headers).not_to have_key("WWW-Authenticate")
    end

    it "never reaches the deck on a denied call" do
      post_atomspace(space_stats_call)

      expect(per_user_tools).not_to have_received(:atomspace_space_stats)
    end
  end

  describe "the existing authentication gate" do
    it "refuses an unauthenticated external request with 401 and no grant read" do
      status, headers, body = post_atomspace(listing, token: nil)

      expect(status).to eq(401)
      expect(body.dig("error", "code")).to eq(-32_001)
      expect(body.dig("error", "message")).to eq("Authentication required")
      expect(headers["WWW-Authenticate"]).to include("resource_metadata=")
      expect(per_user_auth).not_to have_received(:read_grant)
    end

    it "refuses a token that does not verify" do
      token_error = Hyperon::Wiki::Mcp::OAuth::TokenIssuer::TokenError
      allow(described_class.token_issuer).to receive(:verify)
        .with("bogus").and_raise(token_error, "Token verification failed")

      status, _headers, body = post_atomspace(listing, token: "bogus")

      expect(status).to eq(401)
      expect(body.dig("error", "code")).to eq(-32_001)
    end

    it "refuses a verified token whose session no longer exists" do
      allow(described_class.credential_store).to receive(:get_session).with(session_id).and_return(nil)

      status, = post_atomspace(listing)

      expect(status).to eq(401)
    end

    # A trusted same-box caller is admitted by the gate -- it is trusted by deployment -- and
    # then authorized by nothing, because it holds no deck grant. Admission is not authorization.
    context "with a trusted same-box caller" do
      def post_local(payload)
        post_atomspace(payload, token: nil, host: "127.0.0.1:3002", local_secret_header: local_secret)
      end

      it "is admitted by the gate" do
        status, = post_local(listing)

        expect(status).not_to eq(401)
      end

      it "is authorized nothing, because it holds no deck grant" do
        _status, _headers, body = post_local(listing)

        expect(body.dig("result", "tools")).to be_empty
      end

      it "is denied a call with the authorization error, not the authentication one" do
        _status, _headers, body = post_local(space_stats_call)

        expect(body.dig("error", "code")).to eq(entrypoint::AUTHORIZATION_DENIED)
      end

      it "performs no grant read on the default identity's behalf" do
        post_local(listing)

        expect(per_user_auth).not_to have_received(:read_grant)
      end
    end
  end

  describe "public Deck endpoints" do
    it "still dispatch POST /mcp through the shared MCP::Server" do
      status, _headers, body = post_atomspace(listing, path: "/mcp")

      expect(status).to eq(200)
      expect(server_state[:handled].map { |request| request[:id] }).to eq([1])
      expect(body.dig("result", "tools")).to eq([])
    end

    it "still dispatch POST / through the shared MCP::Server" do
      post_atomspace(listing, path: "/")

      expect(server_state[:handled].size).to eq(1)
    end

    it "still answer /health unchanged" do
      status, _headers, response = app.call(env_for("/health", body: "", method: "GET", token: nil))
      body = JSON.parse(response.first)

      expect(status).to eq(200)
      expect(body["status"]).to eq("healthy")
    end

    it "keep /messages on its own 202 status" do
      status, = post_atomspace(listing, path: "/messages")

      expect(status).to eq(202)
    end
  end

  # (d): nothing advertises the dedicated path. A client that cannot discover it cannot be
  # sent into a denial loop by a grant the deck does not issue yet.
  describe "discovery" do
    def json_get(path)
      _status, _headers, response = app.call(env_for(path, body: "", method: "GET", token: nil))
      JSON.parse(response.first)
    end

    it "does not list the dedicated path in the root endpoints map" do
      root = json_get("/")

      expect(root["endpoints"]).to eq({ "health" => "/health", "mcp" => "/mcp", "sse" => "/sse",
                                        "messages" => "/messages", "message" => "/message" })
      expect(JSON.generate(root)).not_to match(/atomspace/i)
    end

    it "does not advertise the AtomSpace scope in protected-resource metadata" do
      document = json_get("/.well-known/oauth-protected-resource")

      expect(document["scopes_supported"]).to eq(["mcp:read", "mcp:write", "mcp:admin"])
      expect(JSON.generate(document)).not_to match(/atomspace/i)
    end

    it "does not advertise the AtomSpace scope or path in authorization-server metadata" do
      document = json_get("/.well-known/oauth-authorization-server")

      expect(document["scopes_supported"]).to eq(["mcp:read", "mcp:write", "mcp:admin"])
      expect(JSON.generate(document)).not_to match(/atomspace/i)
    end

    it "does not advertise the AtomSpace scope or path in the OpenID configuration" do
      document = json_get("/.well-known/openid-configuration")

      expect(document["scopes_supported"]).to eq(["mcp:read", "mcp:write", "mcp:admin"])
      expect(JSON.generate(document)).not_to match(/atomspace/i)
    end

    # The path is reachable, and still unadvertised. Without this the examples above would be
    # satisfied by a mount that did not exist: "no document mentions it" is trivially true of a
    # path nobody serves, and the point here is that serving and advertising are separable.
    it "serves the path it does not advertise" do
      status, = post_atomspace(listing)

      expect(status).to eq(200)
    end
  end

  # Batch, notification and malformed-body behaviour is the envelope layer's, asserted
  # against the gem in spec/server/atomspace_json_rpc_spec.rb. These examples only pin that
  # the mount hands requests to it and maps its answers onto HTTP the way this host already
  # does.
  describe "envelope behaviour over HTTP" do
    it "answers a batch with one response per member" do
      status, _headers, body = post_atomspace([listing(id: 1), listing(id: 2)])

      expect(status).to eq(200)
      expect(body.map { |response| response["id"] }).to eq([1, 2])
    end

    it "answers an id-less notification with an empty JSON-RPC body" do
      status, _headers, body = post_atomspace({ jsonrpc: "2.0", method: "tools/list" })

      expect(status).to eq(200)
      expect(body).to be_nil
    end

    it "answers a malformed body with the parse error this host already returns" do
      status, _headers, body = post_atomspace("{not json", path: atomspace_path)

      expect(status).to eq(400)
      expect(body.dig("error", "code")).to eq(-32_700)
    end

    it "refuses an unauthenticated malformed body before parsing it" do
      status, _headers, body = post_atomspace("{not json", token: nil)

      expect(status).to eq(401)
      expect(body.dig("error", "code")).to eq(-32_001)
    end
  end
end
