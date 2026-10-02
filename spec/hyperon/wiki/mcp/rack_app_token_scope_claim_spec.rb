# frozen_string_literal: true

require "spec_helper"
require "hyperon/wiki/mcp/rack_app"
require "hyperon/wiki/mcp/oauth/token_issuer"
require "hyperon/wiki/mcp/oauth/credential_store"
require "hyperon/wiki/mcp/oauth/client_cards"

# The token endpoint stops disagreeing with the credential it issues
# (INTEGRATION.md step 1, rack_app half).
#
# WHAT WAS WRONG. #issue_token_response computed a role-derived scope string, put
# it in the OAuth response body, and then signed a token that said nothing about
# scope. The body and the credential described different grants, and only the body
# -- the half a resource server cannot verify -- carried the scope at all.
#
# THE PROPERTY PINNED HERE is one source: the scope in the response body and the
# scope claim inside the signed token are the same string, for every grant type
# that issues a token. A spec that only read the body would not notice them
# drifting apart again, so every example below reads the TOKEN.
#
# WHAT IS DELIBERATELY NOT CHANGED, because this slice is the smallest reversible
# one and must not move policy:
#   * The role -> scope mapping itself. admin -> mcp:admin, gm -> mcp:write,
#     everything else -> mcp:read is rack_app's existing behaviour, asserted here
#     as characterization so a later policy change is a visible change.
#   * Who is granted what. mcp:atomspace:read is owned by McpApi::AtomspaceGrants
#     (deck repo, POLICY REV4) and signed into the DECK's token that Auth#read_grant
#     reads. This endpoint signs the gem's own inbound token and must never mint
#     that scope -- pinned below.
#   * The client's REQUESTED scope is not honoured. A client asking for mcp:admin
#     is asserting its own grant, which is exactly what Auth#scopes refuses to read
#     from an untrusted source. The server's role-derived answer wins.
#
# Local and offline: a real TokenIssuer (generated RSA key), a real CredentialStore,
# a verifying double for ClientCards, and real Config env for the per-user Tools the
# endpoint builds. No JWKS, no Decko, no network.
RSpec.describe Hyperon::Wiki::Mcp::RackApp, "scope claim in issued tokens" do
  let(:app) { described_class.new }
  let(:token_issuer) { Hyperon::Wiki::Mcp::OAuth::TokenIssuer.new(issuer: "test-issuer", ttl: 3600) }
  let(:credential_store) { Hyperon::Wiki::Mcp::OAuth::CredentialStore.new }
  let(:client_cards) { instance_double(Hyperon::Wiki::Mcp::OAuth::ClientCards) }

  let(:client_id) { "client-abc" }
  let(:client_secret) { "secret-not-real" }

  around do |example|
    saved = {
      token_issuer: described_class.token_issuer,
      credential_store: described_class.credential_store,
      client_cards: described_class.client_cards,
      rate_limiter: described_class.rate_limiter,
      server: described_class.mcp_server_instance
    }
    example.run
  ensure
    described_class.token_issuer = saved[:token_issuer]
    described_class.credential_store = saved[:credential_store]
    described_class.client_cards = saved[:client_cards]
    described_class.rate_limiter = saved[:rate_limiter]
    described_class.mcp_server_instance = saved[:server]
  end

  before do
    described_class.token_issuer = token_issuer
    described_class.credential_store = credential_store
    described_class.client_cards = client_cards
    described_class.rate_limiter = nil
    described_class.instance_variable_set(:@session_manager, nil)
  end

  # The endpoint builds a per-user Tools for the session it caches. Config needs
  # a base URL and credentials to construct; nothing here makes a request.
  def client_data_for(role)
    { username: "person@example.test", password: "deck-password-not-real", role: role }
  end

  def post_token(body)
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/token",
      "CONTENT_TYPE" => "application/json",
      "rack.input" => StringIO.new(JSON.generate(body))
    }
    status, _headers, response_body = app.call(env)
    [status, JSON.parse(response_body.join)]
  end

  def issue_for(role, extra = {})
    allow(client_cards).to receive(:verify_client)
      .with(client_id: client_id, client_secret: client_secret)
      .and_return(client_data_for(role))

    status, payload = post_token({ grant_type: "client_credentials", client_id: client_id,
                                   client_secret: client_secret }.merge(extra))
    expect(status).to eq(200)
    payload
  end

  def token_scope(payload)
    token_issuer.verify(payload.fetch("access_token"))["scope"]
  end

  describe "the signed token carries the scope the response advertises" do
    {
      "admin" => "mcp:admin",
      "gm" => "mcp:write",
      "user" => "mcp:read",
      "anything-else" => "mcp:read"
    }.each do |role, expected_scope|
      it "signs #{expected_scope.inspect} for role #{role.inspect}" do
        payload = issue_for(role)

        expect(payload["scope"]).to eq(expected_scope)
        expect(token_scope(payload)).to eq(expected_scope)
      end
    end

    # The regression this slice exists to prevent: a token whose signature says
    # nothing about scope while the body claims one.
    it "never issues a token with no scope claim at all" do
      expect(token_scope(issue_for("user"))).not_to be_nil
    end

    it "keeps role in the token alongside the new scope claim" do
      payload = issue_for("gm")
      claims = token_issuer.verify(payload.fetch("access_token"))

      expect(claims["role"]).to eq("gm")
      expect(claims["scope"]).to eq("mcp:write")
      expect(claims["jti"]).to be_a(String)
    end
  end

  describe "a client cannot assert its own grant" do
    it "ignores a requested scope wider than the role allows" do
      payload = issue_for("user", scope: "mcp:admin mcp:atomspace:read")

      expect(payload["scope"]).to eq("mcp:read")
      expect(token_scope(payload)).to eq("mcp:read")
    end
  end

  describe "scopes this endpoint does not own" do
    # Granted by McpApi::AtomspaceGrants (deck repo, POLICY REV4) and signed into
    # the deck's own token, which Auth#read_grant reads. The gem's inbound token
    # is not where that grant is decided.
    it "never mints the AtomSpace read scope for any role" do
      %w[user gm admin].each do |role|
        payload = issue_for(role)

        expect(payload["scope"]).not_to include("mcp:atomspace:read")
        expect(token_scope(payload)).not_to include("mcp:atomspace:read")
      end
    end
  end

  describe "the refresh path issues the same shape" do
    it "re-issues a token carrying the scope claim" do
      first = issue_for("gm")
      refresh_token = first.fetch("refresh_token")

      status, payload = post_token(grant_type: "refresh_token", refresh_token: refresh_token)

      expect(status).to eq(200)
      expect(payload["scope"]).to eq("mcp:write")
      expect(token_scope(payload)).to eq("mcp:write")
    end
  end
end
