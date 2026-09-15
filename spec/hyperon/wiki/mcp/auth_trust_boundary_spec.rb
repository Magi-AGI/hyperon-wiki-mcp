# frozen_string_literal: true

# Offline characterization spec for the auth trust boundary: where the identity
# facts this client acts on actually come from.
#
# This file RECORDS current behavior; it does not assert desired behavior and it
# must not drive a change to lib/.
#
# The boundary in one line: the `username` and `resolved_role` that
# Auth#fetch_token stores are read straight out of the auth endpoint's HTTP
# response BODY. Neither is derived from the JWT that same response carried, and
# neither is checked against the role the client asked for.
#
#   Config#auth_payload ---- POST /auth ---->  Decko
#   (username/password                            |
#    or api_key, role)                            | JSON body
#                                                 v
#   Auth#fetch_token stores, unverified:  token, username, role, expires_in
#                                                 |
#                                                 | Auth#resolved_role
#                                                 v
#   RackApp#authenticate_with_decko  ->  that role, or "user" when it is nil
#
# Sources under characterization:
#   lib/hyperon/wiki/mcp/auth.rb:39      attr_reader :username, :resolved_role
#   lib/hyperon/wiki/mcp/auth.rb:172     #fetch_token (private)
#   lib/hyperon/wiki/mcp/config.rb:95    #auth_payload
#   lib/hyperon/wiki/mcp/rack_app.rb:859 #authenticate_with_decko (private)
#   lib/hyperon/wiki/mcp/rack_app.rb:951 role -> scope mapping (private)
#
# Deliberately NOT re-covered here (already characterized elsewhere):
#   * token/JWKS caching, refresh and error mapping  -> auth_spec.rb
#   * #verify_token claim handling, including the fact that it never reads or
#     enforces a `scope` claim                       -> auth_verify_token_spec.rb
#
# On "scope": Auth extracts none. It has no payload field, no reader and no ivar
# for one, even when the response body offers a `scope` -- whatever scope claim
# the token itself carries stays sealed inside that opaque string. The one place
# a scope is produced in this flow is downstream and separate:
# RackApp#issue_token_response maps the role it is handed onto the scope of its
# own OAuth token response. That mapping neither feeds nor is fed by
# Auth#verify_token's JWT claim verification.

require "spec_helper"
require "webmock/rspec"
require "base64"
require "json"
require "hyperon/wiki/mcp/config"
require "hyperon/wiki/mcp/auth"
require "hyperon/wiki/mcp/client"
require "hyperon/wiki/mcp/tools"
require "hyperon/wiki/mcp/rack_app"
require "hyperon/wiki/mcp/oauth/token_issuer"
require "hyperon/wiki/mcp/oauth/credential_store"

RSpec.describe "auth trust boundary" do
  let(:base_url) { "https://test.example.com/api/mcp" }
  let(:auth_url) { "https://test.example.com/api/mcp/auth" }
  let(:jwks_url) { "https://test.example.com/api/mcp/.well-known/jwks.json" }

  # Examples below build Config straight off the process environment, so they
  # write MCP_*/DECKO_API_BASE_URL directly. Snapshot every key this file touches
  # and restore it afterwards: nothing here may leak into a neighboring example,
  # in this file or anywhere else in a randomized full-suite run.
  around do |example|
    keys = %w[MCP_API_KEY MCP_USERNAME MCP_PASSWORD MCP_ROLE DECKO_API_BASE_URL]
    saved = keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    keys.each { |key| ENV.delete(key) }
    example.run
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
  end

  before do
    WebMock.disable_net_connect!(allow_localhost: false)
  end

  after do
    WebMock.reset!
  end

  # A syntactically well-formed compact JWS whose signature segment is filler.
  # Nothing in fetch_token looks at either half, which is the point: these tokens
  # exist only so the response body can carry a token that *disagrees* with the
  # body's own role field.
  def unverified_jwt(payload)
    [
      Base64.urlsafe_encode64(JSON.generate({ "alg" => "RS256", "kid" => "spec-kid" }), padding: false),
      Base64.urlsafe_encode64(JSON.generate(payload), padding: false),
      Base64.urlsafe_encode64("filler-signature", padding: false)
    ].join(".")
  end

  # Reads the payload segment back out of a compact JWS. urlsafe_decode64 is
  # strict about padding, which unverified_jwt deliberately omits, so restore it
  # the same way auth.rb's own #decode_base64url does.
  def claims_in(token)
    segment = token.split(".")[1]
    segment += "=" * ((4 - (segment.length % 4)) % 4)
    JSON.parse(Base64.urlsafe_decode64(segment))
  end

  describe Hyperon::Wiki::Mcp::Auth do
    # Requests role "user" via API key. Every example below contrasts this
    # *requested* role with whatever the response body hands back.
    let(:config) do
      ENV["MCP_API_KEY"] = "test-api-key"
      ENV["DECKO_API_BASE_URL"] = base_url
      ENV["MCP_ROLE"] = "user"
      Hyperon::Wiki::Mcp::Config.new
    end

    let(:auth) { described_class.new(config) }

    # A token whose own claims say "user" with read-only scope.
    let(:player_token) do
      unverified_jwt(
        "sub" => "player",
        "role" => "user",
        "scope" => ["cards:read"],
        "iss" => "hyperon"
      )
    end

    # NOTE: callers must brace the body hash. A brace-less `"token" => ...`
    # argument is parsed as keyword arguments under Ruby 3, and this signature,
    # which declares `status:`, rejects it.
    def stub_auth(body, status: 201)
      stub_request(:post, auth_url).to_return(
        status: status,
        body: JSON.generate(body),
        headers: { "Content-Type" => "application/json" }
      )
    end

    describe "#token identity provenance" do
      it "stores username and resolved_role out of the auth response body" do
        stub_auth({
                    "token" => player_token,
                    "username" => "decko_account",
                    "role" => "gm",
                    "expires_in" => 3600
                  })

        auth.token

        expect(auth.username).to eq("decko_account")
        expect(auth.resolved_role).to eq("gm")
      end

      it "takes resolved_role from the response body, not from the role it requested" do
        stub_auth({ "token" => player_token, "role" => "admin" })

        auth.token

        expect(config.role).to eq("user")
        expect(auth.resolved_role).to eq("admin")
        expect(WebMock).to(have_requested(:post, auth_url).with { |req| JSON.parse(req.body)["role"] == "user" })
      end

      it "takes resolved_role from the response body even when the token disagrees" do
        # Body says admin; the accompanying token says role "user", scope
        # ["cards:read"]. The body wins because the token is never opened.
        stub_auth({ "token" => player_token, "role" => "admin" })

        auth.token

        expect(claims_in(auth.token)).to include("role" => "user", "scope" => ["cards:read"])
        expect(auth.resolved_role).to eq("admin")
      end

      it "neither decodes nor verifies the token while fetching it" do
        stub_auth({ "token" => player_token, "role" => "admin" })

        expect(JWT).not_to receive(:decode)
        expect(auth).not_to receive(:verify_token)

        auth.token

        # Verification would have to fetch JWKS; no such request is made.
        expect(WebMock).not_to have_requested(:get, jwks_url)
      end

      it "stores the token string verbatim even when it is not a JWT at all" do
        stub_auth({ "token" => "not-a-jwt-at-all", "role" => "admin" })

        expect(auth.token).to eq("not-a-jwt-at-all")
        expect(auth.resolved_role).to eq("admin")
      end

      it "leaves resolved_role nil when the response body carries no role" do
        stub_auth({ "token" => player_token, "username" => "decko_account", "expires_in" => 3600 })

        auth.token

        expect(auth.resolved_role).to be_nil
        expect(auth.username).to eq("decko_account")
      end

      it "leaves username nil when the response body carries no username" do
        stub_auth({ "token" => player_token, "role" => "gm" })

        auth.token

        expect(auth.username).to be_nil
      end

      it "stores the username the response body reports, not the one it signed in with" do
        ENV["MCP_USERNAME"] = "player@example.com"
        ENV["MCP_PASSWORD"] = "s3cret"
        ENV["DECKO_API_BASE_URL"] = base_url
        stub_auth({ "token" => player_token, "username" => "decko_account", "role" => "user" })

        password_auth = described_class.new(Hyperon::Wiki::Mcp::Config.new)
        password_auth.token

        expect(password_auth.username).to eq("decko_account")
      end

      it "drops the stored identity on clear_cache!" do
        stub_auth({ "token" => player_token, "username" => "decko_account", "role" => "admin" })
        auth.token

        auth.clear_cache!

        expect(auth.username).to be_nil
        expect(auth.resolved_role).to be_nil
      end
    end

    describe "#token and scope" do
      it "ignores a scope field in the auth response body" do
        stub_auth({
                    "token" => player_token,
                    "username" => "decko_account",
                    "role" => "gm",
                    "scope" => ["admin:*"]
                  })

        auth.token

        expect(auth).not_to respond_to(:scope)
        expect(auth).not_to respond_to(:scopes)
        expect(auth.resolved_role).to eq("gm")
      end

      it "extracts no scope state, though the token it stored carries a scope claim" do
        stub_auth({
                    "token" => player_token,
                    "username" => "decko_account",
                    "role" => "gm",
                    "scope" => ["admin:*"]
                  })

        auth.token

        # The claim survives inside the opaque token string. What is absent is any
        # separately extracted scope state for this client to read or act on.
        expect(claims_in(auth.token)).to include("scope" => ["cards:read"])
        expect(auth.instance_variables).not_to include(:@scope, :@scopes)
      end

      it "exposes no scope reader on the class" do
        expect(described_class.public_instance_methods).to include(:username, :resolved_role)
        expect(described_class.public_instance_methods).not_to include(:scope, :scopes)
      end
    end
  end

  describe Hyperon::Wiki::Mcp::Config do
    describe "#auth_payload has no scope field" do
      it "sends exactly api_key and role for API-key auth" do
        ENV["MCP_API_KEY"] = "test-api-key"
        ENV["DECKO_API_BASE_URL"] = base_url
        ENV["MCP_ROLE"] = "admin"

        expect(described_class.new.auth_payload).to eq(api_key: "test-api-key", role: "admin")
      end

      it "sends exactly username and password when the role is left at the default" do
        ENV["MCP_USERNAME"] = "decko_account"
        ENV["MCP_PASSWORD"] = "s3cret"
        ENV["DECKO_API_BASE_URL"] = base_url

        config = described_class.new

        expect(config.role).to eq("user")
        expect(config.auth_payload).to eq(username: "decko_account", password: "s3cret")
      end

      it "adds role, and only role, when a non-default role is requested" do
        ENV["MCP_USERNAME"] = "decko_account"
        ENV["MCP_PASSWORD"] = "s3cret"
        ENV["MCP_ROLE"] = "gm"
        ENV["DECKO_API_BASE_URL"] = base_url

        expect(described_class.new.auth_payload)
          .to eq(username: "decko_account", password: "s3cret", role: "gm")
      end
    end

    it "produces an on-the-wire /auth body with no scope member" do
      ENV["MCP_API_KEY"] = "test-api-key"
      ENV["DECKO_API_BASE_URL"] = base_url
      ENV["MCP_ROLE"] = "user"

      stub_request(:post, auth_url).to_return(
        status: 201,
        body: JSON.generate({ "token" => "t", "role" => "user" }),
        headers: { "Content-Type" => "application/json" }
      )

      Hyperon::Wiki::Mcp::Auth.new(described_class.new).token

      expected_body = { "api_key" => "test-api-key", "role" => "user" }
      expect(WebMock).to(have_requested(:post, auth_url).with { |req| JSON.parse(req.body) == expected_body })
    end
  end

  describe Hyperon::Wiki::Mcp::RackApp do
    let(:app) { described_class.new }
    let(:email) { "player@example.com" }
    let(:password) { "s3cret" }

    # Nested double standing in for Tools -> Client -> Auth. No real Tools is
    # built and no HTTP is performed: create_user_tools is stubbed on the
    # instance under test.
    def stub_tools(resolved_role:, token: "decko-token")
      auth = instance_double(Hyperon::Wiki::Mcp::Auth, token: token, resolved_role: resolved_role)
      allow(auth).to receive(:verify_token)
      client = instance_double(Hyperon::Wiki::Mcp::Client, auth: auth)
      tools = instance_double(Hyperon::Wiki::Mcp::Tools, client: client)
      allow(app).to receive(:create_user_tools).and_return(tools)
      auth
    end

    describe "#authenticate_with_decko" do
      it "returns the role Decko resolved, not the role it asked for" do
        stub_tools(resolved_role: "admin")

        expect(app.send(:authenticate_with_decko, email, password)).to eq("admin")
        # "user" is the default, which makes Config omit role from the payload
        # so Decko auto-detects the caller's highest role.
        expect(app).to have_received(:create_user_tools).with(email, password, "user")
      end

      it "forces a token fetch to validate the credentials" do
        auth = stub_tools(resolved_role: "gm")

        expect(app.send(:authenticate_with_decko, email, password)).to eq("gm")
        expect(auth).to have_received(:token)
      end

      it "does not verify the token it just fetched" do
        auth = stub_tools(resolved_role: "admin")

        app.send(:authenticate_with_decko, email, password)

        expect(auth).not_to have_received(:verify_token)
      end

      it "falls back to \"user\" when the fetch succeeded but resolved no role" do
        auth = stub_tools(resolved_role: nil)

        expect(app.send(:authenticate_with_decko, email, password)).to eq("user")
        expect(auth).to have_received(:token)
      end

      it "passes an unrecognized role straight through" do
        stub_tools(resolved_role: "shepherd")

        expect(app.send(:authenticate_with_decko, email, password)).to eq("shepherd")
      end

      it "applies that \"user\" fallback on Ruby falsiness: a blank role survives, false does not" do
        # `resolved_role || "user"`: an empty string is truthy and is returned as
        # is, while a JSON `"role": false` is swallowed by the same fallback nil takes.
        stub_tools(resolved_role: "")
        expect(app.send(:authenticate_with_decko, email, password)).to eq("")

        stub_tools(resolved_role: false)
        expect(app.send(:authenticate_with_decko, email, password)).to eq("user")
      end

      context "when it returns nil" do
        it "rejects blank credentials without contacting Decko" do
          allow(app).to receive(:create_user_tools)

          expect(app.send(:authenticate_with_decko, nil, password)).to be_nil
          expect(app.send(:authenticate_with_decko, "", password)).to be_nil
          expect(app.send(:authenticate_with_decko, email, nil)).to be_nil
          expect(app.send(:authenticate_with_decko, email, "")).to be_nil
          expect(app).not_to have_received(:create_user_tools)
        end

        it "swallows an authentication failure from the token fetch" do
          auth = instance_double(Hyperon::Wiki::Mcp::Auth)
          allow(auth).to receive(:token)
            .and_raise(Hyperon::Wiki::Mcp::Auth::AuthenticationError, "HTTP 401")
          client = instance_double(Hyperon::Wiki::Mcp::Client, auth: auth)
          tools = instance_double(Hyperon::Wiki::Mcp::Tools, client: client)
          allow(app).to receive(:create_user_tools).and_return(tools)

          expect(app.send(:authenticate_with_decko, email, password)).to be_nil
        end

        it "swallows a misconfiguration just as quietly as a bad password" do
          # `rescue StandardError` is broad enough that the caller cannot tell a
          # rejected credential from a broken config or a dead network.
          allow(app).to receive(:create_user_tools)
            .and_raise(Hyperon::Wiki::Mcp::Config::ConfigurationError, "MCP_ROLE is required")

          expect(app.send(:authenticate_with_decko, email, password)).to be_nil
        end
      end
    end

    # Downstream of the boundary above, and separate from Auth#verify_token:
    # issue_token_response maps whatever role it is handed onto the `scope` it
    # reports in its own OAuth token response. These examples hand that role in
    # directly, so they characterize the mapping alone -- not how the role was
    # obtained. #authenticate_with_decko above is what supplies it in production.
    # Either way no JWT claim is consulted to produce the scope.
    describe "#issue_token_response role to OAuth response scope (downstream)" do
      # RackApp's issuer and store are class-level, so restore them from an
      # ensure for the same reason the ENV hook above uses one.
      around do |example|
        prior_issuer = described_class.token_issuer
        prior_store = described_class.credential_store
        example.run
      ensure
        described_class.token_issuer = prior_issuer
        described_class.credential_store = prior_store
      end

      before do
        described_class.token_issuer = instance_double(
          Hyperon::Wiki::Mcp::OAuth::TokenIssuer, issue: "access-token", ttl: 900
        )
        described_class.credential_store = instance_double(
          Hyperon::Wiki::Mcp::OAuth::CredentialStore,
          store_refresh_token: nil, store_session: nil
        )
        # issue_token_response builds a Tools instance to cache on the session.
        # Stub it so nothing real is constructed; no example here reads it back,
        # and in particular no Auth of any kind supplies the role under test.
        allow(app).to receive(:create_user_tools).and_return(instance_double(Hyperon::Wiki::Mcp::Tools))
      end

      def scope_for(role)
        _status, _headers, body = app.send(
          :issue_token_response,
          { username: "decko_account", password: password, role: role },
          { "Content-Type" => "application/json" }
        )
        JSON.parse(body.first)["scope"]
      end

      {
        "admin" => "mcp:admin",
        "gm" => "mcp:write",
        "user" => "mcp:read",
        "shepherd" => "mcp:read",
        nil => "mcp:read"
      }.each do |role, scope|
        it "maps a supplied role of #{role.inspect} to #{scope.inspect}" do
          expect(scope_for(role)).to eq(scope)
        end
      end
    end
  end
end
