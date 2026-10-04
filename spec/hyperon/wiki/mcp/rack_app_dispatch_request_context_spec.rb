# frozen_string_literal: true

# How RackApp dispatch swaps, carries, and restores the shared MCP::Server's
# context around each mcp_server.handle(...).
#
# The server's context is shared mutable state. For an authenticated request,
# RackApp#handle_with_user_tools (private) swaps it to that request's
# per-user Tools -- and, when the caller supplies one, the request's
# Hyperon::Wiki::Mcp::RequestContext -- for the duration of handle(...), and
# every tool call reads its identity from it. Catalog filtering,
# Registry.gate! and AtomSpace invocation can consume Phase 6 authorization
# only through that context, so this file pins what they will rely on:
#   * carry, don't build: the caller's RequestContext is installed as
#     server_context[:request_context] -- that object, not a copy or one
#     rebuilt here -- beside the unchanged :magi_tools and :working_directory;
#   * always restore: the server's own context comes back untouched
#     afterward, INCLUDING when handle(...) raises. The outer handler turns
#     that error into a 500 and keeps serving, so a skipped restore would hand
#     the next request this one's tools and RequestContext;
#   * never observed mid-swap: a default-identity (trusted same-box) request
#     arriving while a per-user swap is in flight must not run under it.
# Building the RequestContext (bearer claims, Auth#read_grant, session
# identity) belongs upstream in the transport path and is out of scope here,
# as are catalog filtering, gating, and JWT issuance.
#
# Local and offline: a real Auth::GrantReadResult and Auth::CredentialRef
# built directly (no JWKS, no Decko, no OAuth flow), verifying doubles for
# the Tools, and a stateful MCP::Server double that records the context each
# handle(...) actually ran under.

require "spec_helper"
require "hyperon/wiki/mcp"
require "hyperon/wiki/mcp/rack_app"

RSpec.describe Hyperon::Wiki::Mcp::RackApp, "dispatch context" do
  let(:app) { described_class.new }
  let(:mcp_server) { instance_double("MCP::Server") }
  let(:request_data) { { jsonrpc: "2.0", id: 1, method: "tools/list" } }
  let(:per_user_tools) { instance_double(Hyperon::Wiki::Mcp::Tools, "per-user Tools") }

  # The shared server's own context, as installed at boot. Frozen so a
  # "carry" that writes into it in place fails loudly instead of leaking one
  # request's context into every later request.
  let(:server_own_context) do
    { magi_tools: instance_double(Hyperon::Wiki::Mcp::Tools, "default Tools"),
      working_directory: "/srv/hyperon-mcp" }.freeze
  end

  let(:read_at) { Time.at(1_800_000_000) }
  let(:credential_ref) { Hyperon::Wiki::Mcp::Auth::CredentialRef.new("synthetic-deck-token-not-a-jwt") }

  # A verified deck grant shaped exactly as Auth#read_grant returns one:
  # deep-frozen, so RequestContext keeps it whole rather than snapshotting it.
  let(:grant_read_result) do
    Hyperon::Wiki::Mcp::Auth::GrantReadResult.new(
      verification_status: :verified, verification_error_class: nil,
      grant_scopes: ["mcp:atomspace:read"].freeze, token_version: credential_ref.fingerprint,
      credential_ref: credential_ref, signed_exp_status: :present_numeric,
      signed_exp_value: read_at + 900, token_refresh_deadline: read_at + 3300,
      token_hard_expiry: read_at + 3600, grant_read_at: read_at,
      authorization_valid_until: read_at + 900, authorization_bound_kind: :signed_exp
    )
  end

  let(:request_context) do
    Hyperon::Wiki::Mcp::RequestContext.new(
      principal_kind: :authenticated_session, session_id: "mcp-session-0001",
      verified_inbound_claims: { "sub" => "user:Alice" }, grant_read_result: grant_read_result,
      outbound_credential_ref: credential_ref, grant_source: :deck_verified_token,
      local_trusted: false, request_id: "req-dispatch-0001"
    )
  end

  # What the fake server holds now, and what it held while handle(...) ran.
  let(:server_state) { { installed: server_own_context, during_handle: nil } }

  around do |example|
    server_before = described_class.mcp_server_instance
    example.run
  ensure
    described_class.mcp_server_instance = server_before
  end

  before do
    state = server_state
    allow(mcp_server).to receive(:server_context) { state[:installed] }
    allow(mcp_server).to receive(:server_context=) { |context| state[:installed] = context }
    allow(mcp_server).to receive(:handle) do |_request_data|
      state[:during_handle] = state[:installed]
      { jsonrpc: "2.0", id: 1, result: { tools: [] } }
    end
    described_class.mcp_server_instance = mcp_server
  end

  def dispatch_with_user_tools
    app.send(:handle_with_user_tools, request_data, per_user_tools, request_context: request_context)
  end

  it "installs the caller's authenticated-session RequestContext in the swapped server_context " \
     "while handle(...) runs, then restores the server's own context" do
    dispatch_with_user_tools
    during_handle = server_state[:during_handle]

    expect(during_handle).to include(magi_tools: per_user_tools, working_directory: "/srv/hyperon-mcp")
    expect(during_handle).to include(:request_context)
    expect(during_handle[:request_context]).to equal(request_context)
    expect(during_handle[:request_context]).to be_a(Hyperon::Wiki::Mcp::RequestContext)
      .and have_attributes(principal_kind: :authenticated_session, grant_source: :deck_verified_token,
                           local_trusted: false, outbound_credential_ref: credential_ref)
    expect(server_state[:installed]).to equal(server_own_context)
  end

  it "restores the server's own context when handle(...) raises, so the next request cannot " \
     "inherit this one's tools or RequestContext" do
    allow(mcp_server).to receive(:handle) do |_request_data|
      server_state[:during_handle] = server_state[:installed]
      raise "tool exploded mid-dispatch"
    end

    expect { dispatch_with_user_tools }.to raise_error(RuntimeError, "tool exploded mid-dispatch")

    # The swap really happened, so the restore below is not vacuous.
    expect(server_state[:during_handle]).to include(request_context: request_context)
    expect(server_state[:installed]).to equal(server_own_context)
  end

  context "when a default-identity request arrives while a per-user dispatch is in flight" do
    # A trusted same-box caller: localhost origin plus the shared secret and
    # no bearer token, so it is served under the server's own context.
    let(:trusted_local_env) do
      {
        "REQUEST_METHOD" => "POST",
        "PATH_INFO" => "/",
        "HTTP_HOST" => "127.0.0.1:3002",
        "HTTP_X_MCP_LOCAL" => local_secret,
        "CONTENT_TYPE" => "application/json",
        "rack.input" => StringIO.new('{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
      }
    end

    def local_secret
      "spec-local-secret"
    end

    # OAuth off, so the default path is reached through the trusted-local
    # branch alone; the class-level settings are restored afterward.
    around do |example|
      oauth_attrs = %i[token_issuer credential_store client_cards]
      saved_oauth = oauth_attrs.to_h { |attr| [attr, described_class.public_send(attr)] }
      saved_secret = ENV.fetch("MCP_LOCAL_SECRET", nil)
      oauth_attrs.each { |attr| described_class.public_send(:"#{attr}=", nil) }
      ENV["MCP_LOCAL_SECRET"] = local_secret
      example.run
    ensure
      saved_oauth&.each { |attr, value| described_class.public_send(:"#{attr}=", value) }
      if saved_secret
        ENV["MCP_LOCAL_SECRET"] = saved_secret
      else
        ENV.delete("MCP_LOCAL_SECRET")
      end
    end

    # Parked waiting to take a lock -- the way a serialized dispatch keeps a
    # request out without running it. Thread#status alone cannot say so: it
    # also reads "sleep" while a thread sits in any GVL-releasing call (the
    # session id's random bytes, say), which let an earlier revision of this
    # example release the swap before the default request got anywhere near
    # handle(...) and pass vacuously against the unserialized dispatch.
    def parked_on_lock?(thread)
      thread.status == "sleep" && thread.backtrace.to_a.first.to_s.match?(/Mutex#|Monitor#|synchroniz/)
    end

    # Deterministic, not timed: the per-user handle(...) is held open on a
    # queue until the default request has either been served or is parked on
    # a lock, and only then released. Nothing asserts HOW the default request
    # is kept out (a shared lock, or no shared mutable context at all), only
    # that it is never served under another request's swap.
    it "never serves it under the per-user tools or RequestContext, only under the server's " \
       "own context" do
      rack_app = app
      env = trusted_local_env
      per_user_swapped = Queue.new
      release_per_user = Queue.new
      default_served = Queue.new
      default_ran_under = nil
      per_user_thread = nil
      default_thread = nil

      allow(mcp_server).to receive(:handle) do |incoming|
        if incoming[:id] == 2
          default_ran_under = server_state[:installed]
          default_served << :served
        else
          per_user_swapped << :swapped
          release_per_user.pop(timeout: 5)
        end
        { jsonrpc: "2.0", id: incoming[:id], result: { tools: [] } }
      end

      per_user_thread = Thread.new { dispatch_with_user_tools }
      expect(per_user_swapped.pop(timeout: 5)).to eq(:swapped)

      default_thread = Thread.new { rack_app.call(env) }
      deadline = Time.now + 5
      until default_served.size.positive? || parked_on_lock?(default_thread) ||
            !default_thread.alive? || Time.now > deadline
        Thread.pass
      end

      release_per_user << :released
      status, = default_thread.value
      per_user_thread.value

      expect(status).to eq(200)
      expect(default_ran_under).to equal(server_own_context)
    ensure
      release_per_user&.push(:released)
      [per_user_thread, default_thread].compact.each { |thread| thread.join(5) || thread.kill }
    end
  end
end
