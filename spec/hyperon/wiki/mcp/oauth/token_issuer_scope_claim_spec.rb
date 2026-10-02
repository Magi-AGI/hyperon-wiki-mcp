# frozen_string_literal: true

require "spec_helper"
require "hyperon/wiki/mcp/oauth/token_issuer"

# The `scope` claim on the gem's OWN access token (INTEGRATION.md step 1).
#
# WHAT WAS WRONG. The issuer signed `role` and nothing else, while the OAuth token
# RESPONSE carried a `scope` string derived from that role. A client was therefore
# told one thing in the response body and handed a credential that asserted
# something narrower -- and a resource server reading only the signature could not
# see the scope at all. Step 1 closes that: an explicit, space-delimited `scope`
# claim inside the signature.
#
# WHICH TOKEN FAMILY THIS IS, because the gem has two and they must not be
# confused:
#   * THIS one -- OAuth::TokenIssuer -- signs the gem's own INBOUND access tokens
#     with the gem's own RSA key, and rack_app#verify_access_token verifies them.
#     It is what an MCP client presents as its Bearer credential.
#   * The OTHER one -- Auth#token -- is fetched from the DECK's /auth endpoint and
#     verified against the DECK's JWKS. Auth#scopes and Auth#read_grant read THAT
#     token's scope claim, which is decided and signed deck-side (POLICY REV4).
#
# So this claim does NOT feed Auth#read_grant and does NOT make
# `mcp:atomspace:read` reachable: that scope is the deck's to grant, and nothing
# here invents it. See the boundary examples at the bottom, which pin that
# absence rather than leaving it to be assumed.
#
# WHY SCOPE IS NOT DERIVED HERE. The issuer takes the scope it is given and signs
# it. Mapping a role to a scope inside the issuer would put authorization policy
# behind a signing key, where neither the deck (which owns grants) nor a reader of
# rack_app could see it. The caller decides; this signs.
#
# Local and offline: a generated RSA key, no JWKS, no network.
RSpec.describe Hyperon::Wiki::Mcp::OAuth::TokenIssuer, "scope claim" do
  let(:issuer_name) { "test-issuer" }
  let(:ttl) { 3600 }
  let(:token_issuer) { described_class.new(issuer: issuer_name, ttl: ttl) }

  def claims_for(**kwargs)
    token_issuer.verify(
      token_issuer.issue(sub: "user@example.com", role: "user", session_id: "sess-1", **kwargs)
    )
  end

  describe "a scope the caller supplies" do
    it "signs a single scope as a space-delimited string claim" do
      expect(claims_for(scope: "mcp:read")["scope"]).to eq("mcp:read")
    end

    it "signs several scopes as one space-delimited string" do
      expect(claims_for(scope: %w[mcp:read mcp:write])["scope"]).to eq("mcp:read mcp:write")
    end

    # RFC 6749 puts scope on the wire as a space-delimited string, and the deck
    # emits that shape too. Normalizing to it here means a reader never has to
    # handle two shapes for the same claim.
    it "normalizes a string carrying stray whitespace" do
      expect(claims_for(scope: "  mcp:read   mcp:write ")["scope"]).to eq("mcp:read mcp:write")
    end

    # A nil or non-String element joined blindly would sign an empty scope
    # between two separators -- a scope nobody granted. Same definition of
    # unusable the AtomSpace registry's resolve_required_scope already uses:
    # what a membership check can act on, not nil alone.
    it "drops array elements that no membership check could act on" do
      expect(claims_for(scope: ["mcp:read", nil, "", :mcp_write, "mcp:write"])["scope"])
        .to eq("mcp:read mcp:write")
    end
  end

  describe "a scope the caller does not supply" do
    # Absent, not empty. An empty claim is an assertion -- "this credential was
    # granted nothing" -- and an omitted one is the honest "no scope was decided
    # for this token". Both fail closed downstream (Auth#scopes answers [] either
    # way), but only absence stays truthful about what the signer knew.
    it "omits the claim entirely rather than signing an empty one" do
      claims = claims_for
      expect(claims).not_to have_key("scope")
    end

    it "omits the claim when given nil" do
      expect(claims_for(scope: nil)).not_to have_key("scope")
    end

    it "omits the claim when given a string with no scopes in it" do
      expect(claims_for(scope: "   ")).not_to have_key("scope")
    end

    it "omits the claim when given an array holding nothing usable" do
      expect(claims_for(scope: [nil, "", 7])).not_to have_key("scope")
    end

    it "omits the claim when given something that is neither string nor array" do
      expect(claims_for(scope: { mcp: "read" })).not_to have_key("scope")
    end
  end

  describe "what the claim does not change" do
    it "leaves the existing claims exactly as they were" do
      session_id = "sess-unchanged"
      claims = token_issuer.verify(
        token_issuer.issue(sub: "user@example.com", role: "gm", session_id: session_id,
                           scope: "mcp:write")
      )

      expect(claims["sub"]).to eq("user@example.com")
      expect(claims["role"]).to eq("gm")
      expect(claims["jti"]).to eq(session_id)
      expect(claims["iss"]).to eq(issuer_name)
      expect(claims["iat"]).to be_a(Integer)
      expect(claims["exp"]).to eq(claims["iat"] + ttl)
    end

    # The scope claim is an addition, not a replacement: role is still what the
    # credential store and the existing role checks read.
    it "keeps role even when a scope is signed" do
      expect(claims_for(role: "admin", scope: "mcp:admin")["role"]).to eq("admin")
    end

    it "still accepts the pre-existing keyword set with no scope at all" do
      expect { token_issuer.issue(sub: "a@b.test", role: "user", session_id: "s") }
        .not_to raise_error
    end
  end

  describe "the claim is an authorization input, so the signature must cover it" do
    # The whole point of moving scope out of the response body and into the token.
    # A scope a holder can edit is not a grant; this proves the signature is what
    # carries it.
    it "rejects a token whose scope claim was rewritten after signing" do
      token = token_issuer.issue(sub: "user@example.com", role: "user", session_id: "s",
                                 scope: "mcp:read")
      header, payload, signature = token.split(".")
      padding = "=" * (-payload.bytesize % 4)
      decoded = JSON.parse(Base64.urlsafe_decode64(payload + padding))
      expect(decoded["scope"]).to eq("mcp:read")
      decoded["scope"] = "mcp:admin"
      forged_payload = Base64.urlsafe_encode64(JSON.generate(decoded), padding: false)

      expect { token_issuer.verify([header, forged_payload, signature].join(".")) }
        .to raise_error(described_class::TokenError)
    end
  end

  describe "policy the issuer does not own" do
    # Role -> scope is rack_app's existing mapping and the deck's POLICY REV4 is
    # the authority on grants. An issuer that derived scope from role would hide
    # an authorization decision behind a signing key.
    it "does not derive a scope from the role" do
      expect(claims_for(role: "admin")).not_to have_key("scope")
      expect(claims_for(role: "gm")).not_to have_key("scope")
    end

    # mcp:atomspace:read is granted by McpApi::AtomspaceGrants (deck repo, POLICY
    # REV4) and signed into the DECK's token, which Auth#read_grant reads. Nothing
    # in this issuer may conjure it.
    it "never invents the AtomSpace read scope" do
      %w[user gm admin].each do |role|
        expect(claims_for(role: role).fetch("scope", "")).not_to include("mcp:atomspace:read")
      end
    end
  end
end
