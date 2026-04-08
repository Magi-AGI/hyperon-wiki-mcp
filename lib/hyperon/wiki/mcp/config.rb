# frozen_string_literal: true

require "dotenv"

# Load .env from the gem root, not the process CWD.
# When MCP clients (Cursor, Claude Desktop, etc.) spawn the server,
# the CWD is typically NOT the project directory, so dotenv/load
# (which searches CWD) would silently fail to find the .env file.
_gem_root = File.expand_path("../../../../..", __FILE__)
Dotenv.load(File.join(_gem_root, ".env"))

module Hyperon
  module Wiki
    module Mcp
      # Configuration management for Hyperon Wiki MCP client
      #
      # Loads configuration from environment variables and provides
      # validation and defaults for all required settings.
      #
      # Two authentication methods supported:
      # 1. Username/Password (Recommended for human users)
      # 2. API Key (For service accounts/automation)
      #
      # Method 1: Username/Password
      # - MCP_USERNAME: Your Decko username
      # - MCP_PASSWORD: Your Decko password
      # - MCP_ROLE: Optional (will auto-determine from your permissions)
      #
      # Method 2: API Key
      # - MCP_API_KEY: API key for authentication with Decko
      # - MCP_ROLE: Required role scope (as defined in Decko)
      #
      # Common optional variables:
      # - DECKO_API_BASE_URL: Base URL for Decko API (default: https://wiki.hyperon.dev/api/mcp)
      # - JWT_ISSUER: Expected JWT issuer (default: hyperon)
      # - JWKS_CACHE_TTL: JWKS cache duration in seconds (default: 3600)
      #
      # @example Username/password configuration
      #   config = Hyperon::Wiki::Mcp::Config.new
      #   config.username # => "john_doe"
      #   config.auth_method # => :username
      #
      # @example API key configuration
      #   config = Hyperon::Wiki::Mcp::Config.new
      #   config.api_key # => "your-api-key"
      #   config.auth_method # => :api_key
      class Config
        # Configuration error raised when required settings are missing
        class ConfigurationError < StandardError; end

        # Valid authentication methods
        VALID_AUTH_METHODS = %i[username api_key].freeze

        # Default configuration values
        DEFAULTS = {
          base_url: "https://wiki.hyperon.dev/api/mcp",
          role: "user",
          issuer: "hyperon",
          jwks_cache_ttl: 3600,
          ssl_verify_mode: :peer  # :peer (strict), :none (disable), or OpenSSL constant
        }.freeze

        attr_reader :username, :password, :api_key, :base_url, :role, :issuer, :jwks_cache_ttl, :auth_method, :ssl_verify_mode

        # Initialize configuration from environment variables
        #
        # @raise [ConfigurationError] if required configuration is missing or invalid
        def initialize
          load_configuration
          determine_auth_method
          validate_configuration
        end

        # Get full URL for a given endpoint path
        #
        # @param path [String] the endpoint path (e.g., "/cards", "/auth")
        # @return [String] the full URL
        def url_for(path)
          path = path.delete_prefix("/")
          "#{base_url}/#{path}"
        end

        # Get authentication payload for token request
        #
        # Returns appropriate payload based on authentication method:
        # - Username/password: { username:, password:, role: (optional) }
        # - API key: { api_key:, role: (required) }
        #
        # @return [Hash] authentication parameters
        def auth_payload
          case auth_method
          when :username
            payload = {
              username: username,
              password: password
            }
            # Role is optional for username auth (auto-determined if not provided)
            payload[:role] = role if role && role != DEFAULTS[:role]
            payload
          when :api_key
            {
              api_key: api_key,
              role: role
            }
          else
            raise ConfigurationError, "Invalid auth method: #{auth_method}"
          end
        end

        # Check if using username/password authentication
        #
        # @return [Boolean] true if using username auth
        def username_auth?
          auth_method == :username
        end

        # Check if using API key authentication
        #
        # @return [Boolean] true if using API key auth
        def api_key_auth?
          auth_method == :api_key
        end

        private

        def load_configuration
          # Load credentials
          # MCP_PASS is an alias for MCP_PASSWORD to work around clients
          # that redact env vars matching *PASSWORD* patterns (e.g., Gemini CLI)
          @username = ENV.fetch("MCP_USERNAME", nil)
          @password = ENV.fetch("MCP_PASSWORD", nil) || ENV.fetch("MCP_PASS", nil)
          @api_key = ENV.fetch("MCP_API_KEY", nil)

          # Load common settings
          @base_url = ENV.fetch("DECKO_API_BASE_URL", DEFAULTS[:base_url])
          @role = ENV.fetch("MCP_ROLE", DEFAULTS[:role])
          @issuer = ENV.fetch("JWT_ISSUER", DEFAULTS[:issuer])
          @jwks_cache_ttl = ENV.fetch("JWKS_CACHE_TTL", DEFAULTS[:jwks_cache_ttl]).to_i

          # SSL configuration (optional, defaults to strict peer verification)
          ssl_mode = ENV.fetch("SSL_VERIFY_MODE", DEFAULTS[:ssl_verify_mode].to_s)
          @ssl_verify_mode = ssl_mode == "none" ? :none : :peer
        end

        def determine_auth_method
          # Determine which authentication method to use based on what's provided
          if username && password
            @auth_method = :username
          elsif api_key
            @auth_method = :api_key
          else
            @auth_method = nil # Will be caught in validation
          end
        end

        def validate_configuration
          # Validate auth method
          unless auth_method
            raise ConfigurationError,
                  "Must provide either (MCP_USERNAME + MCP_PASSWORD) or MCP_API_KEY"
          end

          # Validate credentials for chosen method
          case auth_method
          when :username
            if username.nil? || username.empty?
              raise ConfigurationError, "MCP_USERNAME is required for username authentication"
            end
            if password.nil? || password.empty?
              raise ConfigurationError, "MCP_PASSWORD is required for username authentication"
            end
            # Role is optional for username auth (will be auto-determined)
          when :api_key
            if api_key.nil? || api_key.empty?
              raise ConfigurationError, "MCP_API_KEY is required for API key authentication"
            end
            # Role is required for API key auth
            if role.nil? || role.empty?
              raise ConfigurationError, "MCP_ROLE is required when using API key authentication"
            end
          end
        end
      end
    end
  end
end
