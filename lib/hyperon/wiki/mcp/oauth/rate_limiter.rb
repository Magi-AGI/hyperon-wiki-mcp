# frozen_string_literal: true

module Hyperon
  module Wiki
    module Mcp
      module OAuth
        # In-memory rate limiter for the OAuth token endpoint
        #
        # Tracks failed authentication attempts per client_id and blocks
        # further attempts after exceeding the threshold within a time window.
        class RateLimiter
          DEFAULT_MAX_ATTEMPTS = 10
          DEFAULT_WINDOW_SECONDS = 300 # 5 minutes

          # @param max_attempts [Integer] maximum failed attempts before blocking
          # @param window_seconds [Integer] time window in seconds
          def initialize(max_attempts: DEFAULT_MAX_ATTEMPTS, window_seconds: DEFAULT_WINDOW_SECONDS)
            @max_attempts = max_attempts
            @window_seconds = window_seconds
            @failures = {}
            @mutex = Mutex.new
          end

          # Record a failed authentication attempt
          #
          # @param client_id [String] the client identifier
          def record_failure(client_id)
            return unless client_id

            @mutex.synchronize do
              cleanup_expired_entries
              @failures[client_id] ||= []
              @failures[client_id] << Time.now
            end
          end

          # Check if a client_id is currently rate limited
          #
          # @param client_id [String] the client identifier
          # @return [Boolean] true if rate limited
          def rate_limited?(client_id)
            return false unless client_id

            @mutex.synchronize do
              entries = @failures[client_id]
              return false unless entries

              # Count failures within the window
              cutoff = Time.now - @window_seconds
              recent = entries.count { |t| t > cutoff }
              recent >= @max_attempts
            end
          end

          # Reset failure count for a client (on successful auth)
          #
          # @param client_id [String] the client identifier
          def reset(client_id)
            return unless client_id

            @mutex.synchronize do
              @failures.delete(client_id)
            end
          end

          # Number of tracked clients
          #
          # @return [Integer]
          def tracked_count
            @mutex.synchronize { @failures.size }
          end

          private

          # Remove entries outside the time window (amortized cleanup)
          def cleanup_expired_entries
            cutoff = Time.now - @window_seconds
            @failures.each do |client_id, entries|
              entries.reject! { |t| t <= cutoff }
              @failures.delete(client_id) if entries.empty?
            end
          end
        end
      end
    end
  end
end
