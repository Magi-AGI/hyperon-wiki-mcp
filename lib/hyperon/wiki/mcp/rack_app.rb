# frozen_string_literal: true

require "base64"
require "json"
require "rack"
require "securerandom"
require "uri"

module Hyperon
  module Wiki
    module Mcp
      # Simple host authorization middleware - only allows specific hosts
      class HostAuthorization
        ALLOWED_HOSTS = [
          "127.0.0.1",
          "127.0.0.1:3002",
          "localhost",
          "localhost:3002",
          "mcp.hyperon.dev",
          "dev-mcp.hyperon.dev"
        ].freeze

        def initialize(app)
          @app = app
        end

        def call(env)
          host = env["HTTP_HOST"] || env["SERVER_NAME"]

          if ALLOWED_HOSTS.include?(host)
            @app.call(env)
          else
            [403, { "Content-Type" => "text/plain" }, ["Forbidden: Host '#{host}' not allowed"]]
          end
        end
      end

      # Session manager for MCP protocol with TTL and cleanup
      class SessionManager
        SESSION_TTL = 7200 # 2 hours
        CLEANUP_INTERVAL = 300 # 5 minutes

        def initialize
          @sessions = {}
          @mutex = Mutex.new
          @last_cleanup = Time.now
        end

        def get_or_create(session_id = nil)
          @mutex.synchronize do
            cleanup_expired
            if session_id && @sessions.key?(session_id)
              @sessions[session_id][:last_used_at] = Time.now
              session_id
            else
              new_id = SecureRandom.uuid
              @sessions[new_id] = { created_at: Time.now, last_used_at: Time.now }
              new_id
            end
          end
        end

        def exists?(session_id)
          @mutex.synchronize do
            return false unless @sessions.key?(session_id)

            @sessions[session_id][:last_used_at] = Time.now
            true
          end
        end

        def delete(session_id)
          @mutex.synchronize { @sessions.delete(session_id) }
        end

        def size
          @mutex.synchronize { @sessions.size }
        end

        private

        def cleanup_expired
          return if Time.now - @last_cleanup < CLEANUP_INTERVAL

          now = Time.now
          @sessions.delete_if { |_id, data| now - data[:last_used_at] > SESSION_TTL }
          @last_cleanup = now
        end
      end

      # SSE Streamer for MCP protocol
      # Supports both old SSE transport (session_id in URL) and new Streamable HTTP (header)
      class SSEStreamer
        def initialize(session_id)
          @session_id = session_id
        end

        def each
          # Send keepalive comment IMMEDIATELY as first byte to prevent client timeout.
          # ChatGPT's openai-mcp client has a very short timeout on SSE GET connections;
          # delivering the first byte quickly prevents 499 (client closed request).
          yield ": connected\n\n"

          # Send endpoint event for backward compatibility with old SSE transport
          # Format: /messages?session_id={uuid}
          yield "event: endpoint\ndata: /messages?session_id=#{@session_id}\n\n"

          # Keep connection alive with periodic keepalive messages
          begin
            loop do
              sleep 15
              yield ": keepalive #{Time.now.iso8601}\n\n"
            end
          rescue IOError, Errno::EPIPE
            # Client disconnected
          end
        end
      end

      # Who an authenticated MCP request is, as resolved from its Bearer token:
      # the per-user Tools the session holds, the session id the token's `jti`
      # named, and the claims the SIGNATURE covered.
      #
      # The three travel together because they are only meaningful together.
      # The Tools alone say what a request can call but not who is calling; the
      # claims alone name an identity with no session behind it. Keeping them
      # as one value means the dispatch path cannot pair a session's tools with
      # an identity read from somewhere else -- an unverified decode, say.
      BearerPrincipal = Struct.new(:tools, :session_id, :verified_claims, keyword_init: true)

      # Pure Rack app without Sinatra - complete control over middleware
      # rubocop:disable Metrics/ClassLength
      class RackApp
        # CORS headers required by OpenAI Streamable HTTP transport
        CORS_HEADERS = {
          "Access-Control-Allow-Origin" => "*",
          "Access-Control-Allow-Methods" => "GET, POST, DELETE, OPTIONS",
          "Access-Control-Allow-Headers" => "Content-Type, Authorization, Mcp-Session-Id, mcp-session-id",
          "Access-Control-Expose-Headers" => "Mcp-Session-Id, MCP-Protocol-Version",
          "Access-Control-Max-Age" => "86400"
        }.freeze

        # Cached health response TTL (seconds)
        HEALTH_CACHE_TTL = 30

        # One lock for every #handle on the shared MCP::Server. Its context is
        # shared mutable state: a per-user dispatch swaps it for the duration
        # of that request, so any #handle running alongside -- per-user or
        # default identity -- would otherwise be served under another
        # request's tools and RequestContext. Created eagerly, because a
        # lazily assigned `@mutex ||= Mutex.new` can hand two first requests
        # two different locks.
        DISPATCH_LOCK = Mutex.new

        class << self
          attr_accessor :mcp_server_instance, :token_issuer, :credential_store, :client_cards, :rate_limiter

          def session_manager
            @session_manager ||= SessionManager.new
          end

          # Whether OAuth auth is required for MCP requests
          def oauth_require_auth?
            ENV.fetch("OAUTH_REQUIRE_AUTH", "false") == "true"
          end

          # OAuth issuer URL used in discovery documents
          def oauth_issuer_url
            ENV.fetch("OAUTH_ISSUER_URL", "https://mcp.hyperon.dev")
          end

          # Whether OAuth components are initialized
          def oauth_enabled?
            token_issuer && credential_store && client_cards
          end

          # Localhost bypass: requests directly addressed to 127.0.0.1 /
          # localhost (same-box services). nginx-proxied external traffic
          # preserves the original Host header so it is NOT treated as local.
          def localhost_origin?(env)
            host = env["HTTP_HOST"] || env["SERVER_NAME"] || ""
            ["127.0.0.1", "127.0.0.1:3002", "localhost", "localhost:3002"].include?(host)
          end

          # A trusted same-box caller may use the default identity without an
          # OAuth token, but ONLY if it both originates from localhost AND
          # presents the shared secret in the X-MCP-Local header. If
          # MCP_LOCAL_SECRET is unset the bypass is disabled entirely (fail
          # closed), so neither an nginx Host misconfiguration nor a missing
          # secret can reopen an unauthenticated path to the default identity.
          def trusted_local_caller?(env)
            return false unless localhost_origin?(env)

            secret = ENV["MCP_LOCAL_SECRET"].to_s
            return false if secret.empty?

            Rack::Utils.secure_compare(secret, env["HTTP_X_MCP_LOCAL"].to_s)
          end
        end

        def initialize
          @health_cache = nil
          @health_cached_at = nil
        end

        # Add MCP protocol and CORS headers to response
        def add_mcp_headers(headers, session_id)
          headers.merge(CORS_HEADERS).merge({
                                              "MCP-Protocol-Version" => "2025-06-18",
                                              "Mcp-Session-Id" => session_id
                                            })
        end

        # rubocop:disable Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/AbcSize
        def call(env)
          request = Rack::Request.new(env)

          # Handle CORS preflight for all paths
          if request.request_method == "OPTIONS"
            return [204, add_mcp_headers({ "Content-Type" => "text/plain" }, ""), []]
          end

          # Extract session ID from request or create new one
          incoming_session_id = env["HTTP_MCP_SESSION_ID"]
          session_id = self.class.session_manager.get_or_create(incoming_session_id)

          case [request.request_method, request.path]
          when ["GET", "/health"]
            handle_health(session_id)

          when ["GET", "/debug-headers"]
            handle_debug_headers(env, session_id)

          when ["GET", "/sse"], ["GET", "/sse/"], ["GET", "/mcp"], ["GET", "/mcp/"]
            handle_sse(session_id)

          when ["GET", "/.well-known/oauth-protected-resource"]
            handle_protected_resource_metadata(session_id)

          when ["GET", "/.well-known/oauth-authorization-server"]
            handle_authorization_server_metadata(session_id)

          when ["GET", "/.well-known/openid-configuration"]
            handle_openid_configuration(session_id)

          when ["GET", "/jwks"], ["GET", "/jwks.json"], ["GET", "/.well-known/jwks.json"]
            handle_jwks(session_id)

          when ["GET", "/authorize"]
            handle_authorize_get(request, session_id)

          when ["POST", "/authorize"]
            handle_authorize_post(request, session_id)

          when ["POST", "/register"]
            handle_register(request, session_id)

          when ["POST", "/token"]
            handle_token(request, session_id)

          when ["POST", "/revoke"]
            handle_revoke(request, session_id)

          when ["POST", "/"], ["POST", "/sse"], ["POST", "/sse/"],
               ["POST", "/mcp"], ["POST", "/mcp/"],
               ["POST", "/message"], ["POST", "/messages"]
            handle_mcp_message(request, env, session_id)

          when ["DELETE", "/sse"], ["DELETE", "/sse/"], ["DELETE", "/mcp"], ["DELETE", "/mcp/"]
            handle_session_delete(incoming_session_id, session_id)

          when ["GET", "/"]
            handle_root(env, session_id)

          else
            headers = add_mcp_headers({ "Content-Type" => "text/plain" }, session_id)
            [404, headers, ["Not Found"]]
          end
        end
        # rubocop:enable Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/AbcSize

        private

        def handle_health(session_id)
          headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)

          # Cache health response to avoid repeated upstream calls when Decko is slow
          now = Time.now
          if @health_cache && @health_cached_at && (now - @health_cached_at < HEALTH_CACHE_TTL)
            return [200, headers, [@health_cache]]
          end

          @health_cache = JSON.generate({
                                          status: "healthy",
                                          version: Hyperon::Wiki::Mcp::VERSION,
                                          timestamp: now.iso8601
                                        })
          @health_cached_at = now
          [200, headers, [@health_cache]]
        end

        def handle_debug_headers(env, session_id)
          headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)
          [200, headers, [JSON.generate({
                                          http_host: env["HTTP_HOST"],
                                          server_name: env["SERVER_NAME"],
                                          server_port: env["SERVER_PORT"],
                                          http_x_forwarded_host: env["HTTP_X_FORWARDED_HOST"],
                                          http_mcp_session_id: env["HTTP_MCP_SESSION_ID"],
                                          http_mcp_protocol_version: env["HTTP_MCP_PROTOCOL_VERSION"],
                                          all_http_headers: env.select { |k, _v| k.start_with?("HTTP_") }
                                        })]]
        end

        def handle_sse(session_id)
          headers = add_mcp_headers({
                                      "Content-Type" => "text/event-stream",
                                      "Cache-Control" => "no-cache",
                                      "X-Accel-Buffering" => "no"
                                    }, session_id)

          [200, headers, SSEStreamer.new(session_id)]
        end

        # RFC 9728 - OAuth Protected Resource Metadata
        def handle_protected_resource_metadata(session_id)
          issuer_url = self.class.oauth_issuer_url
          headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)
          [200, headers, [JSON.generate({
                                          resource: issuer_url,
                                          authorization_servers: [issuer_url],
                                          bearer_methods_supported: ["header"],
                                          scopes_supported: ["mcp:read", "mcp:write", "mcp:admin"]
                                        })]]
        end

        # RFC 8414 - OAuth Authorization Server Metadata
        def handle_authorization_server_metadata(session_id)
          issuer_url = self.class.oauth_issuer_url
          headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)
          [200, headers, [JSON.generate({
                                          issuer: issuer_url,
                                          authorization_endpoint: "#{issuer_url}/authorize",
                                          token_endpoint: "#{issuer_url}/token",
                                          revocation_endpoint: "#{issuer_url}/revoke",
                                          registration_endpoint: "#{issuer_url}/register",
                                          response_types_supported: ["code"],
                                          code_challenge_methods_supported: ["S256"],
                                          grant_types_supported:
                                            %w[authorization_code refresh_token client_credentials],
                                          token_endpoint_auth_methods_supported: %w[client_secret_post none],
                                          scopes_supported: ["mcp:read", "mcp:write", "mcp:admin"]
                                        })]]
        end

        # OpenID Connect Discovery 1.0 (for ChatGPT and other OIDC-aware clients)
        # rubocop:disable Metrics/MethodLength
        def handle_openid_configuration(session_id)
          issuer_url = self.class.oauth_issuer_url
          headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)
          [200, headers, [JSON.generate({
                                          issuer: issuer_url,
                                          authorization_endpoint: "#{issuer_url}/authorize",
                                          token_endpoint: "#{issuer_url}/token",
                                          revocation_endpoint: "#{issuer_url}/revoke",
                                          registration_endpoint: "#{issuer_url}/register",
                                          jwks_uri: "#{issuer_url}/jwks",
                                          response_types_supported: ["code"],
                                          code_challenge_methods_supported: ["S256"],
                                          grant_types_supported:
                                            %w[authorization_code refresh_token client_credentials],
                                          token_endpoint_auth_methods_supported: %w[client_secret_post none],
                                          scopes_supported: ["mcp:read", "mcp:write", "mcp:admin"],
                                          subject_types_supported: ["public"],
                                          id_token_signing_alg_values_supported: ["RS256"]
                                        })]]
        end
        # rubocop:enable Metrics/MethodLength

        # JWKS endpoint - exposes public signing key for token verification
        def handle_jwks(session_id)
          headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)

          if self.class.token_issuer
            pub_key = self.class.token_issuer.public_key
            jwk = build_jwk(pub_key)
            [200, headers, [JSON.generate({ keys: [jwk] })]]
          else
            [200, headers, [JSON.generate({ keys: [] })]]
          end
        end

        # Dynamic Client Registration (RFC 7591)
        # rubocop:disable Metrics/MethodLength
        def handle_register(request, session_id)
          headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)
          body = parse_request_body(request)

          client_id = SecureRandom.uuid
          client_name = body["client_name"] || "MCP Client"
          redirect_uris = body["redirect_uris"] || []
          grant_types = body["grant_types"] || ["authorization_code"]
          response_types = body["response_types"] || ["code"]
          token_auth_method = body["token_endpoint_auth_method"] || "none"

          # Store the registered client for later validation
          if self.class.oauth_enabled?
            self.class.credential_store.store_registered_client(
              client_id,
              client_name: client_name,
              redirect_uris: redirect_uris,
              grant_types: grant_types,
              response_types: response_types,
              token_endpoint_auth_method: token_auth_method
            )
          end

          [201, headers, [JSON.generate({
                                          client_id: client_id,
                                          client_id_issued_at: Time.now.to_i,
                                          client_name: client_name,
                                          redirect_uris: redirect_uris,
                                          grant_types: grant_types,
                                          response_types: response_types,
                                          token_endpoint_auth_method: token_auth_method
                                        })]]
        end
        # rubocop:enable Metrics/MethodLength

        # OAuth Token Endpoint - core authentication
        def handle_token(request, session_id)
          headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)

          # Parse form-encoded or JSON body
          params = parse_token_params(request)
          grant_type = params["grant_type"]

          case grant_type
          when "authorization_code"
            handle_authorization_code_grant(params, headers, session_id)
          when "client_credentials"
            handle_client_credentials(params, headers, session_id)
          when "refresh_token"
            handle_refresh_token(params, headers, session_id)
          else
            # Fail closed when OAuth is unavailable: never issue a public token.
            return oauth_unavailable_response(headers) unless self.class.oauth_enabled?

            [400, headers, [JSON.generate({
                                            error: "unsupported_grant_type",
                                            error_description: "Grant type '#{grant_type}' is not supported"
                                          })]]
          end
        end

        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def handle_client_credentials(params, headers, _session_id)
          client_id = params["client_id"]
          client_secret = params["client_secret"]

          # Fail closed when OAuth is unavailable: never issue a public token.
          return oauth_unavailable_response(headers) unless self.class.oauth_enabled?

          # Rate limiting check
          if self.class.rate_limiter&.rate_limited?(client_id)
            return [429, headers, [JSON.generate({
                                                   error: "rate_limit_exceeded",
                                                   error_description: "Too many failed authentication attempts"
                                                 })]]
          end

          unless client_id && client_secret
            return [400, headers, [JSON.generate({
                                                   error: "invalid_request",
                                                   error_description: "client_id and client_secret are required"
                                                 })]]
          end

          begin
            # Verify credentials against Decko card
            client_data = self.class.client_cards.verify_client(
              client_id: client_id,
              client_secret: client_secret
            )

            self.class.rate_limiter&.reset(client_id)

            issue_token_response(client_data, headers)
          rescue Hyperon::Wiki::Mcp::OAuth::ClientCards::ClientError => e
            self.class.rate_limiter&.record_failure(client_id)

            [401, headers, [JSON.generate({
                                            error: "invalid_client",
                                            error_description: e.message
                                          })]]
          end
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        def handle_refresh_token(params, headers, _session_id)
          refresh_token = params["refresh_token"]

          unless self.class.oauth_enabled? && refresh_token
            return [400, headers, [JSON.generate({
                                                   error: "invalid_request",
                                                   error_description: "refresh_token is required"
                                                 })]]
          end

          token_data = self.class.credential_store.consume_refresh_token(refresh_token)
          unless token_data
            return [401, headers, [JSON.generate({
                                                   error: "invalid_grant",
                                                   error_description: "Refresh token is invalid or expired"
                                                 })]]
          end

          # Re-issue tokens using stored credentials
          issue_token_response(token_data, headers)
        end

        # Fail-closed response for token requests made when OAuth components are
        # not initialized. The server previously issued a long-lived
        # "public-access" Bearer token here; if OAuth ever failed to initialize
        # that became an unauthenticated path to the default identity. Refuse now.
        def oauth_unavailable_response(headers)
          [503, headers, [JSON.generate({
                                          error: "server_error",
                                          error_description: "OAuth is not configured on this server"
                                        })]]
        end

        # RFC 7009 - Token Revocation
        def handle_revoke(request, session_id)
          headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)
          params = parse_token_params(request)
          token = params["token"]

          self.class.credential_store.revoke_token(token) if token && self.class.oauth_enabled?

          # Always return 200 per RFC 7009
          [200, headers, [JSON.generate({ status: "revoked" })]]
        end

        # Handle MCP JSON-RPC messages with optional Bearer auth
        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def handle_mcp_message(request, env, session_id)
          # For /messages endpoint, extract session_id from query param (old SSE transport)
          if request.path == "/messages" || request.path.start_with?("/messages?")
            query_session_id = request.params["session_id"]
            if query_session_id && self.class.session_manager.exists?(query_session_id)
              session_id = query_session_id
            elsif query_session_id
              headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)
              return [404, headers, [JSON.generate({
                                                     jsonrpc: "2.0",
                                                     id: nil,
                                                     error: { code: -32001, message: "Session not found",
                                                              data: { session_id: query_session_id } }
                                                   })]]
            end
          end

          begin
            body = request.body.read

            # Handle empty POST body BEFORE auth check — ChatGPT sends empty POST
            # as a connectivity probe before it has a token. Returning 401 here
            # causes ChatGPT to abort the MCP connection entirely.
            if body.nil? || body.strip.empty?
              accept = env["HTTP_ACCEPT"] || ""
              if accept.include?("text/event-stream")
                # Client wants SSE notification channel — return SSE stream
                return handle_sse(session_id)
              end

              # Return server info for empty POST probe
              headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)
              return [200, headers, [JSON.generate({
                                                      jsonrpc: "2.0",
                                                      id: nil,
                                                      result: {
                                                        protocolVersion: "2025-06-18",
                                                        serverInfo: {
                                                          name: "hyperon",
                                                          version: Hyperon::Wiki::Mcp::VERSION
                                                        }
                                                      }
                                                    })]]
            end

            # Resolve the Bearer token to the principal it names: the session's
            # per-user Tools plus the identity the signature covered.
            principal = resolve_bearer_principal(env)

            # Fail closed: a request without a valid per-user token is rejected
            # unless it is a trusted same-box caller (localhost origin + shared
            # secret). This is independent of OAUTH_REQUIRE_AUTH / oauth_enabled?
            # so a missing or degraded OAuth stack can never widen external
            # access to the default identity.
            if principal.nil? && !self.class.trusted_local_caller?(env)
              issuer_url = self.class.oauth_issuer_url
              headers = add_mcp_headers({
                                          "Content-Type" => "application/json",
                                          "WWW-Authenticate" => "Bearer resource_metadata=" \
                                                                "\"#{issuer_url}/.well-known/oauth-protected-resource\""
                                        }, session_id)
              return [401, headers, [JSON.generate({
                                                     jsonrpc: "2.0",
                                                     id: nil,
                                                     error: { code: -32001, message: "Authentication required" }
                                                   })]]
            end

            request_data = JSON.parse(body, symbolize_names: true)

            response = if principal
                         # The context is built per request, from this
                         # principal's own grant read, and may be nil when no
                         # grant backs it -- see #build_request_context for why
                         # that absence is the fail-closed answer rather than a
                         # refusal.
                         handle_with_user_tools(request_data, principal.tools,
                                                request_context: build_request_context(principal))
                       else
                         handle_with_default_context(request_data)
                       end

            headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)
            status_code = request.path == "/messages" || request.path.start_with?("/messages?") ? 202 : 200
            [status_code, headers, [JSON.generate(response)]]
          rescue JSON::ParserError => e
            error_response = {
              jsonrpc: "2.0",
              id: nil,
              error: { code: -32700, message: "Parse error", data: e.message }
            }
            headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)
            [400, headers, [JSON.generate(error_response)]]
          rescue StandardError => e
            error_response = {
              jsonrpc: "2.0",
              id: request_data&.dig(:id),
              error: { code: -32603, message: "Internal error", data: e.message }
            }
            headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)
            [500, headers, [JSON.generate(error_response)]]
          end
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        def handle_session_delete(incoming_session_id, session_id)
          self.class.session_manager.delete(incoming_session_id) if incoming_session_id
          headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)
          [200, headers, [JSON.generate({ status: "session closed" })]]
        end

        # rubocop:disable Metrics/MethodLength
        def handle_root(env, session_id)
          accept_header = env["HTTP_ACCEPT"] || ""

          if accept_header.include?("text/event-stream")
            headers = add_mcp_headers({
                                        "Content-Type" => "text/event-stream",
                                        "Cache-Control" => "no-cache",
                                        "X-Accel-Buffering" => "no"
                                      }, session_id)
            [200, headers, SSEStreamer.new(session_id)]
          else
            headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)
            [200, headers, [JSON.generate({
                                            name: "hyperon-mcp",
                                            version: Hyperon::Wiki::Mcp::VERSION,
                                            protocol: "mcp",
                                            protocol_version: "2025-03-26",
                                            transport: "streamable-http",
                                            transports_supported: %w[streamable-http sse],
                                            endpoints: {
                                              health: "/health",
                                              mcp: "/mcp",
                                              sse: "/sse",
                                              messages: "/messages",
                                              message: "/message"
                                            },
                                            tools_count: self.class.mcp_server_instance.tools.length
                                          })]]
          end
        end
        # rubocop:enable Metrics/MethodLength

        # --- Authorization Code + PKCE flow ---

        # GET /authorize - render login page
        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        def handle_authorize_get(request, session_id)
          params = request.params
          response_type = params["response_type"]
          client_id = params["client_id"]
          code_challenge = params["code_challenge"]
          code_challenge_method = params["code_challenge_method"]

          # Validate required OAuth params
          unless response_type == "code" && client_id && code_challenge && code_challenge_method == "S256"
            headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)
            return [400, headers, [JSON.generate({
                                                   error: "invalid_request",
                                                   error_description: "Missing or invalid OAuth parameters. " \
                                                                      "Required: response_type=code, client_id, " \
                                                                      "code_challenge, code_challenge_method=S256"
                                                 })]]
          end

          # Look up client name from DCR registration
          client_name = "MCP Client"
          if self.class.oauth_enabled?
            registered = self.class.credential_store.get_registered_client(client_id)
            client_name = registered[:client_name] if registered
          end

          # Render login page with OAuth params as hidden fields
          oauth_params = {
            response_type: response_type,
            client_id: client_id,
            redirect_uri: params["redirect_uri"],
            code_challenge: code_challenge,
            code_challenge_method: code_challenge_method,
            state: params["state"],
            scope: params["scope"]
          }

          html = Hyperon::Wiki::Mcp::OAuth::LoginPage.render(
            params: oauth_params,
            client_name: client_name
          )

          headers = add_mcp_headers({ "Content-Type" => "text/html" }, session_id)
          [200, headers, [html]]
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

        # POST /authorize - authenticate user and redirect with auth code
        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def handle_authorize_post(request, session_id)
          params = request.params
          email = params["email"]
          password = params["password"]
          redirect_uri = params["redirect_uri"]
          client_id = params["client_id"]
          state = params["state"]
          code_challenge = params["code_challenge"]
          code_challenge_method = params["code_challenge_method"]

          # Validate redirect_uri is present
          unless redirect_uri && !redirect_uri.empty?
            headers = add_mcp_headers({ "Content-Type" => "application/json" }, session_id)
            return [400, headers, [JSON.generate({
                                                   error: "invalid_request",
                                                   error_description: "redirect_uri is required"
                                                 })]]
          end

          # Authenticate with Decko
          role = authenticate_with_decko(email, password)
          unless role
            # Auth failed - re-render login page with error
            oauth_params = {
              response_type: params["response_type"],
              client_id: client_id,
              redirect_uri: redirect_uri,
              code_challenge: code_challenge,
              code_challenge_method: code_challenge_method,
              state: state,
              scope: params["scope"]
            }

            client_name = "MCP Client"
            if self.class.oauth_enabled?
              registered = self.class.credential_store.get_registered_client(client_id)
              client_name = registered[:client_name] if registered
            end

            html = Hyperon::Wiki::Mcp::OAuth::LoginPage.render(
              params: oauth_params,
              error: "Invalid email or password. Please try again.",
              client_name: client_name
            )
            headers = add_mcp_headers({ "Content-Type" => "text/html" }, session_id)
            return [200, headers, [html]]
          end

          # Generate authorization code and store it
          code = SecureRandom.urlsafe_base64(32)
          if self.class.oauth_enabled?
            self.class.credential_store.store_auth_code(
              code,
              client_id: client_id,
              redirect_uri: redirect_uri,
              code_challenge: code_challenge,
              code_challenge_method: code_challenge_method,
              scope: params["scope"],
              username: email,
              password: password,
              role: role
            )
          end

          # 302 redirect back to the client with the auth code
          redirect_params = { code: code }
          redirect_params[:state] = state if state && !state.empty?
          location = build_redirect_url(redirect_uri, redirect_params)

          headers = add_mcp_headers({ "Location" => location }, session_id)
          [302, headers, []]
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        # Handle authorization_code grant type in token endpoint
        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def handle_authorization_code_grant(params, headers, _session_id)
          code = params["code"]
          code_verifier = params["code_verifier"]
          client_id = params["client_id"]
          redirect_uri = params["redirect_uri"]

          unless self.class.oauth_enabled?
            return [400, headers, [JSON.generate({
                                                   error: "server_error",
                                                   error_description: "OAuth is not configured"
                                                 })]]
          end

          unless code && code_verifier
            return [400, headers, [JSON.generate({
                                                   error: "invalid_request",
                                                   error_description: "code and code_verifier are required"
                                                 })]]
          end

          # Consume the auth code (single-use)
          code_data = self.class.credential_store.consume_auth_code(code)
          unless code_data
            return [400, headers, [JSON.generate({
                                                   error: "invalid_grant",
                                                   error_description: "Authorization code is invalid or expired"
                                                 })]]
          end

          # Validate client_id and redirect_uri match
          if code_data[:client_id] != client_id
            return [400, headers, [JSON.generate({
                                                   error: "invalid_grant",
                                                   error_description: "client_id does not match"
                                                 })]]
          end

          if code_data[:redirect_uri] != redirect_uri
            return [400, headers, [JSON.generate({
                                                   error: "invalid_grant",
                                                   error_description: "redirect_uri does not match"
                                                 })]]
          end

          # Verify PKCE
          unless Hyperon::Wiki::Mcp::OAuth::PkceVerifier.verify(
            code_verifier: code_verifier,
            code_challenge: code_data[:code_challenge],
            method: code_data[:code_challenge_method] || "S256"
          )
            return [400, headers, [JSON.generate({
                                                   error: "invalid_grant",
                                                   error_description: "PKCE verification failed"
                                                 })]]
          end

          # Issue tokens using stored credentials
          issue_token_response(code_data, headers)
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        # Authenticate a user against Decko and return their role.
        # Forces a token fetch to validate credentials against Decko API.
        #
        # @param email [String] Decko email
        # @param password [String] Decko password
        # @return [String, nil] role string or nil if auth failed
        def authenticate_with_decko(email, password)
          return nil if blank?(email) || blank?(password)

          # Use default role so Config omits it from the auth payload,
          # letting Decko auto-detect the user's highest role.
          tools = create_user_tools(email, password, "user")
          # Force token fetch to validate credentials against Decko
          tools.client.auth.token
          # Read the role that Decko actually assigned (from the auth response),
          # not the role we requested.
          tools.client.auth.resolved_role || "user"
        rescue StandardError
          nil
        end

        # Check if a string is nil or empty
        def blank?(str)
          str.nil? || str.empty?
        end

        # Build a redirect URL with query parameters
        #
        # @param base_url [String] the base redirect URI
        # @param params [Hash] query parameters to append
        # @return [String] the full redirect URL
        def build_redirect_url(base_url, params)
          uri = URI.parse(base_url)
          existing_params = URI.decode_www_form(uri.query || "")
          params.each { |k, v| existing_params << [k.to_s, v.to_s] }
          uri.query = URI.encode_www_form(existing_params)
          uri.to_s
        end

        # --- Helper methods ---

        # Parse request body as JSON (with fallback for empty body)
        def parse_request_body(request)
          body = request.body.read
          return {} if body.nil? || body.empty?

          JSON.parse(body)
        rescue JSON::ParserError
          {}
        end

        # Parse token endpoint params from form-encoded or JSON body
        def parse_token_params(request)
          content_type = request.content_type || ""

          if content_type.include?("application/x-www-form-urlencoded")
            # Standard OAuth form encoding
            request.params
          else
            # JSON body (also common with MCP clients)
            parse_request_body(request)
          end
        end

        # Issue a new token pair and cache the Tools instance
        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        def issue_token_response(client_data, headers)
          new_session_id = SecureRandom.uuid
          username = client_data[:username]
          password = client_data[:password]
          role = client_data[:role]

          # ONE source for the scope, computed before the token is signed.
          #
          # This used to be derived AFTER issuing, and only for the response body:
          # the signed token said nothing about scope at all, so the body and the
          # credential described different grants and only the unverifiable half
          # carried the scope. Computing it once and signing it (INTEGRATION.md
          # step 1) means a resource server reads the same answer the client was
          # told, from material the signature covers.
          #
          # Role-derived, and the client's REQUESTED scope is deliberately not
          # consulted: honouring it would let a caller assert its own grant, which
          # is exactly what Auth#scopes refuses to read from an untrusted source.
          scope = scope_for_role(role)

          # Issue access token
          access_token = self.class.token_issuer.issue(
            sub: username,
            role: role,
            session_id: new_session_id,
            scope: scope
          )

          # Issue refresh token
          refresh_token = SecureRandom.uuid
          self.class.credential_store.store_refresh_token(
            refresh_token,
            session_id: new_session_id,
            username: username,
            password: password,
            role: role
          )

          # Create per-user Tools instance and cache it
          tools = create_user_tools(username, password, role)
          self.class.credential_store.store_session(
            new_session_id,
            username: username,
            role: role,
            tools: tools
          )

          [200, headers, [JSON.generate({
                                          access_token: access_token,
                                          token_type: "Bearer",
                                          expires_in: self.class.token_issuer.ttl,
                                          refresh_token: refresh_token,
                                          scope: scope
                                        })]]
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

        # The scope a role is issued, as this server has always mapped it.
        #
        # Unchanged policy, moved to one place so the signed claim and the response
        # body cannot drift apart. It says nothing about mcp:atomspace:read: that
        # scope is granted by McpApi::AtomspaceGrants (deck repo, POLICY REV4) and
        # signed into the DECK's token that Auth#read_grant reads, not into the
        # gem's own inbound credential. mcp:admin is likewise a separate scope and
        # is never implied by a read scope.
        def scope_for_role(role)
          case role
          when "admin" then "mcp:admin"
          when "gm" then "mcp:write"
          else "mcp:read"
          end
        end

        # Create a Tools instance for a specific user
        def create_user_tools(username, password, role)
          # Set up per-user env vars temporarily for Config
          original_env = {
            "MCP_USERNAME" => ENV.fetch("MCP_USERNAME", nil),
            "MCP_PASSWORD" => ENV.fetch("MCP_PASSWORD", nil),
            "MCP_ROLE" => ENV.fetch("MCP_ROLE", nil)
          }

          ENV["MCP_USERNAME"] = username
          ENV["MCP_PASSWORD"] = password
          ENV["MCP_ROLE"] = role

          Hyperon::Wiki::Mcp::Tools.new
        ensure
          # Restore original env
          original_env.each do |key, val|
            if val
              ENV[key] = val
            else
              ENV.delete(key)
            end
          end
        end

        # Extract and verify a Bearer token, returning the principal it names
        # or nil.
        #
        # Returns the whole resolved principal rather than just its Tools,
        # because what the request may do is decided from the claims the
        # SIGNATURE covered and from the session those claims named -- the
        # token's jti, which is the key the credential store filed the session
        # under. A caller that kept only the Tools would have to re-derive the
        # identity from somewhere else, and the only other sources are an
        # unverified decode or a guess.
        def resolve_bearer_principal(env)
          return nil unless self.class.oauth_enabled?

          auth_header = env["HTTP_AUTHORIZATION"]
          return nil unless auth_header&.start_with?("Bearer ")

          token = auth_header[7..]
          return nil if token == "public-access" # Skip legacy public token

          claims = verify_access_token(token)
          return nil unless claims

          session_principal(claims)
        end

        # nil rather than a raised error: an unverifiable token is simply not a
        # principal, and the caller's fail-closed gate turns that into a 401.
        def verify_access_token(token)
          self.class.token_issuer.verify(token)
        rescue Hyperon::Wiki::Mcp::OAuth::TokenIssuer::TokenError
          nil
        end

        def session_principal(claims)
          session_id = claims["jti"]
          session = self.class.credential_store.get_session(session_id)
          tools = session&.dig(:tools)
          return nil unless tools

          BearerPrincipal.new(tools: tools, session_id: session_id, verified_claims: claims)
        end

        # Build the RequestContext one authenticated request runs under, or nil
        # when no grant backs it.
        #
        # The grant is read through THIS principal's own Auth -- the per-user
        # Tools' client -- so the capture describes the credential this request
        # will send outbound, not the server's default identity. Nothing else
        # on the request can be asked: the claims say who is calling, only a
        # deck read says what they currently hold.
        #
        # No required scope is named. Auth#read_grant records the caller's
        # scope intent and nothing more -- the capture is scope-agnostic, and
        # the decision is applied later by
        # GrantReadResult#authorization_valid_now? -- so passing nil states
        # that this seam makes no scope demand yet rather than inventing one no
        # policy has chosen.
        #
        # Returns nil, not a refusal, when the grant did not verify: this seam
        # plumbs capture and decides nothing. A consumer reads the ABSENCE of a
        # context as "nothing was authorized" -- never as permission -- and
        # refusing the request belongs to whichever slice enforces a scope.
        #
        # Runs BEFORE the dispatch lock is taken and outside the dispatch
        # deadline, deliberately. The budget exists to bound how long the lock
        # is HELD (see #with_dispatch_deadline), so arming it around this read
        # would spend the dispatch's budget before the dispatch owned the lock;
        # a slow read here delays only this request and blocks no other
        # session.
        def build_request_context(principal)
          grant = read_principal_grant(principal)
          return nil unless grant&.verification_status == :verified && grant.credential_ref

          Hyperon::Wiki::Mcp::RequestContext.new(
            principal_kind: :authenticated_session,
            session_id: principal.session_id,
            verified_inbound_claims: principal.verified_claims,
            grant_read_result: grant,
            outbound_credential_ref: grant.credential_ref,
            grant_source: :deck_verified_token,
            local_trusted: false,
            # Per dispatch, not per session: a session serves many requests,
            # so only a fresh id can tie one grant read to the one request
            # that acted on it.
            request_id: SecureRandom.uuid
          )
        end

        # A grant read that cannot complete leaves the request with no context,
        # the same fail-closed answer as one that does not verify. Scoped to
        # the read alone: construction below is guarded by explicit checks, and
        # swallowing errors from it would hide a contract bug as a missing
        # context.
        def read_principal_grant(principal)
          principal.tools.client.auth.read_grant(required_scope: nil)
        rescue StandardError
          nil
        end

        # Build a JWK (JSON Web Key) from an RSA public key
        def build_jwk(pub_key)
          key_data = pub_key.public_key
          n = key_data.n
          e = key_data.e
          kid = OpenSSL::Digest::SHA256.hexdigest(key_data.to_der)[0..15]

          {
            kty: "RSA",
            use: "sig",
            alg: "RS256",
            kid: kid,
            n: base64url_encode(n.to_s(2)),
            e: base64url_encode(e.to_s(2))
          }
        end

        # Base64url encode without padding (per RFC 7515)
        def base64url_encode(data)
          Base64.urlsafe_encode64(data, padding: false)
        end

        # Handle MCP request with per-user Tools (thread-safe context swap).
        # A caller-supplied RequestContext is carried in the swapped context
        # as-is and dropped with it on restore; without one, the key is
        # omitted rather than set to nil.
        #
        # The server's own context is restored even when handle raises: the
        # caller turns that error into a 500 and keeps serving, so a skipped
        # restore would hand the next request this one's tools and context.
        def handle_with_user_tools(request_data, per_user_tools, request_context: nil)
          mcp_server = self.class.mcp_server_instance

          DISPATCH_LOCK.synchronize do
            with_dispatch_deadline do
              original_context = mcp_server.server_context
              working_dir = original_context&.dig(:working_directory) || Dir.pwd
              request_server_context = { magi_tools: per_user_tools, working_directory: working_dir }
              request_server_context[:request_context] = request_context if request_context
              begin
                mcp_server.server_context = request_server_context
                mcp_server.handle(request_data)
              ensure
                mcp_server.server_context = original_context
              end
            end
          end
        end

        # Handle MCP request under the server's own (default-identity)
        # context. Takes the same lock as every per-user swap, so it can never
        # be served under one.
        def handle_with_default_context(request_data)
          DISPATCH_LOCK.synchronize do
            with_dispatch_deadline { self.class.mcp_server_instance.handle(request_data) }
          end
        end

        # Arm the total outbound budget for the duration of one dispatch.
        #
        # INSIDE the lock, not around it. The budget exists to bound how long
        # the lock is HELD, so it must start when this request owns the lock
        # rather than when it started queueing -- otherwise a request that
        # waited behind a slow one would arrive with its budget already spent
        # and fail without having made a single call.
        #
        # This is the ONLY place the deadline is armed, which is what keeps it
        # server-dispatch-only: the stdio entrypoints and every CLI or batch
        # caller share the same Client, Auth, and Tools, run no lock, block
        # nobody, and keep their long-tail retries untouched.
        #
        # What the budget bounds and what it does not -- a trickling peer and
        # Tools#upload_from_url's own Net::HTTP timeouts are outside it -- is
        # spelled out on DispatchDeadline, along with why the budget is total
        # rather than per-attempt, and why 15s.
        def with_dispatch_deadline(&)
          Hyperon::Wiki::Mcp::DispatchDeadline.arm(&)
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end
