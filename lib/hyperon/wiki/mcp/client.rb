# frozen_string_literal: true

require "http"
require "json"
require_relative "config"
require_relative "auth"
require_relative "dispatch_deadline"
require_relative "http_timeouts"

module Hyperon
  module Wiki
    module Mcp
      # HTTP client for Hyperon Wiki Decko API
      #
      # Provides authenticated HTTP access to the Decko MCP API with:
      # - Automatic JWT token management
      # - Role-based access enforcement
      # - Pagination support
      # - Error handling
      #
      # @example Basic usage
      #   client = Hyperon::Wiki::Mcp::Client.new
      #   cards = client.get("/cards", limit: 10)
      #   card = client.get("/cards/User")
      #
      # @example Creating a card
      #   client = Hyperon::Wiki::Mcp::Client.new
      #   client.post("/cards", name: "My Card", content: "Card content")
      class Client
        # API error raised when requests fail
        class APIError < StandardError
          attr_reader :status, :error_code, :details

          def initialize(message, status: nil, error_code: nil, details: nil)
            super(message)
            @status = status
            @error_code = error_code
            @details = details
          end
        end

        # Validation error (4xx responses)
        class ValidationError < APIError; end

        # Authentication error (401 responses)
        class AuthenticationError < APIError; end

        # Authorization error (403 responses)
        class AuthorizationError < APIError; end

        # Not found error (404 responses)
        class NotFoundError < APIError; end

        # Server error (5xx responses)
        class ServerError < APIError; end

        attr_reader :config, :auth

        # The timeout policy every outbound call in this class carries, shared
        # verbatim with Auth. Exposed as a constant so the budgets are
        # assertable directly rather than by scraping this file's source.
        HTTP_TIMEOUTS = HttpTimeouts::OUTBOUND

        # Initialize client with optional configuration
        #
        # @param config [Config, nil] optional config object (creates new one if nil)
        def initialize(config = nil)
          @config = config || Config.new
          @auth = Auth.new(@config)
        end

        # GET request to API endpoint
        #
        # @param path [String] the endpoint path
        # @param params [Hash] query parameters
        # @return [Hash, Array] the response data
        # @raise [APIError] if request fails
        def get(path, **params)
          request(:get, path, params: params)
        end

        # POST request to API endpoint
        #
        # @param path [String] the endpoint path
        # @param data [Hash] request body data
        # @return [Hash, Array] the response data
        # @raise [APIError] if request fails
        def post(path, **data)
          request(:post, path, json: data)
        end

        # PATCH request to API endpoint
        #
        # @param path [String] the endpoint path
        # @param data [Hash] request body data
        # @return [Hash, Array] the response data
        # @raise [APIError] if request fails
        def patch(path, **data)
          request(:patch, path, json: data)
        end

        # PUT request to API endpoint
        #
        # @param path [String] the endpoint path
        # @param data [Hash] data to send in the request body
        # @return [Hash, Array] the response data
        # @raise [APIError] if request fails
        def put(path, **data)
          request(:put, path, json: data)
        end

        # DELETE request to API endpoint
        #
        # @param path [String] the endpoint path
        # @return [Hash, Array] the response data
        # @raise [APIError] if request fails
        def delete(path)
          request(:delete, path)
        end

        # Health check - check if wiki is operational
        #
        # This is a lightweight endpoint that doesn't require authentication.
        # Checks database connectivity and basic card access.
        #
        # @return [Hash] health status with timestamp and component checks
        # @raise [APIError] if wiki is unreachable
        #
        # @example
        #   client.health_check
        #   # => { "status" => "healthy", "timestamp" => "2025-12-07T...", "checks" => {...} }
        def health_check
          url = config.url_for("/health")
          response = http_client.get(url, ssl_context: ssl_context)

          unless response.status.success?
            raise APIError.new("Health check failed", status: response.code)
          end

          JSON.parse(response.body.to_s)
        end

        # Ping - ultra-lightweight check
        #
        # Even faster than health_check - just verifies the server responds.
        # Doesn't check database or card access.
        #
        # @return [Hash] ping response with timestamp
        # @raise [APIError] if server doesn't respond
        #
        # @example
        #   client.ping
        #   # => { "status" => "ok", "timestamp" => "2025-12-07T..." }
        def ping
          url = config.url_for("/health/ping")
          response = http_client.get(url, ssl_context: ssl_context)

          unless response.status.success?
            raise APIError.new("Ping failed", status: response.code)
          end

          JSON.parse(response.body.to_s)
        end

        # Get authenticated Decko username
        #
        # Returns the username from the authentication response.
        # This is the Decko username (e.g., "Nemquae"), not the system username.
        #
        # @return [String, nil] the Decko username, or nil if not yet authenticated
        #
        # @example
        #   client.username
        #   # => "Nemquae"
        def username
          # Trigger authentication if not done yet
          auth.token unless auth.username
          auth.username
        end

        # GET request returning raw HTTP response (for file downloads)
        #
        # @param path [String] the endpoint path
        # @param params [Hash] query parameters
        # @return [HTTP::Response] the raw HTTP response
        # @raise [APIError] if request fails
        def get_raw(path, **params)
          url = config.url_for(path)
          token = auth.token

          headers = {
            "Authorization" => "Bearer #{token}"
          }

          response = http_client(headers).get(url, params: params, ssl_context: ssl_context)

          # Check for errors but return raw response
          case response.code
          when 200..299
            response
          when 400..499
            handle_client_error(response)
          when 500..599
            handle_server_error(response)
          else
            raise APIError, "Unexpected HTTP status: #{response.code}"
          end
        rescue HTTP::Error => e
          raise APIError, "HTTP request failed: #{e.message}"
        end

        # Make paginated GET request
        #
        # @param path [String] the endpoint path
        # @param limit [Integer] items per page (default: 50, max: 100)
        # @param offset [Integer] starting offset
        # @param params [Hash] additional query parameters
        # @return [Hash] response with :data, :total, :limit, :offset, :next_offset
        def paginated_get(path, limit: 50, offset: 0, **params)
          params[:limit] = [limit, 100].min
          params[:offset] = offset

          response = get(path, **params)

          {
            data: response["cards"] || response["types"] || response,
            total: response["total"],
            limit: response["limit"] || limit,
            offset: response["offset"] || offset,
            next_offset: response["next_offset"]
          }
        end

        # Fetch all pages of a paginated resource
        #
        # Under an armed DispatchDeadline (server dispatch only) the walk is
        # bounded by the budget, not by the page count: once it is spent the
        # shared HTTP seam refuses the next page and that refusal surfaces as
        # APIError. Raising rather than returning early is deliberate -- a
        # silently truncated walk looks like a complete one, and a caller that
        # wrote back a "full" list it never finished reading would do real
        # damage. Off the server path nothing is armed and the walk runs to
        # the end as it always has.
        #
        # @param path [String] the endpoint path
        # @param limit [Integer] items per page
        # @param params [Hash] additional query parameters
        # @yield [Array] each page of items
        # @return [Array] all items if no block given
        # @raise [APIError] if an armed dispatch budget expires mid-walk
        def each_page(path, limit: 50, **params)
          return enum_for(:each_page, path, limit: limit, **params) unless block_given?

          offset = 0
          loop do
            page = paginated_get(path, limit: limit, offset: offset, **params)
            items = page[:data]

            break if items.nil? || items.empty?

            yield items

            # Check if there are more pages
            break unless page[:next_offset]

            offset = page[:next_offset]
          end
        end

        # Fetch all items from a paginated resource
        #
        # @param path [String] the endpoint path
        # @param limit [Integer] items per page
        # @param params [Hash] additional query parameters
        # @return [Array] all items
        def fetch_all(path, limit: 50, **params)
          items = []
          each_page(path, limit: limit, **params) do |page|
            items.concat(page)
          end
          items
        end

        private

        # Make HTTP request with authentication and retry logic
        def request(method, path, params: nil, json: nil, retry_count: 0)
          response = dispatch(method, path, params: params, json: json)

          if should_retry?(response, retry_count) &&
             retry_after_backoff?(calculate_retry_delay(retry_count), retry_count, notice: "Retrying request after")
            return request(method, path, params: params, json: json, retry_count: retry_count + 1)
          end

          handle_response(response)
        rescue HTTP::Error => e
          # Retry on network errors -- but never on the seam's own refusal.
          # BudgetExhaustedError arrives here as an HTTP::Error like any other,
          # and retrying it would be incoherent: the budget that refused this
          # attempt cannot have grown, so the retry would sleep the backoff and
          # then be refused again at the same seam.
          if retryable_transport_error?(e, retry_count) &&
             retry_after_backoff?(calculate_retry_delay(retry_count), retry_count,
                                  notice: "Network error, retrying after")
            return request(method, path, params: params, json: json, retry_count: retry_count + 1)
          end

          report_transport_give_up(e, retry_count)
          raise APIError, "HTTP request failed: #{e.message}"
        end

        # Send one bounded attempt and hand back the raw response.
        #
        # Split out of #request so the retry policy there reads as policy. The
        # client comes from #http_client, which is the only outbound builder in
        # this class and the seam that refuses an attempt a spent server-dispatch
        # budget cannot pay for -- so an expired dispatch stops here, before a
        # socket is opened, rather than on the next retry decision.
        def dispatch(method, path, params: nil, json: nil)
          url = config.url_for(path)
          bounded = http_client(
            "Authorization" => "Bearer #{auth.token}",
            "Content-Type" => "application/json"
          )

          case method
          when :get then bounded.get(url, params: params, ssl_context: ssl_context)
          when :post then bounded.post(url, json: json, ssl_context: ssl_context)
          when :patch then bounded.patch(url, json: json, ssl_context: ssl_context)
          when :put then bounded.put(url, json: json, ssl_context: ssl_context)
          when :delete then bounded.delete(url, ssl_context: ssl_context)
          else raise ArgumentError, "Unsupported HTTP method: #{method}"
          end
        end

        # Whether a transport failure is worth another attempt.
        #
        # The seam's own refusal never is: the budget that refused this attempt
        # cannot have grown by the time a backoff ends, so retrying it would
        # sleep and then be refused again at the same place.
        def retryable_transport_error?(error, retry_count)
          return false if error.is_a?(HttpTimeouts::BudgetExhaustedError)

          retry_count < 3
        end

        # Sleep the backoff if the dispatch budget can pay for the retry, and
        # answer whether the next attempt may be made. Sleeps as a side effect
        # -- the question and the waiting are one decision, since the budget
        # that authorizes the wait is the same one the wait spends.
        #
        # Checked TWICE, which is the point. Before the sleep, because sleeping
        # the delay out and only then finding nothing left spends lock time to
        # learn nothing; and the check is #room_for_retry?, which charges the
        # backoff AND an attempt's worth of budget, because authorizing a sleep
        # for an attempt that cannot run is the same waste one step later.
        # After the sleep, because the pre-check is a prediction -- a real
        # sleep(1) can take rather longer than a second under load, and only
        # the clock afterwards knows what it actually cost. The recheck asks
        # the same question the pre-check asked (is there an attempt's worth
        # left?) rather than the weaker "is it expired?": a chain waking with
        # 0.4s left is not expired, but starting an attempt there buys a
        # floored socket allowance and no useful work.
        #
        # When no budget is armed -- every CLI, batch, and stdio caller -- both
        # checks are unconditionally true and this is exactly the retry that
        # has always run, same message, same delay.
        #
        # @return [Boolean] true when the caller should make the next attempt
        def retry_after_backoff?(retry_delay, retry_count, notice:)
          unless DispatchDeadline.room_for_retry?(retry_delay)
            report_refused_retry("before backoff")
            return false
          end

          $stderr.puts "#{notice} #{retry_delay}s (attempt #{retry_count + 1}/3)"
          sleep(retry_delay)

          return true if DispatchDeadline.room_for?(DispatchDeadline::MIN_ATTEMPT_SECONDS)

          report_refused_retry("after #{retry_delay}s backoff")
          false
        end

        # Say why the chain stopped retrying.
        #
        # Audible rather than silent: from the outside a bounded refusal and a
        # genuinely failing Decko look identical, and the operator question --
        # "did the request fail, or did we decline to make it?" -- is only
        # answerable from here. The remaining budget is included because its
        # sign distinguishes "ran out mid-chain" from "arrived with nothing".
        def report_refused_retry(stage)
          left = format("%.1f", DispatchDeadline.remaining.to_f)
          $stderr.puts "Dispatch budget exhausted #{stage}; not retrying (#{left}s left)"
        end

        # Say why a transport failure is being surfaced instead of retried.
        #
        # The response path logs when it gives up; this path raised APIError in
        # silence, so an exhausted retry chain, a refused dispatch, and a
        # single unretryable failure were indistinguishable in the logs. The
        # budget state is named explicitly because HttpTimeouts' refusal
        # arrives here as an HTTP::Error like any other and would otherwise
        # read as a network fault.
        def report_transport_give_up(error, retry_count)
          reason = if error.is_a?(HttpTimeouts::BudgetExhaustedError)
                     "dispatch budget exhausted"
                   elsif retry_count >= 3
                     "retries exhausted"
                   elsif DispatchDeadline.armed?
                     format("dispatch budget too small to retry (%.1fs left)", DispatchDeadline.remaining.to_f)
                   else
                     "not retryable"
                   end

          $stderr.puts "Giving up after #{retry_count + 1} attempt(s) (#{reason}): #{error.class}: #{error.message}"
        end

        # Handle HTTP response and errors
        def handle_response(response)
          case response.code
          when 200..299
            parse_response_body(response)
          when 400..499
            handle_client_error(response)
          when 500..599
            handle_server_error(response)
          else
            raise APIError, "Unexpected HTTP status: #{response.code}"
          end
        end

        # Parse response body as JSON
        def parse_response_body(response)
          return nil if response.body.to_s.empty?

          JSON.parse(response.body.to_s)
        rescue JSON::ParserError => e
          raise APIError, "Response parse failed: #{e.message}"
        end

        # Handle 4xx client errors
        def handle_client_error(response)
          data = parse_error_body(response)
          message = data["message"] || data["error"] || "Request failed"
          error_code = data["error"]
          details = data["details"]

          error_class = case response.code
                        when 401
                          AuthenticationError
                        when 403
                          AuthorizationError
                        when 404
                          NotFoundError
                        when 422
                          ValidationError
                        else
                          APIError
                        end

          raise error_class.new(
            message,
            status: response.code,
            error_code: error_code,
            details: details
          )
        end

        # Handle 5xx server errors
        def handle_server_error(response)
          data = parse_error_body(response)
          message = data["message"] || data["error"] || "Server error"

          raise ServerError.new(
            message,
            status: response.code,
            error_code: data["error"]
          )
        end

        # Parse error response body
        def parse_error_body(response)
          JSON.parse(response.body.to_s)
        rescue JSON::ParserError
          { "error" => "unknown", "message" => response.body.to_s }
        end

        # Check if request should be retried
        def should_retry?(response, retry_count)
          return false if retry_count >= 3 # Max 3 retries

          # Retry on rate limit (429) or server errors (5xx)
          response.code == 429 || response.code >= 500
        end

        # Calculate exponential backoff delay
        def calculate_retry_delay(retry_count)
          # Exponential backoff: 1s, 2s, 4s
          2**retry_count
        end

        # Build SSL context for HTTP requests (nil = default verification)
        def ssl_context
          return nil unless config.ssl_verify_mode == :none

          @ssl_context ||= begin
            require "openssl"
            ctx = OpenSSL::SSL::SSLContext.new
            ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
            ctx
          end
        end

        # Timeout-bounded HTTP client for this class's outbound calls.
        #
        # Every outbound call here goes through this rather than touching HTTP
        # directly. `HTTP.get(url)` reads as perfectly ordinary but carries NO
        # timeout, which is how #health_check, #ping, and #get_raw each ended
        # up unbounded while #request beside them was bounded; routing them all
        # through one builder is what keeps that from recurring.
        #
        # @param headers [Hash, nil] request headers, or nil for an
        #   unauthenticated call (#health_check and #ping hit public endpoints)
        # @return [HTTP::Client] a client carrying HTTP_TIMEOUTS' budgets
        def http_client(headers = nil)
          client = HttpTimeouts.client
          headers ? client.headers(headers) : client
        end
      end
    end
  end
end
