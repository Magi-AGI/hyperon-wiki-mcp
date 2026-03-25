# frozen_string_literal: true

require "spec_helper"
require "hyperon/wiki/mcp/oauth/token_issuer"

RSpec.describe Hyperon::Wiki::Mcp::OAuth::TokenIssuer do
  let(:issuer) { "test-issuer" }
  let(:ttl) { 3600 }
  let(:token_issuer) { described_class.new(issuer: issuer, ttl: ttl) }

  describe "#initialize" do
    it "generates RSA key when none provided" do
      expect(token_issuer.public_key).to be_a(OpenSSL::PKey::RSA)
    end

    it "accepts an existing RSA key" do
      key = OpenSSL::PKey::RSA.generate(2048)
      issuer_with_key = described_class.new(signing_key: key, issuer: issuer)
      expect(issuer_with_key.public_key.to_pem).to eq(key.public_key.to_pem)
    end

    it "loads key from OAUTH_SIGNING_KEY env var" do
      key = OpenSSL::PKey::RSA.generate(2048)
      ENV["OAUTH_SIGNING_KEY"] = key.to_pem
      issuer_from_env = described_class.new(issuer: issuer)
      expect(issuer_from_env.public_key.to_pem).to eq(key.public_key.to_pem)
    ensure
      ENV.delete("OAUTH_SIGNING_KEY")
    end

    it "uses default issuer when not specified" do
      ENV.delete("OAUTH_ISSUER_URL")
      default_issuer = described_class.new
      expect(default_issuer.issuer).to eq("mcp.hyperon.dev")
    end

    it "uses OAUTH_ISSUER_URL env var for issuer" do
      ENV["OAUTH_ISSUER_URL"] = "https://custom.example.com"
      env_issuer = described_class.new
      expect(env_issuer.issuer).to eq("https://custom.example.com")
    ensure
      ENV.delete("OAUTH_ISSUER_URL")
    end

    it "uses default TTL when not specified" do
      ENV.delete("OAUTH_TOKEN_TTL")
      default_issuer = described_class.new(issuer: issuer)
      expect(default_issuer.ttl).to eq(3600)
    end
  end

  describe "#issue" do
    it "returns a JWT string" do
      token = token_issuer.issue(sub: "user@example.com", role: "user", session_id: "sess-123")
      expect(token).to be_a(String)
      expect(token.split(".").length).to eq(3)
    end

    it "includes correct claims" do
      session_id = "sess-#{SecureRandom.uuid}"
      token = token_issuer.issue(sub: "user@example.com", role: "gm", session_id: session_id)
      claims = token_issuer.verify(token)

      expect(claims["sub"]).to eq("user@example.com")
      expect(claims["role"]).to eq("gm")
      expect(claims["jti"]).to eq(session_id)
      expect(claims["iss"]).to eq(issuer)
      expect(claims["iat"]).to be_a(Integer)
      expect(claims["exp"]).to eq(claims["iat"] + ttl)
    end

    it "includes kid in JWT header" do
      token = token_issuer.issue(sub: "user@example.com", role: "user", session_id: "sess-123")
      header = JWT.decode(token, nil, false)[1]
      expect(header["kid"]).to be_a(String)
      expect(header["kid"].length).to eq(16)
    end
  end

  describe "#verify" do
    it "successfully verifies a valid token" do
      token = token_issuer.issue(sub: "user@example.com", role: "admin", session_id: "sess-456")
      claims = token_issuer.verify(token)

      expect(claims["sub"]).to eq("user@example.com")
      expect(claims["role"]).to eq("admin")
    end

    it "raises TokenError for expired token" do
      expired_issuer = described_class.new(issuer: issuer, ttl: -1)
      token = expired_issuer.issue(sub: "user@example.com", role: "user", session_id: "sess-789")

      expect { expired_issuer.verify(token) }
        .to raise_error(described_class::TokenError, /expired/i)
    end

    it "raises TokenError for token signed by different key" do
      other_issuer = described_class.new(issuer: issuer, ttl: ttl)
      token = other_issuer.issue(sub: "user@example.com", role: "user", session_id: "sess-aaa")

      expect { token_issuer.verify(token) }
        .to raise_error(described_class::TokenError)
    end

    it "raises TokenError for tampered token" do
      token = token_issuer.issue(sub: "user@example.com", role: "user", session_id: "sess-bbb")
      tampered = "#{token[0..-5]}XXXX"

      expect { token_issuer.verify(tampered) }
        .to raise_error(described_class::TokenError)
    end

    it "raises TokenError for wrong issuer" do
      other_issuer = described_class.new(
        signing_key: OpenSSL::PKey::RSA.generate(2048),
        issuer: "wrong-issuer",
        ttl: ttl
      )
      token = other_issuer.issue(sub: "user@example.com", role: "user", session_id: "sess-ccc")

      expect { token_issuer.verify(token) }
        .to raise_error(described_class::TokenError)
    end

    it "raises TokenError for invalid token string" do
      expect { token_issuer.verify("not.a.valid.token") }
        .to raise_error(described_class::TokenError)
    end
  end

  describe "#encryption_key" do
    it "returns a 32-byte key" do
      key = token_issuer.encryption_key
      expect(key).to be_a(String)
      expect(key.bytesize).to eq(32)
    end

    it "returns the same key on repeated calls" do
      expect(token_issuer.encryption_key).to eq(token_issuer.encryption_key)
    end

    it "returns different keys for different RSA keys" do
      other_issuer = described_class.new(issuer: issuer)
      expect(token_issuer.encryption_key).not_to eq(other_issuer.encryption_key)
    end
  end
end
