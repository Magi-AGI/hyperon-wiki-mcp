# frozen_string_literal: true

# Phase 6 RED spec -- the per-request dispatch context must CARRY the
# request's Hyperon::Wiki::Mcp::RequestContext.
#
# Seam: RackApp#handle_with_user_tools (private), today the only place an
# authenticated request's context is swapped onto the shared MCP::Server
# before mcp_server.handle(...) dispatches it. Catalog filtering,
# Registry.gate! and AtomSpace invocation can consume Phase 6 authorization
# only through the context a tool receives at dispatch, and today that
# context holds just :magi_tools and :working_directory. The key check below
# is therefore expected to FAIL against current lib/ -- that failure is the
# intended RED, and this file must not drive a lib/ change as part of this
# authoring step.
#
# Contract encoded -- carry, don't build:
#   * handle_with_user_tools takes the caller's RequestContext as a
#     `request_context:` keyword and installs THAT object (not a copy, not one
#     rebuilt here) as server_context[:request_context] for the duration of
#     handle(...), beside the unchanged :magi_tools and :working_directory.
#   * The server's own context is restored afterward, untouched, so the
#     carried context does not outlive its request.
# Building the RequestContext -- bearer claims, Auth#read_grant, session
# identity -- belongs upstream in the transport path and is out of scope here,
# as are catalog filtering, gating, JWT issuance, and server-context
# synchronization.
#
# Local and offline: a real Auth::GrantReadResult and Auth::CredentialRef
# built directly (no JWKS, no Decko, no OAuth flow), a verifying double for
# the per-user Tools, and a stateful MCP::Server double that records the
# context handle(...) actually ran under.

require "spec_helper"
require "hyperon/wiki/mcp"
require "hyperon/wiki/mcp/rack_app"

RSpec.describe Hyperon::Wiki::Mcp::RackApp, "dispatch context carries the RequestContext" do
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

  # Transitional RED device -- delete the fallback branch with the GREEN
  # change. Passing request_context: to today's two-argument method raises
  # ArgumentError before handle(...) ever runs, a RED that says nothing about
  # the context a tool sees. Until the seam accepts the keyword, the current
  # signature is called instead, so the failure lands on the context itself.
  # The fallback cannot pass: the example requires the exact object passed
  # here, and the fallback never hands it over.
  def dispatch_with_user_tools
    if seam_accepts_request_context?
      app.send(:handle_with_user_tools, request_data, per_user_tools, request_context: request_context)
    else
      app.send(:handle_with_user_tools, request_data, per_user_tools)
    end
  end

  def seam_accepts_request_context?
    app.method(:handle_with_user_tools).parameters.any? do |kind, name|
      %i[key keyreq].include?(kind) && name == :request_context
    end
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
end
