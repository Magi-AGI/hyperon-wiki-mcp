# frozen_string_literal: true

# Where a request's RequestContext comes from on the LIVE dispatch path.
#
# rack_app_dispatch_request_context_spec.rb pins how a context handed to
# RackApp#handle_with_user_tools is carried and restored. It says nothing about
# where that context comes from, and until now nothing did: the real POST
# handler dispatched with tools alone, so RequestContext never reached a
# running tool.
#
# This file pins the missing link -- that an authenticated MCP request arriving
# over HTTP builds its own context from the authorization primitive, not from a
# test caller:
#   * the bearer token's VERIFIED claims identify the principal, and the
#     session id is the one the token's jti names (the same key the credential
#     store filed the session under) -- never an unverified decode;
#   * the grant is read through the authenticated principal's OWN
#     Auth#read_grant -- the per-user Tools' client -- so the capture describes
#     the credential that request will send outbound, not the server's default
#     identity;
#   * the context carries the exact GrantReadResult that read returned, and is
#     bound to the credential that read captured.
#
# Deliberately NOT here, because this slice plumbs capture and does not decide
# policy:
#   * no required scope is named at capture time. read_grant records the
#     caller's scope intent only, and no per-tool scope vocabulary is specified
#     yet, so naming one here would smuggle in a guess and later look decided.
#     The spec pins the absence so that choosing a scope is a visible change.
#   * no request is refused for want of authorization. A grant that fails to
#     verify yields NO context rather than a 403, and the request dispatches
#     exactly as it does today. An enforcement slice must read that absence as
#     "nothing was authorized" -- never as permission.
#   * the trusted same-box path is unchanged: it still runs under the server's
#     own context with no :request_context at all.
#
# Local and offline: a real Auth::GrantReadResult and Auth::CredentialRef built
# directly (no JWKS, no Decko, no OAuth flow), verifying doubles for the token
# issuer, credential store, Tools, Client and Auth, and a stateful MCP::Server
# double that records the context each handle(...) actually ran under.

require "spec_helper"
require "hyperon/wiki/mcp"
require "hyperon/wiki/mcp/rack_app"
require "hyperon/wiki/mcp/oauth/token_issuer"
require "hyperon/wiki/mcp/oauth/credential_store"
require "hyperon/wiki/mcp/oauth/client_cards"

RSpec.describe Hyperon::Wiki::Mcp::RackApp, "request context on the live dispatch path" do
  let(:app) { described_class.new }
  let(:mcp_server) { instance_double("MCP::Server") }

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

  let(:read_at) { Time.at(1_800_000_000) }
  let(:credential_ref) { Hyperon::Wiki::Mcp::Auth::CredentialRef.new("synthetic-deck-token-not-a-jwt") }

  # A verified deck grant shaped exactly as Auth#read_grant returns one:
  # deep-frozen, so RequestContext keeps it whole rather than snapshotting it,
  # and identity comparison below is meaningful.
  let(:verified_grant) do
    Hyperon::Wiki::Mcp::Auth::GrantReadResult.new(
      verification_status: :verified, verification_error_class: nil,
      grant_scopes: ["mcp:atomspace:read"].freeze, token_version: credential_ref.fingerprint,
      credential_ref: credential_ref, signed_exp_status: :present_numeric,
      signed_exp_value: read_at + 900, token_refresh_deadline: read_at + 3300,
      token_hard_expiry: read_at + 3600, grant_read_at: read_at,
      authorization_valid_until: read_at + 900, authorization_bound_kind: :signed_exp
    )
  end

  # The same read, failing closed: nothing verified, so nothing is authorized.
  # It still carries the credential the read captured, which is exactly why a
  # context must not be built from it.
  let(:failed_grant) do
    Hyperon::Wiki::Mcp::Auth::GrantReadResult.new(
      verification_status: :verification_failed,
      verification_error_class: Hyperon::Wiki::Mcp::Auth::VerificationError,
      grant_scopes: [].freeze, token_version: credential_ref.fingerprint,
      credential_ref: credential_ref, signed_exp_status: nil, signed_exp_value: nil,
      token_refresh_deadline: read_at + 3300, token_hard_expiry: read_at + 3600,
      grant_read_at: read_at, authorization_valid_until: nil, authorization_bound_kind: nil
    )
  end

  # The shared server's own context, as installed at boot. Frozen so a dispatch
  # that writes into it in place fails loudly instead of leaking one request's
  # context into every later request.
  let(:server_own_context) do
    { magi_tools: instance_double(Hyperon::Wiki::Mcp::Tools, "default Tools"),
      working_directory: "/srv/hyperon-mcp" }.freeze
  end

  # What the fake server holds now, and what it held while handle(...) ran.
  let(:server_state) { { installed: server_own_context, during_handle: nil } }

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
      state[:during_handle] = state[:installed]
      { jsonrpc: "2.0", id: request_data[:id], result: { tools: [] } }
    end
    described_class.mcp_server_instance = mcp_server

    described_class.token_issuer = instance_double(
      Hyperon::Wiki::Mcp::OAuth::TokenIssuer, "TokenIssuer"
    )
    described_class.credential_store = instance_double(
      Hyperon::Wiki::Mcp::OAuth::CredentialStore, "CredentialStore"
    )
    described_class.client_cards = instance_double(
      Hyperon::Wiki::Mcp::OAuth::ClientCards, "ClientCards"
    )
    described_class.rate_limiter = nil

    allow(described_class.token_issuer).to receive(:verify).with(access_token).and_return(verified_claims)
    session = { username: "alice@example.test", role: "gm", tools: per_user_tools }
    allow(described_class.credential_store).to receive(:get_session).with(session_id).and_return(session)
    allow(per_user_auth).to receive(:read_grant).and_return(verified_grant)
  end

  def mcp_env(token: access_token, host: "mcp.hyperon.dev", local_secret_header: nil, request_id: 1)
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/",
      "HTTP_HOST" => host,
      "CONTENT_TYPE" => "application/json",
      "rack.input" => StringIO.new(JSON.generate({ jsonrpc: "2.0", id: request_id, method: "tools/list" }))
    }
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    env["HTTP_X_MCP_LOCAL"] = local_secret_header if local_secret_header
    env
  end

  describe "an authenticated bearer request" do
    it "runs under a RequestContext built from the verified claims and the principal's own grant read" do
      status, = app.call(mcp_env)
      during_handle = server_state[:during_handle]

      expect(status).to eq(200)
      expect(during_handle).to include(magi_tools: per_user_tools, working_directory: "/srv/hyperon-mcp")
      context = during_handle[:request_context]
      expect(context).to be_a(Hyperon::Wiki::Mcp::RequestContext)
        .and have_attributes(
          principal_kind: :authenticated_session,
          grant_source: :deck_verified_token,
          local_trusted: false,
          session_id: session_id,
          outbound_credential_ref: credential_ref
        )
      expect(context.verified_inbound_claims).to include("sub" => "alice@example.test", "role" => "gm")
    end

    it "carries the exact GrantReadResult that read returned, so the context describes one capture" do
      app.call(mcp_env)

      expect(server_state[:during_handle][:request_context].grant_read_result).to equal(verified_grant)
    end

    it "reads the grant through the authenticated principal's own Auth, not the default identity's" do
      app.call(mcp_env)

      expect(per_user_auth).to have_received(:read_grant).once
    end

    it "names no required scope at capture time, leaving the scope decision to a later slice" do
      app.call(mcp_env)

      expect(per_user_auth).to have_received(:read_grant).with(required_scope: nil)
    end

    it "restores the server's own context afterward" do
      app.call(mcp_env)

      expect(server_state[:installed]).to equal(server_own_context)
    end
  end

  describe "an authenticated request whose grant does not verify" do
    before { allow(per_user_auth).to receive(:read_grant).and_return(failed_grant) }

    # Fail closed WITHOUT inventing a refusal surface: no context is built, so
    # nothing downstream can mistake a failed read for a grant. The request is
    # served exactly as it is today; turning this into a 403 is the enforcement
    # slice's decision, not a side effect of plumbing.
    it "dispatches with no RequestContext at all rather than one built from an unverified read" do
      status, = app.call(mcp_env)
      during_handle = server_state[:during_handle]

      expect(status).to eq(200)
      expect(during_handle).to include(magi_tools: per_user_tools)
      expect(during_handle).not_to include(:request_context)
    end
  end

  describe "an authenticated request whose grant read itself fails" do
    before { allow(per_user_auth).to receive(:read_grant).and_raise(StandardError, "deck unreachable") }

    # A context that cannot be built must not break a request that works
    # today. The absence is the fail-closed signal.
    it "still serves the request, without a RequestContext" do
      status, = app.call(mcp_env)

      expect(status).to eq(200)
      expect(server_state[:during_handle]).not_to include(:request_context)
    end
  end

  describe "a trusted same-box request" do
    # Unchanged by this slice: the default path deliberately does not swap the
    # server's shared context, so there is nowhere to install a context and
    # nothing is installed. A trusted-local principal shape exists on
    # RequestContext, but giving the default path one means swapping shared
    # state it currently leaves alone -- its own change.
    it "runs under the server's own context with no RequestContext and no grant read" do
      status, = app.call(mcp_env(token: nil, host: "127.0.0.1:3002",
                                 local_secret_header: local_secret, request_id: 2))

      expect(status).to eq(200)
      expect(server_state[:during_handle]).to equal(server_own_context)
      expect(server_state[:installed]).to equal(server_own_context)
      expect(per_user_auth).not_to have_received(:read_grant)
    end
  end

  describe "an unauthenticated external request" do
    it "is still refused before any grant read happens" do
      token_error = Hyperon::Wiki::Mcp::OAuth::TokenIssuer::TokenError
      allow(described_class.token_issuer).to receive(:verify)
        .with("bogus").and_raise(token_error, "Token verification failed")

      status, = app.call(mcp_env(token: "bogus"))

      expect(status).to eq(401)
      expect(per_user_auth).not_to have_received(:read_grant)
    end
  end
end
