# frozen_string_literal: true

require "time"
require_relative "http_timeouts"

module Hyperon
  module Wiki
    module Mcp
      # How long a rate-limited response has asked this client to wait, read
      # from Retry-After and reconciled with the client's own backoff.
      #
      # WHY A MODULE AND NOT A COUPLE OF METHODS ON CLIENT
      #
      # Everything here is a fact about reading a HEADER -- which forms RFC
      # 9110 defines, what an unreadable value means, what a peer may not be
      # allowed to ask for. Client's business is the retry POLICY: when to
      # retry at all, how many times, and whether the dispatch budget can pay
      # for the next attempt. Keeping the header reading out of that class
      # means the policy stays readable as policy, and this parsing is
      # assertable without constructing a retry chain to reach it.
      #
      # WHAT IS DELIBERATELY NARROW
      #
      #   * 429 ONLY. RFC 9110 permits Retry-After on 503 and on 3xx too, and
      #     honoring it there may well be an improvement, but 5xx retry timing
      #     is existing behavior nothing has asked to change -- and a Decko
      #     that sent a long Retry-After with a 503 would silently lengthen
      #     every server-error chain in the gem. Rate limiting is the case
      #     where the server genuinely knows something the client does not, so
      #     that is the case this honors.
      #   * A LOWER BOUND, never an upper one. .delay returns at least the
      #     caller's own backoff, so honoring the header cannot make any
      #     existing retry more aggressive. See .delay.
      #   * TWO FORMS, and nothing else. Anything this cannot parse means
      #     "nothing to honor" rather than a guessed number.
      module RetryAfter
        # The longest single wait this gem will take because a server asked
        # it to.
        #
        # Retry-After is a number the PEER chooses, so honoring it without a
        # ceiling hands a misconfigured or hostile Decko the ability to park a
        # caller for as long as it likes: `Retry-After: 86400` would turn one
        # request into a day-long sleep. Under a server dispatch
        # DispatchDeadline would refuse that anyway, but off the server path
        # there is no budget to refuse it with -- and that absence is
        # deliberate (see DispatchDeadline's WHY SERVER DISPATCH ONLY), so the
        # ceiling has to be stated here rather than borrowed from a deadline
        # that is not armed.
        #
        # 30s because that is the longest single outbound wait this gem
        # already accepts: HttpTimeouts::OUTBOUND[:read]. The analogy is not
        # exact and is not claimed to be -- a read timeout is an inactivity
        # window the peer can keep re-arming, not a planned sleep -- but it is
        # an existing tolerance rather than a fresh invention, and nothing
        # about waiting 30s because a server asked is worse than the 30s this
        # client will already spend waiting for that same server's bytes.
        MAX_SECONDS = HttpTimeouts::OUTBOUND.fetch(:read)

        class << self
          # The wait to take before retrying `response`, given the caller's
          # own backoff.
          #
          # NEVER SHORTER THAN `default`, which is the whole reason honoring
          # this header needs no retry-policy decision. Retry-After is a lower
          # bound -- RFC 9110 says a client should not retry BEFORE the stated
          # point, not that it must retry AT it -- so a server asking for 1s
          # when the backoff is already 4s is satisfied by waiting the 4s.
          # Taking the maximum honors the header while leaving every existing
          # delay exactly where it was: no retry becomes more aggressive, and
          # a response with no Retry-After gets `default` untouched.
          #
          # The cap applies to what the PEER asked for, before the maximum and
          # never to the result, so it can only shorten a peer's demand and
          # can never shorten the caller's own backoff. Floored with an
          # endless range rather than clamp(default, MAX_SECONDS) because a
          # two-argument clamp raises when its min exceeds its max, which a
          # future backoff longer than MAX_SECONDS would quietly arrange.
          #
          # @param response [HTTP::Response] the response about to be retried
          # @param default [Numeric] the backoff the caller would otherwise use
          # @return [Numeric] seconds to wait; `default` when there is nothing
          #   usable to honor
          def delay(response, default:)
            requested = requested(response)
            return default if requested.nil?

            [requested, MAX_SECONDS].min.clamp(default..)
          end

          # The wait this response explicitly asked for, uncapped.
          #
          # @param response [HTTP::Response] the response about to be retried
          # @return [Integer, nil] seconds, or nil when there is nothing
          #   usable to honor
          def requested(response)
            return nil unless response.code == 429

            # A repeated header arrives as an Array; take the first rather
            # than calling .to_s on the Array and parsing "[\"5\", \"9\"]" as
            # garbage.
            parse(Array(response.headers["Retry-After"]).first)
          end

          # Parse a Retry-After field value into seconds.
          #
          # Both forms RFC 9110 defines, and nothing else: delta-seconds (a
          # non-negative integer) or an HTTP-date. Anything else -- empty,
          # "soon", "-5", "1.5" -- returns nil, so the caller falls back to
          # its own backoff rather than acting on a number guessed out of a
          # field this cannot read. Silently, because a malformed header from
          # Decko is not actionable by the caller and the retry chain still
          # behaves correctly without it.
          #
          # @param value [String, nil] the raw field value
          # @return [Integer, nil] seconds, or nil when unparseable
          def parse(value)
            raw = value.to_s.strip
            return nil if raw.empty?
            return raw.to_i if /\A\d+\z/.match?(raw)

            from_http_date(raw)
          end

          private

          # Seconds from now until an HTTP-date Retry-After.
          #
          # WALL CLOCK, unavoidably: the header names an absolute civil time,
          # so the only clock that can be compared against it is Time.now,
          # even though DispatchDeadline is deliberately monotonic. The skew
          # that buys is bounded and harmless -- the DELTA computed here is
          # then spent and gated entirely in monotonic terms by Client's retry
          # gate, so a wall-clock step can mis-measure one backoff but cannot
          # move the deadline.
          #
          # Rounded UP and floored at zero: a date already in the past is "no
          # extra wait", which .delay turns back into the caller's own backoff
          # rather than into no wait at all.
          def from_http_date(raw)
            [(Time.httpdate(raw) - Time.now).ceil, 0].max
          rescue ArgumentError
            nil
          end
        end
      end
    end
  end
end
