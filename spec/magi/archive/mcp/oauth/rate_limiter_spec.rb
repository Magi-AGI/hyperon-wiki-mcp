# frozen_string_literal: true

require "spec_helper"
require "magi/archive/mcp/oauth/rate_limiter"

RSpec.describe Magi::Archive::Mcp::OAuth::RateLimiter do
  let(:limiter) { described_class.new(max_attempts: 3, window_seconds: 60) }

  describe "#rate_limited?" do
    it "returns false for unknown client" do
      expect(limiter.rate_limited?("unknown")).to be false
    end

    it "returns false when under the limit" do
      2.times { limiter.record_failure("client-1") }
      expect(limiter.rate_limited?("client-1")).to be false
    end

    it "returns true when at the limit" do
      3.times { limiter.record_failure("client-1") }
      expect(limiter.rate_limited?("client-1")).to be true
    end

    it "returns true when over the limit" do
      5.times { limiter.record_failure("client-1") }
      expect(limiter.rate_limited?("client-1")).to be true
    end

    it "handles nil client_id gracefully" do
      expect(limiter.rate_limited?(nil)).to be false
    end

    it "tracks clients independently" do
      3.times { limiter.record_failure("client-1") }
      2.times { limiter.record_failure("client-2") }

      expect(limiter.rate_limited?("client-1")).to be true
      expect(limiter.rate_limited?("client-2")).to be false
    end
  end

  describe "#record_failure" do
    it "handles nil client_id gracefully" do
      expect { limiter.record_failure(nil) }.not_to raise_error
    end
  end

  describe "#reset" do
    it "clears failure count on successful auth" do
      3.times { limiter.record_failure("client-1") }
      expect(limiter.rate_limited?("client-1")).to be true

      limiter.reset("client-1")
      expect(limiter.rate_limited?("client-1")).to be false
    end

    it "handles nil client_id gracefully" do
      expect { limiter.reset(nil) }.not_to raise_error
    end
  end

  describe "window expiry" do
    it "expires old failures outside the window" do
      limiter_short = described_class.new(max_attempts: 3, window_seconds: 0.01)

      3.times { limiter_short.record_failure("client-1") }
      expect(limiter_short.rate_limited?("client-1")).to be true

      sleep 0.02

      # After window expires, new failure shouldn't trigger limit
      limiter_short.record_failure("client-1")
      expect(limiter_short.rate_limited?("client-1")).to be false
    end
  end

  describe "#tracked_count" do
    it "returns number of tracked clients" do
      expect(limiter.tracked_count).to eq(0)

      limiter.record_failure("client-1")
      limiter.record_failure("client-2")
      expect(limiter.tracked_count).to eq(2)

      limiter.reset("client-1")
      expect(limiter.tracked_count).to eq(1)
    end
  end

  describe "thread safety" do
    it "handles concurrent access without errors" do
      threads = 10.times.map do |i|
        Thread.new do
          cid = "client-#{i % 3}"
          5.times do
            limiter.record_failure(cid)
            limiter.rate_limited?(cid)
          end
        end
      end

      expect { threads.each(&:join) }.not_to raise_error
    end
  end
end
