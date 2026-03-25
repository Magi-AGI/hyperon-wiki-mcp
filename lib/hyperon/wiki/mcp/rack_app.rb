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
            # Fallback: if no OAuth components or no grant_type, return public token
            # This preserves backward compatibility for clients that don't send credentials
            unless self.class.oauth_enabled?
              return [200, headers, [JSON.generate({
                                                     access_token: "public-access",
                                                     token_type: "Bearer",
                                                     expires_in: 31_536_000
                                                   })]]
            end

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

          unless self.class.oauth_enabled?
            return [200, headers, [JSON.generate({
                                                   access_token: "public-access",
                                                   token_type: "Bearer",
                                                   expires_in: 31_536_000
                                                 })]]
          end

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

            # Check Bearer token for per-user Tools
            per_user_tools = resolve_bearer_token(env)

            # If auth required but no valid token, reject
            if self.class.oauth_require_auth? && per_user_tools.nil? && self.class.oauth_enabled?
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

            response = if per_user_tools
                         handle_with_user_tools(request_data, per_user_tools)
                       else
                         self.class.mcp_server_instance.handle(request_data)
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

          # Issue access token
          access_token = self.class.token_issuer.issue(
            sub: username,
            role: role,
            session_id: new_session_id
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

          # Map role to scope
          scope = case role
                  when "admin" then "mcp:admin"
                  when "gm" then "mcp:write"
                  else "mcp:read"
                  end

          [200, headers, [JSON.generate({
                                          access_token: access_token,
                                          token_type: "Bearer",
                                          expires_in: self.class.token_issuer.ttl,
                                          refresh_token: refresh_token,
                                          scope: scope
                                        })]]
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

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

        # Extract and verify Bearer token, return per-user Tools or nil
        def resolve_bearer_token(env)
          return nil unless self.class.oauth_enabled?

          auth_header = env["HTTP_AUTHORIZATION"]
          return nil unless auth_header&.start_with?("Bearer ")

          token = auth_header[7..]
          return nil if token == "public-access" # Skip legacy public token

          begin
            claims = self.class.token_issuer.verify(token)
            session = self.class.credential_store.get_session(claims["jti"])
            session&.dig(:tools)
          rescue Hyperon::Wiki::Mcp::OAuth::TokenIssuer::TokenError
            nil
          end
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

        # Handle MCP request with per-user Tools (thread-safe context swap)
        def handle_with_user_tools(request_data, per_user_tools)
          mcp_server = self.class.mcp_server_instance

          # Thread-safe: swap server_context for this request
          @request_mutex ||= Mutex.new
          @request_mutex.synchronize do
            original_context = mcp_server.server_context
            working_dir = original_context&.dig(:working_directory) || Dir.pwd
            mcp_server.server_context = { magi_tools: per_user_tools, working_directory: working_dir }
            response = mcp_server.handle(request_data)
            mcp_server.server_context = original_context
            response
          end
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end
