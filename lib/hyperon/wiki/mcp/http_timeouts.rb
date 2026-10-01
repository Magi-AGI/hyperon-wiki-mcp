# frozen_string_literal: true

require "http"

module Hyperon
  module Wiki
    module Mcp
      # The single timeout policy for every outbound Decko HTTP call.
      #
      # WHY THIS IS A CONTRACT, NOT A TUNING DETAIL
      #
      # http.rb applies NO timeout by default. A Decko socket that accepts the
      # connection and then never answers blocks the calling thread forever --
      # not slowly, permanently. Every outbound call in this gem is reachable
      # from inside RackApp::DISPATCH_LOCK (tool dispatch -> Client#request ->
      # Auth#token -> #fetch_token, the verification path -> #fetch_jwks, and
      # the health/ping/backup tools), and that lock serializes EVERY MCP
      # dispatch. So one hung socket is not a slow request, it is a stalled
      # server: no other session can acquire the lock to make progress, and
      # nothing ever releases it. These budgets are the only thing that bounds
      # that stall.
      #
      # WHY ONE SHARED POLICY
      #
      # Auth and Client previously each spelled the same three numbers out
      # locally, which meant the parity between them could only be checked by
      # scraping one file's source from the other's spec. Owning the numbers
      # here makes that parity an identity instead of a coincidence: there is
      # one place to read the policy, one place to change it, and no second
      # budget that can drift. The module is deliberately neutral -- neither
      # Auth nor Client owns it -- so neither has to require the other to stay
      # bounded.
      module HttpTimeouts
        # Per-operation budgets for outbound Decko traffic.
        #
        # Per-operation rather than a single global budget on purpose: a global
        # timeout would also cap legitimate long reads, while these bound each
        # phase independently -- a dead connect fails in 5s, a stalled read in
        # 30s. The read budget is the generous one because it is the only one a
        # slow-but-working deployment actually needs; tightening it would start
        # failing such deployments, which is a policy change and not a fix.
        OUTBOUND = { connect: 5, write: 5, read: 30 }.freeze

        # A timeout-bounded HTTP client, ready to chain (.headers, .get, ...).
        #
        # Call sites should start from this rather than from HTTP directly:
        # `HTTP.get(url)` is unbounded and looks perfectly ordinary, so the
        # bounded builder being the obvious entry point is what keeps an
        # unbounded call from being reintroduced by accident.
        #
        # Built fresh per call rather than memoized: HTTP::Client carries
        # per-connection state and these call sites are reachable concurrently
        # (two sessions, or a verification path racing a refresh), so a shared
        # instance would be cross-thread mutable state for no gain --
        # `HTTP.timeout` only branches an options object.
        #
        # Callers need no new rescue: HTTP::TimeoutError and
        # HTTP::ConnectTimeoutError both descend from HTTP::Error, so an
        # expired budget surfaces through an existing `rescue HTTP::Error` and
        # fails closed like any other transport failure instead of escaping as
        # an unmapped error class.
        #
        # @return [HTTP::Client] a client carrying OUTBOUND's budgets
        def self.client
          HTTP.timeout(OUTBOUND)
        end
      end
    end
  end
end
